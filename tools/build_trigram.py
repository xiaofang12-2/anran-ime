# -*- coding: utf-8 -*-
"""构建三元语言模型 assoc_t.bin（ANWT v1）—— 词级 trigram。

为什么需要它：
    assoc_w（bigram）分不出「虚词/同音」这类歧义，因为两项都「没见过」：
        wochayixiazaihuifuni → 我查一下**在**恢复你   （应为「再」）
        nixianbiezheji       → 你先别**这几**         （应为「着急」）
    二元信息到这里就断了 —— 「一下 → 在」和「一下 → 再」同样没有统计，
    罚分相同，只能由 unigram 决胜，而 unigram 里「在」比「再」常见得多。
    三元能看到「查 / 一下 / 再」这个组合，这是 commercial IME 拉开差距的地方。

数据来源（与 assoc_w 完全一致，合法可商用、离线可复现）：
    rime-ice 的 base/ext/tencent/41448/8105 短语词典 + 项目策展表
    （hot_words / core_words / colloquial）。

方法：
    每条短语用 jieba 切成词序列，滑动窗口取 (a,b,c)，按短语权重累加计数；
    再按 P(c | a,b) = cnt(a,b,c) / cnt(a,b) 归一，量化成单字节对数概率。

格式（ANWT v1，与 ANWG 同构，便于复用读取代码）：
    magic(4)="ANWT" + ver(1)='1' + entryCount(4) + keyOffTbl(4) + valOffTbl(4)
      + keyBlkPos(4) + valBlkPos(4)  = 25 字节头
    key   = 前前词 + "\\x1f" + 前词      （\\x1f 是 ASCII US，汉字里不会出现）
    value = 每条后继 [概率字节][后继词 UTF8]，entry 之间 0x01 分隔
    概率字节 = log P(c|a,b) 在 [LPMIN, 0] 上线性量化到 0x02..0xFF
    ⚠️ 概率字节是原始单字节，绝不能与 UTF-8 文本混在同一字符串里解码。

用法：
    python tools/build_trigram.py
"""
import importlib.util
import math
import os
import re
import struct
import sys
import tempfile

# 本机 pip 装不上 jieba（会被环境掐断），但托管环境里有一份，直接借路径用。
# 纯 Python 包，跨 3.13 小版本无 ABI 问题。
for _p in (
    os.path.expanduser("~/.workbuddy/binaries/python/envs/default/Lib/site-packages"),
    "/usr/local/lib/python3.11/site-packages",
):
    if os.path.isdir(os.path.join(_p, "jieba")) and _p not in sys.path:
        sys.path.insert(0, _p)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
_ICE_TMP = os.path.join(tempfile.gettempdir(), "ice_inspect")
ICE_DIR = os.path.join(_ICE_TMP, "cn_dicts")
OUT = os.path.join(ROOT, "Support", "dict", "assoc_t.bin")

RIME_FILES = ["base.dict.yaml", "ext.dict.yaml", "tencent.dict.yaml",
              "41448.dict.yaml", "8105.dict.yaml", "others.dict.yaml"]

PINYIN_BIN = os.path.join(ROOT, "Support", "dict", "pinyin.bin")

SEP = "\u0001"          # 短语分隔哨兵
KEYSEP = "\x1f"         # 三元键内部分隔
LPMIN = -8.0            # log P 下限
TOPK = 6                # 每个 (a,b) 最多留几个后继
MIN_CTX = 3.0           # (a,b) 上下文总计数下限（滤掉一次性组合）
MIN_PROB = 0.010        # 后继最低条件概率

CJK = re.compile(r"^[\u4e00-\u9fff]+$")


def is_num(s):
    try:
        float(s)
        return True
    except ValueError:
        return False


def load_rime(path):
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
            last = fields[-1].strip()
            out.append((word, float(last) if is_num(last) else 1.0))
    return out


