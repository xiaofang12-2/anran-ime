# -*- coding: utf-8 -*-
"""合成一把「扣字」专用按键音，输出 Support/Keyboard/click.wav。

音色目标：干脆、清脆、有机械手感，不拖泥带水。
构成 = 极短的高频瞬态（敲击感） + 900Hz 共鸣体（厚度） + 2.6kHz 尖点（脆）。
"""
import math
import os
import random
import struct
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "Support", "Keyboard", "click.wav")

SR = 44100
DUR = 0.048
N = int(SR * DUR)

random.seed(20261010)
samples = []
for i in range(N):
    t = i / SR
    body = math.sin(2 * math.pi * 900 * t) * 0.34 * math.exp(-t / 0.011)
    crack = math.sin(2 * math.pi * 2600 * t) * 0.30 * math.exp(-t / 0.0032)
    tick = (random.uniform(-1, 1)) * 0.42 * math.exp(-t / 0.0016)
    v = body + crack + tick
    # 1ms 淡入去爆音，末端 12ms 淡出收干净
    if t < 0.001:
        v *= t / 0.001
    if t > DUR - 0.012:
        v *= max(0.0, (DUR - t) / 0.012)
    samples.append(v)

peak = max(abs(x) for x in samples) or 1.0
scale = 0.82 / peak
frames = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, x * scale)) * 32767)) for x in samples)

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with wave.open(OUT, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes(frames)

print("输出:", os.path.abspath(OUT), os.path.getsize(OUT), "字节")
