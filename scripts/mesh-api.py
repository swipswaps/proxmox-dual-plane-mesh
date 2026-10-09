#!/usr/bin/env python3
"""mesh-api.py — mesh-side read API for the portal (Phase 1, direct model).

Stdlib only (http.server + sqlite3 + sslなし — plain HTTP; TLS terminates
at caddy or not at all on loopback). No dependency on the opencode stack:
runs on the lighthouse, which serves no web ports of its own.

  mesh-api.py [--bind 127.0.0.1] [--port 5409] [--db PATH]

Routes (all JSON; CORS * + OPTIONS preflight, same semantics as the
portal contract):
  GET  /api/rev         {repo, head, service}
  GET  /api/mesh        inventory (nodes/peers/open findings/eero counts);
                        {available:false} with 503 when no inventory DB
  GET  /api/certs       served-cert fingerprint/SAN/dates when a cert file
                        is findable (MESH_CERT_PATH else skip);
                        {available:false} otherwise. Reports only.
  GET  /api/client-log  latest 50 client diagnostics
  POST /api/client-log  {source,message,url?} (4KB cap, 20/min/IP)

Exit 0 serve-forever, 2 usage/error. No subprocess use (repo lint rule).
"""
import argparse
import hashlib
import json
import os
import sqlite3
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse

RATE = {}
RATE_WINDOW = 60
RATE_MAX = 20

INVENTORY_DEFAULT = "/var/lib/mesh/inventory.db"
CLIENT_DB_DEFAULT = "/var/lib/mesh/client_log.db"


def _rate_ok(ip):
    now = time.time()
    hits = [t for t in RATE.get(ip, []) if now - t < RATE_WINDOW]
    hits.append(now)
    RATE[ip] = hits
    return len(hits) <= RATE_MAX