def load_curated():
    phrases = []

    def grab(modname, names):
        try:
            spec = importlib.util.spec_from_file_location(
                modname, os.path.join(HERE, modname + ".py"))
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            for nm in names:
                obj = getattr(mod, nm, None)
                if obj is None:
                    continue
                for item in obj:
                    w = item[0] if isinstance(item, tuple) else item
                    if not isinstance(w, str):
                        continue
                    w = w.strip()
                    if w and CJK.fullmatch(w):
                        phrases.append((w, 60.0))
        except Exception as e:
            print("  策展表载入跳过:", modname, e)

    grab("hot_words", ["TOP", "COMBOS"])
    grab("core_words", ["CORE", "CORE_TOP"])
    grab("colloquial", ["COLLOQUIAL"])
    return phrases


def load_vocab(path):
    """从 pinyin.bin 取全部词，用于「最长匹配切分」。

    为什么需要第二套切分：rime-ice 的短语词典里，「今天天气」这种会整条成为一个
    词条，jieba 切出来就是一个 token —— 词边界消失，`今天|天气` 的三元永远统计不到。
    而用户打 jixntian... 时引擎是按「今天 / 天气」两个词组的。
    所以对每条短语同时做「词典最长匹配」切分，两套切分的三元组取并集。
    """
    d = open(path, "rb").read()
    assert d[:4] == b"ANPY"
    n, kT, vT = struct.unpack("<III", d[8:20])
    def u32(o):
        return struct.unpack("<I", d[o:o + 4])[0]
    vocab = set()
    for i in range(n):
        key = d[u32(kT + 4 * i):u32(kT + 4 * (i + 1))].decode("utf-8", "replace")
        if not (1 <= len(key) <= 6) or not key.isalpha():
            continue
        blob = d[u32(vT + 4 * i):u32(vT + 4 * (i + 1))]
        for seg in blob.split(b"\x01"):
            if len(seg) >= 3:
                w = seg[2:].decode("utf-8", "replace")
                if w and CJK.fullmatch(w):
                    vocab.add(w)
    return vocab


def maxmatch(text, vocab, maxw=4):
    """正向最长匹配切词。切不开的字符各自成词。"""
    out, i = [], 0
    while i < len(text):
        hit = ""
        for L in range(min(maxw, len(text) - i), 0, -1):
            cand = text[i:i + L]
            if L == 1 or cand in vocab:
                hit = cand
                break
        if not hit:
            hit = text[i]
        out.append(hit)
        i += len(hit)
    return out


def count_trigrams(phrases_w, vocab):
    """-> (tri: {(a,b,c): cnt}, ctx: {(a,b): cnt})"""
    import jieba
    jieba.setLogLevel(60)
    tri, ctx = {}, {}
    joined = SEP.join(w for w, _ in phrases_w)
    weights = [wt for _, wt in phrases_w]
    toks = list(jieba.cut(joined))
    idx, buf = 0, []

    def flush(words, w, text):
        # 两套切分各记一半权重：jieba 尊重词频，最长匹配尊重我们的词库边界
        for seq in (words, maxmatch(text, vocab) if text else []):
            if len(seq) < 3:
                continue
            share = w if seq is words else w * 0.5
            for i in range(len(seq) - 2):
                a, b, c = seq[i], seq[i + 1], seq[i + 2]
                if a == b or b == c:
                    continue
                tri[(a, b, c)] = tri.get((a, b, c), 0.0) + share
                ctx[(a, b)] = ctx.get((a, b), 0.0) + share

    for t in toks:
        if t == SEP:
            if buf and idx < len(weights):
                flush(buf, weights[idx], "".join(buf))
            buf, idx = [], idx + 1
        else:
            buf.append(t)
    if buf and idx < len(weights):
        flush(buf, weights[idx], "".join(buf))
    return tri, ctx


def quantize(p):
    """log P -> 单字节（0x02..0xFF），0x01 留给分隔符"""
    lp = max(LPMIN, min(0.0, math.log(max(1e-12, p))))
    q = int(round((lp - LPMIN) / (0.0 - LPMIN) * 253)) + 2
    return max(2, min(255, q))


