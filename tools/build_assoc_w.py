# -*- coding: utf-8 -*-
"""构建词级 n-gram 语言模型 assoc_w.bin —— 自研兜底引擎的「上下文项」升级版。

为什么做：
    旧 assoc.bin 是「字级 bigram」：只统计每个词内部的字对（今天/天气 是两个
    独立词，永远学不到 今天→天气 这种跨词搭配）。这正是自研兜底「切分准、越打越顺」
    不如百度的根。词级 n-gram 直接建模 词→词 接续，是 librime grammar / 百度引擎
    做对的那一项。

数据来源（全部合法可商用，离线可复现）：
    1) rime-ice 短语词典 base/ext/tencent/41448/8105 —— 社区开源方案，
       本就是从大规模语料提炼的高频词与短语，短语内部切分即真实词序；
    2) 项目策展表 hot_words / core_words / colloquial —— 口语/网络语/高频组合，
       补通用语料缺的聊天口癖与代词+动词搭配（我是/我要/虽然但是…）。

方法：
    把每条短语用 jieba 切词 → 词序列 → 按短语权重累加 词→词 共现计数 →
    归一成条件概率 P(后继词 | 前词) → 量化写入 ANWG v1。

格式（ANWG v2，紧凑 mmap 二进制，读取走二分+偏移，不整块进堆）：
    magic(4) + ver(1)='2' + entryCount(4) + keyOffTblPos(4) + valOffTblPos(4)
      + keyBlkPos(4) + valBlkPos(4)  = 25 字节头
    keyOffTbl / valOffTbl: 各 (N+1) 个 u32（绝对文件偏移）
    keyBlock: 前词 UTF-8 拼接
    valBlock: 每条后继 entry = [概率字节 1 字节][后继词 UTF8]，entry 之间用 0x01 分隔
概率字节 = log P(后继 | 前驱) 在 [LPMIN, 0] 上的线性量化（0x02..0xFF）。
注意：概率字节是原始单字节，绝不能与 UTF-8 文本混在同一字符串解码
（>=0x80 会被替换成 U+FFFD 而失真）。读取见 PinyinEngine.loadAssocW /
wlmValBlob / wlmParseEntry，走字节层解析。
"""
import importlib.util
import math
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
import tempfile
_ICE_TMP = os.path.join(tempfile.gettempdir(), "ice_inspect")
ICE_DIR = os.path.join(_ICE_TMP, "cn_dicts")                  # 预先解包的 rime-ice
DICT_DIR = os.path.join(HERE, "..", "Support", "dict")
OUT = os.path.join(DICT_DIR, "assoc_w.bin")

MAGIC = b"ANWG"
VER = b"2"                       # v2：紧凑 mmap 二进制（非文本），读取走二分+偏移，不整块进堆
SENT = "\u0001"                       # 短语边界哨兵（非 CJK，jieba 不会跨它成词）

# 量化参数（与 PinyinEngine 词级 LM 读取一一对应）
LPMIN = -10.0
REF = -3.0
WEIGHT = 0.35
TOPK = 24                            # 每个前词最多存多少后继
MIN_CTX = 5.0                         # 前词总共现低于此值则整行丢弃
MIN_PAIR = 2.0                        # 单条词对共现低于此值则丢弃

CJK = re.compile(r"^[\u4e00-\u9fff]+$")


def is_num(s):
    try:
        float(s)
        return True
    except ValueError:
        return False


