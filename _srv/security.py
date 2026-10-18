# -*- coding: utf-8 -*-
"""口令哈希 + 票据签发 + 后台会话

票据用 RSA-PSS 私钥签名（跟客户端内置的公钥配对），客户端因此能离线验签、
自己判断到期时间，不必每次联网问服务端。私钥只在服务端，不进客户端包。
"""

import base64
import hashlib
import hmac
import json
import os
import secrets

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

PBKDF2_ROUNDS = 200_000


# ---------------------------------------------------------------- 口令
def hash_password(password, salt=None):
    salt = salt if salt is not None else os.urandom(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, PBKDF2_ROUNDS)
    return salt.hex(), dk.hex()


def verify_password(password, salt_hex, hash_hex):
    try:
        _, calc = hash_password(password, bytes.fromhex(salt_hex))
    except Exception:
        return False
    return hmac.compare_digest(calc, hash_hex)


def random_password(length=12):
    """建号时没填密码就用这个随机生成一个发给用户"""
    import string
    alphabet = string.ascii_letters + string.digits
    return "".join(secrets.choice(alphabet) for _ in range(length))


def account_key(username):
    """由账号名确定性派生数据密钥（服务端与客户端同一算法）

    不存随机密钥：换机登录同一账号照样解得开，作者凭账号名也能解开用户数据。
    返回 64 位十六进制 = 32 字节。
    """
    return hashlib.sha256(("ANRAN-ACCOUNT::" + username).encode("utf-8")).hexdigest()


# ---------------------------------------------------------------- 票据
def _canonical(payload):
    return json.dumps(payload, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False).encode("utf-8")


def _pss():
    return padding.PSS(mgf=padding.MGF1(hashes.SHA256()),
                       salt_length=hashes.SHA256().digest_size)


def _b64e(raw):
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _b64d(text):
    pad = "=" * (-len(text) % 4)
    return base64.urlsafe_b64decode(text + pad)


def sign_ticket(payload, private_key_pem):
    key = serialization.load_pem_private_key(
        private_key_pem.encode("utf-8"), password=None)
    body = _b64e(_canonical(payload))
    sig = key.sign(_canonical(payload), _pss(), hashes.SHA256())
    return body + "." + _b64e(sig)


def read_ticket(ticket):
    """拆出 payload（不验签，仅服务端内部用；验签在 verify_ticket）"""
    try:
        body = ticket.split(".", 1)[0]
        return json.loads(_b64d(body).decode("utf-8"))
    except Exception:
        return None


def verify_ticket(ticket, public_key_pem):
    try:
        body, sig = ticket.split(".", 1)
        key = serialization.load_pem_public_key(public_key_pem.encode("utf-8"))
        key.verify(_b64d(sig), _b64d(body), _pss(), hashes.SHA256())
        return json.loads(_b64d(body).decode("utf-8"))
    except Exception:
        return None


# ---------------------------------------------------------------- 后台会话
def load_or_create_secret(path):
    try:
        with open(path, "rb") as f:
            raw = f.read().strip()
        if raw:
            return raw
    except Exception:
        pass
    raw = secrets.token_bytes(32)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(raw)
    return raw


def make_session(secret, ttl_seconds):
    import time
    exp = int(time.time()) + int(ttl_seconds)
    msg = "admin:%d" % exp
    mac = hmac.new(secret, msg.encode("ascii"), hashlib.sha256).hexdigest()
    return "%s.%s" % (exp, mac)


def check_session(secret, token):
    import time
    try:
        exp_s, mac = token.split(".", 1)
    except Exception:
        return False
    msg = "admin:%s" % exp_s
    want = hmac.new(secret, msg.encode("ascii"), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(want, mac):
        return False
    try:
        return int(exp_s) > int(time.time())
    except Exception:
        return False