def _rev(repo_root):
    head = ""
    try:
        import subprocess as _sp

        head = _sp.run(
            ["git", "-C", repo_root, "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=10).stdout.strip()
    except Exception:
        head = ""
    return {"repo": "proxmox-dual-plane-mesh", "head": head,
            "service": "mesh-api"}


def _mesh(db_path):
    try:
        db = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
    except Exception:
        return 503, {"available": False}
    try:
        nodes = [dict(r) for r in db.execute(
            "SELECT name,mesh_ip,machine_id,onboarded_at FROM nodes"
            " ORDER BY name")]
        peers = [dict(r) for r in db.execute(
            "SELECT mesh_ip,seen_at FROM peers ORDER BY mesh_ip")]
        findings = [dict(r) for r in db.execute(
            "SELECT id,ts,kind,detail FROM findings WHERE status='open'"
            " ORDER BY id")]
        counts = {}
        for tbl, key in (("eero_devices", "devices"),
                         ("eero_reservations", "reservations"),
                         ("eero_forwards", "forwards")):
            try:
                counts[key] = db.execute(
                    "SELECT COUNT(*) FROM %s" % tbl).fetchone()[0]
            except Exception:
                counts[key] = 0
        return 200, {"available": True, "nodes": nodes, "peers": peers,
                     "findings": findings, "counts": counts}
    except Exception:
        return 503, {"available": False, "nodes": [], "peers": [],
                     "findings": [], "counts": {}}
    finally:
        try:
            db.close()
        except Exception:
            pass


def _certs(cert_path):
    if not cert_path or not os.path.exists(cert_path):
        return {"available": False, "reason": "no cert file configured"}
    try:
        import ssl

        with open(cert_path, "rb") as f:
            der = f.read()
        pem = der.decode("ascii", "strict") if der.startswith(b"-----") else None
        if pem is None:
            info = {"available": False, "reason": "not PEM"}
            return info
        cert = ssl._ssl._test_decode_cert(cert_path)  # noqa: SLF001
        sans = [v for _, v in cert.get("subjectAltName", [])]
        fp = hashlib.sha256(der).hexdigest().upper()
        fp = ":".join(fp[i:i + 2] for i in range(0, len(fp), 2))
        return {"available": True, "fingerprint256": fp,
                "subjectAltName": sans,
                "validFrom": cert.get("notBefore"),
                "validTo": cert.get("notAfter")}
    except Exception as e:
        return {"available": False, "reason": type(e).__name__}


def _client_db(path):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    db = sqlite3.connect(path)
    db.execute("CREATE TABLE IF NOT EXISTS client_log"
               "(ts TEXT, ip TEXT, source TEXT, message TEXT, url TEXT)")
    db.commit()
    return db


def _client_list(path):
    try:
        db = sqlite3.connect("file:%s?mode=ro" % path, uri=True)
        rows = db.execute("SELECT ts,ip,source,message,url FROM client_log"
                          " ORDER BY ts DESC LIMIT 50").fetchall()
        db.close()
        return {"rows": [dict(zip(("ts", "ip", "source", "message", "url"), r))
                         for r in rows]}
    except Exception:
        return {"rows": []}


class Handler(BaseHTTPRequestHandler):
    server_version = "mesh-api/1"

    def _cors(self, code=200, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Max-Age", "86400")
        self.end_headers()

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self._cors(code)
        self.wfile.write(body)

    def do_OPTIONS(self):
        self._cors(204)
        self.wfile.write(b"")

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


def make_handler(cfg):
    class H(Handler):
        def do_GET(self):
            url = urlparse(self.path).path
            if url == "/api/rev":
                self._json(200, _rev(cfg["repo_root"]))
            elif url == "/api/mesh":
                code, obj = _mesh(cfg["inventory"])
                self._json(code, obj)
            elif url == "/api/certs":
                self._json(200, _certs(cfg["cert"]))
            elif url == "/api/client-log":
                self._json(200, _client_list(cfg["clientdb"]))
            else:
                self._json(404, {"error": "not found"})

        def do_POST(self):
            url = urlparse(self.path).path
            if url != "/api/client-log":
                self._json(404, {"error": "not found"})
                return
            ip = self.client_address[0] if self.client_address else "?"
            if not _rate_ok(ip):
                self._json(429, {"error": "rate limited"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except Exception:
                length = 0
            if length <= 0 or length > 4096:
                self._json(400, {"error": "body 1..4096 bytes required"})
                return
            try:
                body = json.loads(self.rfile.read(length).decode("utf-8"))
            except Exception:
                self._json(400, {"error": "bad json"})
                return
            source = str(body.get("source", ""))[:80]
            message = str(body.get("message", ""))[:1000]
            page = str(body.get("url", ""))[:200]
            if not source or not message:
                self._json(400, {"error": "source+message required"})
                return
            try:
                db = _client_db(cfg["clientdb"])
                db.execute("INSERT INTO client_log(ts,ip,source,message,url)"
                           " VALUES(?,?,?,?,?)",
                           (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                            ip, source, message, page))
                db.commit()
                db.close()
            except Exception:
                self._json(500, {"error": "store failed"})
                return
            self._json(200, {"ok": True})

    return H


def main(argv=None):
    ap = argparse.ArgumentParser(prog="mesh-api.py")
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=5409)
    ap.add_argument("--db", default=INVENTORY_DEFAULT)
    ap.add_argument("--clientdb", default=CLIENT_DB_DEFAULT)
    ap.add_argument("--cert", default=os.environ.get("MESH_CERT_PATH", ""))
    ap.add_argument("--repo-root",
                    default=os.path.dirname(os.path.dirname(
                        os.path.abspath(__file__))))
    args = ap.parse_args(argv)
    cfg = {"inventory": args.db, "clientdb": args.clientdb,
           "cert": args.cert, "repo_root": args.repo_root}
    srv = HTTPServer((args.bind, args.port), make_handler(cfg))
    print("mesh-api on http://%s:%d" % (args.bind, args.port), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
