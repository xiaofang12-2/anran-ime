# -*- coding: utf-8 -*-
"""黯然扣魂 · 账号服务端（FastAPI + SQLite）

两类使用者：
  客户端 /api/*    登录发票据、心跳续期、数据快照上传下载
  作者   /admin/*  浏览器登录后台，建号 / 改到期 / 解绑设备 / 查看用户数据

票据用 RSA-PSS 私钥签名（私钥只在服务端），客户端内置对应公钥离线验签，
断网也能用；联网时心跳会带出「被禁用 / 已到期 / 设备被解绑」的最新状态。
数据密钥由账号名确定性派生（不存随机密钥）：换机登录同一账号照样解得开，
作者凭账号名也能解开任意用户的数据快照。
"""

import os
import io
import time
import json
import base64
import hashlib
import sqlite3
import zipfile

from urllib.parse import quote

from fastapi import FastAPI, Request, UploadFile, File, Form
from fastapi.responses import (JSONResponse, HTMLResponse,
                               Response, StreamingResponse, RedirectResponse)

from cryptography.hazmat.primitives import serialization

import db
import security
import datacrypto
import update_store
import ai_style_store
from config import (ADMIN_PASSWORD, SESSION_TTL, MAX_SNAPSHOT_BYTES,
                    TICKET_KEY_PATH, SESSION_KEY_PATH, BASE_DIR,
                    UPDATE_APP_NAME, UPDATE_FULL_NAME, UPDATE_IOS_NAME)

TICKET_TTL = 30 * 86400          # 票据有效期（秒），到期前客户端心跳会自动换新
ADMIN_DIR = os.path.join(BASE_DIR, "admin")
DOWNLOAD_DIR = os.path.join(BASE_DIR, "download")

app = FastAPI(title="AnRan Account Server", docs_url=None, redoc_url=None)

# HTTP(80) 专门给下载站：只放公开内容（首页跳转/下载页/更新分发）
# 其余路径（后台、账号接口）一律 301 到 HTTPS 不在明文口子上露面
_HTTP_PUBLIC_PREFIXES = ("/download", "/update/")


@app.middleware("http")
async def _http_only_public(request: Request, call_next):
    if request.url.scheme == "http":
        path = request.url.path
        if path != "/" and not path.startswith(_HTTP_PUBLIC_PREFIXES):
            https_url = "https://" + request.url.netloc + path
            return RedirectResponse(https_url, status_code=301)
    return await call_next(request)

_session_secret = None
_ticket_priv = None
_ticket_pub_pem = None


# ============================================================
# 密钥 / 会话懒加载
# ============================================================
def _ticket_private():
    global _ticket_priv
    if _ticket_priv is None:
        with open(TICKET_KEY_PATH, "r", encoding="utf-8") as f:
            _ticket_priv = f.read()
    return _ticket_priv


def _ticket_public():
    """从私钥推出公钥 PEM，用于服务端内部验签（不对外分发）"""
    global _ticket_pub_pem
    if _ticket_pub_pem is None:
        key = serialization.load_pem_private_key(
            _ticket_private().encode("utf-8"), password=None)
        _ticket_pub_pem = key.public_key().public_bytes(
            serialization.Encoding.PEM,
            serialization.PublicFormat.SubjectPublicKeyInfo).decode("utf-8")
    return _ticket_pub_pem


def _session_secret_get():
    global _session_secret
    if _session_secret is None:
        _session_secret = security.load_or_create_secret(SESSION_KEY_PATH)
    return _session_secret


@app.on_event("startup")
def _startup():
    db.init()
    update_store.ensure_dirs()


# ============================================================
# 小工具
# ============================================================
def _ip(request):
    xff = request.headers.get("x-forwarded-for", "")
    if xff:
        return xff.split(",")[0].strip()
    return request.client.host if request.client else ""


def _account_by_name(name):
    return db.query_one("SELECT * FROM accounts WHERE username=?", (name,))


def _account_by_id(aid):
    try:
        aid = int(aid)
    except Exception:
        return None
    return db.query_one("SELECT * FROM accounts WHERE id=?", (aid,))


def _issue_ticket(acc, machine):
    now = int(time.time())
    payload = {
        "v": 1,
        "uid": acc["id"],
        "u": acc["username"],
        "m": machine,
        "exp": acc["expire_at"],
        "iat": now,
        "texp": now + TICKET_TTL,
    }
    return security.sign_ticket(payload, _ticket_private())


def _authed_account(request):
    """从 X-Ticket 头验出账号，失败返回 None"""
    ticket = request.headers.get("x-ticket", "")
    if not ticket:
        return None
    payload = security.verify_ticket(ticket, _ticket_public())
    if not payload:
        return None
    acc = _account_by_id(payload.get("uid"))
    if not acc or acc["disabled"]:
        return None
    machine = str(payload.get("m", ""))
    rows = db.query("SELECT machine FROM devices WHERE account_id=?", (acc["id"],))
    if machine not in [r["machine"] for r in rows]:
        return None
    return acc


