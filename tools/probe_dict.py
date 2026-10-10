# -*- coding: utf-8 -*-
"""诊断 pinyin.bin：跑的就是键盘里那台解码器（Python 参考实现）。

引擎路子对标 librime / 百度输入法：
    输入拼音
      -> 音节图（SyllableGraph）：每个位置能切出哪些音节
      -> 词图（WordGraph）：音节路径拼成拼音串去词典查词
      -> 词图上的 Beam Search / Viterbi：score = Σ log P(词)
      -> 候选：全覆盖句子 + 前缀补全词

词典里每条候选存的是「全局对数概率」（两字节），不是名次。
所以跨键比较、句子路径打分用的是同一把尺子 —— 不再有 900000/620000 这种手写常数。

用法:
  python probe_dict.py xbzz za nmsl        # 看具体输入
  python probe_dict.py --cover             # 扫 1~3 字母，列出「一个汉字都出不来」的输入
"""
import math
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "..", "Support", "dict", "pinyin.bin")
BIN_LM = os.path.join(HERE, "..", "Support", "dict", "assoc.bin")
MARK = "\u007f"

LOGB0 = 0x10
LOGB1 = 0x7E
LOGSPAN = LOGB1 - LOGB0 + 1
LOGN = LOGSPAN * LOGSPAN
LOG_FLOOR = 24.0

# librime poet.cc：单句每状态扩 7 条；N-best 的 beam = max_sentences*3。
# 这里取 12，兼顾候选丰富度与速度。
BEAM = 12

# 前缀补全惩罚：补全得越多，越靠后（打 nihao 时 你好 要压过 你好吗 这种长词）。
COMP_PEN = 0.55

# librime grammar.h：路径得分 = Σ entry_weight(词) + Σ context_penalty(词 | 前文)。
# entry_weight 就是词库里的 log P(词)；context_penalty 由语言模型给出。
# 这里用字级 bigram（assoc.bin）近似：上一个词的尾字 -> 这个词的头字，
# 接续越可信罚越少，接续越离谱罚越重 —— 这是「词图 + n-gram」里 n-gram 那一项。
LM_REF = -3.5          # 参考线：比它常见的接续不罚，比它罕见按差距罚
LM_W = 0.3             # 上下文项权重：只做「切分微调」，不许盖过 entry_weight
LPMIN = -12.0          # 与 build_assoc.py 的量化下限一致


class LM:
    """字级 bigram：ctx 首字 -> {后继字: log P(后继 | ctx)}。"""

    def __init__(self, path):
        self.tab = {}
        if not os.path.exists(path):
            return
        d = open(path, "rb").read()
        if d[:4] != b"ANBG":
            return
        for rec in d[5:].decode("utf-8", "ignore").split("\x03"):
            if not rec:
                continue
            ctx, sep, rest = rec.partition("\x02")
            if not sep or not ctx:
                continue
            row = {}
            for ent in rest.split("\x01"):
                if len(ent) < 2:
                    continue
                code = ord(ent[-1])
                row[ent[:-1]] = LPMIN + (code - 2) / 253.0 * (0 - LPMIN)
            if row:
                self.tab[ctx] = row

    def penalty(self, ctx, fol):
        """把一个词的尾字接到下一个词的头字，返回该接续的罚分（>= 0）。

        没见过的接续（含「这个字从没当过上下文」）按最罕见处理 ——
        否则生僻字会白捡一个「零罚分」把常用字挤下去。
        """
        row = self.tab.get(ctx)
        lp = row.get(fol) if row else None
        if lp is None:
            lp = LPMIN
        if lp >= LM_REF:
            return 0.0
        return LM_W * (LM_REF - lp)


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def dec_logp(rec):
    """两字节 -> 对数概率，落在 [-24, 0]。越大越常用。"""
    hi = ord(rec[0]) - LOGB0
    lo = ord(rec[1]) - LOGB0
    q = hi * LOGSPAN + lo
    if q < 0:
        q = 0
    if q > LOGN - 1:
        q = LOGN - 1
    return q / (LOGN - 1) * LOG_FLOOR - LOG_FLOOR