def main():
    phrases = []
    if os.path.isdir(ICE_DIR):
        for fn in RIME_FILES:
            p = os.path.join(ICE_DIR, fn)
            if os.path.exists(p):
                got = load_rime(p)
                phrases += got
                print("  %-20s %d 条" % (fn, len(got)))
    else:
        print("!! 找不到 rime-ice 目录:", ICE_DIR)
        return 1
    cur = load_curated()
    phrases += cur
    print("策展短语 %d 条，合计 %d 条" % (len(cur), len(phrases)))

    vocab = load_vocab(PINYIN_BIN) if os.path.exists(PINYIN_BIN) else set()
    print("最长匹配词表 %d 词" % len(vocab))
    tri, ctx = count_trigrams(phrases, vocab)
    print("原始三元组 %d，上下文 %d" % (len(tri), len(ctx)))

    # 按上下文聚合，过滤低置信
    rows = {}
    for (a, b, c), n in tri.items():
        rows.setdefault((a, b), {})[c] = n
    items = []
    kept_ct = 0
    for k, succ in rows.items():
        tot = ctx.get(k, 0.0)
        if tot < MIN_CTX:
            continue
        top = sorted(succ.items(), key=lambda kv: (-kv[1], kv[0]))[:TOPK]
        packed = []
        for c, n in top:
            p = n / tot
            if p < MIN_PROB:
                continue
            packed.append((c, p))
        if not packed:
            continue
        items.append((k[0] + KEYSEP + k[1], packed))
        kept_ct += 1
    items.sort(key=lambda kv: kv[0])
    print("保留上下文 %d（每条前 %d 个后继）" % (kept_ct, TOPK))

    # 落盘
    keys = [k for k, _ in items]
    key_blob = bytearray()
    key_off = [0]
    for k in keys:
        key_blob += k.encode("utf-8")
        key_off.append(len(key_blob))

    val_blob = bytearray()
    val_off = [0]
    for _, packed in items:
        for i, (c, p) in enumerate(packed):
            if i:
                val_blob.append(0x01)
            val_blob.append(quantize(p))
            val_blob += c.encode("utf-8")
        val_off.append(len(val_blob))

    header_len = 25
    key_tbl_pos = header_len
    val_tbl_pos = key_tbl_pos + 4 * len(key_off)
    key_blk_pos = val_tbl_pos + 4 * len(val_off)
    val_blk_pos = key_blk_pos + len(key_blob)

    out = bytearray()
    out += b"ANWT" + b"1"
    out += struct.pack("<I", len(items))
    out += struct.pack("<I", key_tbl_pos)
    out += struct.pack("<I", val_tbl_pos)
    out += struct.pack("<I", key_blk_pos)
    out += struct.pack("<I", val_blk_pos)
    out += b"".join(struct.pack("<I", key_blk_pos + o) for o in key_off)
    out += b"".join(struct.pack("<I", val_blk_pos + o) for o in val_off)
    out += bytes(key_blob)
    out += bytes(val_blob)

    with open(OUT, "wb") as f:
        f.write(out)
    print("写出 %s：%.2fMB  条目 %d" % (OUT, len(out) / 1048576, len(items)))

    # 抽样验证：几个真实难点
    idx_map = {k: i for i, k in enumerate(keys)}
    for probe in ["查" + KEYSEP + "一下", "别" + KEYSEP + "着急",
                  "我" + KEYSEP + "已经", "今天" + KEYSEP + "天气"]:
        i = idx_map.get(probe)
        if i is None:
            print("  %-12s —（无此上下文）" % probe.replace(KEYSEP, "|"))
            continue
        rows_s = [(c, p) for c, p in items[i][1]][:3]
        print("  %-12s -> %s" % (probe.replace(KEYSEP, "|"),
                                 ", ".join("%s(%.2f)" % (c, p) for c, p in rows_s)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
