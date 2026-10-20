# -*- coding: utf-8 -*-
"""把百度输入法内置词条做成一个独立词库 cell（seed.bin）。

来源：百度输入法 Android APK 的 `assets/ipt/{0,1,2}.bcd`（魔数 biptbdsw），
记录格式（逆向得出，见 _baidu_re/百度输入法_PlumCore_拼音架构逆向报告.md）：

    u32 length            词长
    u8  codes[length*2]   每字 2 字节拼音码 = (声母ID, 韵母ID)
    u16 chars[length]     UTF-16LE 汉字

三个分片分别是：口语片段 / 成语 / 软件功能名。合计 10,744 条。

产出与主词库同格式（ANPY v2），让 PinyinEngine 用同一套 mmap + 二分读取，
不新增解析代码；只是作为「优先 cell」在主词库之前查一遍。

权重分档（越大越靠前）：
    口语片段  -2.0   整串命中就该它（"我也不知道啊"）
    成语      -2.6
    软件名    -3.0
"""
import math
import os
import struct
import sys

from pypinyin import pinyin, Style

HERE = os.path.dirname(os.path.abspath(__file__))
DICT_DIR = os.path.join(HERE, "..", "Support", "dict")
OUT = os.path.join(DICT_DIR, "seed.bin")
SRC = os.environ.get("BAIDU_IPT", r"D:\AndroidProjects\_baidu_re\ext\ipt")

LOGB0, LOGB1, LOG_N, LOG_FLOOR = 0x10, 0x7E, 0x7E - 0x10 + 1, 24.0
LOGN = LOG_N * LOG_N
MARK = "\u007f"

# 分片 -> (类别名, 目标 logP)
SHARDS = [
    ("0.bcd", "口语片段", -2.0),
    ("1.bcd", "成语", -2.6),
    ("2.bcd", "软件名", -3.0),
]


def parse_bcd(path):
    """按 (u32 len, len*2 拼音码, len*2 UTF-16) 顺扫，返回词表。"""
    d = open(path, "rb").read()
    out, i, n = [], 0, len(d)
    while i + 4 <= n:
        L = struct.unpack("<I", d[i:i + 4])[0]
        if not (1 <= L <= 40):
            i += 1
            continue
        need = i + 4 + L * 4
        if need > n:
            break
        try:
            w = d[i + 4 + L * 2:need].decode("utf-16-le")
        except UnicodeDecodeError:
            i += 1
            continue
        if all(0x3400 <= ord(c) <= 0x9fff for c in w):
            out.append(w)
            i = need
        else:
            i += 1
    return out


def logp_code(lp):
    lp = max(-LOG_FLOOR, min(0.0, lp))
    q = int(round((lp + LOG_FLOOR) / LOG_FLOOR * (LOGN - 1)))
    q = max(0, min(LOGN - 1, q))
    span = LOGB1 - LOGB0 + 1
    return chr(LOGB0 + q // span) + chr(LOGB0 + q % span)


def syllables(word):
    g = pinyin(word, style=Style.NORMAL, errors="ignore")
    if len(g) != len(word):
        return None
    syls = [x[0] for x in g]
    if not all(s and s.isascii() and s.isalpha() for s in syls):
        return None
    return syls


def build():
    table = {}          # key -> {word: logp}
    stat = []
    for fn, name, lp in SHARDS:
        path = os.path.join(SRC, fn)
        if not os.path.exists(path):
            print("!! 缺分片:", path)
            continue
        words = parse_bcd(path)
        kept = 0
        for w in words:
            if not (2 <= len(w) <= 8):
                continue
            syls = syllables(w)
            if not syls:
                continue
            key = "".join(syls)
            if not (2 <= len(key) <= 32):
                continue
            slot = table.setdefault(key, {})
            if slot.get(w, -99.0) < lp:
                slot[w] = lp
            kept += 1
        stat.append((name, len(words), kept))
        print("%-8s 解析 %5d 条，可用 %5d 条" % (name, len(words), kept))

    keys = sorted(table)
    entries = []
    for k in keys:
        recs = [logp_code(lp) + w for w, lp in
                sorted(table[k].items(), key=lambda x: -x[1])]
        entries.append((k, recs))

    key_blob, key_off = bytearray(), [0]
    for k, _ in entries:
        key_blob += k.encode("utf-8")
        key_off.append(len(key_blob))
    val_blob, val_off = bytearray(), [0]
    for _, recs in entries:
        val_blob += "\x01".join(recs).encode("utf-8")
        val_off.append(len(val_blob))

    HEADER = 44
    n = len(entries)
    s = 0
    key_off_off = HEADER
    val_off_off = key_off_off + 4 * (n + 1)
    keys_blob_off = val_off_off + 4 * (n + 1)
    vals_blob_off = keys_blob_off + len(key_blob)
    syl_off_off = vals_blob_off + len(val_blob)
    syl_blob_off = syl_off_off + 4 * (s + 1)

    out = bytearray()
    out += b"ANPY"
    out += struct.pack("<IIIIIIIIII", 2, n, key_off_off, val_off_off,
                       keys_blob_off, vals_blob_off, s, syl_off_off,
                       syl_blob_off, 0)
    for off in key_off:
        out += struct.pack("<I", keys_blob_off + off)
    for off in val_off:
        out += struct.pack("<I", vals_blob_off + off)
    out += key_blob
    out += val_blob
    for off in [0]:
        out += struct.pack("<I", syl_blob_off + off)

    os.makedirs(DICT_DIR, exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(out)
    print("keys=%d 候选=%d 输出 %s %d 字节"
          % (n, sum(len(r) for _, r in entries), OUT, len(out)))
    for k in ["woyebuzhidaoa", "jushiwudi", "gaojiduANxin"]:
        print("  样例", k, "->", table.get(k.lower(), {}))


if __name__ == "__main__":
    build()