def load_rime(path):
    """读 rime dict yaml：返回 [(短语, 权重), ...]。跳过注释/表头。"""
    out = []
    with open(path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.startswith("#") or line.startswith("---"):
                continue
            if "\t" not in line:
                continue
            fields = line.split("\t")
            word = fields[0].strip()
            if not word or not CJK.fullmatch(word):
                continue
            # 最后一字段若是数字即权重，否则默认 1
            last = fields[-1].strip()
            wt = float(last) if is_num(last) else 1.0
            out.append((word, wt))
    return out


def load_curated():
    """导入项目策展表，提取短语字符串列表。"""
    phrases = []
    def grab(modname, names):
        try:
            spec = importlib.util.spec_from_file_location(modname,
                                                         os.path.join(HERE, modname + ".py"))
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            for nm in names:
                obj = getattr(mod, nm, None)
                if obj is None:
                    continue
                for item in obj:
                    if isinstance(item, tuple):
                        w = item[0]
                    elif isinstance(item, str):
                        w = item
                    else:
                        continue
                    w = w.strip()
                    if w and CJK.fullmatch(w):
                        phrases.append((w, 100.0))   # 策展词权重高，钉住搭配
        except Exception as e:
            print("  策展表载入跳过:", modname, e)
    grab("hot_words", ["TOP", "COMBOS"])
    grab("core_words", ["CORE", "CORE_TOP"])
    grab("colloquial", ["COLLOQUIAL"])
    return phrases


def seg_and_count(phrases_w, bigram, unigram):
    """用 \u0001 哨兵把一批短语拼成大字符串，一次 jieba.cut 切完，
    按短语权重累加 词→词 共现。返回处理短语数。"""
    import jieba
    jieba.setLogLevel(60)  # 关掉 jieba 的 verbose 日志
    joined = SENT.join(w for w, _ in phrases_w)
    weights = [wt for _, wt in phrases_w]
    toks = list(jieba.cut(joined))
    idx = 0
    buf = []
    for t in toks:
        if t == SENT:
            # 冲刷当前短语的词序列
            for i in range(len(buf) - 1):
                a, b = buf[i], buf[i + 1]
                if a == b:
                    continue
                bigram[(a, b)] = bigram.get((a, b), 0.0) + weights[idx]
            unigram[buf[0]] = unigram.get(buf[0], 0.0) + weights[idx] if buf else None
            buf = []
            idx += 1
        else:
            buf.append(t)
    # 最后一段
    if buf and idx < len(weights):
        for i in range(len(buf) - 1):
            a, b = buf[i], buf[i + 1]
            if a != b:
                bigram[(a, b)] = bigram.get((a, b), 0.0) + weights[idx]
    return len(phrases_w)


def main():
    bigram = {}
    unigram = {}
    total = 0

    # 1) rime-ice 短语词典（base/ext/tencent 多字短语能切出词→词共现；
    #    41448/8105 是单字词表，切不出内部词对，跳过省时）
    rime_files = [
        "base.dict.yaml", "ext.dict.yaml", "tencent.dict.yaml",
    ]
    for fn in rime_files:
        p = os.path.join(ICE_DIR, fn)
        if not os.path.exists(p):
            print("  跳过（不存在）:", p)
            continue
        print("== 处理", fn, "==")
        ph = load_rime(p)
        print("  短语条数:", len(ph))
        total += seg_and_count(ph, bigram, unigram)

    # 2) 策展表
    cur = load_curated()
    print("== 策展短语:", len(cur), "==")
    total += seg_and_count(cur, bigram, unigram)

    print("总短语:", total, "原始词对:", len(bigram))

    # 归一并裁剪：扁平表 (a,b)->count 聚合成 a -> {b: count}（O(词对数)）
    rows = {}
    for (a, b), c in bigram.items():
        d = rows.get(a)
        if d is None:
            d = {}
            rows[a] = d
        d[b] = d.get(b, 0.0) + c
    del bigram

    # 按前词排序，量化每条后继为「后继词 + \x04 + 概率字节」
    items = []          # [(前词, 后继blob), ...]
    kept_pairs = 0
    for a in sorted(rows.keys()):
        row = rows[a]
        tot = sum(row.values())
        if tot < MIN_CTX:
            continue
        succ = []
        for b, v in sorted(row.items(), key=lambda kv: (-kv[1], kv[0]))[:TOPK]:
            if v < MIN_PAIR:
                continue
            lp = max(LPMIN, math.log(v / tot))
            code = 2 + int(round((lp - LPMIN) / (0 - LPMIN) * 253))
            code = max(2, min(255, code))
            succ.append(bytes([code]) + b.encode("utf-8"))
            kept_pairs += 1
        if succ:
            items.append((a, b"\x01".join(succ)))

    # 紧凑二进制格式（可 mmap，不整块读进堆 —— 键盘扩展内存硬约束）：
    #   magic(4) + ver(1) + entryCount(4) + keyOffTblPos(4) + valOffTblPos(4)
    #     + keyBlkPos(4) + valBlkPos(4)   = 25 字节头
    #   keyOffTbl: (N+1) 个 u32；valOffTbl: (N+1) 个 u32
    #   keyBlock: 前词字符串拼接（由 keyOff 定界）
    #   valBlock: 后继 blob 拼接（由 valOff 定界），blob 内 \x01 分隔
    key_block = b"".join(a.encode("utf-8") for a, _ in items)
    n = len(items)
    key_off, p = [], 0
    for a, _ in items:
        key_off.append(p)
        p += len(a.encode("utf-8"))
    key_off.append(p)
    val_off, p = [], 0
    for _, v in items:
        val_off.append(p)
        p += len(v)
    val_off.append(p)

    keyOffTblPos = 25
    valOffTblPos = keyOffTblPos + (n + 1) * 4
    keyBlkPos = valOffTblPos + (n + 1) * 4
    valBlkPos = keyBlkPos + len(key_block)
    # 偏移表存「绝对文件偏移」，与 Swift 读取端一致（PinyinEngine 直接拿作绝对切片起点）
    key_abs = [keyBlkPos + o for o in key_off]
    val_abs = [valBlkPos + o for o in val_off]
    header = (MAGIC + VER +
              struct.pack("<I", n) +
              struct.pack("<I", keyOffTblPos) +
              struct.pack("<I", valOffTblPos) +
              struct.pack("<I", keyBlkPos) +
              struct.pack("<I", valBlkPos))
    out = bytearray()
    out += header
    out += b"".join(struct.pack("<I", o) for o in key_abs)
    out += b"".join(struct.pack("<I", o) for o in val_abs)
    out += key_block
    out += b"".join(v for _, v in items)
    with open(OUT, "wb") as f:
        f.write(out)
    print("前词数:", n, "保留词对:", kept_pairs)
    print("输出:", OUT, os.path.getsize(OUT), "字节 (紧凑 mmap 格式)")


if __name__ == "__main__":
    main()
