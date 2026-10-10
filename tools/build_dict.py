# -*- coding: utf-8 -*-
"""构建 iOS 键盘用的紧凑二进制拼音词库（全量增强版）。

数据源（全部 MIT 许可，可闭源商用）：
  pinyin-data        单字读音权威表（4.4 万行，覆盖全部 CJK 单字，一字多音齐全）
  phrase-pinyin-data 词语读音权威表（41.2 万词，能正确处理「重庆 chóng qìng」这类多音词）
  jieba dict.txt     词频（34.9 万词）

相比旧版的关键改动：
  1. ü 归一化：nǚ→nv，并额外补一份 u 变体键（nv→nu），
     这样「女 绿 略 虐」打 nv/lv/nve/lve 或 nu/lu/nue/lue 都能出字（旧版这类键完全打不出来）
  2. 单字收全部读音，并按「简体常用字」白名单过滤（挡住 鍔/錒/禰 这类繁体异体字）
  3. 词条源从 26 万扩到 60 万+（jieba ∪ phrase-pinyin-data）
  4. 每键候选上限按长度分档放大（旧版一律 14 条，打 shi 只出 14 个字）
  5. 短输入（1~2 字母）预排「最常用补全」表，key = 前缀 + \\x7f，引擎精确取
  6. 简拼表：首字母缩写（bjdx → 北京大学），key = \\x7f + 缩写，引擎精确取

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
from collections import defaultdict

import jieba
from pypinyin import pinyin, Style
from pypinyin.constants import PHRASES_DICT

from hot_words import TOP, COMBOS
from colloquial import COLLOQUIAL

HERE = os.path.dirname(os.path.abspath(__file__))
DICT_DIR = os.path.join(HERE, "..", "Support", "dict")
OUT = os.path.join(DICT_DIR, "pinyin.bin")

SRC_DIR = os.environ.get(
    "DICT_SRC", os.path.join(os.path.expanduser("~"), "AppData", "Local", "Temp", "dict_src")
)

CJK = re.compile(r"^[\u3400-\u4dbf\u4e00-\u9fff]+$")
MAX_WORD_LEN = 8
CHAR_MIN_FREQ = 100          # 单字词频低于此值的当噪声丢掉（楽/徳/悳 这类日式异体）
READING_PENALTY = 8          # 多音字：非首读音降权，免得「有 wěi」这种生僻音压过常用音
AGG_PREFIX_LEN = 2
AGG_TOP = 60
ABBR_TOP = 40
ABBR_MIN_SYL = 2
ABBR_MAX_SYL = 5
MARK = "\u007f"              # a~z 输入永远带不上这个字符，用来放「引擎专用表」

# 繁体/异体专用字：简体输入法不该把它们当候选
TRAD_VARIANT = set("妳牠祂")

# 带调拼音 -> 无调拼音。ü 统一映射成 v，稍后再补 u 变体键
TONE = {
    "ā": "a", "á": "a", "ǎ": "a", "à": "a",
    "ē": "e", "é": "e", "ě": "e", "è": "e", "ê": "e",
    "ī": "i", "í": "i", "ǐ": "i", "ì": "i",
    "ō": "o", "ó": "o", "ǒ": "o", "ò": "o",
    "ū": "u", "ú": "u", "ǔ": "u", "ù": "u",
    "ǖ": "v", "ǘ": "v", "ǚ": "v", "ǜ": "v", "ü": "v",
    "ń": "n", "ň": "n", "ǹ": "n",
    "ḿ": "m", "m̀": "m",
}


def strip_tone(s):
    return "".join(TONE.get(c, c) for c in s)


def cap_for(klen):
    """每键候选上限，按拼音串长度分档：短键给多（打 shi 要出几十个字），长键给少。"""
    if klen <= 4:
        return 260
    if klen <= 8:
        return 130
    return 70


def has_trad_variant(w):
    return any(c in TRAD_VARIANT for c in w)


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


# ---------------------------------------------------------------- 数据源

def load_char_readings():
    """pinyin-data：char -> [无调读音, ...]（按数据里的顺序，首读音优先）"""
    path = os.path.join(SRC_DIR, "pinyin.txt")
    out = {}
    if not os.path.exists(path):
        print("!! 缺 pinyin.txt，单字读音回退 pypinyin")
        return out
    for line in read_text(path).splitlines():
        line = line.split("#")[0].strip()
        if not line or ":" not in line:
            continue
        code, _, readings = line.partition(":")
        code = code.strip()
        if not code.startswith("U+"):
            continue
        try:
            ch = chr(int(code[2:], 16))
        except ValueError:
            continue
        if not CJK.match(ch):
            continue
        rs = []
        for r in readings.strip().split(","):
            k = strip_tone(r.strip())
            if k and k not in rs:
                rs.append(k)
        if rs:
            out[ch] = rs
    return out


def load_phrase_readings():
    """phrase-pinyin-data：word -> 无调拼音串"""
    path = os.path.join(SRC_DIR, "large_pinyin.txt")
    out = {}
    if not os.path.exists(path):
        print("!! 缺 large_pinyin.txt，词语读音回退 pypinyin")
        return out
    for line in read_text(path).splitlines():
        line = line.split("#")[0].strip()
        if not line or ":" not in line:
            continue
        w, _, py = line.partition(":")
        w = w.strip()
        if not CJK.match(w) or len(w) > MAX_WORD_LEN:
            continue
        key = "".join(strip_tone(s) for s in py.split())
        if key and key.isalpha():
            out[w] = key
    return out


def load_freqs():
    """jieba 词频：word -> freq"""
    path = os.path.join(SRC_DIR, "jieba_dict.txt")
    if not os.path.exists(path):
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


def load_opencc():
    """OpenCC 繁体->简体字表（Apache-2.0）：返回繁体字集合"""
    path = os.path.join(SRC_DIR, "TSCharacters.txt")
    out = set()
    if not os.path.exists(path):
        print("!! 缺 TSCharacters.txt，繁体字只能靠词频阈值粗筛")
        return out
    for line in read_text(path).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) >= 2:
            out.add(parts[0])
    return out


def split_syllables(key, syl_set):
    """把拼音串按音节表贪心切成音节，切不干净就返回 None"""
    out = []
    i, n = 0, len(key)
    while i < n:
        hit = None
        for L in range(min(6, n - i), 0, -1):
            if key[i:i + L] in syl_set:
                hit = key[i:i + L]
                break
        if hit is None:
            return None
        out.append(hit)
        i += len(hit)
    return out


# ---------------------------------------------------------------- 构建

def build():
    freqs = load_freqs()
    char_read = load_char_readings()
    phrase_read = load_phrase_readings()
    print("jieba 词条:", len(freqs), " 单字读音:", len(char_read), " 词语读音:", len(phrase_read))

    if not char_read:
        for cp in range(0x3400, 0x9FFF + 1):
            ch = chr(cp)
            if not CJK.match(ch):
                continue
            rs = pinyin(ch, style=Style.NORMAL, heteronym=True, errors="ignore")
            flat = [strip_tone(r) for grp in rs for r in grp if r]
            if flat:
                char_read[ch] = list(dict.fromkeys(flat))

    # 非标准叹词读音归一：嗯=n、唔=m、哼=hng、噷=hm……
    # 不归一的话会生成 "n" "m" "ng" 这种键，于是打「nb」会先蹦「嗯帮忙」
    # （键 nbangmang = n+bang+mang，被当成 nb 开头的词误配）
    SYL_FIX = {"n": "en", "m": "wu", "ng": "en", "hm": "hen", "hng": "heng", "ê": "e"}
    for ch in list(char_read.keys()):
        fixed = []
        for r in char_read[ch]:
            r = SYL_FIX.get(r, r)
            if not r:
                continue
            if r not in fixed:
                fixed.append(r)
        if fixed:
            char_read[ch] = fixed
        else:
            del char_read[ch]

    char_first = {c: rs[0] for c, rs in char_read.items()}
    # 简体常用字白名单：jieba 出现过的字。用来挡繁体异体词/字
    known_chars = set()
    for w in freqs:
        known_chars.update(w)

    # 噪声字：繁体字（OpenCC 表）+ 词频过低的生僻/日式异体字（楽 徳 悳…）
    trad_chars = load_opencc()
    bad_chars = set(trad_chars)
    for w, f in freqs.items():
        if len(w) == 1 and f < CHAR_MIN_FREQ:
            bad_chars.add(w)
    print("繁体字表:", len(trad_chars), " 噪声字合计:", len(bad_chars))

    def ok_char(c):
        return c in known_chars and c not in bad_chars

    max_freq = max(freqs.values()) if freqs else 1
    CHAR_DEFAULT = max(1, max_freq // 200000)
    PHRASE_ONLY = max(1, max_freq // 20000)      # 只在 phrase-pinyin-data 里出现的词，给个中低权重
    # 手工高频短语：只用来保证「整串打出来」时它排头，权重不能压过单字，
    # 否则短输入补全表会被这些短语塞满（打 w 先蹦「午安 完成 微信」就很难看）
    TOP_W = max_freq // 2
    COMBO_W = max_freq // 50
    # 口语/网络语/怼人词：权重给到最高，保证简拼（xbzz/nmsl/sb/nb）时
    # 它们压过同缩写的书面词（那边/上班/随便…）—— 这软件就是拿来扣字的
    COLLOQ_W = max_freq

    table = defaultdict(dict)

    def add(key, word, weight):
        if not key or not word or has_trad_variant(word) or not key.isalpha():
            return
        d = table[key]
        if d.get(word, -1) < weight:
            d[word] = weight

    def add_uv(key, word, weight):
        """ü 词：主键用 v（nv），再补一份 u 变体（nu）降权，兼容两种打法"""
        add(key, word, weight)
        if "v" in key:
            add(key.replace("v", "u"), word, max(1, weight // 3))

    # 1) 单字：收全部读音，只保留简体常用字；非首读音降权
    kept_chars = 0
    for ch, rs in char_read.items():
        if has_trad_variant(ch) or not ok_char(ch):
            continue
        kept_chars += 1
        wt = freqs.get(ch, CHAR_DEFAULT)
        for ri, r in enumerate(rs):
            add_uv(r, ch, wt if ri == 0 else max(1, wt // READING_PENALTY))
    print("单字保留:", kept_chars, "/", len(char_read))

    # 2) 词语
    phrase_hit = fallback = 0
    for word in set(freqs) | set(phrase_read):
        n = len(word)
        if n == 1 or has_trad_variant(word):
            continue
        if not all(ok_char(c) for c in word):
            continue
        f = freqs.get(word)
        if f is None and n >= 5:
            continue                      # 长词只在 jieba 有词频时才收，避免长尾噪声

        key = phrase_read.get(word)
        if key:
            phrase_hit += 1
        elif word in PHRASES_DICT:
            key = "".join(strip_tone(s) for s in
                          pinyin(word, style=Style.NORMAL, errors="ignore"))
        elif all(c in char_first for c in word):
            key = "".join(char_first[c] for c in word)
            fallback += 1
        else:
            continue

        add_uv(key, word, f if f is not None else PHRASE_ONLY)
    print("词语读音命中:", phrase_hit, " 逐字回退:", fallback)

    # 3) 手工高频短语
    for w in TOP:
        if CJK.match(w) and len(w) <= MAX_WORD_LEN:
            add_uv(_py_key(w, char_first, phrase_read), w, TOP_W)
    for w in COMBOS:
        if CJK.match(w) and len(w) <= MAX_WORD_LEN:
            add_uv(_py_key(w, char_first, phrase_read), w, COMBO_W)

    # 3.5) 口语 / 网络语 / 怼人词：显式读音，一个字一个音节。
    #      jieba、phrase-pinyin-data 都是书面语词典，这批词根本不在里面，
    #      打 xbzz / nmsl / gkd / xswl 一个汉字都出不来，全靠这张表补。
    syl_valid = set()
    for rs in char_read.values():
        syl_valid.update(rs)
    colloq_ok = colloq_bad = 0
    for w, py in COLLOQUIAL:
        if not CJK.match(w) or len(w) > MAX_WORD_LEN:
            continue
        syls = py.split()
        if len(syls) != len(w):
            colloq_bad += 1
            continue
        key = "".join(syls)
        if not key.isalpha():
            colloq_bad += 1
            continue
        if any(s not in syl_valid for s in syls):
            colloq_bad += 1        # 读音里有非标准音节，宁可不要也别塞错键
            continue
        add_uv(key, w, COLLOQ_W)
        colloq_ok += 1
    print("口语词入库:", colloq_ok, " 丢弃(读音/字数不符):", colloq_bad)

    # 4) 短输入「最常用补全」表：1~2 字母前缀下最常用的词排前面。
    #    单字母只放单字（打 s 该出「是 说 上」，不是「傻逼 上班」）；
    #    双字母放全部，单字仍加权 3 倍保证基本字优先。
    LEN_MUL = {1: 1.0, 2: 0.5}
    buckets = defaultdict(list)
    for key, d in table.items():
        if MARK in key:
            continue
        lim = min(AGG_PREFIX_LEN, len(key))
        for L in range(1, lim + 1):
            p = key[:L]
            for w, wt in d.items():
                if L == 1 and len(w) > 1:
                    continue
                buckets[p].append((wt * LEN_MUL.get(len(w), 0.3), w))
    agg_n = 0
    for p, lst in buckets.items():
        if len(lst) < 2:
            continue
        lst.sort(key=lambda x: (-x[0], len(x[1]), x[1]))
        seen, top = set(), []
        for _, w in lst:
            if w in seen:
                continue
            seen.add(w)
            top.append(w)
            if len(top) >= AGG_TOP:
                break
        d = table[p + MARK]
        for i, w in enumerate(top):
            d[w] = AGG_TOP - i
        agg_n += 1
    print("短输入补全表:", agg_n, "个前缀")

    # 5) 简拼表：首字母缩写。key = \x7f + 缩写，引擎精确取，词格切分不会误用
    syl_set = set(char_first.values())
    abbr = defaultdict(dict)
    for key, d in table.items():
        if MARK in key:
            continue
        sylls = split_syllables(key, syl_set)
        if not sylls or not (ABBR_MIN_SYL <= len(sylls) <= ABBR_MAX_SYL):
            continue
        ini = "".join(s[0] for s in sylls)
        if len(ini) != len(sylls):
            continue
        slot = abbr[ini]
        for w, wt in d.items():
            if len(w) != len(sylls):
                continue          # 缩写必须逐字对应，避免「你好」塞进 4 字母缩写
            if slot.get(w, -1) < wt:
                slot[w] = wt
    abbr_n = 0
    for ini, slot in abbr.items():
        if len(slot) < 1:
            continue
        items = sorted(slot.items(), key=lambda kv: (-kv[1], len(kv[0]), kv[0]))[:ABBR_TOP]
        d = table[MARK + ini]
        for i, (w, _) in enumerate(items):
            d[w] = ABBR_TOP - i
        abbr_n += 1
    print("简拼表:", abbr_n, "个缩写")

    # 6) 落盘
    keys = sorted(table.keys())
    entries = []
    for k in keys:
        if MARK in k:
            cap = AGG_TOP if k.endswith(MARK) else ABBR_TOP
        else:
            cap = cap_for(len(k))
        words = sorted(table[k].items(), key=lambda kv: (-kv[1], len(kv[0]), kv[0]))
        entries.append((k, [w for w, _ in words[:cap]]))

    syllables = sorted(k for k in table.keys() if 1 <= len(k) <= 6 and k in syl_set)

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

    os.makedirs(DICT_DIR, exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(out)

    total_cands = sum(len(c) for _, c in entries)
    print("词条数:", n, " 候选总数:", total_cands)
    print("音节数:", s)
    print("输出:", OUT, os.path.getsize(OUT), "字节")


def _py_key(w, char_first, phrase_read):
    if w in phrase_read:
        return phrase_read[w]
    if w in PHRASES_DICT:
        return "".join(strip_tone(s) for s in pinyin(w, style=Style.NORMAL, errors="ignore"))
    if all(c in char_first for c in w):
        return "".join(char_first[c] for c in w)
    return ""


if __name__ == "__main__":
    build()
