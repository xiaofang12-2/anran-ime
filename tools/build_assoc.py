# -*- coding: utf-8 -*-
"""构建字级 bigram 语言模型 assoc.bin —— 词图打分的「上下文项」。

对标 librime grammar.h 的 Grammar::Evaluate()：
    路径得分 = Σ entry_weight(词) + Σ context_penalty(词 | 前文)
entry_weight 就是词库里的 log P(词)（build_dict.py 已算好）；
context_penalty 由语言模型给出 —— 这正是「词图 + n-gram + Beam Search」
里的 n-gram，也是百度/搜狗引擎「越打越顺、切分准」的关键一项。

没有原始语料，但词库本身是「真实词频 + 真实词形」的统计产物：
把每个词的相邻字对按该词的词频加权累加，再按上下文首字归一成条件概率。
统计得到，不是手写词表 —— 词频越高的词，它内部的字搭配越可信。

格式（ANBG v2，纯文本可读）：
    b"ANBG" + b"2" + payload
    payload = record 之间用 \\x03 分隔
    record  = 上下文首字 + \\x02 + entry 之间用 \\x01 分隔
    entry   = 后继字 + \\x04 + 概率字节(0x02..0xFF)
概率字节 = log P(后继字 | 上下文首字) 在 [-12, 0] 上的线性量化。
"""
import math
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
DICT_DIR = os.path.join(HERE, "..", "Support", "dict")
SRC = os.path.join(DICT_DIR, "pinyin.bin")
OUT = os.path.join(DICT_DIR, "assoc.bin")

MARK = "\u007f"                 # 引擎专用表（短输入补全/简拼）不算语料
MAX_FOLLOW = 24                 # 每个上下文首字最多存多少个后继
MIN_WORD_LEN = 2
LPMIN = -12.0                   # log P 量化下限
MAGIC = b"ANBG"
VER = b"2"

LOGB0 = 0x10
LOGSPAN = 0x7E - 0x10 + 1
LOGN = LOGSPAN * LOGSPAN
LOG_FLOOR = 24.0


def dec_logp(a, b):
    """两字节 -> 词库里的全局对数概率（与 build_dict.py 的 logp_code 对应）。"""
    hi = ord(a) - LOGB0
    lo = ord(b) - LOGB0
    q = max(0, min(LOGN - 1, hi * LOGSPAN + lo))
    return q / (LOGN - 1) * LOG_FLOOR - LOG_FLOOR


def u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def parse(path):
    """读 pinyin.bin，返回 [(词, 相对词频权重), ...]。"""
    d = open(path, "rb").read()
    assert d[:4] == b"ANPY", "bad magic"
    n = u32(d, 8)
    key_off_off = u32(d, 12)
    val_off_off = u32(d, 16)
    words = []
    for i in range(n):
        ka = u32(d, key_off_off + 4 * i)
        kb = u32(d, key_off_off + 4 * (i + 1))
        if MARK in d[ka:kb].decode("utf-8", "ignore"):
            continue
        va = u32(d, val_off_off + 4 * i)
        vb = u32(d, val_off_off + 4 * (i + 1))
        blob = d[va:vb].decode("utf-8", "ignore")
        if not blob:
            continue
        for rec in blob.split("\x01"):
            if len(rec) < 3:
                continue
            wt = math.exp(dec_logp(rec[0], rec[1]))   # 比值即真实词频比
            w = rec[2:]
            if len(w) >= MIN_WORD_LEN:
                words.append((w, wt))
    return words


def main():
    words = parse(SRC)
    print("语料词条:", len(words))

    cnt = {}
    for w, wt in words:
        for i in range(len(w) - 1):
            row = cnt.setdefault(w[i], {})
            row[w[i + 1]] = row.get(w[i + 1], 0.0) + wt

    recs = []
    for ctx in sorted(cnt.keys()):
        row = cnt[ctx]
        total = sum(row.values()) or 1.0
        items = sorted(row.items(), key=lambda kv: (-kv[1], kv[0]))[:MAX_FOLLOW]
        parts = []
        for fol, v in items:
            lp = max(LPMIN, math.log(v / total))
            code = 2 + int(round((lp - LPMIN) / (0 - LPMIN) * 253))
            code = max(2, min(255, code))
            parts.append(fol + "\x04" + chr(code))
        recs.append(ctx + "\x02" + "\x01".join(parts))

    payload = "\x03".join(recs)
    with open(OUT, "wb") as f:
        f.write(MAGIC + VER + payload.encode("utf-8"))
    print("上下文首字:", len(recs))
    print("输出:", OUT, os.path.getsize(OUT), "字节")


if __name__ == "__main__":
    main()
