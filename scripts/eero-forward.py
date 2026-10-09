#!/usr/bin/env python3
"""eero-forward.py — manage eero port forwards via the (unofficial) cloud API.

Needs: pip install eero-api. Auth is email/SMS code (one-time user step);
session persists in a mode-600 cookie file, no keyring needed headless.

Usage:
  eero-forward.py login EMAIL            # sends verification code
  eero-forward.py verify                 # silent-prompt for code, stores session
  eero-forward.py networks               # list networks (id + name)
  eero-forward.py devices NET_ID         # clients: hostname, ip, mac
  eero-forward.py forwards NET_ID        # list rules (id, desc, ports, ip)
  eero-forward.py add NET_ID IP GW CLI PROTO DESC
                                         # e.g. add <net> 192.168.4.45 4242 4242 udp nebula
  eero-forward.py delete NET_ID FWD_ID --yes
  eero-forward.py nickname NET_ID DEVICE_ID NAME
                                         # rename a device (id or mac)
  eero-forward.py reserve NET_ID MAC IP [DESC]
                                         # DHCP reservation (create or update)
  eero-forward.py ensure-lab NET_ID MAC IP NICKBASE [PORT] [--mid MID8]
                                         # one shot: nickname NICKBASE-MID8,
                                         # reserve IP, ensure PORT forward.
                                         # MID8 = target's /etc/machine-id[0:8]
                                         # (read once on the target by hand)

Secrets: email/code/session never printed; only ids, names, and counts.
Identity: device names are human + machine-id suffix (NAME-mid8), never
raw hardware serials. No subprocess use in this file (repo lint rule):
the operator reads the target's machine-id once; everything after is code.
"""
import asyncio
import getpass
import os
import stat
import sys

COOKIE = os.path.expanduser("~/.local/share/eero-cookies")


def fail(msg):
    sys.stderr.write("FAIL: %s\n" % msg)
    raise SystemExit(2)


def client():
    from eero import EeroClient
    os.makedirs(os.path.dirname(COOKIE), exist_ok=True)
    c = EeroClient(cookie_file=COOKIE, use_keyring=False)
    return c


def lock_cookie():
    if os.path.exists(COOKIE):
        os.chmod(COOKIE, 0o600)


async def cmd_login(email):
    c = client()
    async with c:
        ok = await c.login(email)
        print("CODE-SENT" if ok else "LOGIN-FAILED")
        if not ok:
            fail("eero rejected the login request")


async def cmd_verify():
    code = getpass.getpass("eero verification code (hidden): ").strip()
    if len(code) < 4:
        fail("code too short; nothing changed")
    c = client()
    async with c:
        ok = await c.verify(code)
        lock_cookie()
        print("VERIFIED" if ok else "VERIFY-FAILED")
        if not ok:
            fail("code rejected")


async def cmd_networks():
    c = client()
    async with c:
        r = await c.get_networks()
        for n in r.get("data", {}).get("networks", []):
            print(n.get("id"), "|", n.get("name"), "|", n.get("status"))


async def cmd_devices(net):
    c = client()
    async with c:
        r = await c.get_devices(net)
        devs = r.get("data", [])
        if isinstance(devs, dict):
            devs = devs.get("devices", [devs])
        for d in devs:
            if not isinstance(d, dict):
                continue
            print(d.get("hostname", d.get("nickname", "?")), "|",
                  d.get("ip"), "|", d.get("mac"))


async def cmd_forwards(net):
    c = client()
    async with c:
        r = await c.get_forwards(net)
        items = r.get("data", [])
        if isinstance(items, dict):
            items = [items]
        for f in items:
            if not isinstance(f, dict):
                continue
            print(f.get("id"), "|", f.get("description"), "|",
                  f.get("protocol"), f.get("gateway_port"),
                  "->", f.get("ip"), f.get("client_port"))


async def cmd_add(net, ip, gw, cli, proto, desc):
    c = client()
    async with c:
        body = {"client_port": int(cli), "description": desc,
                "enabled": True, "gateway_port": int(gw),
                "ip": ip, "protocol": proto.lower()}
        r = await c.create_forward(body, net)
        d = r.get("data", {})
        blob = str(d)
        import re as _re
        m = _re.search(r"'id': '([^']+)'", blob)
        print("CREATED", m.group(1) if m else d.get("id"),
              "|", d.get("description"))


async def cmd_delete(net, fid, yes):
    if yes != "--yes":
        fail("refusing without --yes (two-word confirm pattern)")
    c = client()
    async with c:
        await c.delete_forward(fid, net)
        print("DELETED", fid)


async def find_device(c, net, ident):
    r = await c.get_devices(net)
    devs = r.get("data", [])
    if isinstance(devs, dict):
        devs = devs.get("devices", [devs])
    want = ident.lower()
    for d in devs:
        if not isinstance(d, dict):
            continue
        if str(d.get("url", "")).lower() == want:
            return d
        if str(d.get("mac", "")).lower() == want:
            return d
        if str(d.get("hostname", "")).lower() == want:
            return d
        if str(d.get("nickname", "")).lower() == want:
            return d
    return None