def _admin_ok(request):
    tok = request.cookies.get("anran_admin", "")
    return security.check_session(_session_secret_get(), tok)


def _deny(msg, code=401):
    return JSONResponse({"ok": False, "error": msg}, status_code=code)


def _fix_filename(name):
    """multipart 里的非 ASCII 文件名有时被按 latin-1 解开，这里还原成 UTF-8"""
    try:
        fixed = name.encode("latin-1").decode("utf-8")
        return fixed or name
    except Exception:
        return name


# ============================================================
# 客户端接口
# ============================================================
@app.get("/")
def index():
    # 根地址直接给下载站，手机电脑浏览器输个网址就能进
    return RedirectResponse("/download", status_code=302)


@app.get("/download", response_class=HTMLResponse)
def download_page():
    path = os.path.join(DOWNLOAD_DIR, "index.html")
    try:
        with open(path, "r", encoding="utf-8") as f:
            return HTMLResponse(f.read())
    except Exception:
        return HTMLResponse("<h3>下载页缺失：%s</h3>" % path, status_code=500)


@app.get("/download/tools/{name}")
def download_tool(request: Request, name: str):
    """侧载配套工具直链（Sideloadly / iTunes / TrollInstallerX / SideStore）

    用户不用去官网、不用翻墙，点一下就从本站拿工具。
    """
    safe = os.path.basename(name)
    if not safe or safe != name or safe.startswith("."):
        return _deny("not_found", 404)
    path = os.path.join(DOWNLOAD_DIR, "tools", safe)
    return _serve_pkg(request, path, safe)


@app.post("/api/login")
async def api_login(request: Request):
    try:
        body = await request.json()
    except Exception:
        return _deny("bad_body", 400)
    username = str(body.get("username", "")).strip()
    password = str(body.get("password", ""))
    machine = str(body.get("machine", "")).strip()
    platform = str(body.get("platform", "pc")).strip().lower()
    if platform not in ("pc", "ios"):
        platform = "pc"
    if not username or not password or not machine:
        return _deny("missing", 400)

    acc = _account_by_name(username)
    if not acc or not security.verify_password(
            password, acc["pass_salt"], acc["pass_hash"]):
        db.log(None, "login_fail", username, _ip(request))
        return _deny("bad_credential", 401)

    if acc["disabled"]:
        db.log(acc["id"], "login_disabled", "", _ip(request))
        return _deny("disabled", 403)

    # 绑定按平台分开算：一个账号最多一台电脑 + 一台手机
    now = int(time.time())
    machines = [r["machine"] for r in db.query(
        "SELECT machine FROM devices WHERE account_id=? AND platform=?",
        (acc["id"], platform))]
    bound_new = False
    if machine not in machines:
        if machines:
            db.log(acc["id"], "login_other_device",
                   "%s %s" % (platform, machine), _ip(request))
            return JSONResponse({"ok": False, "error": "bound_elsewhere",
                                 "platform": platform,
                                 "machine": machines[0]}, status_code=403)
        db.execute(
            "INSERT INTO devices (account_id, machine, platform, bound_at,"
            " last_seen_at) VALUES (?,?,?,?,?)",
            (acc["id"], machine, platform, now, now))
        bound_new = True
    else:
        db.execute("UPDATE devices SET last_seen_at=? WHERE account_id=? AND machine=?",
                   (now, acc["id"], machine))

    db.execute("UPDATE accounts SET last_login_at=? WHERE id=?", (now, acc["id"]))
    db.log(acc["id"], "login_ok",
           ("new_device " + platform) if bound_new else platform, _ip(request))
    return {
        "ok": True,
        "ticket": _issue_ticket(acc, machine),
        "username": acc["username"],
        "expire_at": acc["expire_at"],
        "bound_new": bound_new,
        "platform": platform,
        "logout_seq": acc["logout_seq"],
    }


@app.post("/api/heartbeat")
async def api_heartbeat(request: Request):
    """客户端定期调：续票据 + 带出最新到期/禁用状态"""
    try:
        body = await request.json()
    except Exception:
        return _deny("bad_body", 400)
    ticket = str(body.get("ticket", ""))
    machine = str(body.get("machine", "")).strip()
    payload = security.verify_ticket(ticket, _ticket_public())
    if not payload:
        return _deny("bad_ticket", 401)
    acc = _account_by_id(payload.get("uid"))
    if not acc:
        return _deny("no_account", 403)
    if acc["disabled"]:
        return _deny("disabled", 403)
    if str(payload.get("m", "")) != machine:
        return _deny("machine_mismatch", 403)
    machines = [r["machine"] for r in db.query(
        "SELECT machine FROM devices WHERE account_id=?", (acc["id"],))]
    if machine not in machines:
        return _deny("unbound", 403)

    now = int(time.time())
    db.execute("UPDATE devices SET last_seen_at=? WHERE account_id=? AND machine=?",
               (now, acc["id"], machine))
    return {
        "ok": True,
        "ticket": _issue_ticket(acc, machine),
        "expire_at": acc["expire_at"],
        "logout_seq": acc["logout_seq"],
    }


