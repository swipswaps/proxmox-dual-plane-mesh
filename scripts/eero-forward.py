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

Secrets: email/code/session never printed; only ids, names, and counts.
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
        devs = r.get("data", {}).get("devices", r.get("data", []))
        if isinstance(devs, dict):
            devs = [devs]
        for d in devs:
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
            print(f.get("id"), "|", f.get("description"), "|",
                  f.get("protocol"), f.get("gateway_port"),
                  "->", f.get("ip"), f.get("client_port"))


async def cmd_add(net, ip, gw, cli, proto, desc):
    c = client()
    async with c:
        body = {"client_port": int(cli), "description": desc,
                "enabled": True, "gateway_port": int(gw),
                "ip": ip, "protocol": proto.lower()}
        r = await c.create_forward(net, body)
        d = r.get("data", {})
        print("CREATED", d.get("id"), "|", d.get("description"))


async def cmd_delete(net, fid, yes):
    if yes != "--yes":
        fail("refusing without --yes (two-word confirm pattern)")
    c = client()
    async with c:
        await c.delete_forward(net, fid)
        print("DELETED", fid)


def main():
    if len(sys.argv) < 2:
        fail("usage: eero-forward.py [login|verify|networks|devices|forwards|add|delete] ...")
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
        else:
            fail("bad args; see module docstring")
    except SystemExit:
        raise
    except Exception as e:
        fail("%s: %s" % (type(e).__name__, str(e)[:200]))


main()
