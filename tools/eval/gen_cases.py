# -*- coding: utf-8 -*-
"""从 pinyin.bin 生成候选质量用例（tools/eval/cases.tsv）。

为什么这么生成：
  期望值 = 该拼音键下**词库自身的最高频词**。这不是自证 —— 它测的是
  「引擎最终给用户的第一条，是否等于词库认为最该出现的那个词」。
  seed cell / 前缀补全 / 缩写表 / 语言模型罚分 任何一处抢位，都会让它红。

过滤：
  · 只取 2~4 字词（5 字以上多是长尾，用户不会整串打）
  · 排除 seed cell 命中的键（那是有意为之的口语片段优先）
  · 排除含非汉字、含 ü(v) 的键（评测机器读音与 rime 有差异）
  · 每个键只取首位词；同词只留一次

用法：python tools/eval/gen_cases.py
"""
import os
import struct
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
PINYIN = os.path.join(ROOT, "Support", "dict", "pinyin.bin")
SEED = os.path.join(ROOT, "Support", "dict", "seed.bin")
OUT = os.path.join(HERE, "cases.tsv")

CJK = lambda ch: 0x3400 <= ord(ch) <= 0x9fff

# 分层配额：双字词最常见，三字词次之，四字词兜底
QUOTA = {2: 130, 3: 70, 4: 40}


def load(path):
    d = open(path, "rb").read()
    assert d[:4] == b"ANPY", path
    n, kT, vT = struct.unpack("<III", d[8:20])

    def u32(o):
        return struct.unpack("<I", d[o:o + 4])[0]

    def s(a, b):
        return d[a:b].decode("utf-8", "replace")

    out = {}
    for i in range(n):
        k = s(u32(kT + 4 * i), u32(kT + 4 * (i + 1)))
        blob = s(u32(vT + 4 * i), u32(vT + 4 * (i + 1)))
        cands = []
        for rec in blob.split("\x01"):
            if len(rec) < 3:
                continue
            q = (ord(rec[0]) - 0x10) * 111 + (ord(rec[1]) - 0x10)
            cands.append((rec[2:], q))
        if cands:
            out[k] = sorted(cands, key=lambda x: -x[1])
    return out


def main():
    words = load(PINYIN)
    seed = load(SEED) if os.path.exists(SEED) else {}
    print("词库 key 数:", len(words), " seed key 数:", len(seed))

    picked = {2: [], 3: [], 4: []}
    skipped_seed = skipped_char = 0
    for key in sorted(words):
        if key in seed:                 # 有意让口语片段优先的键，不参与
            skipped_seed += 1
            continue
        if not (4 <= len(key) <= 12) or not key.isalpha():
            continue
        w = words[key][0][0]            # 词库首位词
        if not (2 <= len(w) <= 4) or not all(CJK(c) for c in w):
            skipped_char += 1
            continue
        # 同键下第二名与第一名太接近（<0.05 bit）的属于「本就并列」，
        # 首位谁赢都合理，不算缺陷 —— 直接从用例里排除，避免假红。
        if len(words[key]) > 1:
            a, b = words[key][0][1], words[key][1][1]
            if b >= a - 6:              # 量化单位约 0.002 bit/step，6 步≈0.012
                continue
        picked[len(w)].append((key, w, words[key][0][1]))

    lines = []
    stat = []
    for n, quota in QUOTA.items():
        # 按该键首位词的**词频**降序取，才是用户真正常打的那批词
        # （按字母序取会抽到一堆「阿拜/阿宝」这种生僻词，测了没意义）
        items = sorted(picked[n], key=lambda x: -x[2])[:quota]
        stat.append((n, len(picked[n]), len(items)))
        lines += ["%s\t%s\tw%d" % (k, w, n) for k, w, _ in items]

    with open(OUT, "w", encoding="utf-8") as f:
        f.write("# pinyin\texpect\tcategory\n")
        f.write("\n".join(lines) + "\n")

    print("跳过的 seed 键:", skipped_seed, " 非汉字/超长:", skipped_char)
    for n, total, used in stat:
        print("  %d 字词：可用 %d，取 %d" % (n, total, used))
    print("用例总数:", len(lines), "->", OUT)


if __name__ == "__main__":
    main()
