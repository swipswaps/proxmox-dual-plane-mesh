#!/usr/bin/env python3
"""mesh-inventory.py — mesh-owned SQLite inventory (choice a).

Owns operational state so questions become queries, not archaeology:
nodes registry, peers file, eero devices/reservations/forwards, audit
findings. Schema-migrated (PRAGMA user_version), WAL mode.

  mesh-inventory.py init [--db PATH]
  mesh-inventory.py import-local [--db PATH]     # nodes + peers files
  mesh-inventory.py import-eero NET_ID [--db PATH]  # live read-only eero state
  mesh-inventory.py finding add KIND DETAIL [--db PATH]
  mesh-inventory.py findings [--db PATH]         # open findings
  mesh-inventory.py sync [--db PATH]             # drift checks -> findings + report

Default DB: /var/lib/mesh/inventory.db (needs root to write there;
override with --db for tests). Exit 0 ok, 1 findings present (sync),
2 usage/error. No subprocess use (repo lint rule).
"""
import argparse
import json
import os
import sqlite3
import sys
import time

SCHEMA_VERSION = 2

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS nodes(
  name TEXT PRIMARY KEY, mesh_ip TEXT, machine_id TEXT,
  onboarded_at TEXT, source TEXT DEFAULT 'registry');
CREATE TABLE IF NOT EXISTS peers(mesh_ip TEXT PRIMARY KEY, seen_at TEXT);
CREATE TABLE IF NOT EXISTS eero_devices(
  mac TEXT PRIMARY KEY, hostname TEXT, nickname TEXT, ip TEXT,
  seen_at TEXT);
CREATE TABLE IF NOT EXISTS eero_reservations(
  mac TEXT PRIMARY KEY, ip TEXT, description TEXT, seen_at TEXT);
CREATE TABLE IF NOT EXISTS eero_forwards(
  fwd_id TEXT PRIMARY KEY, description TEXT, protocol TEXT,
  gateway_port TEXT, ip TEXT, client_port TEXT, seen_at TEXT);
CREATE TABLE IF NOT EXISTS findings(
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, kind TEXT,
  detail TEXT, status TEXT DEFAULT 'open');
CREATE TABLE IF NOT EXISTS latency(
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT, network TEXT,
  target TEXT, sent INTEGER, recv INTEGER, min_ms REAL, avg_ms REAL,
  max_ms REAL);
CREATE TABLE IF NOT EXISTS rustdesk_server(
  id INTEGER PRIMARY KEY CHECK (id=1), host TEXT, key_pub TEXT,
  installed_at TEXT);
CREATE TABLE IF NOT EXISTS rustdesk_nodes(
  name TEXT PRIMARY KEY, rustdesk_id TEXT, mesh_ip TEXT, configured_at TEXT);
