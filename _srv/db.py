# -*- coding: utf-8 -*-
"""SQLite 存储层：账号 / 设备 / 数据快照 / 日志

几十个用户的量级，SQLite 完全够用，也不引入额外依赖。
每次操作新开一个连接，避免 uvicorn 多线程下的共享连接问题。
"""

import os
import sqlite3

from config import DB_PATH, DATA_DIR, SNAPSHOT_DIR

_SCHEMA = """
CREATE TABLE IF NOT EXISTS accounts (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    username      TEXT    NOT NULL UNIQUE,
    pass_salt     TEXT    NOT NULL,
    pass_hash     TEXT    NOT NULL,
    expire_at     INTEGER NOT NULL DEFAULT 0,
    disabled      INTEGER NOT NULL DEFAULT 0,
    note          TEXT    NOT NULL DEFAULT '',
    created_at    INTEGER NOT NULL,
    last_login_at INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS devices (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id   INTEGER NOT NULL,
    machine      TEXT    NOT NULL,
    platform     TEXT    NOT NULL DEFAULT 'pc',
    bound_at     INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL DEFAULT 0,
    UNIQUE(account_id, machine)
);

CREATE TABLE IF NOT EXISTS kb_sessions (
    account_id   INTEGER NOT NULL,
    machine      TEXT    NOT NULL,
    first_seen_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    UNIQUE(account_id, machine)
);

CREATE TABLE IF NOT EXISTS snapshots (
    account_id INTEGER PRIMARY KEY,
    size       INTEGER NOT NULL,
    sha256     TEXT    NOT NULL,
    updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS logs (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id INTEGER,
    action     TEXT    NOT NULL,
    detail     TEXT    NOT NULL DEFAULT '',
    ip         TEXT    NOT NULL DEFAULT '',
    at         INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_logs_account ON logs(account_id, at DESC);
CREATE INDEX IF NOT EXISTS idx_devices_account ON devices(account_id);
"""


def init():
    os.makedirs(DATA_DIR, exist_ok=True)
    os.makedirs(SNAPSHOT_DIR, exist_ok=True)
    with sqlite3.connect(DB_PATH) as conn:
        conn.executescript(_SCHEMA)
        _migrate(conn)


def _migrate(conn):
    """老库补列：devices.platform（老数据一律当电脑端）；
    accounts.phone / phone_at（后台可改，用户首绑随快照落库）"""
    cols = {r[1] for r in conn.execute("PRAGMA table_info(devices)").fetchall()}
    if "platform" not in cols:
        conn.execute("ALTER TABLE devices ADD COLUMN platform TEXT"
                     " NOT NULL DEFAULT 'pc'")
    acols = {r[1] for r in conn.execute("PRAGMA table_info(accounts)").fetchall()}
    if "phone" not in acols:
        conn.execute("ALTER TABLE accounts ADD COLUMN phone TEXT"
                     " NOT NULL DEFAULT ''")
    if "phone_at" not in acols:
        conn.execute("ALTER TABLE accounts ADD COLUMN phone_at"
                     " INTEGER NOT NULL DEFAULT 0")
    if "logout_seq" not in acols:
        conn.execute("ALTER TABLE accounts ADD COLUMN logout_seq"
                     " INTEGER NOT NULL DEFAULT 0")


def connect():
    conn = sqlite3.connect(DB_PATH, timeout=15)
    conn.row_factory = sqlite3.Row
    return conn


def query(sql, args=()):
    with connect() as conn:
        return [dict(r) for r in conn.execute(sql, args).fetchall()]


def query_one(sql, args=()):
    rows = query(sql, args)
    return rows[0] if rows else None


def execute(sql, args=()):
    """返回 (lastrowid, rowcount)"""
    with connect() as conn:
        cur = conn.execute(sql, args)
        return cur.lastrowid, cur.rowcount


def snapshot_path(account_id):
    return os.path.join(SNAPSHOT_DIR, "%d.bin" % int(account_id))


def log(account_id, action, detail="", ip=""):
    import time
    execute(
        "INSERT INTO logs (account_id, action, detail, ip, at) VALUES (?,?,?,?,?)",
        (account_id, action, detail, ip, int(time.time())),
    )