async def cmd_nickname(net, ident, name):
    if not name or len(name) > 64:
        fail("bad nickname (1-64 chars)")
    c = client()
    async with c:
        d = await find_device(c, net, ident)
        if not d:
            fail("no device matches %s" % ident)
        did = d.get("url") or d.get("id")
        if not did:
            fail("device has no id")
        await c.set_device_nickname(did, name, net)
        print("NICKNAMED", d.get("mac"), "->", name)


async def cmd_reserve(net, mac, ip, desc):
    c = client()
    async with c:
        r = await c.get_reservations(net)
        items = r.get("data", [])
        if isinstance(items, dict):
            items = [items]
        for res in items:
            if not isinstance(res, dict):
                continue
            if str(res.get("mac", "")).lower() == mac.lower():
                rid = res.get("url") or res.get("id")
                # NOTE: no public_static_ip field — the API 400s on it;
                # declared updatable fields are description/ip/mac.
                body = {"description": desc or res.get("description", ""),
                        "ip": ip, "mac": mac}
                await c.update_reservation(rid, body, net)
                print("RESERVED-UPDATE", mac, "->", ip)
                return
        body = {"description": desc or "mesh-node",
                "ip": ip, "mac": mac}
        await c.create_reservation(body, net)
        print("RESERVED-CREATE", mac, "->", ip)


async def cmd_ensure_lab(net, mac, ip, nickbase, port, mid):
    mid = (mid or "").strip().lower()
    if mid and (len(mid) != 8 or any(
            ch not in "0123456789abcdef" for ch in mid)):
        fail("bad --mid (want 8 hex chars from the target's /etc/machine-id)")
    name = ("%s-%s" % (nickbase, mid)) if mid else nickbase
    c = client()
    async with c:
        d = await find_device(c, net, mac)
        if not d:
            fail("no device with mac %s (is it on the LAN?)" % mac)
        did = d.get("url") or d.get("id")
        await c.set_device_nickname(did, name, net)
        print("NICKNAMED", mac, "->", name)
    await cmd_reserve(net, mac, ip, "mesh-node " + name)
    c2 = client()
    async with c2:
        r = await c2.get_forwards(net)
        items = r.get("data", [])
        if isinstance(items, dict):
            items = [items]
        for f in items:
            if not isinstance(f, dict):
                continue
            if (str(f.get("ip", "")) == ip
                    and str(f.get("gateway_port", "")) == str(port)
                    and str(f.get("client_port", "")) == str(port)):
                print("FORWARD-EXISTS", f.get("id"), "|",
                      f.get("description"))
                print("ENSURED", name, ip, port)
                return
        await cmd_add(net, ip, port, port, "udp", "nebula " + name)
        print("ENSURED", name, ip, port)


def main():
    if len(sys.argv) < 2:
        fail("usage: eero-forward.py [login|verify|networks|devices|forwards|add|delete|nickname|reserve|ensure-lab] ...")
    cmd = sys.argv[1]
    try:
        if cmd == "login" and len(sys.argv) == 3:
            asyncio.run(cmd_login(sys.argv[2]))
        elif cmd == "verify":
            asyncio.run(cmd_verify())
        elif cmd == "networks":
            asyncio.run(cmd_networks())
        elif cmd == "devices" and len(sys.argv) == 3:
            asyncio.run(cmd_devices(sys.argv[2]))
        elif cmd == "forwards" and len(sys.argv) == 3:
            asyncio.run(cmd_forwards(sys.argv[2]))
        elif cmd == "add" and len(sys.argv) == 8:
            asyncio.run(cmd_add(*sys.argv[2:8]))
        elif cmd == "delete" and len(sys.argv) == 5:
            asyncio.run(cmd_delete(sys.argv[2], sys.argv[3], sys.argv[4]))
        elif cmd == "nickname" and len(sys.argv) == 5:
            asyncio.run(cmd_nickname(sys.argv[2], sys.argv[3], sys.argv[4]))
        elif cmd == "reserve" and 5 <= len(sys.argv) <= 6:
            desc = sys.argv[5] if len(sys.argv) == 6 else ""
            asyncio.run(cmd_reserve(sys.argv[2], sys.argv[3], sys.argv[4], desc))
        elif cmd == "ensure-lab" and 6 <= len(sys.argv) <= 8:
            port, mid = "4242", ""
            rest = list(sys.argv[6:])
            if rest and not rest[0].startswith("--mid"):
                port = rest.pop(0)
            if "--mid" in rest:
                i = rest.index("--mid")
                if i + 1 < len(rest):
                    mid = rest[i + 1]
            for tok in rest:
                if tok.startswith("--mid="):
                    mid = tok.split("=", 1)[1]
            asyncio.run(cmd_ensure_lab(
                sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], port, mid))
        else:
            fail("bad args; see module docstring")
    except SystemExit:
        raise
    except Exception as e:
        fail("%s: %s" % (type(e).__name__, str(e)[:200]))


main()
