# -*- coding: utf-8 -*-
"""全方案官方参考码验证：把各百科/官网文档里的示例编码逐一核对"""
import re

sw = open(r'D:\AndroidProjects\anran_ime\Sources\Shared\DoublePinyinTables.swift', encoding='utf-8').read()
tables = {}
for m in re.finditer(r'"(\w+)": "([^"]+)"', sw):
    tables[m.group(1)] = dict(
        e.split("=", 1) for e in m.group(2).split(";") if "=" in e)

# (方案, 编码, 期望音节, 来源)
REFS = [
    # 小鹤（flypy.cc 官网 + 新人角度 PDF + shuangpin.xyz）
    ("flypy", "il", "chuang", "床前明月光示例"),
    ("flypy", "qm", "qian", "床前明月光示例"),
    ("flypy", "mk", "ming", "床前明月光示例"),
    ("flypy", "yt", "yue", "床前明月光示例"),
    ("flypy", "gl", "guang", "床前明月光示例"),
    ("flypy", "ai", "ai", "官网:爱=ai"),
    ("flypy", "en", "en", "官网:恩=en"),
    ("flypy", "ou", "ou", "官网:欧=ou"),
    ("flypy", "ah", "ang", "官网:昂=ah"),
    ("flypy", "aa", "a", "官网:啊=aa"),
    ("flypy", "oo", "o", "官网:哦=oo"),
    ("flypy", "ee", "e", "官网:额=ee"),
    ("flypy", "ul", "shuang", "PDF:双=ul"),
    ("flypy", "fh", "fang", "PDF:方=fh"),
    ("flypy", "da", "da", "PDF:大=da"),
    ("flypy", "yb", "yin", "口诀:滨=in(B)"),
    ("flypy", "yk", "ying", "口诀:迎=ing(K)"),
    ("flypy", "ww", "wei", "口诀:闱=ei(W)"),
    ("flypy", "wd", "wai", "口诀:带=ai(D),外=w+d"),
    ("flypy", "yy", "yun", "口诀:云=un(Y)"),
    ("flypy", "yt", "yue", "口诀:月=ue(T)"),
    ("flypy", "ya", "ya", "注音指南:牙=ya"),
    # 微软（百度百科 + 搜狗百科 + 中文百科）
    ("mspy", "mm", "mian", "棉鞋=MMXX"),
    ("mspy", "xx", "xie", "棉鞋=MMXX"),
    ("mspy", "dm", "dian", "电脑=DMNK"),
    ("mspy", "nk", "nao", "电脑=DMNK"),
    ("mspy", "yp", "yun", "云=YP"),
    ("mspy", "lb", "lou", "楼=LB"),
    ("mspy", "js", "jiong", "窘=JS"),
    ("mspy", "ld", "liang", "梁=LD"),
    ("mspy", "lm", "lian", "连=LM"),
    ("mspy", "wf", "wen", "百科:文(w+en)=F"),
    ("mspy", "ol", "ai", "百科:爱=OL"),
    ("mspy", "oj", "an", "百科:安=OJ"),
    ("mspy", "oh", "ang", "百科:昂=OH"),
    ("mspy", "oa", "a", "百科:啊=OA"),
    ("mspy", "oe", "e", "百科:额=OE"),
    ("mspy", "or", "er", "百科:儿=OR"),
    ("mspy", "oo", "o", "百科:哦=OO"),
    # 搜狗（百度百科）
    ("sogou", "vb", "zhou", "周=vb"),
    ("sogou", "su", "su", "苏=su"),
    ("sogou", "vj", "zhan", "展=vj"),
    ("sogou", "mn", "min", "黾=mn"),
    ("sogou", "ns", "nong", "农=ns"),
    ("sogou", "ol", "ai", "百科:爱=OL"),
    ("sogou", "oj", "an", "百科:安=OJ"),
    ("sogou", "oh", "ang", "百科:昂=OH"),
    ("sogou", "oa", "a", "百科:啊=OA"),
    ("sogou", "oe", "e", "百科:额=OE"),
    ("sogou", "or", "er", "百科:儿=OR"),
]

ok = bad = 0
fails = []
for scheme, code, want, src in REFS:
    got = tables.get(scheme, {}).get(code)
    if got and want in got:
        ok += 1
    else:
        bad += 1
        fails.append((scheme, code, want, got, src))

print("通过 %d / %d" % (ok, ok + bad))
for scheme, code, want, got, src in fails:
    print("  [%s] %s 期望 %s 实得 %s   (%s)" % (scheme, code, want, got, src))