@app.post("/api/snapshot")
async def api_snapshot_upload(request: Request, file: UploadFile = File(...)):
    acc = _authed_account(request)
    if not acc:
        return _deny("unauthorized", 401)
    raw = await file.read()
    if len(raw) > MAX_SNAPSHOT_BYTES:
        return _deny("too_large", 413)
    sha = hashlib.sha256(raw).hexdigest()
    path = db.snapshot_path(acc["id"])
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(raw)
    os.replace(tmp, path)
    now = int(time.time())
    db.execute(
        "INSERT INTO snapshots (account_id, size, sha256, updated_at) VALUES (?,?,?,?)"
        " ON CONFLICT(account_id) DO UPDATE SET size=excluded.size,"
        " sha256=excluded.sha256, updated_at=excluded.updated_at",
        (acc["id"], len(raw), sha, now))
    db.log(acc["id"], "snapshot_upload", "%d bytes" % len(raw), _ip(request))

    # 用户首绑的手机号随快照落库：只在账号还没号时采纳，避免用户本地
    # 旧号在后续上报里覆盖管理员改过的新号
    try:
        snap = json.loads(raw.decode("utf-8"))
        p = str(snap.get("phone", "") or "").strip()
        if p and not acc.get("phone"):
            db.execute("UPDATE accounts SET phone=?, phone_at=? WHERE id=?",
                       (p, int(snap.get("phone_at", 0) or now), acc["id"]))
    except Exception:
        pass
    return {"ok": True, "sha256": sha, "size": len(raw), "updated_at": now}


@app.get("/api/snapshot")
def api_snapshot_download(request: Request):
    acc = _authed_account(request)
    if not acc:
        return _deny("unauthorized", 401)
    path = db.snapshot_path(acc["id"])
    if not os.path.exists(path):
        return _deny("empty", 404)
    with open(path, "rb") as f:
        raw = f.read()
    meta = db.query_one("SELECT sha256, updated_at FROM snapshots WHERE account_id=?",
                        (acc["id"],)) or {}
    return Response(content=raw, media_type="application/octet-stream",
                    headers={"X-Sha256": meta.get("sha256", ""),
                             "X-Updated-At": str(meta.get("updated_at", 0))})


# ============================================================
# 公共 AI 风格库（作者在管理端训练好上传 全体客户端拉取共用）
# ============================================================
@app.get("/api/ai/style")
def api_ai_style(request: Request):
    """客户端拉公共风格库：登录态才能取，没上传过就 404"""
    acc = _authed_account(request)
    if not acc:
        return _deny("unauthorized", 401)
    pack = ai_style_store.read_pack()
    if not pack:
        return _deny("empty", 404)
    return JSONResponse(pack, headers={
        "X-Updated-At": str(int(pack.get("updated_at", 0) or 0)),
        "Cache-Control": "no-store",
    })


@app.get("/admin/api/ai/style")
def admin_ai_style_status(request: Request):
    if not _admin_ok(request):
        return _deny("auth", 401)
    return {"ok": True, "status": ai_style_store.status()}


@app.post("/admin/api/ai/style")
async def admin_ai_style_upload(request: Request):
    """管理端把训练好的风格库整体传上来（覆盖旧的一份）"""
    if not _admin_ok(request):
        return _deny("auth", 401)
    try:
        body = await request.json()
    except Exception:
        return _deny("bad_body", 400)
    sents = body.get("sentences")
    if not isinstance(sents, list) or not sents:
        return _deny("no_sentences", 400)
    obj = ai_style_store.save_pack(sents, body.get("digest", ""),
                                   body.get("note", ""), body.get("version", ""))
    db.log(None, "ai_style_upload",
           "v%s %d sentences" % (obj.get("version") or "-", obj["count"]),
           _ip(request))
    return {"ok": True, "status": ai_style_store.status()}


@app.post("/admin/api/ai/style/clear")
def admin_ai_style_clear(request: Request):
    """下架：删掉公共风格库，客户端下次同步就退回本机范文"""
    if not _admin_ok(request):
        return _deny("auth", 401)
    ai_style_store.clear()
    db.log(None, "ai_style_clear", "", _ip(request))
    return {"ok": True}


