# -*- coding: utf-8 -*-
"""构建 iOS 键盘用的紧凑二进制拼音词库。

数据源（均可闭源商用）：
  rime-ice 雾凇拼音词库   拼音输入法专用词库，含真实词频、口语与网络词
  pinyin-data             单字读音权威表（4.4 万行，一字多音齐全）
  phrase-pinyin-data      词语读音权威表（41.2 万词，多音词正确）
  jieba dict.txt          词频补充
  colloquial.py           本产品核心词（扣字/怼人）的显式读音兜底

为什么用 rime-ice 而不是自己攒词表：
  百度/搜狗之所以「打什么有什么」，靠的是输入法专用词库 + 真实词频。
  rime-ice 就是这么一个开放词库：
    8105.dict.yaml     字表，字频取自 25 亿字语料（真实）
    41448.dict.yaml    扩展字表，只有读音没有词频
    base.dict.yaml     白霜词库基础词，带真实词频（核心）
    ext.dict.yaml      扩展词，权重平铺（只有「有没有」，没有「多常用」）
    others.dict.yaml   需要注音的词，只有读音
    tencent.dict.yaml  腾讯词向量长词，权重平铺（量大且杂，不采用）
  所以：词频排序完全交给 base + 8105，ext 只补短词覆盖面，
  41448/others 只取读音，tencent 直接不要。

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
import math
import os
import re
import struct
from collections import defaultdict

import jieba
from pypinyin import pinyin, Style
from pypinyin.constants import PHRASES_DICT

from colloquial import COLLOQUIAL, STRONG, STRONG_TOP
from core_words import CORE, CORE_TOP

HERE = os.path.dirname(os.path.abspath(__file__))
DICT_DIR = os.path.join(HERE, "..", "Support", "dict")
OUT = os.path.join(DICT_DIR, "pinyin.bin")

SRC_DIR = os.environ.get(
    "DICT_SRC", os.path.join(os.path.expanduser("~"), "AppData", "Local", "Temp", "dict_src")
)
RIME_DIR = os.path.join(SRC_DIR, "rime")

CJK = re.compile(r"^[\u3400-\u4dbf\u4e00-\u9fff]+$")
MAX_WORD_LEN = 8
CHAR_MIN_FREQ = 100          # 单字词频低于此值的当噪声丢掉（楽/徳/悳 这类日式异体）
READING_PENALTY = 8          # 多音字：非首读音降权，免得「有 wěi」这种生僻音压过常用音
AGG_PREFIX_LEN = 2
AGG_TOP = 48
ABBR_TOP = 32
ABBR_MIN_SYL = 2
ABBR_MAX_SYL = 6
MARK = "\u007f"              # a~z 输入永远带不上这个字符，用来放「引擎专用表」

RIME_MAX = 10000             # 归一后词频上限
BASE_MIN = 10                # base 词库低于此词频的长尾直接丢（越界词占地方还没人打）
EXT_MAXLEN = 3               # ext 权重平铺，只留短词补覆盖面；长词没词频反而添乱
EXT_SCORE = 120              # ext 平铺词统一低分：只在同键没有 base 词时才露头

# 生僻长尾剪枝：同一个键下，词频低于「键内最高词频 × KEEP_RATIO」的词直接不要。
# 这是百度那种「打 xiexie 只出 谢谢/歇歇，不出 媟亵/愶愶」的关键。
KEEP_RATIO = 0.008
KEEP_ABS_MIN = 15

# jieba 常用度加成：rime 顶部词频被压平（怎么 501014 与 专门 500506 取对数后几乎相等），
# 不靠 jieba 的话同档词谁前谁后全看汉字 Unicode 码。加成上限压得很小（≤400），
# 只在「rime 词频相差 1.7 倍以内」的压缩区里起作用，不会把真正的高频词拉下来。
JIEBA_BONUS = 400

# 核心高频词加权：rime 把常用词压在 50 万档、jieba 又跟聊天习惯对不上，
# 光靠语料排不出「打 nh 先出 你好 还是 女孩」。这里人工给入口词加权钉位。
CORE_BONUS = 1200
CORE_TOP_BONUS = 3000

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
        return 180
    if klen <= 8:
        return 100
    return 56


def has_trad_variant(w):
    return any(c in TRAD_VARIANT for c in w)


def norm_score(wt, mx, prio=1.0):
    """词频 -> 0~RIME_MAX 的对数归一，抹平各词库之间的量纲差。"""
    if mx <= 1:
        return 1
    return max(1, int(round(RIME_MAX * prio * math.log(1 + wt) / math.log(1 + mx))))


# ---------------------------------------------------------------- 对数概率编码
# 百度/librime 的引擎里，词典条目存的是「对数概率」而不是名次。
# grammar.h 的打分就是 score = entry_weight + grammar.Query(context, entry)，
# entry_weight 即 log P(词)。只有把每个词都换算成同一把尺子上的 log P，
# 词图上的 Viterbi 才能跨键比较（否则 900000/620000 这种手写常数就是穷举）。
#
# 编码成两个字节，每个字节落在 0x10..0x7E（111 档），共 12321 档，
# 正好躲开 \x01（候选分隔符），解析端不会串味。
LOGB0 = 0x10
LOGB1 = 0x7E
LOGN = (LOGB1 - LOGB0 + 1) ** 2        # 12321
LOG_FLOOR = 24.0                        # log P 下限（≈ e^-24，比 log(1e-6) 还低）


def logp_code(wt, total):
    """词频 -> 全局 log 概率的定长两字节编码（越大越常用）。"""
    if wt <= 0 or total <= 0:
        lp = -LOG_FLOOR
    else:
        lp = math.log(wt / total)
    if lp < -LOG_FLOOR:
        lp = -LOG_FLOOR
    if lp > 0:
        lp = 0.0
    q = int(round((lp + LOG_FLOOR) / LOG_FLOOR * (LOGN - 1)))
    q = max(0, min(LOGN - 1, q))
    span = LOGB1 - LOGB0 + 1
    return chr(LOGB0 + q // span) + chr(LOGB0 + q % span)


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


# ---------------------------------------------------------------- 数据源

def load_rime_raw(fn):
    """读一个 rime 词库：word -> (音节列表 或 None, 词频)。

    两种格式都认：
        <词>\\t<音节 空格分隔>\\t<词频>     （带注音，如 base/ext/8105）
        <词>\\t<词频>                       （columns: [text, weight]，如 tencent）
    音节为 None 表示这个词没有注音，后面用字表回退补。
    """
    path = os.path.join(RIME_DIR, fn)
    if not os.path.exists(path):
        print("!! 缺 rime 词库:", fn)
        return {}
    out = {}
    started = False
    for line in read_text(path).splitlines():
        if not started:
            if line.strip() == "...":
                started = True
            continue
        if not line or line[0] == "#":
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        w = parts[0].strip()
        if not CJK.match(w) or len(w) > MAX_WORD_LEN:
            continue
        c2 = parts[1].strip()
        syls = None
        if c2.isdigit():                       # 只有「词 + 词频」两列
            wt = int(c2)
        else:                                  # 「词 + 注音 [+ 词频]」
            syls = [s for s in c2.split() if s]
            if not syls or not all(s.isascii() and s.isalpha() for s in syls):
                continue
            wt = 0
            if len(parts) >= 3:
                try:
                    wt = int(parts[2])
                except ValueError:
                    wt = 0
        prev = out.get(w)
        if prev is None or wt > prev[1]:
            out[w] = (syls, wt)
    return out


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
    """phrase-pinyin-data：word -> [无调音节, ...]（保留音节边界，缩写表要用）"""
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
        syls = [strip_tone(s) for s in py.split()]
        if syls and all(s.isalpha() for s in syls):
            out[w] = syls
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


# ---------------------------------------------------------------- 构建

def build():
    jb = load_freqs()
    char_read = load_char_readings()
    phrase_read = load_phrase_readings()

    r8105 = load_rime_raw("8105.dict.yaml")       # 字表：真实字频
    r41448 = load_rime_raw("41448.dict.yaml")     # 扩展字表：只有读音
    rbase = load_rime_raw("base.dict.yaml")       # 核心词库：真实词频
    rext = load_rime_raw("ext.dict.yaml")         # 扩展词：权重平铺
    rother = load_rime_raw("others.dict.yaml")    # 注音词：只有读音
    print("rime: 8105=%d 41448=%d base=%d ext=%d others=%d"
          % (len(r8105), len(r41448), len(rbase), len(rext), len(rother)))

    # 读音表：哪个词怎么读。优先 base（最准）> ext > 扩展字表 > 注音词 > 字表
    READ = {}
    for src in (rother, r41448, r8105, rext, rbase):
        for w, (syls, _wt) in src.items():
            if syls:
                READ[w] = syls

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
    SYL_FIX = {"n": "en", "m": "wu", "ng": "en", "hm": "hen", "hng": "heng", "ê": "e"}
    for ch in list(char_read.keys()):
        fixed = []
        for r in char_read[ch]:
            r = SYL_FIX.get(r, r)
            if r and r not in fixed:
                fixed.append(r)
        if fixed:
            char_read[ch] = fixed
        else:
            del char_read[ch]

    char_first = {c: rs[0] for c, rs in char_read.items()}

    # 统一词频：base 真实词频为主，ext 平铺低分补面，jieba 折到同量纲补词
    FREQ = {}
    CAT_OF = {}
    bmx = max((w for _s, w in rbase.values()), default=1)
    for w, (syls, wt) in rbase.items():
        if wt < BASE_MIN:
            continue
        FREQ[w] = norm_score(wt, bmx)
        CAT_OF[w] = "rime"
    for w, (syls, wt) in rext.items():
        if len(w) > EXT_MAXLEN or w in FREQ:
            continue
        FREQ[w] = EXT_SCORE
        CAT_OF[w] = "rime"
    if jb:
        jmx = math.log(1 + max(jb.values()))
        for w, f in jb.items():
            ratio = math.log(1 + f) / jmx
            if w in FREQ:
                # 语料里已有：只加一点点「常用度」，用来打破 rime 顶部被压平后的并列
                FREQ[w] += int(round(JIEBA_BONUS * ratio))
                continue
            FREQ[w] = max(1, int(round(RIME_MAX * 0.85 * ratio)))
            CAT_OF[w] = "jb"

    # 核心高频词加权：把「打字时第一眼要看到」的入口词顶到简拼位最前。
    # 不在语料里的（宝宝/拜拜/备注 这类）也一并建条，权重给到 BONUS 即可。
    core_added = 0
    for w in CORE:
        if w not in FREQ:
            core_added += 1
        FREQ[w] = FREQ.get(w, 0) + CORE_BONUS
    for w in CORE_TOP:
        if w not in FREQ:
            core_added += 1
        FREQ[w] = FREQ.get(w, 0) + CORE_TOP_BONUS
    print("核心高频词: TOP=%d 常规=%d 其中语料外新建=%d"
          % (len(CORE_TOP), len(CORE), core_added))

    # 简体常用字白名单：8105 规范字表 + jieba 出现过的字。挡繁体异体词/字
    known_chars = set(r8105.keys())
    for w in jb:
        known_chars.update(w)
    for w in FREQ:
        known_chars.update(w)

    # 噪声字：繁体字（OpenCC 表，但 8105 规范字表里有的算简体，别误伤 么/于/藉 这些）
    # + 不在规范字表里、词频又极低的生僻/日式异体字（楽 徳 悳…）
    trad_chars = load_opencc()
    bad_chars = {c for c in trad_chars if c not in r8105}
    for w, f in jb.items():
        if len(w) == 1 and f < CHAR_MIN_FREQ and w not in r8105:
            bad_chars.add(w)
    print("繁体字表:", len(trad_chars), "噪声字合计:", len(bad_chars))

    def ok_char(c):
        return c in known_chars and c not in bad_chars

    max_freq = max(FREQ.values()) if FREQ else 1
    CHAR_DEFAULT = max(1, max_freq // 200000)
    PHRASE_ONLY = 40                                  # 只有读音、没有词频的词
    COLLOQ_W = max_freq + 1                           # 强优先口语词（骂人/网络梗）：压过一切
    # 顶级优先：缩写位撞车时压过 STRONG 同侪。要拉开「真倍数」——
    # 两字节对数概率的量化精度约 0.002，+1/+2 会被压成同一个码值分不出胜负。
    COLLOQ_TOP_W = max_freq * 8
    COVER_W = max(1, int(max_freq * 0.30))            # 覆盖面口语词：语料里没有才用，给中等权重不抢位

    table = defaultdict(dict)
    CAT = {}
    CAT_PRI = {"colloq": 5, "rime": 3, "jb": 2, "char": 3, "phrase": 1}
    # 缩写表：ini -> {word: weight}。用「词的真实音节」算首字母，
    # 不做二次贪心切分 —— 否则 zan|men|gei 会被切成 zan|meng|ei，
    # 于是「咱们给」被塞进 zme 槽，打 zme（怎么）先蹦出它。
    ABBR_SRC = defaultdict(dict)

    def add(key, word, weight, cat, syls=None, abbr_weight=None):
        if not key or not word or has_trad_variant(word) or not key.isascii() or not key.isalpha():
            return
        d = table[key]
        if d.get(word, -1) < weight:
            d[word] = weight
        if CAT_PRI.get(cat, 0) >= CAT_PRI.get(CAT.get(word, "phrase"), 0):
            CAT[word] = cat
        if syls and ABBR_MIN_SYL <= len(syls) <= ABBR_MAX_SYL and len(syls) == len(word):
            ini = "".join(s[0] for s in syls)
            if len(ini) == len(syls) and ini.isalpha():
                slot = ABBR_SRC[ini]
                # 缩写槽可以单独给权重：顶级优先词只在「缩写撞车」时才压人，
                # 全拼键（如 shenmegui）仍用常规权重，免得打 shenme 先蹦「什么鬼」。
                aw = weight if abbr_weight is None else abbr_weight
                if slot.get(word, -1) < aw:
                    slot[word] = aw

    def add_uv(key, word, weight, cat, syls=None, abbr_weight=None):
        """ü 词：主键用 v（nv），再补一份 u 变体（nu）降权，兼容两种打法"""
        add(key, word, weight, cat, syls, abbr_weight)
        if "v" in key:
            add(key.replace("v", "u"), word, max(1, weight // 3), cat, syls)

    # 1) 单字：只收「通用规范字表」里的，或 jieba 里够常用的字。
    #    挡掉 鏂/筽/櫙 这类生僻字与韩式异体（打 o 冒出来的垃圾候选就是它们）。
    kept_chars = 0
    for ch, rs in char_read.items():
        if has_trad_variant(ch) or not ok_char(ch):
            continue
        if ch not in r8105 and jb.get(ch, 0) < CHAR_MIN_FREQ:
            continue
        kept_chars += 1
        wt = FREQ.get(ch, CHAR_DEFAULT)
        for ri, r in enumerate(rs):
            add_uv(r, ch, wt if ri == 0 else max(1, wt // READING_PENALTY), "char", [r])
    print("单字保留:", kept_chars, "/", len(char_read))

    # 2) 词语：rime 注音优先（最准），其次 phrase-pinyin-data / pypinyin / 逐字回退
    rime_n = phrase_n = fallback = 0
    for word in set(FREQ) | set(phrase_read):
        n = len(word)
        if n == 1 or has_trad_variant(word):
            continue
        if not all(ok_char(c) for c in word):
            continue
        # 只有读音、没有词频的长词：没人整串打，白占地方
        if n >= 5 and word not in FREQ:
            continue

        syls = READ.get(word)
        if syls:
            rime_n += 1
        else:
            syls = phrase_read.get(word)
            if syls:
                phrase_n += 1
            elif word in PHRASES_DICT:
                syls = [strip_tone(g[0]) for g in
                        pinyin(word, style=Style.NORMAL, errors="ignore") if g]
            elif all(c in char_first for c in word):
                syls = [char_first[c] for c in word]
                fallback += 1
            else:
                continue
        if not syls or not all(syls):
            continue
        key = "".join(syls)

        wt = FREQ.get(word)
        if wt is not None:
            add_uv(key, word, wt, CAT_OF.get(word, "rime"), syls)
        else:
            add_uv(key, word, PHRASE_ONLY, "phrase", syls)
    print("词语读音：rime", rime_n, " phrase", phrase_n, " 逐字回退", fallback)

    # 3) 口语 / 网络语 / 怼人词。分两档：
    #    · STRONG（骂人/网络梗）：给最高权重，打简拼时必须第一时间蹦出来
    #    · 其余口语词：语料里有就按真实词频走（绝不抢 微信/怎么 的位），
    #      语料里没有才给个中等权重兜底，保证「打得出」但不霸榜
    syl_valid = set()
    for rs in char_read.values():
        syl_valid.update(rs)
    colloq_ok = colloq_bad = colloq_strong = 0
    for w, py in COLLOQUIAL:
        if not CJK.match(w) or len(w) > MAX_WORD_LEN:
            continue
        syls = py.split()
        key = "".join(syls)
        if (len(syls) != len(w) or not key.isalpha()
                or any(s not in syl_valid for s in syls)):
            colloq_bad += 1
            continue
        if w in STRONG_TOP:
            # 顶级权重只挂在「缩写槽」上：xsl 这种缩写撞车位靠它分胜负；
            # 全拼键仍给常规强优先权重，否则打 shenme 会被「什么鬼」的前缀补全顶掉「什么」。
            wt = COLLOQ_W
            aw = COLLOQ_TOP_W
            colloq_strong += 1
        elif w in STRONG:
            wt = COLLOQ_W
            aw = COLLOQ_W
            colloq_strong += 1
        else:
            wt = FREQ.get(w, COVER_W)
            aw = wt
        add_uv(key, w, wt, "colloq", syls, abbr_weight=aw)
        colloq_ok += 1
    print("核心词入库:", colloq_ok, "其中强优先:", colloq_strong, "丢弃(读音/字数不符):", colloq_bad)

    # 4) 剪生僻长尾：同一键下只留「词频够高」的词。
    def keep_words(items):
        nat_max = 0
        for w, wt in items.items():
            if CAT.get(w, "phrase") != "colloq" and wt > nat_max:
                nat_max = wt
        thresh = max(nat_max * KEEP_RATIO, KEEP_ABS_MIN) if nat_max else 0
        out = {}
        for w, wt in items.items():
            if CAT.get(w, "colloq") == "colloq" or wt >= thresh:
                out[w] = wt
        if not out:      # 整键都是生僻词：留最强的几条兜底
            top = sorted(items.items(), key=lambda kv: (-kv[1], len(kv[0]), kv[0]))[:3]
            out = dict(top)
        return out

    filtered = {k: keep_words(v) for k, v in table.items()}
    print("剪枝后词条:", len(filtered), "候选:", sum(len(v) for v in filtered.values()))

    # 5) 短输入「最常用补全」表：1~2 字母前缀下最常用的词排前面。
    #    单字母只放单字（打 s 该出「是 说 上」，不是「傻逼 上班」）；
    #    双字母放全部，单字仍加权保证基本字优先。
    LEN_MUL = {1: 1.0, 2: 0.5}
    buckets = defaultdict(list)
    for key, d in list(filtered.items()):
        if MARK in key:
            continue
        lim = min(AGG_PREFIX_LEN, len(key))
        for L in range(1, lim + 1):
            p = key[:L]
            for w, wt in d.items():
                if L == 1 and len(w) > 1:
                    continue
                # 顶级优先词权重太大，不进两字母补全表 —— 否则打 ha/sm 会被 好兄弟/什么鬼 顶掉常用单字
                if wt > COLLOQ_W:
                    continue
                buckets[p].append((wt * LEN_MUL.get(len(w), 0.3), wt, w))
    agg_n = 0
    for p, lst in buckets.items():
        if len(lst) < 2:
            continue
        lst.sort(key=lambda x: (-x[0], len(x[2]), x[2]))
        seen, top = set(), []
        for sc, wt, w in lst:
            if w in seen:
                continue
            seen.add(w)
            top.append((sc, w))
            if len(top) >= AGG_TOP:
                break
        d = filtered.setdefault(p + MARK, {})
        # 存「按长度折算过的词频」（落盘时换算成对数概率）：
        #   不能存名次 —— 存名次的话 是 会被算成 log(48/总量) ≈ -17.6，连 撒(-13.5) 都压不过；
        #   也不能存原始词频 —— 那样打 za 会被 在线/咱们 这种长词霸榜，单字 咋/咱 挤不进去。
        for sc, w in top:
            d[w] = max(1, int(round(sc)))
        agg_n += 1
    print("短输入补全表:", agg_n, "个前缀")

    # 6) 简拼表：首字母缩写。key = \x7f + 缩写，引擎精确取。
    syl_set = set(char_first.values())
    alive = set()
    for _d in filtered.values():
        alive.update(_d)
    abbr_n = 0
    for ini, slot in ABBR_SRC.items():
        items = [(w, wt) for w, wt in slot.items() if w in alive]
        if not items:
            continue
        items.sort(key=lambda kv: (-kv[1], len(kv[0]), kv[0]))
        d = filtered.setdefault(MARK + ini, {})
        for w, wt in items[:ABBR_TOP]:
            d[w] = wt
        abbr_n += 1
    print("简拼表:", abbr_n, "个缩写")

    # 7) 落盘。每条候选编码成「两字节全局对数概率 + 词」。
    #    引擎不再看名次，直接吃 log P(词)：前缀、缩写、词图 Viterbi 用的是同一把尺子。
    TOTAL = sum(FREQ.values()) or 1
    keys = sorted(filtered.keys())
    entries = []
    for k in keys:
        if MARK in k:
            cap = AGG_TOP if k.endswith(MARK) else ABBR_TOP
        else:
            cap = cap_for(len(k))
        words = sorted(filtered[k].items(), key=lambda kv: (-kv[1], len(kv[0]), kv[0]))
        recs = []
        for w, wt in words[:cap]:
            recs.append(logp_code(wt, TOTAL) + w)
        entries.append((k, recs))

    syllables = sorted(k for k in filtered.keys() if 1 <= len(k) <= 6 and k in syl_set)

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
    out += struct.pack("<IIIIIIIIII", 2, n, key_off_off, val_off_off,
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


if __name__ == "__main__":
    build()
