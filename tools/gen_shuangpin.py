# -*- coding: utf-8 -*-
"""从 rime-ice 官方双拼 schema 的 algebra 生成 Swift 解码表。

不手抄映射表（错一个键整个方案就废）——直接执行 algebra 规则：
对每个无调音节应用 derive(别名分支)/xform(变换) + xlit(键位翻译)，
收集所有 2 键编码，生成 code -> [音节] 映射。

零声母双轨制（关键兼容性设计）：
  rime-ice 的 algebra 与各方案官方标准有偏差（如小鹤官方 爱=ai/昂=ah，
  rime-ice algebra 却给 ad/aah）。商业输入法（搜狗/百度/QQ）实现的是官方标准，
  而 rime 用户的肌肉记忆是 algebra 产物。因此两套编码全部入表：
    · algebra 产物（rime 兼容）
    · 官方标准码：小鹤/自然码字长分类法（单字母 VV、双字母全拼、三字母 V+韵母键）；
      微软/搜狗/紫光/ABC 的 O 占位法（o+韵母键）；加加的首字母重复法
  冲突检测：若官方标准码已被别的音节占用则跳过并报告。

输出：Sources/Shared/DoublePinyinTables.swift
"""
import os
import re

RIME = r"C:\Users\刘强强\AppData\Local\Temp\rime-ice"
OUT = r"D:\AndroidProjects\anran_ime\Sources\Shared\DoublePinyinTables.swift"
PINYIN_TXT = r"C:\Users\刘强强\AppData\Local\Temp\dict_src\pinyin.txt"

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

# ---------------------------------------------------------------- 音节表
syllables = set()
for line in open(PINYIN_TXT, encoding="utf-8"):
    line = line.split("#")[0].strip()
    if not line or ":" not in line:
        continue
    code, _, readings = line.partition(":")
    if not code.strip().startswith("U+"):
        continue
    for r in readings.strip().split(","):
        k = strip_tone(r.strip())
        if k and k.isalpha() and k.isascii():
            syllables.add(k)
syllables.update(["en", "wu", "heng", "hen"])   # 词典 SYL_FIX 后的形态
syllables = sorted(syllables)

# 零声母音节（无声母，以 a/o/e 开头）
INITIALS = set("bpmfdtnlgkhjqxrzcsyw")
def is_zero_init(syl):
    return syl and syl[0] not in INITIALS

# ---------------------------------------------------------------- algebra 解析
def parse_algebra(path):
    txt = open(path, encoding="utf-8").read()
    m = re.search(r"\n  algebra:\n((?:    - .*\n)+)", txt)
    if not m:
        raise SystemExit("no algebra in " + path)
    rules = []
    for line in m.group(1).splitlines():
        line = line.strip()
        if not line.startswith("- "):
            continue
        body = line[2:]
        if "/" not in body:
            continue
        kind, _, rest = body.partition("/")
        if kind not in ("xform", "derive", "xlit", "erase", "abbrev"):
            continue
        segs = rest.split("/")
        pat = segs[0]
        rep = segs[1] if len(segs) > 1 else ""
        # rime 用 $1 反向引用，Python 用 \1
        rep = re.sub(r"\$(\d)", r"\\\1", rep)
        rules.append((kind, pat, rep))
    return rules

def apply_algebra(syl, rules):
    """分支应用：derive 保留原形+派生形，xform 替换，xlit 逐字符翻译。"""
    forms = {syl}
    for kind, pat, rep in rules:
        nxt = set()
        rx = re.compile(pat)
        for f in forms:
            if kind == "xform":
                nxt.add(rx.sub(rep, f))
            elif kind == "derive":
                nxt.add(f)
                d = rx.sub(rep, f)
                if d != f:
                    nxt.add(d)
            elif kind == "xlit":
                nxt.add(f.translate(str.maketrans(pat, rep)))
            else:
                nxt.add(f)
        forms = nxt
    return forms

# 韵母键位探测：用「声母+韵母」的真实音节跑 algebra，取编码第二字符。
# 例：bang -> bh  => ang 的键是 h
PROBE = {
    "a": "da", "o": "bo", "e": "de",
    "ai": "bai", "an": "ban", "ang": "bang", "ao": "bao",
    "ei": "bei", "en": "ben", "eng": "beng",
    "ou": "dou", "er": None,
}

def er_key(rules):
    """从 algebra 里找 er 的键位（如 xform/er$|.../Ⓡ/ -> r）。"""
    for kind, pat, rep in rules:
        if kind != "xform":
            continue
        # 模式形如 er$ / er$|[uv]an$ / er$|iu$
        if re.search(r"(^|\|)er\$", pat):
            m = re.match(r"([^a-z\\])", rep)
            if m:
                return m.group(1)
    return None

SCHEMES = [
    ("flypy", "小鹤双拼", "double_pinyin_flypy.schema.yaml"),
    ("mspy", "微软双拼", "double_pinyin_mspy.schema.yaml"),
    ("sogou", "搜狗双拼", "double_pinyin_sogou.schema.yaml"),
    ("nature", "自然码", "double_pinyin.schema.yaml"),
    ("ziguang", "紫光拼音", "double_pinyin_ziguang.schema.yaml"),
    ("abc", "智能ABC", "double_pinyin_abc.schema.yaml"),
    ("jiajia", "加加双拼", "double_pinyin_jiajia.schema.yaml"),
]