# ============================================================
# 更新分发（公开：客户端免登录读清单、下安装包）
# ============================================================
@app.get("/update/version.json")
def update_manifest():
    obj = update_store.read_manifest()
    if not obj:
        return _deny("no_manifest", 404)
    return JSONResponse(obj)


def _content_disposition(name):
    """中文文件名走 RFC 5987，另给个 ASCII 兜底，免得浏览器存成乱码"""
    try:
        name.encode("ascii")
        ascii_name = name
    except Exception:
        ascii_name = "anran_download.zip"
    return ('attachment; filename="%s"; filename*=UTF-8\'\'%s'
            % (ascii_name.replace('"', ""), quote(name, safe="")))


def _serve_pkg(request: Request, path: str, download_name: str):
    """按 Range 断点续传地吐出安装包（5G 的完整包断了好接着下）"""
    if not os.path.exists(path):
        return _deny("no_file", 404)
    total = os.path.getsize(path)

    start, end, status = 0, total - 1, 200
    rng = request.headers.get("range", "")
    if rng.startswith("bytes="):
        spec = rng[6:].split(",")[0].strip()
        a, _, b = spec.partition("-")
        try:
            if a:
                start = int(a)
            if b:
                end = int(b)
        except Exception:
            start, end = 0, total - 1
        if start >= total:
            return Response(status_code=416,
                            headers={"Content-Range": "bytes */%d" % total})
        end = min(end, total - 1)
        status = 206
    length = end - start + 1

    def _iter():
        with open(path, "rb") as f:
            f.seek(start)
            left = length
            while left > 0:
                chunk = f.read(min(1 << 20, left))
                if not chunk:
                    break
                left -= len(chunk)
                yield chunk

    headers = {
        "Content-Length": str(length),
        "Accept-Ranges": "bytes",
        "Content-Disposition": _content_disposition(download_name),
    }
    if status == 206:
        headers["Content-Range"] = "bytes %d-%d/%d" % (start, end, total)
    return StreamingResponse(_iter(), status_code=status,
                             media_type="application/octet-stream",
                             headers=headers)


@app.get("/update/file/{name}")
def update_file(request: Request, name: str):
    """增量更新包下载，客户端自动更新走这儿"""
    if name != UPDATE_APP_NAME:
        return _deny("not_found", 404)
    m = update_store.read_manifest() or {}
    friendly = str(m.get("name") or "").strip() or UPDATE_APP_NAME
    return _serve_pkg(request, update_store.app_path(), friendly)


@app.get("/update/full/{name}")
def update_full_file(request: Request, name: str):
    """新用户完整包下载，下载站主按钮走这儿"""
    if name != UPDATE_FULL_NAME:
        return _deny("not_found", 404)
    m = update_store.read_manifest() or {}
    full = m.get("full") if isinstance(m.get("full"), dict) else {}
    friendly = str(full.get("name") or "").strip() or UPDATE_FULL_NAME
    return _serve_pkg(request, update_store.full_path(), friendly)


@app.get("/update/ios/{name}")
def update_ios_file(request: Request, name: str):
    """iOS 安装包下载，下载站 iOS 区走这儿

    文件名固定 app.ipa，用户存下来是「黯然输入法.ipa」这种能认出来的名字。
    """
    if name != UPDATE_IOS_NAME:
        return _deny("not_found", 404)
    m = update_store.read_manifest() or {}
    ios = m.get("ios") if isinstance(m.get("ios"), dict) else {}
    friendly = str(ios.get("name") or "").strip() or "黯然输入法.ipa"
    return _serve_pkg(request, update_store.ios_path(), friendly)


# ============================================================
# 作者后台
# ============================================================
@app.get("/admin", response_class=HTMLResponse)
def admin_page():
    path = os.path.join(ADMIN_DIR, "index.html")
    try:
        with open(path, "r", encoding="utf-8") as f:
            return HTMLResponse(f.read())
    except Exception:
        return HTMLResponse("<h3>后台页面缺失：%s</h3>" % path, status_code=500)


@app.post("/admin/api/login")
async def admin_login(request: Request):
    try:
        body = await request.json()
    except Exception:
        return _deny("bad_body", 400)
    if str(body.get("password", "")) != ADMIN_PASSWORD:
        return _deny("bad_password", 401)
    tok = security.make_session(_session_secret_get(), SESSION_TTL)
    resp = JSONResponse({"ok": True})
    resp.set_cookie("anran_admin", tok, httponly=True, samesite="lax",
                    max_age=SESSION_TTL, path="/")
    return resp


@app.post("/admin/api/logout")
def admin_logout():
    resp = JSONResponse({"ok": True})
    resp.delete_cookie("anran_admin", path="/")
    return resp


