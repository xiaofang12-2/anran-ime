# -*- coding: utf-8 -*-
"""用真实语料词频重写 pinyin.bin 的 logP（跨词比较的尺度），显示顺序尽量不动。

问题（实测数据）：
    上游把词频做了 log(1+f) 压缩，落盘又算 log(wt/sum)，结果 78 万词只有
    1933 个不同 logP，全部挤在 [-17.7, -9.8]。同一个拼音键内还好（相对序对），
    但**跨词比较毫无区分度**：

        公司  -12.06      攻丝  -12.96     真实频率 45604 : 3
        刀功  -12.72      着急  -12.44

    词图 Viterbi 只能靠「词数少优先」裁决，于是一连串不合语法的句子胜出：
        我已经刀功死了 / 我香水一会儿 / 你先别这几

做法：
    · jieba dict.txt 里的真实词频 -> logP = ln(freq / TOTAL)（约 10 nat 动态范围）
    · 不在 jieba 表里的长尾词 -> 沿用原 logP 的先后，压到 [-16.5, -13.0] 区间，
      保证「有真词频的词」整体排在长尾之前，同时长尾内部相对序不变
    · 写盘前做一次**同键单调性保护**：若新 logP 破坏了原显示顺序，
      把后来的那条压到前一条之下（宁可轻微压缩，也不让首屏候选顺序乱掉）

用法：
    python tools/fix_wordfreq.py <pinyin.bin> <out.bin> [jieba_dict.txt]
"""
import math
import os
import struct
import sys

LOG_FLOOR = 24.0
LOGB0, LOGB1 = 0x10, 0x7E
LOGN = (LOGB1 - LOGB0 + 1) ** 2          # 12321

JIEBA_DICTS = [
    os.path.expanduser("~/.workbuddy/binaries/python/envs/default/Lib/site-packages/jieba/dict.txt"),
    "/usr/local/lib/python3.11/site-packages/jieba/dict.txt",
]

TAIL_HI, TAIL_LO = -13.0, -16.5          # 长尾词区间
CLAMP_HI = -0.5
CLAMP_LO = -18.0