def final_key(final, rules):
    probe = PROBE.get(final)
    if probe is None:
        return None
    codes = [c for c in apply_algebra(probe, rules)
             if len(c) == 2 and c.isascii() and c.isalpha()]
    return codes[0][1] if codes else None

blocks = []
for sid, name, fn in SCHEMES:
    rules = parse_algebra(os.path.join(RIME, fn))
    code2syl = {}

    def put(code, syl):
        if len(code) != 2 or not code.isascii() or not code.isalpha():
            return False
        code2syl.setdefault(code, [])
        if syl not in code2syl[code]:
            code2syl[code].append(syl)
        return True

    # 1) algebra 产物（rime 兼容）
    for syl in syllables:
        for code in apply_algebra(syl, rules):
            put(code, syl)

    # 2) 官方标准零声母码（与各商业输入法实现对齐）
    keys = {}
    for f in PROBE:
        k = final_key(f, rules)
        if k:
            keys[f] = k
    ek = er_key(rules)
    if ek:
        keys["er"] = ek
    added = {"len1": 0, "len2": 0, "len3": 0, "o": 0}
    skipped = []
    for syl in syllables:
        if not is_zero_init(syl) or len(syl) > 3:
            continue
        cand = []
        if len(syl) == 1:
            cand.append(("len1", syl + syl))              # 啊=aa
        elif len(syl) == 2:
            cand.append(("len2", syl))                    # 爱=ai（全拼方式）
        else:
            k = keys.get(syl)
            if k:
                cand.append(("len3", syl[0] + k))         # 昂=ah
        # O 占位法（微软/搜狗/紫光/ABC）：所有零声母 = o + 韵母键
        k = keys.get(syl)
        if k:
            cand.append(("o", "o" + k))                   # 昂=OH
        for style, code in cand:
            if code in code2syl and syl not in code2syl[code]:
                skipped.append((code, syl, code2syl[code]))
                continue
            if put(code, syl):
                added[style] += 1

    parts = []
    for code in sorted(code2syl):
        parts.append(code + "=" + ",".join(sorted(code2syl[code])))
    blob = ";".join(parts)
    blocks.append('        "%s": "%s",' % (sid, blob))
    multi = sum(1 for v in code2syl.values() if len(v) > 1)
    print("%-8s %-6s 编码=%d 多音节编码=%d 官方码补充(aa/ai/ah/o)=%s 跳过冲突=%d"
          % (sid, name, len(code2syl), multi, added, len(skipped)))
    for c, s, ex in skipped[:5]:
        print("    skip %s->%s (已被 %s 占用)" % (c, s, ex))

swift = '''// -*- coding: utf-8 -*-
// 双拼解码表（自动生成，勿手改）。
//
// 由 tools/gen_shuangpin.py 执行 rime-ice 官方 schema 的 speller/algebra 生成：
// 对每个无调音节应用 derive/xform/xlit 规则得到 2 键编码；零声母额外收录
// 各方案官方标准码（小鹤/自然码字长分类法、微软/搜狗/紫光/ABC 的 O 占位法），
// 兼容搜狗/百度/QQ 输入法用户的肌肉记忆。改方案请改生成器。
//
// 格式：每方案一段紧凑串，条目用 ; 分隔，条目内 code=音节1,音节2。
// 音节为无调拼音，ü 写作 v（与词库 pinyin.bin 约定一致）。

import Foundation

enum DoublePinyinTables {

    /// 方案 id -> 紧凑表。运行时按需解析成字典。
    static let raw: [String: String] = [
%s
    ]

    static func decode(_ scheme: String, _ code: String) -> [String]? {
        table(scheme)?[code]
    }

    private static var cache: [String: [String: [String]]] = [:]

    static func table(_ scheme: String) -> [String: [String]]? {
        if let c = cache[scheme] { return c }
        guard let blob = raw[scheme] else { return nil }
        var d: [String: [String]] = [:]
        for entry in blob.split(separator: ";") {
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let code = String(entry[entry.startIndex..<eq])
            let syls = entry[entry.index(after: eq)...].split(separator: ",").map(String.init)
            if !code.isEmpty && !syls.isEmpty {
                d[code] = syls
            }
        }
        cache[scheme] = d
        return d
    }
}
''' % ("\n".join(blocks))

os.makedirs(os.path.dirname(OUT), exist_ok=True)
open(OUT, "w", encoding="utf-8").write(swift)
print("written:", OUT, os.path.getsize(OUT), "bytes")

# 抽验：床前明月光 = il qmmkyt gl（小鹤官方示例）
fp = dict(p.split("=", 1) for p in
          [b for b in blocks[0].split('"')[3].split(";") if b])
for w, c in [("床", "il"), ("前", "qm"), ("明", "mk"), ("月", "yt"), ("光", "gl"),
             ("爱", "ai"), ("昂", "ah"), ("啊", "aa"), ("恩", "en"), ("双", "ul"),
             ("方", "fh"), ("大", "da")]:
    print("  小鹤 %s = %s -> %s" % (w, c, fp.get(c)))