@app.get("/admin/api/accounts")
def admin_accounts(request: Request):
    if not _admin_ok(request):
        return _deny("auth", 401)
    rows = db.query("""
        SELECT a.id, a.username, a.expire_at, a.disabled, a.note,
               a.created_at, a.last_login_at,
               a.phone, a.phone_at,
               (SELECT updated_at FROM snapshots s WHERE s.account_id=a.id) AS snap_at,
               (SELECT size FROM snapshots s WHERE s.account_id=a.id) AS snap_size
        FROM accounts a ORDER BY a.id DESC
    """)
    devs = db.query("SELECT account_id, platform, machine, bound_at, last_seen_at"
                    " FROM devices ORDER BY bound_at")
    by_acc = {}
    for d in devs:
        by_acc.setdefault(d["account_id"], []).append(d)
    for r in rows:
        ds = by_acc.get(r["id"], [])
        r["devices"] = ds
        # 兼容老版管理端：machine / device_seen 仍指第一台设备
        first = ds[0] if ds else None
        r["machine"] = first["machine"] if first else None
        r["device_seen"] = first["last_seen_at"] if first else None
    return {"ok": True, "accounts": rows, "now": int(time.time())}


@app.post("/admin/api/account/create")
async def admin_create(request: Request):
    if not _admin_ok(request):
        return _deny("auth", 401)
    try:
        body = await request.json()
    except Exception:
        return _deny("bad_body", 400)
    username = str(body.get("username", "")).strip()
    if not username:
        return _deny("no_username", 400)
    password = str(body.get("password", "")).strip() or security.random_password()
    days = int(body.get("days", 30) or 0)
    note = str(body.get("note", ""))
    expire_at = 0 if days <= 0 else int(time.time()) + days * 86400

    salt, h = security.hash_password(password)
    now = int(time.time())
    try:
        lastid, _ = db.execute(
            "INSERT INTO accounts (username, pass_salt, pass_hash,"
            " expire_at, disabled, note, created_at, last_login_at)"
            " VALUES (?,?,?,?,0,?,?,0)",
            (username, salt, h, expire_at, note, now))
    except sqlite3.IntegrityError:
        return _deny("exists", 409)
    db.log(lastid, "admin_create", username, _ip(request))
    return {"ok": True, "id": lastid, "username": username,
            "password": password, "expire_at": expire_at}


@app.post("/admin/api/account/update")
async def admin_update(request: Request):
    """按需改：续期天数 / 绝对到期 / 禁用 / 备注 / 重置密码"""
    if not _admin_ok(request):
        return _deny("auth", 401)
    try:
        body = await request.json()
    except Exception:
        return _deny("bad_body", 400)
    acc = _account_by_id(body.get("account_id"))
    if not acc:
        return _deny("no_account", 404)

    fields, args = [], []
    if body.get("days") is not None:
        days = int(body["days"])
        exp = 0 if days <= 0 else int(time.time()) + days * 86400
        fields.append("expire_at=?"); args.append(exp)
    if body.get("expire_at") is not None:
        fields.append("expire_at=?"); args.append(int(body["expire_at"]))
    if body.get("disabled") is not None:
        fields.append("disabled=?"); args.append(1 if body["disabled"] else 0)
    if body.get("note") is not None:
        fields.append("note=?"); args.append(str(body["note"]))
    if body.get("phone") is not None:
        fields.append("phone=?"); args.append(str(body["phone"]).strip())
        fields.append("phone_at=?"); args.append(int(time.time()))
    if body.get("password"):
        salt, h = security.hash_password(str(body["password"]))
        fields.append("pass_salt=?"); args.append(salt)
        fields.append("pass_hash=?"); args.append(h)

    if not fields:
        return _deny("nothing_to_update", 400)
    args.append(acc["id"])
    db.execute("UPDATE accounts SET %s WHERE id=?" % ",".join(fields), tuple(args))
    db.log(acc["id"], "admin_update", ",".join(fields), _ip(request))
    return {"ok": True}


@app.post("/admin/api/account/delete")
async def admin_delete(request: Request):
    if not _admin_ok(request):
        return _deny("auth", 401)
    try:
        body = await request.json()
    except Exception:
        return _deny("bad_body", 400)
    acc = _account_by_id(body.get("account_id"))
    if not acc:
        return _deny("no_account", 404)
    db.execute("DELETE FROM devices WHERE account_id=?", (acc["id"],))
    db.execute("DELETE FROM snapshots WHERE account_id=?", (acc["id"],))
    db.execute("DELETE FROM accounts WHERE id=?", (acc["id"],))
    try:
        os.remove(db.snapshot_path(acc["id"]))
    except Exception:
        pass
    db.log(None, "admin_delete", acc["username"], _ip(request))
    return {"ok": True}


