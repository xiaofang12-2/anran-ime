# -*- coding: utf-8 -*-
"""把策展词表（热词/核心词/口语）导出成 Swift 常量，供运行时加权。

为什么需要在运行时加，而不是写进词库：
    `weixin` 在词库里本来就把「威信」排在「微信」前面（rime 词频口径），
    而 fix_wordfreq.py 改写 logP 时必须保证「同一拼音键内显示顺序不变」
    （否则会把用户习惯的首屏顺序打乱）。两者冲突，所以在排序层做加成：
    策展词在 rank() 里额外加分，越过原词库的顺序，但不改动词库字节。

数据来源：tools/hot_words.py / core_words.py / colloquial.py
输出：Sources/Keyboard/CuratedWords.swift（一个 Set<String> 字面量）

用法：python tools/gen_curated.py
"""
import importlib.util
import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(
    HERE, "..", "Sources", "Keyboard", "CuratedWords.swift"))

SOURCES = [
    ("hot_words", ["TOP", "COMBOS"]),
    ("core_words", ["CORE", "CORE_TOP"]),
    ("colloquial", ["COLLOQUIAL"]),
]


def collect():
    words = set()
    for modname, names in SOURCES:
        path = os.path.join(HERE, modname + ".py")
        if not os.path.exists(path):
            print("!! 缺少", path)
            continue
        spec = importlib.util.spec_from_file_location(modname, path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        for nm in names:
            obj = getattr(mod, nm, None)
            if obj is None:
                continue
            for item in obj:
                w = item[0] if isinstance(item, tuple) else item
                if isinstance(w, str) and w.strip():
                    words.add(w.strip())
    return sorted(words)


def main():
    words = collect()
    # 每行 6 个，避免单行超长导致编译器慢
    lines = []
    for i in range(0, len(words), 6):
        chunk = ", ".join('"%s"' % w for w in words[i:i + 6])
        lines.append("        " + chunk + ",")
    body = "\n".join(lines)

    tpl = """// 本文件由 tools/gen_curated.py 自动生成，请勿手改。
// 策展词（热词 / 核心词 / 口语）在排序时享受固定加成：
// 这些词反映「当下中国人真正常打的词」，而 rime 词频口径偏旧（微信、呵呵、绝绝子
// 这类要么权重低、要么排序在后）。加成只影响排序，不改词库字节。
import Foundation

enum CuratedWords {
    /// 命中即加的分（nat）。要越过「rime 口径偏旧」造成的 1~2 nat 差距
    /// （微信 -13.5 vs 威信 -11.6），所以给到 2.8。
    static let boost = 2.8
    /// 抬升上限：策展词再重要也不能超过「真·高频词」的位置，避免刷屏。
    static let ceiling = -6.5

    static let set: Set<String> = [
__BODY__
    ]
}
"""
    src = tpl.replace("__BODY__", body)
    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write(src)
    print("写出 %s：%d 个词，%d 行" % (OUT, len(words), len(lines)))


if __name__ == "__main__":
    main()
