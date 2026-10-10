# -*- coding: utf-8 -*-
"""构建 iOS 键盘用的紧凑二进制拼音词库（全量版）。

数据源：
  pypinyin  读音（含 4.7 万条权威词语读音表，能正确解决多音字）
  jieba     dict.txt 词频（34.9 万条）

做法：
  单字读音先从 pypinyin 逐字取全（heteronym=True），得到一个「一字多音」判定表；
  词语读音优先走 pypinyin 的短语表（权威），短语表没有的再用逐字回退。
  这样不再像旧版那样把含多音字的词整批丢掉，覆盖率大幅提升。

产物：Support/dict/pinyin.bin
布局（小端）：
  [0:4]   魔数 "ANPY"
  [4:8]   u32 version
  [8:12]  u32 词条数 N
  [12:16] u32 key 偏移表起点（存绝对偏移）
  [16:20] u32 value 偏移表起点（存绝对偏移）
  [20:24] u32 key 数据块起点
  [24:28] u32 value 数据块起点
  [28:32] u32 音节数 S
  [32:36] u32 音节偏移表起点
  [36:40] u32 音节数据块起点
  [40:44] u32 保留
"""
import os
import re
import struct

import jieba
from pypinyin import pinyin, Style
from pypinyin.constants import PHRASES_DICT

from hot_words import TOP, COMBOS

HERE = os.path.dirname(os.path.abspath(__file__))
DICT_DIR = os.path.join(HERE, "..", "Support", "dict")
OUT = os.path.join(DICT_DIR, "pinyin.bin")

CJK = re.compile(r"^[\u3400-\u4dbf\u4e00-\u9fff]+$")
MAX_WORD_LEN = 6
MAX_CAND_PER_KEY = 14
# 5~6 字的长词只收高频的，避免长尾噪声把词库撑大
LONG_WORD_MIN_FREQ = 800


def norm(sylls):
    """pypinyin 结果 -> 无调拼音串"""
    return "".join(s[0] for s in sylls if s and s[0])


def load_freqs():
    path = os.path.join(os.path.dirname(jieba.__file__), "dict.txt")
    freqs = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) < 2:
                continue
            w = parts[0]
            if not CJK.match(w) or len(w) > MAX_WORD_LEN:
                continue
            try:
                freqs[w] = int(parts[1])
            except ValueError:
                continue
    return freqs


def load_char_readings():
    """逐字取全部读音：char -> (首读音, 读音集合)"""
    first = {}
    allr = {}
    for cp in range(0x3400, 0x9FFF + 1):
        ch = chr(cp)
        if not CJK.match(ch):
            continue
        rs = pinyin(ch, style=Style.NORMAL, heteronym=True, errors="ignore")
        flat = [r for grp in rs for r in grp if r]
        if not flat:
            continue
        first[ch] = flat[0]
        allr[ch] = set(flat)
    return first, allr


def build():
    freqs = load_freqs()
    char_first, char_all = load_char_readings()
    print("jieba 词条:", len(freqs), " 单字:", len(char_first))

    max_freq = max(freqs.values()) if freqs else 1
    CHAR_DEFAULT = max(1, max_freq // 200000)
    PHRASE_BONUS = 3

    table = {}

    def add(key, word, weight):
        if not key or not word:
            return
        d = table.setdefault(key, {})
        if d.get(word, -1) < weight:
            d[word] = weight

    # 1) 单字
    for ch, key in char_first.items():
        add(key, ch, freqs.get(ch, CHAR_DEFAULT))

    multi_reading = 0
    phrase_hit = 0
    fallback = 0

    for word, freq in freqs.items():
        n = len(word)
        if n == 1:
            continue
        if n >= 5 and freq < LONG_WORD_MIN_FREQ:
            continue
        if any(c not in char_first for c in word):
            continue

        # 全单音字：直接拼，拼音百分百确定
        if all(len(char_all[c]) == 1 for c in word):
            key = "".join(char_first[c] for c in word)
        elif word in PHRASES_DICT:
            key = norm(pinyin(word, style=Style.NORMAL, errors="ignore"))
            phrase_hit += 1
        else:
            key = norm(pinyin(word, style=Style.NORMAL, errors="ignore"))
            multi_reading += 1
            fallback += 1

        if not key or not key.isalpha():
            continue
        w = freq * (PHRASE_BONUS if word in PHRASES_DICT else 1)
        add(key, word, w)

    # 4) 高频短语补充：jieba / pypinyin 两边都漏掉的最常用组合
    top_w = max_freq * 2
    combo_w = max_freq // 6
    added_top = added_combo = 0
    for w in TOP:
        if not CJK.match(w) or len(w) > MAX_WORD_LEN:
            continue
        key = norm(pinyin(w, style=Style.NORMAL, errors="ignore"))
        if not key or not key.isalpha():
            continue
        add(key, w, top_w)
        added_top += 1
    for w in COMBOS:
        if not CJK.match(w) or len(w) > MAX_WORD_LEN:
            continue
        key = norm(pinyin(w, style=Style.NORMAL, errors="ignore"))
        if not key or not key.isalpha():
            continue
        add(key, w, combo_w)
        added_combo += 1

    print("高频短语:", added_top, " 代词组合:", added_combo)

    print("短语表命中:", phrase_hit, " 多音字回退:", fallback,
          " 多音字词:", multi_reading)

    keys = sorted(table.keys())
    entries = []
    for k in keys:
        words = sorted(table[k].items(), key=lambda kv: (-kv[1], len(kv[0]), kv[0]))
        entries.append((k, [w for w, _ in words[:MAX_CAND_PER_KEY]]))

    syllables = sorted({k for k in table.keys()
                        if 1 <= len(k) <= 6 and k in char_first.values()})

    key_blob = bytearray()
    key_off = [0]
    for k, _ in entries:
        key_blob += k.encode("utf-8")
        key_off.append(len(key_blob))

    val_blob = bytearray()
    val_off = [0]
    for _, cands in entries:
        val_blob += "\x01".join(cands).encode("utf-8")
        val_off.append(len(val_blob))

    syl_blob = bytearray()
    syl_off = [0]
    for s in syllables:
        syl_blob += s.encode("utf-8")
        syl_off.append(len(syl_blob))

    HEADER = 44
    n = len(entries)
    s = len(syllables)

    key_off_off = HEADER
    val_off_off = key_off_off + 4 * (n + 1)
    keys_blob_off = val_off_off + 4 * (n + 1)
    vals_blob_off = keys_blob_off + len(key_blob)
    syl_off_off = vals_blob_off + len(val_blob)
    syl_blob_off = syl_off_off + 4 * (s + 1)

    out = bytearray()
    out += b"ANPY"
    out += struct.pack("<IIIIIIIIII", 1, n, key_off_off, val_off_off,
                       keys_blob_off, vals_blob_off, s, syl_off_off,
                       syl_blob_off, 0)
    for off in key_off:
        out += struct.pack("<I", keys_blob_off + off)
    for off in val_off:
        out += struct.pack("<I", vals_blob_off + off)
    out += key_blob
    out += val_blob
    for off in syl_off:
        out += struct.pack("<I", syl_blob_off + off)
    out += syl_blob

    with open(OUT, "wb") as f:
        f.write(out)

    print("词条数:", n)
    print("音节数:", s)
    print("输出:", OUT, os.path.getsize(OUT), "字节")


if __name__ == "__main__":
    build()