@app.post("/admin/api/device/unbind")
async def admin_unbind(request: Request):
    """解绑设备：用户换机时用，解绑后新机登录即可重新绑定

    带 platform 只解绑那一个平台（pc / ios），不带则全解。
    """
    if not _admin_ok(request):
        return _deny("auth", 401)
    try:
        body = await request.json()
    except Exception:
        return _deny("bad_body", 400)
    acc = _account_by_id(body.get("account_id"))
    if not acc:
        return _deny("no_account", 404)
    platform = str(body.get("platform", "")).strip().lower()
    if platform in ("pc", "ios"):
        _, n = db.execute("DELETE FROM devices WHERE account_id=? AND platform=?",
                          (acc["id"], platform))
    else:
        _, n = db.execute("DELETE FROM devices WHERE account_id=?", (acc["id"],))
    db.log(acc["id"], "admin_unbind",
           "%s removed %d" % (platform or "all", n), _ip(request))
    return {"ok": True, "removed": n, "platform": platform or "all"}


@app.get("/admin/api/account/snapshot")
def admin_snapshot(request: Request, account_id: int):
    """作者查看某账号数据：优先用账号密钥解出明文 JSON"""
    if not _admin_ok(request):
        return _deny("auth", 401)
    acc = _account_by_id(account_id)
    if not acc:
        return _deny("no_account", 404)
    path = db.snapshot_path(acc["id"])
    if not os.path.exists(path):
        return _deny("empty", 404)
    with open(path, "rb") as f:
        raw = f.read()
    meta = db.query_one("SELECT size, sha256, updated_at FROM snapshots WHERE account_id=?",
                        (acc["id"],)) or {}
    try:
        data = datacrypto.open_sealed(
            security.account_key(acc["username"]), raw)
    except Exception as exc:
        return {"ok": True, "meta": meta, "plain": None,
                "raw_b64": base64.b64encode(raw).decode("ascii"),
                "note": "解不开（%s），已返回原始密文" % exc}
    return {"ok": True, "meta": meta, "plain": _snapshot_to_text(data)}


@app.get("/admin/api/account/snapshot/raw")
def admin_snapshot_raw(request: Request, account_id: int):
    """作者查看用户数据（结构化用）：返回解封后的快照 zip（base64）

    管理端自己拆 zip：移花接木语料是明文 txt，思想库 .kzs 由管理端用账号
    密钥在本地解密（跟客户端同一套算法）——所以这儿只把 zip 原样交出去。
    """
    if not _admin_ok(request):
        return _deny("auth", 401)
    acc = _account_by_id(account_id)
    if not acc:
        return _deny("no_account", 404)
    path = db.snapshot_path(acc["id"])
    if not os.path.exists(path):
        return _deny("empty", 404)
    with open(path, "rb") as f:
        raw = f.read()
    try:
        data = datacrypto.open_sealed(
            security.account_key(acc["username"]), raw)
    except Exception:
        return _deny("seal_broken", 500)
    return {"ok": True, "username": acc["username"],
            "zip_b64": base64.b64encode(data).decode("ascii")}


def _snapshot_to_text(data):
    """把解开的快照转成作者能看的文本

    快照是 zip（里面一堆词库/配置），直接 decode 会崩；这里优先当纯文本，
    否则拆成 {文件名: 内容} 的 JSON —— 文本文件给正文，二进制给大小和摘要。
    """
    try:
        return data.decode("utf-8")
    except Exception:
        pass
    out = {}
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            for name in z.namelist():
                if name.endswith("/"):
                    continue
                info = z.getinfo(name)
                if info.file_size > 2 * 1024 * 1024:
                    out[name] = {"size": info.file_size,
                                 "note": "文件过大 仅显示大小"}
                    continue
                blob = z.read(name)
                try:
                    out[name] = blob.decode("utf-8")
                except Exception:
                    out[name] = {
                        "size": len(blob),
                        "sha256": hashlib.sha256(blob).hexdigest()[:16],
                        "note": "二进制文件"}
        return json.dumps(out, ensure_ascii=False, indent=2)
    except Exception:
        return None


@app.get("/admin/api/logs")
def admin_logs(request: Request, account_id: int = 0, limit: int = 200):
    if not _admin_ok(request):
        return _deny("auth", 401)
    limit = max(1, min(int(limit), 1000))
    if account_id:
        rows = db.query("SELECT * FROM logs WHERE account_id=? ORDER BY id DESC LIMIT ?",
                        (int(account_id), limit))
    else:
        rows = db.query("SELECT * FROM logs ORDER BY id DESC LIMIT ?", (limit,))
    return {"ok": True, "logs": rows}


