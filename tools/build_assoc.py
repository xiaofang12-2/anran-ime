# -*- coding: utf-8 -*-
"""从 pinyin.bin 反推「联想」表，生成 assoc.bin。

pinyin.bin 里每条是 拼音 -> [词...]，词本身自带拼音信息，
所以直接对词做相邻字统计就能得到「字 -> 常用后继字」，
不需要原始数据集。

产物 assoc.bin（紧凑文本格式，键盘扩展启动时一次性读进字典）：
  b"ANAS" + 记录串
  记录 = 字 + \x02 + 后继字1 \x01 后继字2 ... + \x03
"""
import os
import struct
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
DICT_DIR = os.path.join(HERE, "..", "Support", "dict")
SRC = os.path.join(DICT_DIR, "pinyin.bin")
OUT = os.path.join(DICT_DIR, "assoc.bin")

MAX_FOLLOW = 12          # 每个字最多存多少个后继
MIN_WORD_LEN = 2


def parse(path):
    d = open(path, "rb").read()
    assert d[:4] == b"ANPY", "bad magic"
    n = struct.unpack_from("<I", d, 8)[0]
    key_off_off = struct.unpack_from("<I", d, 12)[0]
    val_off_off = struct.unpack_from("<I", d, 16)[0]

    def u32(off):
        return struct.unpack_from("<I", d, off)[0]

    words = []
    for i in range(n):
        a = u32(key_off_off + 4 * i)
        b = u32(key_off_off + 4 * (i + 1))
        if not d[a:b]:
            continue
        va = u32(val_off_off + 4 * i)
        vb = u32(val_off_off + 4 * (i + 1))
        blob = d[va:vb].decode("utf-8")
        if not blob:
            continue
        for w in blob.split("\x01"):
            if len(w) >= MIN_WORD_LEN:
                words.append(w)
    return words


def main():
    words = parse(SRC)
    print("词条数:", len(words))

    cnt = defaultdict(Counter)
    for w in words:
        for i in range(len(w) - 1):
            cnt[w[i]][w[i + 1]] += 1

    recs = []
    for k in sorted(cnt.keys()):
        follows = [c for c, _ in cnt[k].most_common(MAX_FOLLOW)]
        recs.append(k + "\x02" + "\x01".join(follows))

    payload = "\x03".join(recs)
    with open(OUT, "wb") as f:
        f.write(b"ANAS" + payload.encode("utf-8"))
    print("联想字头数:", len(recs))
    print("输出:", OUT, os.path.getsize(OUT), "字节")


if __name__ == "__main__":
    main()