class Dict:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.b = f.read()
        assert self.b[:4] == b"ANPY"
        self.ver = u32(self.b, 4)
        self.n = u32(self.b, 8)
        self.key_off = u32(self.b, 12)
        self.val_off = u32(self.b, 16)
        self.keys = []
        for i in range(self.n):
            a = u32(self.b, self.key_off + 4 * i)
            e = u32(self.b, self.key_off + 4 * (i + 1))
            self.keys.append(self.b[a:e].decode("utf-8"))
        self.syl_n = u32(self.b, 28)
        self.syl_off = u32(self.b, 32)
        self.syls = set()
        for i in range(self.syl_n):
            a = u32(self.b, self.syl_off + 4 * i)
            e = u32(self.b, self.syl_off + 4 * (i + 1))
            self.syls.add(self.b[a:e].decode("utf-8"))
        self._vcache = {}

    def vals(self, i):
        """第 i 个键的候选 [(词, logP), ...]。"""
        v = self._vcache.get(i)
        if v is not None:
            return v
        a = u32(self.b, self.val_off + 4 * i)
        e = u32(self.b, self.val_off + 4 * (i + 1))
        s = self.b[a:e].decode("utf-8")
        out = []
        pos = 0
        while pos < len(s):
            rec = s[pos:].split("\x01", 1)
            chunk = rec[0]
            pos += len(chunk) + 1
            if len(chunk) < 3:
                continue
            out.append((chunk[2:], dec_logp(chunk)))
        self._vcache[i] = out
        return out

    def lower_bound(self, prefix):
        lo, hi = 0, self.n
        while lo < hi:
            mid = (lo + hi) // 2
            if self.keys[mid] < prefix:
                lo = mid + 1
            else:
                hi = mid
        return lo

    def exact(self, key):
        i = self.lower_bound(key)
        if i < self.n and self.keys[i] == key:
            return i
        return None


FUZZ = [("zh", "z"), ("ch", "c"), ("sh", "s"), ("ang", "an"), ("eng", "en"),
        ("ing", "in"), ("iang", "ian"), ("uang", "uan"), ("n", "l"), ("f", "h")]


def fuzzy_variants(s):
    out = [s]
    for a, b in FUZZ:
        snap = list(out)
        for v in snap:
            if len(out) >= 8:
                return out
            if a in v:
                nv = v.replace(a, b, 1)
                if nv not in out:
                    out.append(nv)
    return out