# ============================================================
# 更新发布（管理端 exe 用）
# ============================================================
@app.get("/admin/api/update/status")
def admin_update_status(request: Request):
    """看当前线上版本与安装包状态"""
    if not _admin_ok(request):
        return _deny("auth", 401)
    path = update_store.app_path()
    fpath = update_store.full_path()
    ipath = update_store.ios_path()
    return {
        "ok": True,
        "manifest": update_store.read_manifest(),
        "file_exists": os.path.exists(path),
        "file_size": os.path.getsize(path) if os.path.exists(path) else 0,
        "full_exists": os.path.exists(fpath),
        "full_size": os.path.getsize(fpath) if os.path.exists(fpath) else 0,
        "ios_exists": os.path.exists(ipath),
        "ios_size": os.path.getsize(ipath) if os.path.exists(ipath) else 0,
    }


async def _stream_to(upload, tmp):
    """边收边算 sha256、流式落盘，5G 的完整包也不会把内存吃爆"""
    h = hashlib.sha256()
    size = 0
    with open(tmp, "wb") as f:
        while True:
            chunk = await upload.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
            h.update(chunk)
            size += len(chunk)
    return size, h.hexdigest()


@app.post("/admin/api/update/publish")
async def admin_update_publish(request: Request,
                               file: UploadFile = File(...),
                               full: UploadFile = File(None),
                               ios: UploadFile = File(None),
                               version: str = Form(""),
                               notes: str = Form("")):
    """上传新安装包 + 写版本清单

    增量包（file）必传，客户端自动更新下载它；
    新用户完整包（full）可选，传了就给下载站用，不传则沿用上一份；
    iOS 安装包（ios）可选，传了就给下载站 iOS 区用，不传则沿用上一份。
    落完临时文件才改名并换清单，保证任意时刻清单指向的文件都在。
    """
    if not _admin_ok(request):
        return _deny("auth", 401)
    version = (version or "").strip()
    if not version:
        return _deny("no_version", 400)

    update_store.ensure_dirs()

    # ---- 增量包（必传）----
    tmp = update_store.tmp_path()
    try:
        size, sha = await _stream_to(file, tmp)
    except Exception as exc:
        try:
            os.remove(tmp)
        except Exception:
            pass
        return _deny("write_failed %s" % exc, 500)
    if size == 0:
        try:
            os.remove(tmp)
        except Exception:
            pass
        return _deny("empty_file", 400)
    size = update_store.commit_app()
    name = _fix_filename(os.path.basename(file.filename or "")) or "黯然扣魂_更新.zip"
    base = str(request.base_url).rstrip("/")

    # ---- 完整包（可选，给新用户下载站用）----
    prev = update_store.read_manifest() or {}
    full_obj = prev.get("full") if isinstance(prev.get("full"), dict) else None
    full_error = ""
    if full is not None:
        ftmp = update_store.full_tmp_path()
        try:
            fsize, fsha = await _stream_to(full, ftmp)
        except Exception as exc:
            fsize, fsha = 0, ""
            full_error = "完整包上传失败：%s" % exc
        if fsize:
            fsize = update_store.commit_full()
            fname = (_fix_filename(os.path.basename(full.filename or ""))
                     or "黯然扣魂_完整版.zip")
            full_obj = update_store.make_full(
                "%s/update/full/%s" % (base, UPDATE_FULL_NAME),
                fsize, fsha, fname)
        else:
            try:
                os.remove(ftmp)
            except Exception:
                pass

    # ---- iOS 安装包（可选，给下载站 iOS 区用）----
    ios_obj = prev.get("ios") if isinstance(prev.get("ios"), dict) else None
    ios_error = ""
    if ios is not None:
        itmp = update_store.ios_tmp_path()
        try:
            isize, isha = await _stream_to(ios, itmp)
        except Exception as exc:
            isize, isha = 0, ""
            ios_error = "iOS 包上传失败：%s" % exc
        if isize:
            isize = update_store.commit_ios()
            iname = (_fix_filename(os.path.basename(ios.filename or ""))
                     or "黯然输入法.ipa")
            ios_obj = update_store.make_ios(
                "%s/update/ios/%s" % (base, UPDATE_IOS_NAME),
                isize, isha, iname, version=version)
        else:
            try:
                os.remove(itmp)
            except Exception:
                pass

    manifest = update_store.make_manifest(
        version, (notes or "").strip(),
        "%s/update/file/%s" % (base, UPDATE_APP_NAME),
        size, sha, name, full=full_obj, ios=ios_obj)
    update_store.save_manifest(manifest)
    db.log(None, "update_publish", "v%s %d bytes" % (version, size),
           _ip(request))
    return {"ok": True, "manifest": manifest,
            "full_error": full_error, "ios_error": ios_error}