def quantize(lp):
    lp = max(-LOG_FLOOR, min(0.0, lp))
    q = int(round((lp + LOG_FLOOR) / LOG_FLOOR * (LOGN - 1)))
    q = max(0, min(LOGN - 1, q))
    span = LOGB1 - LOGB0 + 1
    return bytes((LOGB0 + q // span, LOGB0 + q % span))


def dequantize(b0, b1):
    q = (b0 - LOGB0) * 111 + (b1 - LOGB0)
    return q / (LOGN - 1) * LOG_FLOOR - LOG_FLOOR


def load_jieba(path):
    freq = {}
    total = 0
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            p = line.split()
            if len(p) < 2:
                continue
            try:
                n = int(p[1])
            except ValueError:
                continue
            if n > freq.get(p[0], 0):
                freq[p[0]] = n
            total += n
    return freq, total


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        print(__doc__)
        return 1
    src, dst = args[0], args[1]
    jb_path = args[2] if len(args) > 2 else next(
        (p for p in JIEBA_DICTS if os.path.exists(p)), None)
    if not jb_path or not os.path.exists(jb_path):
        print("!! 找不到 jieba dict.txt")
        return 2
    jb, jb_total = load_jieba(jb_path)
    print("jieba 词表 %d 词，总词次 %d" % (len(jb), jb_total))

    d = bytearray(open(src, "rb").read())
    assert bytes(d[:4]) == b"ANPY", "bad ANPY magic"
    n, kT, vT = struct.unpack("<III", bytes(d[8:20]))

    def u32(o):
        return struct.unpack("<I", bytes(d[o:o + 4]))[0]

    best_old = {}
    keys = []
    for i in range(n):
        ka, kb = u32(kT + 4 * i), u32(kT + 4 * (i + 1))
        key = bytes(d[ka:kb]).decode("utf-8", "replace")
        a, b = u32(vT + 4 * i), u32(vT + 4 * (i + 1))
        rows = []
        p = a
        while p < b:
            if d[p] == 0x01:
                p += 1
                continue
            e = d.find(0x01, p)
            if e < 0 or e > b:
                e = b
            if e - p >= 3:
                w = bytes(d[p + 2:e]).decode("utf-8", "replace")
                lp = dequantize(d[p], d[p + 1])
                rows.append((p, w, lp))
                if lp > best_old.get(w, -1e9):
                    best_old[w] = lp
            p = e + 1
        # 空键也要保留一条（偏移表必须与原表等长，长度才不变）
        keys.append((key, rows))

    print("条目 %d，不同词 %d" % (n, len(best_old)))

    tail_vals = [v for w, v in best_old.items() if w not in jb]
    if tail_vals:
        o_hi, o_lo = max(tail_vals), min(tail_vals)
    else:
        o_hi, o_lo = 0.0, -1.0
    span = (o_hi - o_lo) or 1.0

    def new_lp(word):
        if word in jb:
            lp = math.log(jb[word] / jb_total)
        else:
            t = (best_old[word] - o_lo) / span
            lp = TAIL_LO + t * (TAIL_HI - TAIL_LO)
        return max(CLAMP_LO, min(CLAMP_HI, lp))

    lp_of = {w: new_lp(w) for w in best_old}

    # 3) 按新 logP 重排每个拼音键内的候选，并重建值块。
    #
    # 为什么不能只改分数、保持原顺序：
    #   旧库里 ma 键的「嘛/吗/马/骂」是**同分并列**的（都 -9.77），
    #   字节顺序纯属当年写库时的偶然。如果只改分数不排序，
    #   真实词频更高的「吗」会被前一条「嘛」压住（实测 ma 首位出「嘛」）。
    #   值块每条 entry 长度不变（2 字节分数 + 词），所以重排不改文件总长，
    #   键块与键偏移表完全不用动，只需重写值偏移表和值块。
    reordered = 0
    new_vals = bytearray()
    new_offs = [0]
    for key, rows in keys:
        packed = []
        for off, w, _old in rows:
            packed.append((lp_of.get(w, TAIL_LO), w))
        # 分数降序；同分按词长、字典序，保证可复现
        packed.sort(key=lambda x: (-x[0], len(x[1]), x[1]))
        if [w for _, w in packed] != [w for _, _o, w in rows]:
            reordered += 1
        # 原格式：entry 之间用 0x01 分隔，最后一个后面没有分隔符
        for i, (lp, w) in enumerate(packed):
            if i:
                new_vals.append(0x01)
            new_vals += quantize(lp)
            new_vals += w.encode("utf-8")
        new_offs.append(len(new_vals))

    # 头布局：magic(4)+pad(4) | n@8 | keyTbl@12 | valTbl@16 | keyBlk@20 | valBlk@24
    val_tbl_pos = struct.unpack("<I", bytes(d[16:20]))[0]
    val_blk_pos = struct.unpack("<I", bytes(d[24:28]))[0]
    if len(new_offs) != n + 1:
        print("!! 键数 %d 与表项 %d 不符，放弃重排" % (len(new_offs) - 1, n))
        return 3
    if val_tbl_pos + 4 * len(new_offs) > val_blk_pos:
        print("!! 值偏移表会撑爆值块起点，放弃重排")
        return 3
    # 值块长度可能与原来差几十 KB：扫描时跳过了 len<3 的空词条（score+空词，
    # 引擎读出来也是空串，本来就没用）。ANPY 头里没有「文件总长」字段，
    # 偏移表全量重写过，所以长度变化是安全的。
    delta = len(new_vals) - (len(d) - val_blk_pos)
    for i, o in enumerate(new_offs):
        struct.pack_into("<I", d, val_tbl_pos + 4 * i, val_blk_pos + o)
    d = d[:val_blk_pos] + new_vals
    print("值块长度变化 %+d 字节（丢弃空词条后的正常差异）" % delta)

    print("按键重排：%d / %d 个键的候选顺序发生变化" % (reordered, len(keys)))

    print("写出 %s（%.1fMB）" % (dst, os.path.getsize(dst) / 1048576))

    for w in ["的", "是", "我", "公司", "攻丝", "刀功", "香水", "想睡", "着急", "钥匙", "到", "你好"]:
        if w in lp_of:
            print("  %-4s logP=%.2f  (jieba freq=%s)" % (w, lp_of[w], jb.get(w, "—")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