class Engine:
    def __init__(self, d, lm=None):
        self.d = d
        self.lm = lm if lm is not None else LM(BIN_LM)

    # ---------------------------------------------------------- 词图边
    def _full_edges(self, inp, i):
        """从 i 出发，所有「整词匹配」的边 (j, 词, logP)。"""
        out = []
        n = len(inp)

        def dfs(pos, acc):
            if acc:
                idx = self.d.exact(acc)
                if idx is not None:
                    for w, lp in self.d.vals(idx):
                        out.append((pos, w, lp))
            if pos >= n:
                return
            for L in range(1, min(6, n - pos) + 1):
                sub = inp[pos:pos + L]
                if sub in self.d.syls:
                    dfs(pos + L, acc + sub)

        dfs(i, "")
        return out

    def _abbr_edges(self, inp):
        """整串当缩写/混拼：把每个音节折成首字母，查 \x7f+缩写 表。"""
        n = len(inp)
        out = []
        seen = set()

        def go(pos, ini):
            if pos == n and 2 <= len(ini) <= 5 and ini not in seen:
                idx = self.d.exact(MARK + ini)
                if idx is not None:
                    seen.add(ini)
                    for w, lp in self.d.vals(idx):
                        out.append((n, w, lp))
            if pos >= n or len(ini) >= 5:
                return
            go(pos + 1, ini + inp[pos])
            for L in range(2, min(6, n - pos) + 1):
                sub = inp[pos:pos + L]
                if sub in self.d.syls:
                    go(pos + L, ini + sub[0])

        go(0, "")
        return out

    # ---------------------------------------------------------- 解码
    def beam(self, inp, beam=BEAM):
        """词图上的 Beam Search。返回每个位置的 (总logP, 词元组)。"""
        n = len(inp)
        if n == 0:
            return []
        edges = [self._full_edges(inp, i) for i in range(n)]
        # 缩写/混拼只在「整串切不成完整音节」时才算候选：
        # 否则 gun 会被读成 g(gu)+n，缩写表里 g n 一抓一大把（国内/功能/概念…）把 滚 挤下去。
        if n >= 2 and not self._splits(inp):
            edges[0] = edges[0] + self._abbr_edges(inp)
        states = [[] for _ in range(n + 1)]
        states[0] = [(0.0, ())]
        for i in range(n):
            cur = states[i]
            if not cur:
                continue
            if len(cur) > beam:
                cur.sort(key=lambda x: -x[0])
                cur = cur[:beam]
                states[i] = cur
            for sc, ws in cur:
                for j, w, lp in edges[i]:
                    # grammar.h 的上下文项：上一个词的尾字接这个词的头字
                    pen = self.lm.penalty(ws[-1][-1], w[0]) if ws else 0.0
                    states[j].append((sc + lp - pen, ws + (w,)))
        if len(states[n]) > beam:
            states[n].sort(key=lambda x: -x[0])
            states[n] = states[n][:beam]
        return states

    def prefix_words(self, inp, cap_keys=240, per_key=6):
        """所有拼音以 inp 开头的词（补全候选）。"""
        out = []
        i = self.d.lower_bound(inp)
        scanned = 0
        while i < self.d.n and scanned < cap_keys:
            k = self.d.keys[i]
            if not k.startswith(inp):
                break
            comp = len(k) - len(inp)
            for w, lp in self.d.vals(i)[:per_key]:
                out.append((w, lp - COMP_PEN * comp))
            i += 1
            scanned += 1
        return out

    def candidates(self, raw, limit=24):
        inp = "".join(c for c in raw.lower() if "a" <= c <= "z")
        if not inp:
            return []
        n = len(inp)
        cands = {}   # 文本 -> (coverage, 总logP)

        def put(text, cov, lp):
            if not text or cov <= 0:
                return
            old = cands.get(text)
            if old is None or lp > old[1]:
                cands[text] = (cov, lp)

        # 1~2 字母：直接吃「短输入补全表」。它是按打字概率预排好的（单字优先），
        # 拿 raw logP 排会被 在线/咱们 这种长词霸榜，所以短输入只认这张表。
        if n <= 2:
            ai = self.d.exact(inp + MARK)
            if ai is not None:
                for w, lp in self.d.vals(ai):
                    put(w, n, lp)
            # nb/sb/tm/wx/nh 这类两字母缩写切不成音节，走缩写表（牛逼/傻逼/微信…）
            if not self._splits(inp):
                for j, w, lp in self._abbr_edges(inp):
                    put(w, n, lp)
            return self._rank(cands, inp, limit)

        # 1) 前缀补全词
        for w, lp in self.prefix_words(inp):
            put(w, n, lp)

        # 2) 词图 Beam：句子 / 前缀片段
        states = self.beam(inp)
        for j in range(1, n + 1):
            for sc, ws in states[j]:
                if not ws:
                    continue
                # 没吃完整个输入的「单字」片段纯属噪声（打 awsl 蹦出 啊/阿）
                if j < n and len(ws) == 1 and len(ws[0]) == 1:
                    continue
                put("".join(ws), j, sc)

        # 3) 短输入补全表（1~2 字母，按真实词频预排好）
        if n <= 2:
            ai = self.d.exact(inp + MARK)
            if ai is not None:
                for w, lp in self.d.vals(ai):
                    put(w, n, lp)

        # 4) 缩写表兜底（整串切不成完整音节时）
        if 2 <= n <= 16 and not self._splits(inp):
            for j, w, lp in self._abbr_edges(inp):
                put(w, n, lp)

        # 5) 模糊音兜底
        if len(cands) < 3:
            for vi, variant in enumerate(fuzzy_variants(inp)):
                if vi == 0:
                    continue
                for w, lp in self.prefix_words(variant):
                    put(w, n, lp - 1.0 * vi)

        return self._rank(cands, inp, limit)

    def _rank(self, cands, inp, limit):
        n = len(inp)
        items = []
        for text, (cov, lp) in cands.items():
            norm = lp / cov if cov else -99.0
            items.append((text, cov, lp, norm))
        # 先看覆盖度（吃完全串的排前），再看每字平均 logP
        items.sort(key=lambda t: (-t[1], -t[3], len(t[0]), t[0]))
        out = [(t[0], t[2], t[1]) for t in items[:limit]]
        # 中英混输：原串本身永远垫底
        if inp and not any(w == inp for w, _, _ in out):
            out.append((inp, -99.0, n))
        return out

    def _splits(self, s):
        chars = list(s)
        n = len(chars)
        i = 0
        while i < n:
            hit = 0
            L = min(6, n - i)
            while L >= 1:
                if "".join(chars[i:i + L]) in self.d.syls:
                    hit = L
                    break
                L -= 1
            if hit == 0:
                return False
            i += hit
        return True


def main():
    d = Dict(BIN)
    eng = Engine(d)
    print("词条数:", d.n, "音节数:", d.syl_n, "版本:", d.ver,
          "语言模型首字数:", len(eng.lm.tab))
    # 少量代表输入：常用词 / 缩写 / 多词成句各取几条，够看排序就行，
    # 不搞「把每个键都试一遍」的穷举 —— 引擎对不对由架构保证，不由用例堆。
    tests = sys.argv[1:] or [
        "nihao", "zme", "wx", "nb", "sb", "za",
        "xbzz", "nmsl", "xswl", "gkd",
        "woxihuanni", "nizaiganma", "jintiantianqi", "shoujimeidianle",
        "n", "s", "wo", "shi",
    ]
    for t in tests:
        res = eng.candidates(t)
        head = "  ".join(w for w, _, _ in res[:12])
        print(f"[{t:14}] {head}")


if __name__ == "__main__":
    main()
