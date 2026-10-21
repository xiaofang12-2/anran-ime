# -*- coding: utf-8 -*-
"""从词级语言模型生成「句级」评测用例（tools/eval/sentences.tsv）。

为什么需要它：
    cases.tsv 测的是「单词语音 → 首选词」，那一层已经 100%，测不出解码器好坏。
    真正的差距在**连续输入**：用户打 jintiantianqizenmeyang，
    引擎必须在没有空格的情况下切出「今天 / 天气 / 怎么样」，而不是「今天天 / 气 / 怎么样」。
    这一层唯一可靠的期望值来源就是语言模型自己 —— 词级 LM 里 P(后继|前词) 高的
    词对，本来就是语料里真实连续出现的搭配。

做法：
    1) pinyin.bin 反查，得到 词 → 最常见拼音（只取纯汉字 2~3 字词）；
    2) assoc_w.bin（ANWG v2）里取 P(后继|前词) 最高的若干词对，且两端都有拼音；
    3) 两句拼成一句：pinyin(前)+pinyin(后) → 前+后；再接一层成三词句。

期望值合法性：
    期望值 = 语言模型认为最自然的那个切分。若引擎选了别的切分，说明它的 LM
    权重没压过词频项 —— 这正是「整句不如百度」的病灶，测出来就该红。

用法：python tools/eval/gen_sentences.py
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
PINYIN = os.path.join(ROOT, "Support", "dict", "pinyin.bin")
ASSOC_W = os.path.join(ROOT, "Support", "dict", "assoc_w.bin")
OUT = os.path.join(HERE, "sentences.tsv")

WLM_FLOOR = -10.0

CJK = lambda ch: 0x3400 <= ord(ch) <= 0x9fff


def load_pinyin(path):
    """-> {pinyin: [(word, q)]}  q 越大越常见"""
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


def word_pinyin(py_map):
    """词 -> 最常见拼音；**只收该拼音下的前两名**（= 真正常用的词）。

    为什么卡前两名：词库里 54 万词，大半是生僻长尾。拿它们拼句子，
    出来的都是「一丛深色」这种没人这么打的东西，测不出解码器好坏。
    """
    best = {}
    for py, cands in py_map.items():
        if "v" in py:
            continue
        if not py.isalpha():
            continue
        for rank, (word, q) in enumerate(cands[:5]):
            if not (1 <= len(word) <= 3) or not all(CJK(c) for c in word):
                continue
            # 多字词只收前两名（常用）；单字放宽到前四 —— 单字候选里
            # 「先/样/睡」这类常用虚词经常排在第 3、4 位
            if len(word) >= 2 and rank >= 2:
                continue
            cur = best.get(word)
            if cur is None or q > cur[1]:
                best[word] = (py, q)
    return {w: v[0] for w, v in best.items()}


def load_assoc_w(path):
    """ANWG v2 -> {prev: [(fol, lp)]}"""
    d = open(path, "rb").read()
    assert d[:4] == b"ANWG" and d[4] == 0x32, "bad ANWG"
    n = struct.unpack("<I", d[5:9])[0]
    kT = struct.unpack("<I", d[9:13])[0]
    vT = struct.unpack("<I", d[13:17])[0]

    def u32(o):
        return struct.unpack("<I", d[o:o + 4])[0]

    out = {}
    for i in range(n):
        a, b = u32(kT + 4 * i), u32(kT + 4 * (i + 1))
        if not (0 < b - a < 200):
            continue
        prev = d[a:b].decode("utf-8", "replace")
        va, vb = u32(vT + 4 * i), u32(vT + 4 * (i + 1))
        if not (0 < vb - va):
            continue
        rows = []
        for seg in d[va:vb].split(b"\x01"):
            if len(seg) < 2:
                continue
            code = seg[0]
            fol = seg[1:].decode("utf-8", "replace")
            lp = WLM_FLOOR + (code - 2) / 253.0 * (0 - WLM_FLOOR)
            rows.append((fol, lp))
        if rows:
            out[prev] = sorted(rows, key=lambda x: -x[1])
    return out


# ---------------------------------------------------------------- 手写句库
# 只写「词序列」，拼音一律由词库反查 —— 手写拼音必错（v/lv、儿化、轻声），
# 反查出来的拼音与引擎看到的完全一致，用例才可信。
# 覆盖：日常/口语/工作/时间/疑问/否定/并列/长句，长度 5~22 字母。
SENTENCES = """
今天 天气 怎么样
明天 我们 一起 去 吃饭
这个 事情 很 重要
你 什么 时候 回来
我 不 知道 他 去 哪里 了
今天 晚上 有 空 吗
帮 我 看 一下 这个 文件
你 在 干什么
我 现在 有点 忙
马上 就 好 了
先 这样 吧 再 说
这个 问题 我 不 太 清楚
你 觉得 怎么 样
我们 明天 再 讨论
把 他 的 电话 发 给 我
这个 方案 还 需要 修改
什么 时候 能 完成
我 已经 发 出去 了
请 你 确认 一下
他 说 明天 会 来
今天 太 累 了
你 吃 饭 了 吗
我 想 睡 一会 儿
昨 天 我 去 了 超市
这个 星期 有 时间 吗
麻烦 你 帮 个 忙
我 记得 你 说 过
这样 做 不 太 好
我们 再 看 看 吧
他 不 在 办公 室
我 们 下午 开会
你 有 什么 建议
这 件 事 我 来 处理
今天 的 会议 取消 了
你 到 家 了 吗
我 在 路 上 了
马上 到
再 等 我 五 分钟
这个 价格 太 高 了
我们 需要 更 多 时间
你 先 别 着 急
我 会 尽快 回复 你
他 已经 离 开 了
请 把 门 关 上
我 不 太 舒服
今天 下雨 了
记得 带 伞
天气 预报 说 明天 降温
你 最 近 怎么 样
好久 不 见
最 近 忙 什么 呢
工作 还 顺利 吗
有 什么 需要 帮忙 的
随时 联系 我
我 已经 到 公司 了
会议 室 在 三 楼
文件 放 在 桌子 上
你 看 到 我的 消息 了 吗
我 马上 就 到
你 说 的 对
确实 是 这样
我 同意 你 的 看法
这 个 我 不 太 懂
能 不 能 再 说 一遍
声音 有点 小
我 听 不 清楚
你 能 再说 一遍 吗
今天 是 星期 几
现在 几 点 了
我 忘 了 带 钥匙
外面 风 很 大
注意 保 暖
明天 见
晚 上 好
早 上 好
你 好 呀
谢谢 你 的 帮助
不 用 客气
对 不 起 我 来 晚 了
没 关系
这 是 我的 问题
我 会 改 的
请 稍 等 一下
我 查 一下 再 回复 你
资料 已经 发 你 邮箱 了
请 查 收
有 问题 随时 找 我
我们 下 周 见
"""


def build_from_sentences(py_map, w2p):
    """把词序列句库翻成 (拼音串, 期望文本)"""
    lines, missing = [], {}
    for raw in SENTENCES.strip().splitlines():
        words = raw.split()
        if not words:
            continue
        pys = []
        ok = True
        for w in words:
            py = w2p.get(w)
            if py is None:
                missing[w] = missing.get(w, 0) + 1
                ok = False
                break
            pys.append(py)
        if not ok:
            continue
        py = "".join(pys)
        if not (4 <= len(py) <= 30):
            continue
        lines.append("%s\t%s\ts1" % (py, "".join(words)))
    if missing:
        print("!! 词库缺词（该句已跳过）：", missing)
    return lines


def main():
    py_map = load_pinyin(PINYIN)
    w2p = word_pinyin(py_map)
    lm = load_assoc_w(ASSOC_W)
    print("词->拼音 %d 个，LM 前词 %d 个" % (len(w2p), len(lm)))

    hand = build_from_sentences(py_map, w2p)
    print("手写句：%d 条" % len(hand))

    # ---- 生成式补充：LM 里两端都是「多搭配真词」的接续 ----
    pairs = []
    for prev, rows in lm.items():
        if prev not in w2p or len(rows) < 2:
            continue
        for fol, lp in rows[:3]:
            if fol not in w2p or len(lm.get(fol, [])) < 2:
                continue
            if not (WLM_FLOOR + 0.5 <= lp <= -0.5):
                continue
            pairs.append((prev, fol, lp))
    pairs.sort(key=lambda x: -x[2])
    # 按前词首字打散，避免整份用例集中在同一个字开头
    buckets = {}
    for pr, fo, lp in pairs:
        buckets.setdefault(pr[0], []).append((pr, fo, lp))
    balanced = []
    while len(balanced) < 400 and any(buckets.values()):
        for k in list(buckets.keys()):
            if buckets[k]:
                balanced.append(buckets[k].pop(0))
            if len(balanced) >= 400:
                break
        for k in [k for k, v in buckets.items() if not v]:
            buckets.pop(k, None)
    pairs = balanced
    print("生成式候选词对 %d 个" % len(pairs))

    seen = set()
    lines = list(hand)
    for ln in hand:
        seen.add(ln.split("\t")[0])

    def emit(words, cat):
        py = "".join(w2p[w] for w in words)
        text = "".join(words)
        if not (4 <= len(py) <= 30):
            return
        if py in py_map or py in seen:      # 整串已是词库整词 → 测的是查表
            return
        seen.add(py)
        lines.append("%s\t%s\t%s" % (py, text, cat))

    two = []
    for prev, fol, lp in pairs:
        if len(two) >= 70:
            break
        emit([prev, fol], "s2")
        two.append((prev, fol))
    for prev, fol in two[:30]:
        nxt = [w for w in lm.get(fol, []) if w in w2p][:1]
        if nxt:
            emit([prev, fol, nxt[0]], "s3")

    with open(OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("# pinyin\texpect\tcategory\n")
        f.write("\n".join(lines))
        f.write("\n")
    print("写出 %s：%d 条（手写 %d / 生成 %d）"
          % (OUT, len(lines), len(hand), len(lines) - len(hand)))
    for ln in lines[:6]:
        print("   ", ln)


if __name__ == "__main__":
    main()
