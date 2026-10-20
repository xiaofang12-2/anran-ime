# -*- coding: utf-8 -*-
"""复刻客户端 SecVault 的 ANAX AES-256-GCM 加密，用来产出新的 *.bin.enc。

格式（与 Sources/Shared/SecVault.swift 严格一致）：
    "ANAX" + nonce(12) + ciphertext(+GCM tag 16)
Swift 侧用 AES.GCM.SealedBox(combined:) 解析 nonce+ct+tag，故本脚本产出的
combined = nonce + ct + tag，整包 = "ANAX" + combined。

密钥：SecVault 把 32 字节密钥拆成三段分片各存一份，运行时 k1^k2^k3 异或拼装。
这里照抄三段分片的字面量，离线复刻同一把密钥。
"""
import os
import sys

# —— 与 SecVault.swift 完全一致的三段分片 ——
K1 = bytes.fromhex(
    "5AD0D976CC16E87C9B1FAF8E113F1E472C7734467555447433725F7DA9FC0EC9")
K2 = bytes.fromhex(
    "B466487202E30BD90F911E4DD4892932A6ADAEFA92884FA359F1254F9D13CDC2")
K3 = bytes.fromhex(
    "7F4CB873DA11B3DCC2E6B10DCCB929F767C9D2D2C95CD1C37B5EF0DDFB8B4A90")

assert len(K1) == len(K2) == len(K3) == 32, "key fragment length"

KEY = bytes(K1[i] ^ K2[i] ^ K3[i] for i in range(32))
MAGIC = b"ANAX"


def encrypt(plain: bytes) -> bytes:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    nonce = os.urandom(12)
    ct = AESGCM(KEY).encrypt(nonce, plain, None)  # ct 已含 16 字节 tag
    return MAGIC + nonce + ct


def decrypt(blob: bytes) -> bytes:
    if blob[:4] != MAGIC:
        raise ValueError("bad ANAX magic")
    rest = blob[4:]
    nonce, ct = rest[:12], rest[12:]
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    return AESGCM(KEY).decrypt(nonce, ct, None)


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "enc" and len(sys.argv) == 4:
        with open(sys.argv[2], "rb") as f:
            blob = encrypt(f.read())
        with open(sys.argv[3], "wb") as f:
            f.write(blob)
        print("enc ->", sys.argv[3], len(blob), "bytes")
        return
    if len(sys.argv) >= 2 and sys.argv[1] == "dec" and len(sys.argv) == 4:
        with open(sys.argv[2], "rb") as f:
            plain = decrypt(f.read())
        with open(sys.argv[3], "wb") as f:
            f.write(plain)
        print("dec ->", sys.argv[3], len(plain), "bytes")
        return
    if len(sys.argv) >= 2 and sys.argv[1] == "selftest":
        # 对现有 assoc.bin.enc 做「解密 -> 校验 -> 重加密 -> 再解密」往返，
        # 确认本脚本产出的格式与运行期 SecVault 完全兼容。
        here = os.path.dirname(os.path.abspath(__file__))
        sample = os.path.join(here, "..", "Support", "dict", "assoc.bin.enc")
        if not os.path.exists(sample):
            print("找不到样本", sample)
            return 1
        raw = open(sample, "rb").read()
        plain = decrypt(raw)
        print("样本解密成功，明文长度", len(plain), "magic=", plain[:4])
        if plain[:4] != b"ANBG":
            print("!! 样本明文 magic 不是 ANBG，密钥或格式不匹配")
            return 1
        # 重加密再解密，必须与原文一致
        reenc = encrypt(plain)
        plain2 = decrypt(reenc)
        ok = plain2 == plain
        print("重加密往返一致:", ok)
        return 0 if ok else 1
    print("用法:")
    print("  vault_enc.py enc <in> <out.enc>")
    print("  vault_enc.py dec <in.enc> <out>")
    print("  vault_enc.py selftest")
    return 1


if __name__ == "__main__":
    sys.exit(main())
