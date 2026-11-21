#!/usr/bin/env python3
# Brand: FastDecrypt · https://fastdecrypt.bot
"""
Create a Pyrogram StringSession so the Mac bot uploads IPAs as *you*
(Telegram Premium → ≤4 GB docs + cloud storage).

WebSSH (one iPhone — no second camera needed):
  zsh ~/tetherless/server/mac-ssh.sh session
  → open the http://… link in Safari on the phone → tap “Open Telegram”

Optional:
  zsh ~/tetherless/server/mac-ssh.sh session --code   # phone + login code

Needs api_id / api_hash from https://my.telegram.org (same Premium account).
Writes TELEGRAM_* into ~/.tetherless-mac.env automatically.
"""
from __future__ import annotations

import asyncio
import base64
import http.server
import os
import re
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path


def env_paths() -> list[Path]:
    home = Path.home()
    return [
        home / ".tetherless-mac.env",
        Path("/users/client/.tetherless-mac.env"),
    ]


def read_existing() -> dict[str, str]:
    out: dict[str, str] = {}
    for p in env_paths():
        if not p.is_file():
            continue
        for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
            s = line.strip()
            if not s or s.startswith("#") or "=" not in s:
                continue
            k, v = s.split("=", 1)
            out[k.strip()] = v.strip().strip("'").strip('"')
        break
    for k in ("TELEGRAM_API_ID", "TELEGRAM_API_HASH", "TELEGRAM_SESSION", "TELEGRAM_SESSION_STRING"):
        if os.environ.get(k):
            out[k] = os.environ[k].strip()
    return out


def upsert_env(updates: dict[str, str]) -> Path:
    path = next((p for p in env_paths() if p.is_file()), env_paths()[0])
    path.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = []
    if path.is_file():
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    keys = set(updates)
    new_lines: list[str] = []
    seen: set[str] = set()
    for line in lines:
        m = re.match(r"^([A-Za-z0-9_]+)=", line.strip())
        if m and m.group(1) in keys:
            k = m.group(1)
            new_lines.append(f"{k}={updates[k]}")
            seen.add(k)
        else:
            new_lines.append(line)
    for k, v in updates.items():
        if k not in seen:
            new_lines.append(f"{k}={v}")
    path.write_text("\n".join(new_lines).rstrip() + "\n", encoding="utf-8")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return path


def lan_ips() -> list[str]:
    ips: list[str] = []
    try:
        out = subprocess.check_output(["ifconfig"], text=True, stderr=subprocess.DEVNULL)
        for m in re.finditer(r"inet (192\.168\.\d+\.\d+|10\.\d+\.\d+\.\d+|172\.(1[6-9]|2\d|3[0-1])\.\d+\.\d+)", out):
            ip = m.group(1)
            if ip not in ips:
                ips.append(ip)
    except Exception:
        pass
    return ips


class _LoginPageState:
    def __init__(self) -> None:
        self.url = ""
        self.lock = threading.Lock()

    def set_url(self, url: str) -> None:
        with self.lock:
            self.url = url

    def html(self) -> bytes:
        with self.lock:
            tg = self.url or "tg://"
        body = f"""<!DOCTYPE html>
<html><head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>FastDecrypt · Link Telegram</title>
<style>
body{{font-family:-apple-system,system-ui,sans-serif;background:#0b0d14;color:#e8eef8;
margin:0;padding:28px;text-align:center}}
a.btn{{display:inline-block;margin-top:24px;padding:16px 22px;background:#2AABEE;color:#fff;
text-decoration:none;font-weight:700;border-radius:12px;font-size:18px}}
p{{opacity:.85;line-height:1.45}}
code{{word-break:break-all;font-size:12px;opacity:.7}}
</style></head><body>
<h1>Link Premium session</h1>
<p>You only need this phone — tap the button to open Telegram and approve.</p>
<p><a class="btn" href="{tg}">Open Telegram</a></p>
<p>If the button does nothing, copy this into Safari’s address bar:</p>
<p><code>{tg}</code></p>
</body></html>"""
        return body.encode("utf-8")


def start_login_http(state: _LoginPageState, port: int = 8766):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            data = state.html()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, fmt, *args):  # noqa: A003
            return

    server = http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler)
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return server


