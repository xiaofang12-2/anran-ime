# -*- coding: utf-8 -*-
"""快照加密：AES-256-GCM

客户端把整包数据（词库 + 配置的 JSON）用账号 data_key 加密后上传，
服务端只落密文；作者后台要看时用同一把 data_key 解开。

data_key 是 64 位十六进制字符串 = 32 字节 = 256 位密钥。
密文格式：MAGIC(5) + nonce(12) + ciphertext(含 GCM tag)
"""

import os

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"ANSN\x01"          # AnRan Snapshot v1
_AAD = b"anran-kouhun-snapshot"


def _key(data_key):
    raw = bytes.fromhex(data_key)
    if len(raw) != 32:
        raise ValueError("data_key 必须是 32 字节（64 位十六进制）")
    return raw


def seal(data_key, plaintext):
    """加密快照，返回可直接落盘的字节"""
    nonce = os.urandom(12)
    ct = AESGCM(_key(data_key)).encrypt(nonce, plaintext, _AAD)
    return MAGIC + nonce + ct


def open_sealed(data_key, blob):
    """解密快照，返回明文字节；格式不对或校验失败抛异常"""
    if not blob or blob[:5] != MAGIC:
        raise ValueError("不是本服务的快照格式")
    nonce = blob[5:17]
    return AESGCM(_key(data_key)).decrypt(nonce, blob[17:], _AAD)