"""

DEFAULT_DB = "/var/lib/mesh/inventory.db"


def connect(path):
    if path != ":memory:":
        parent = os.path.dirname(path)
        if parent:
            os.makedirs(parent, exist_ok=True)
    db = sqlite3.connect(path)
    db.execute("PRAGMA journal_mode=WAL")
    return db


def migrate(db):
    ver = db.execute("PRAGMA user_version").fetchone()[0]
    if ver < SCHEMA_VERSION:
        db.executescript(SCHEMA)
        db.execute("PRAGMA user_version=%d" % SCHEMA_VERSION)
        db.commit()
    return db.execute("PRAGMA user_version").fetchone()[0]


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def cmd_init(args):
    db = connect(args.db)
    ver = migrate(db)
    print("INIT %s schema=%d" % (args.db, ver))


def cmd_import_local(args):
    db = connect(args.db)
    migrate(db)
    n_nodes = n_peers = 0
    nodes_path = "/var/lib/mesh/nodes"
    if os.path.exists(nodes_path):
        with open(nodes_path) as f:
            for line in f:
                parts = line.split()
                if not parts:
                    continue
                name = parts[0]
                ip = parts[1] if len(parts) > 1 else ""
                mid = parts[2] if len(parts) > 2 else "unknown"
                at = parts[3] if len(parts) > 3 else ""
                db.execute(
                    "INSERT OR REPLACE INTO nodes(name,mesh_ip,machine_id,onboarded_at)"
                    " VALUES(?,?,?,?)", (name, ip, mid, at))
                n_nodes += 1
    peers_path = "/var/lib/mesh/peers"
    if os.path.exists(peers_path):
        with open(peers_path) as f:
            for line in f:
                ip = line.strip()
                if ip:
                    db.execute(
                        "INSERT OR REPLACE INTO peers(mesh_ip,seen_at)"
                        " VALUES(?,?)", (ip, now()))
                    n_peers += 1
    db.commit()
    print("IMPORT-LOCAL nodes=%d peers=%d" % (n_nodes, n_peers))


def _eero_client():
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import asyncio  # noqa: E402  (stdlib, not subprocess)
    from eero import EeroClient  # noqa: E402
    return asyncio, EeroClient


def cmd_import_eero(args):
    asyncio, EeroClient = _eero_client()

    async def run():
        c = EeroClient(
            cookie_file=os.path.expanduser("~/.local/share/eero-cookies"),
            use_keyring=False)
        async with c:
            ds = await c.get_devices(args.net)
            rs = await c.get_reservations(args.net)
            fs = await c.get_forwards(args.net)
            return ds, rs, fs

    ds, rs, fs = asyncio.run(run())
    db = connect(args.db)
    migrate(db)
    ts = now()
    n_d = n_r = n_f = 0

    def items(r):
        d = r.get("data", [])
        if isinstance(d, dict):
            d = d.get("devices", [d])
        return [x for x in d if isinstance(x, dict)]

    for d in items(ds):
        mac = str(d.get("mac", "")).lower()
        if not mac:
            continue
        db.execute(
            "INSERT OR REPLACE INTO eero_devices(mac,hostname,nickname,ip,seen_at)"
            " VALUES(?,?,?,?,?)", (mac, str(d.get("hostname", "")),
                                   str(d.get("nickname", "")),
                                   str(d.get("ip", "")), ts))
        n_d += 1
    for r in items(rs):
        mac = str(r.get("mac", "")).lower()
        if not mac:
            continue
        db.execute(
            "INSERT OR REPLACE INTO eero_reservations(mac,ip,description,seen_at)"
            " VALUES(?,?,?,?)", (mac, str(r.get("ip", "")),
                                 str(r.get("description", "")), ts))
        n_r += 1
    for f in items(fs):
        fid = str(f.get("id", "") or f.get("url", ""))
        if not fid:
            continue
        db.execute(
            "INSERT OR REPLACE INTO eero_forwards"
            "(fwd_id,description,protocol,gateway_port,ip,client_port,seen_at)"
            " VALUES(?,?,?,?,?,?,?)", (fid, str(f.get("description", "")),
                                       str(f.get("protocol", "")),
                                       str(f.get("gateway_port", "")),
                                       str(f.get("ip", "")),
                                       str(f.get("client_port", "")), ts))
        n_f += 1
    db.commit()
    print("IMPORT-EERO devices=%d reservations=%d forwards=%d" % (n_d, n_r, n_f))


def add_finding(db, kind, detail):
    row = db.execute(
        "SELECT id FROM findings WHERE kind=? AND detail=? AND status='open'",
        (kind, detail)).fetchone()
    if row:
        return None
    cur = db.execute(
        "INSERT INTO findings(ts,kind,detail) VALUES(?,?,?)",
        (now(), kind, detail))
    db.commit()
    return cur.lastrowid


def cmd_finding_add(args):
    db = connect(args.db)
    migrate(db)
    rid = add_finding(db, args.kind, args.detail)
    print("FINDING %s" % ("exists" if rid is None else ("id=%d" % rid)))


def cmd_findings(args):
    db = connect(args.db)
    migrate(db)
    rows = db.execute(
        "SELECT id,ts,kind,detail FROM findings WHERE status='open'"
        " ORDER BY id").fetchall()
    for rid, ts, kind, detail in rows:
        print("%d|%s|%s|%s" % (rid, ts, kind, detail))
    print("OPEN=%d" % len(rows))


def cmd_latency_record(args):
    # Pure DB write (no subprocess: repo lint forbids it in .py).
    # Measurement happens in mesh-latency.sh, which calls this.
    db = connect(args.db)
    migrate(db)
    try:
        sent, recv = int(args.sent), int(args.recv)
    except Exception:
        print("FAIL: sent/recv must be integers")
        sys.exit(2)

    def num(v):
        try:
            return float(v)
        except Exception:
            return None

    db.execute("INSERT INTO latency(ts,network,target,sent,recv,"
               "min_ms,avg_ms,max_ms) VALUES(?,?,?,?,?,?,?,?)",
               (now(), args.network, args.target, sent, recv,
                num(args.min), num(args.avg), num(args.max)))
    db.commit()
    print("LATENCY network=%s target=%s %d/%d avg=%s" %
          (args.network, args.target, recv, sent, args.avg))


def cmd_history(args):
    db = connect(args.db)
    migrate(db)
    rows = db.execute(
        "SELECT ts,network,target,sent,recv,avg_ms FROM latency"
        " ORDER BY id DESC LIMIT ?", (args.limit,)).fetchall()
    for ts, net, tgt, sent, recv, av in rows:
        avail = "%.0f%%" % (100.0 * recv / sent) if sent else "n/a"
        print("%s|%s|%s|%s|%s" % (
            ts, net, tgt, avail,
            ("%.1fms" % av) if av is not None else "n/a"))
    print("ROWS=%d" % len(rows))


def cmd_sync(args):
    db = connect(args.db)
    migrate(db)
    opened = 0

    def check(kind, detail):
        return add_finding(db, kind, detail) is not None

    devs = {r[0]: r for r in db.execute(
        "SELECT mac,hostname,nickname,ip FROM eero_devices").fetchall()}
    res = {r[0]: r[1] for r in db.execute(
        "SELECT mac,ip FROM eero_reservations").fetchall()}
    fwds = db.execute(
        "SELECT fwd_id,description,ip FROM eero_forwards").fetchall()
    nodes = db.execute("SELECT name,mesh_ip FROM nodes").fetchall()

    for mac, d in devs.items():
        if mac not in res and (d[3] or "").startswith("192.168."):
            if check("device-without-reservation",
                     "%s (%s) has LAN ip %s but no DHCP reservation"
                     % (d[0] or d[1] or mac, mac, d[3])):
                opened += 1
    for fid, desc, ip in fwds:
        known = [m for m, dd in devs.items() if dd[3] == ip]
        if not known:
            if check("forward-to-unknown-ip",
                     "forward %s (%s) targets %s with no known device"
                     % (fid, desc, ip)):
                opened += 1
    for name, ip in nodes:
        if not ip:
            continue
        lan = ip.split("/")[0]
        if lan.startswith("10.100."):
            continue
        if check("node-not-on-mesh",
                 "registry node %s has non-mesh ip %s" % (name, ip)):
            opened += 1
    print("SYNC findings-opened=%d" % opened)
    rows = db.execute(
        "SELECT id,kind,detail FROM findings WHERE status='open'"
        " ORDER BY id").fetchall()
    for rid, kind, detail in rows:
        print("%d|%s|%s" % (rid, kind, detail))
    return 1 if rows else 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="mesh-inventory.py")
    ap.add_argument("--db",
                    default=os.environ.get("MESH_INVENTORY_DB", DEFAULT_DB))
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init")
    sub.add_parser("import-local")
    ie = sub.add_parser("import-eero")
    ie.add_argument("net")
    fa = sub.add_parser("finding")
    fas = fa.add_subparsers(dest="sub", required=True)
    faa = fas.add_parser("add")
    faa.add_argument("kind")
    faa.add_argument("detail")
    sub.add_parser("findings")
    sub.add_parser("sync")
    lat = sub.add_parser("latency")
    lats = lat.add_subparsers(dest="sub", required=True)
    latr = lats.add_parser("record")
    latr.add_argument("network")
    latr.add_argument("target")
    latr.add_argument("sent")
    latr.add_argument("recv")
    latr.add_argument("min", nargs="?", default="")
    latr.add_argument("avg", nargs="?", default="")
    latr.add_argument("max", nargs="?", default="")
    lath = lats.add_parser("history")
    lath.add_argument("--limit", type=int, default=30)
    args = ap.parse_args(argv)
    try:
        if args.cmd == "init":
            cmd_init(args)
        elif args.cmd == "import-local":
            cmd_import_local(args)
        elif args.cmd == "import-eero":
            cmd_import_eero(args)
        elif args.cmd == "finding":
            if args.sub == "add":
                cmd_finding_add(args)
        elif args.cmd == "findings":
            cmd_findings(args)
        elif args.cmd == "sync":
            sys.exit(cmd_sync(args))
        elif args.cmd == "latency":
            if args.sub == "record":
                cmd_latency_record(args)
            elif args.sub == "history":
                cmd_history(args)
    except SystemExit:
        raise
    except Exception as e:
        import traceback
        print("FAIL: %s: %s" % (type(e).__name__, str(e)[:200]))
        traceback.print_exc()
        sys.exit(2)


main()