async def login_link(api_id: int, api_hash: str):
    """Authorize via tg:// link — works on one iPhone (no QR camera needed)."""
    from pyrogram import Client
    from pyrogram.errors import SessionPasswordNeeded
    from pyrogram.raw import functions, types

    app = Client(
        name="tetherless_session_setup_link",
        api_id=api_id,
        api_hash=api_hash,
        in_memory=True,
    )
    await app.connect()
    state = _LoginPageState()
    httpd = None
    port = int(os.environ.get("TELEGRAM_LOGIN_HTTP_PORT") or "8766")
    try:
        try:
            httpd = start_login_http(state, port=port)
        except OSError as e:
            print(f"(Could not bind login page on :{port}: {e})")
            httpd = None

        print()
        print("One-phone login (no QR scan needed)")
        print("1) Keep this SSH session open")
        print("2) On the iPhone, open ONE of these in Safari:")
        for ip in lan_ips() or ["<mac-lan-ip>"]:
            print(f"      http://{ip}:{port}/")
        print("3) Tap “Open Telegram” and approve the new device")
        print("   (Or long-press/tap the tg:// link printed below if your SSH app makes it blue)")
        print()

        last_url = ""
        while True:
            try:
                r = await app.invoke(
                    functions.auth.ExportLoginToken(
                        api_id=api_id,
                        api_hash=api_hash,
                        except_ids=[],
                    )
                )
            except SessionPasswordNeeded:
                pw = input("Two-step verification password: ").strip()
                await app.check_password(pw)
                break

            if isinstance(r, types.auth.LoginToken):
                token_b64 = base64.urlsafe_b64encode(r.token).decode("utf-8").rstrip("=")
                url = f"tg://login?token={token_b64}"
                state.set_url(url)
                if url != last_url:
                    last_url = url
                    print("Approve link (refreshes every ~20s):")
                    print(url)
                    print()
                    # If Telegram Desktop/macOS is installed & logged in, this can approve too.
                    try:
                        subprocess.Popen(
                            ["open", url],
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                        )
                    except Exception:
                        pass
                await asyncio.sleep(3)
                continue
            if isinstance(r, types.auth.LoginTokenMigrateTo):
                await app._switch_dc(r.dc_id)  # noqa: SLF001
                continue
            if isinstance(r, types.auth.LoginTokenSuccess):
                break
            raise RuntimeError(f"Unexpected login token response: {type(r)!r}")

        me = await app.get_me()
        session = await app.export_session_string()
        return me, session
    finally:
        if httpd is not None:
            try:
                httpd.shutdown()
            except Exception:
                pass
        await app.disconnect()


async def login_code(api_id: int, api_hash: str):
    from pyrogram import Client

    print()
    print("Phone + code login…")
    print("Phone must be international, e.g. +15551234567")
    print()
    print("APP login code = digits in official “Telegram” chat (NOT my.telegram.org web codes).")
    print("With only one phone, codes are flaky — prefer the default link login instead.")
    print()

    def phone_code_callback() -> str:
        print()
        print("→ Numeric “Login code: …” only (not my.telegram.org web code)")
        return input("Enter login code: ").strip()

    async with Client(
        name="tetherless_session_setup",
        api_id=api_id,
        api_hash=api_hash,
        in_memory=True,
        phone_code_callback=phone_code_callback,
    ) as app:
        me = await app.get_me()
        session = await app.export_session_string()
        return me, session


async def main() -> None:
    try:
        from pyrogram import Client  # noqa: F401
    except Exception:
        print("Install: python3 -m pip install --user pyrogram tgcrypto", file=sys.stderr)
        sys.exit(1)

    args = [a.strip().lower() for a in sys.argv[1:] if a.strip()]
    want_code = any(a in ("--code", "code", "-c") for a in args)

    existing = read_existing()
    api_id_s = existing.get("TELEGRAM_API_ID") or input("TELEGRAM_API_ID (my.telegram.org): ").strip()
    api_hash = existing.get("TELEGRAM_API_HASH") or input("TELEGRAM_API_HASH: ").strip()
    if not api_id_s or not api_hash:
        print("api_id and api_hash are required.", file=sys.stderr)
        sys.exit(1)
    api_id = int(api_id_s)

    if want_code:
        me, session = await login_code(api_id, api_hash)
    else:
        try:
            me, session = await login_link(api_id, api_hash)
        except Exception as e:
            print(f"Link login failed ({e}). Falling back to phone code…", file=sys.stderr)
            me, session = await login_code(api_id, api_hash)

    premium = bool(getattr(me, "is_premium", False))
    uname = getattr(me, "username", None) or ""
    name = " ".join(
        x for x in [getattr(me, "first_name", None) or "", getattr(me, "last_name", None) or ""] if x
    ).strip()

    path = upsert_env(
        {
            "TELEGRAM_API_ID": str(api_id),
            "TELEGRAM_API_HASH": api_hash,
            "TELEGRAM_SESSION": session,
            "TELEGRAM_PREMIUM_UPLOAD": "1",
        }
    )
    print()
    print(f"Logged in as: {name or uname or me.id} (@{uname or '—'}) premium={premium}")
    if not premium:
        print("WARN: this account is not Telegram Premium — uploads stay ≤2 GB as a normal user.")
    print(f"Wrote session into: {path}")
    print("Restart the bot:  zsh ~/tetherless/server/mac-ssh.sh start")


if __name__ == "__main__":
    asyncio.run(main())