@app.post("/admin/api/update/clear")
def admin_update_clear(request: Request):
    """下架：删掉清单与安装包，客户端就不再提示更新"""
    if not _admin_ok(request):
        return _deny("auth", 401)
    update_store.clear_manifest()
    for p in (update_store.app_path(), update_store.full_path(),
              update_store.ios_path()):
        try:
            os.remove(p)
        except Exception:
            pass
    db.log(None, "update_clear", "", _ip(request))
    return {"ok": True}

# ============================================================
# 配置同步连接器：主App <-> 键盘 走服务器中转，不再碰剪贴板
# ============================================================
SYNC_DIR = os.path.join(BASE_DIR, "data", "sync")
os.makedirs(SYNC_DIR, exist_ok=True)
_pairs = {}  # 配对码 -> (uid, machine, 过期时间戳)


def _sync_path(uid):
    return os.path.join(SYNC_DIR, "%d.bin" % int(uid))


@app.post("/api/pair/start")
async def api_pair_start(request: Request):
    """主App发起配对：带着自己的ticket生成一个6位码，键盘输这个码领ticket"""
    acc = _authed_account(request)
    if not acc:
        return _deny("no_auth", 401)
    try:
        body = await request.json()
    except Exception:
        return {"ok": False, "err": "bad_body"}
    code = "".join(ch for ch in str(body.get("code", "")) if ch.isdigit())
    if len(code) != 6:
        return {"ok": False, "err": "bad_code"}
    payload = security.verify_ticket(request.headers.get("x-ticket", ""), _ticket_public())
    if not payload:
        return _deny("bad_ticket", 401)
    import time as _t
    _pairs[code] = (acc["id"], str(payload.get("m", "")), _t.time() + 600)
    db.log(acc["id"], "pair_start", _ip(request))
    return {"ok": True}


@app.post("/api/pair/claim")
async def api_pair_claim(request: Request):
    """键盘用配对码换ticket（一次性，10分钟有效）"""
    try:
        body = await request.json()
    except Exception:
        return {"ok": False, "err": "bad_body"}
    code = "".join(ch for ch in str(body.get("code", "")) if ch.isdigit())
    import time as _t
    item = _pairs.pop(code, None)
    if item and item[2] < _t.time():
        item = None
    if not item:
        return _deny("bad_or_expired", 403)
    uid, machine, _ = item
    acc = _account_by_id(uid)
    if not acc or acc["disabled"]:
        return _deny("no_auth", 401)
    db.log(uid, "pair_claim", _ip(request))
    return {"ok": True, "ticket": _issue_ticket(acc, machine),
            "username": acc["username"], "machine": machine,
            "expire_at": acc["expire_at"],
            "logout_seq": acc["logout_seq"]}


@app.post("/api/sync")
async def api_sync_push(request: Request, file: UploadFile = File(...)):
    """主App推送全量配置包（登录态+思想库+短语+设置+布局）"""
    acc = _authed_account(request)
    if not acc:
        return _deny("no_auth", 401)
    raw = await file.read()
    if not raw or len(raw) > 8 * 1024 * 1024:
        return {"ok": False, "err": "bad_size"}
    with open(_sync_path(acc["id"]), "wb") as f:
        f.write(raw)
    return {"ok": True}


@app.get("/api/sync")
def api_sync_pull(request: Request):
    """键盘拉取最新配置包"""
    acc = _authed_account(request)
    if not acc:
        return _deny("no_auth", 401)
    p = _sync_path(acc["id"])
    if not os.path.exists(p):
        return JSONResponse({"ok": False, "err": "empty"}, status_code=404)
    with open(p, "rb") as f:
        raw = f.read()
    return Response(content=raw, media_type="application/octet-stream")


@app.get("/api/pair/status")
def api_pair_status(request: Request):
    """主App查配对状态：有过一次 pair_claim 记录即视为已配对键盘"""
    acc = _authed_account(request)
    if not acc:
        return _deny("no_auth", 401)
    rows = db.query("SELECT 1 FROM logs WHERE account_id=? AND action='pair_claim' LIMIT 1",
                    (acc["id"],))
    return {"ok": True, "paired": bool(rows)}


@app.post("/api/logout")
async def api_logout(request: Request):
    """主App退登：账号登出序号+1，所有旧票据下一跳心跳全部作废（键盘一并锁死）"""
    try:
        body = await request.json()
    except Exception:
        return _deny("bad_body", 400)
    payload = security.verify_ticket(str(body.get("ticket", "")), _ticket_public())
    if not payload:
        return _deny("bad_ticket", 401)
    acc = _account_by_id(payload.get("uid"))
    if not acc:
        return _deny("no_account", 403)
    db.execute("UPDATE accounts SET logout_seq = logout_seq + 1 WHERE id=?", (acc["id"],))
    db.log(acc["id"], "logout", _ip(request))
    return {"ok": True}
