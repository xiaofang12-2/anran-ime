# -*- coding: utf-8 -*-
"""诊断 pinyin.bin：完整复刻引擎出候选的路子，看看给定输入先蹦什么。

用法:
  python probe_dict.py xbzz za nmsl        # 看具体输入
  python probe_dict.py --cover             # 扫 1~3 字母，列出「一个汉字都出不来」的输入
"""
import struct
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = os.path.join(HERE, "..", "Support", "dict", "pinyin.bin")
MARK = "\u007f"


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


class Dict:
    def __init__(self, path):
        with open(path, "rb") as f:
            self.b = f.read()
        assert self.b[:4] == b"ANPY"
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

    def vals(self, i):
        a = u32(self.b, self.val_off + 4 * i)
        e = u32(self.b, self.val_off + 4 * (i + 1))
        s = self.b[a:e].decode("utf-8")
        return s.split("\x01") if s else []

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


def word_score(w, rank):
    rank_pen = 0 if rank == 0 else (-90 if rank == 1 else -170)
    if len(w) >= 2:
        return 420 + len(w) * 70 + rank_pen
    return 120 + rank_pen


def initial_keys(d, inp):
    chars = list(inp)
    n = len(chars)
    memo = {}

    def go(start):
        if start in memo:
            return memo[start]
        if start >= n:
            memo[start] = {""}
            return memo[start]
        out = set()
        maxlen = min(6, n - start)
        ln = 2
        while ln <= maxlen:
            sub = "".join(chars[start:start + ln])
            if sub in d.syls:
                for tail in go(start + ln):
                    out.add(sub[0] + tail)
            ln += 1
        for tail in go(start + 1):
            out.add(chars[start] + tail)
        if len(out) > 24:
            out = set(sorted(out)[:24])
        memo[start] = out
        return out

    return [k for k in go(0) if 2 <= len(k) <= 8]


def lattice(d, inp):
    chars = list(inp)
    n = len(chars)
    memo = {}

    def go(start):
        if start in memo:
            return memo[start]
        if start >= n:
            memo[start] = [("", 0, 0)]
            return memo[start]
        out = []
        maxlen = min(8, n - start)
        ln = 1
        while ln <= maxlen:
            sub = "".join(chars[start:start + ln])
            idx = d.exact(sub)
            if idx is not None:
                cands = d.vals(idx)[:4]
                if cands:
                    rest = go(start + ln)
                    if rest:
                        for k, w in enumerate(cands):
                            ws = word_score(w, k)
                            for rp, rs, ru in rest:
                                joined = w + rp
                                if len(joined) > 12:
                                    continue
                                pen = 0 if rs == 0 else 200
                                out.append((joined, ws + rs - pen, ln + ru))
            ln += 1
        if not out:
            memo[start] = [("", 0, 0)]
            return memo[start]
        if len(out) > 24:
            out.sort(key=lambda x: -x[1])
            out = out[:24]
        memo[start] = out
        return out

    return [t for t in go(0) if t[0]]


def candidates(d, raw, limit=20):
    inp = "".join(c for c in raw.lower() if "a" <= c <= "z")
    if not inp:
        return []
    scored = {}

    def put(w, s):
        if w not in scored or scored[w] < s:
            scored[w] = s

    for vi, variant in enumerate(fuzzy_variants(inp)):
        pen = vi * 300000
        i = d.lower_bound(variant)
        scanned = 0
        while i < d.n and scanned < 200:
            k = d.keys[i]
            if not k.startswith(variant):
                break
            exact = (k == variant)
            base = (900000 if exact else 620000 - (len(k) - len(variant)) * 2000) - pen
            cands = d.vals(i)
            take = len(cands) if exact else min(len(cands), 5)
            for idx in range(take):
                put(cands[idx], base - idx * 120)
            i += 1
            scanned += 1

    if len(inp) <= 2:
        ai = d.exact(inp + MARK)
        if ai is not None:
            for i, w in enumerate(d.vals(ai)):
                put(w, 940000 - i * 150)

    if 2 <= len(inp) <= 16:
        for ini in initial_keys(d, inp):
            ai = d.exact(MARK + ini)
            if ai is None:
                continue
            for i, w in enumerate(d.vals(ai)):
                put(w, 560000 - i * 400)

    if len(inp) <= 32:
        for phrase, sc, used in lattice(d, inp):
            put(phrase, 300000 + sc)

    return sorted(scored.items(), key=lambda kv: (-kv[1], len(kv[0]), kv[0]))[:limit]


def has_cjk(s):
    return any("\u4e00" <= c <= "\u9fff" for c in s)


if __name__ == "__main__":
    d = Dict(BIN)
    args = sys.argv[1:]
    if args and args[0] == "--cover":
        letters = "abcdefghijklmnopqrstuvwxyz"
        holes2, holes3 = [], []
        for a in letters:
            for b in letters:
                if not any(has_cjk(w) for w, _ in candidates(d, a + b, 6)):
                    holes2.append(a + b)
        # 3 字母抽样（全扫 17576 个太慢，扫所有「声母+韵母」常见形）
        import itertools
        for a, b, c in itertools.product(letters, repeat=3):
            if c not in "aeiouv":
                continue
            if not any(has_cjk(w) for w, _ in candidates(d, a + b + c, 6)):
                holes3.append(a + b + c)
        print("2 字母无汉字:", len(holes2), "/ 676")
        print("  ", " ".join(holes2[:200]))
        print("3 字母(尾元音)无汉字:", len(holes3), "/", 26 * 26 * 6)
        print("  ", " ".join(holes3[:200]))
        sys.exit(0)

    print("词条数:", d.n, "音节数:", d.syl_n)
    tests = args or [
        "xbzz", "za", "nmsl", "wocao", "nb", "yyds", "xswl", "zqsg",
        "awsl", "sb", "laji", "gun", "tm", "nmd", "cnm", "gkd", "yygq",
        "zaijian", "nihao", "wx", "bjdx", "zme", "nh", "shabi", "nmsl",
    ]
    for t in tests:
        res = candidates(d, t)
        head = "  ".join(w for w, _ in res[:12])
        print(f"[{t:8}] {head}")
