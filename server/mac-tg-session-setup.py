#!/usr/bin/env python3
# Brand: FastDecrypt · https://fastdecrypt.bot
"""
Create a Pyrogram StringSession so the Mac bot uploads IPAs as *you*
(Telegram Premium → ≤4 GB).

One iPhone (recommended) — public HTTPS page via Mac API + Cloudflare:
  zsh ~/tetherless/server/mac-ssh.sh session
  → open https://….trycloudflare.com/tg-login in Safari → Open Telegram

Optional:
  zsh ~/tetherless/server/mac-ssh.sh session --code

Writes TELEGRAM_* into ~/.tetherless-mac.env.
"""
from __future__ import annotations

import asyncio
import base64
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path


def env_paths() -> list[Path]:
    home = Path.home()
    return [
        home / ".tetherless-mac.env",
        Path("/users/client/.tetherless-mac.env"),
    ]


def run_dir() -> Path:
    return Path(os.environ.get("MAC_SSH_RUN_DIR") or (Path.home() / "tetherless-run"))


def login_file() -> Path:
    return Path(
        os.environ.get("TELEGRAM_LOGIN_FILE") or (run_dir() / "tg-login.json")
    )


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
    for k in (
        "TELEGRAM_API_ID",
        "TELEGRAM_API_HASH",
        "TELEGRAM_SESSION",
        "TELEGRAM_SESSION_STRING",
        "MAC_PUBLIC_BASE",
    ):
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


def write_login_token(url: str) -> None:
    path = login_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps({"url": url, "updated": int(time.time())}) + "\n",
        encoding="utf-8",
    )


def clear_login_token() -> None:
    path = login_file()
    try:
        if path.is_file():
            path.unlink()
    except OSError:
        pass


def resolve_public_base(existing: dict[str, str]) -> str:
    candidates = [
        (existing.get("MAC_PUBLIC_BASE") or "").strip().rstrip("/"),
        "",
        "",
    ]
    for p in (
        run_dir() / "mac-public-url",
        Path.home() / ".tetherless-mac-public-url",
    ):
        try:
            if p.is_file():
                u = p.read_text(encoding="utf-8", errors="replace").strip().rstrip("/")
                if u.startswith("https://"):
                    return u
        except OSError:
            pass
    cf = run_dir() / "cloudflared.log"
    try:
        if cf.is_file():
            txt = cf.read_text(encoding="utf-8", errors="replace")
            ms = re.findall(r"https://[a-zA-Z0-9.-]+\.trycloudflare\.com", txt)
            if ms:
                return ms[-1].rstrip("/")
    except OSError:
        pass
    for c in candidates:
        if c.startswith("https://"):
            return c
    return ""


async def login_link(api_id: int, api_hash: str, public_base: str):
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
    try:
        page = f"{public_base}/tg-login" if public_base else ""
        print()
        print("Premium login via public HTTPS page (works on cellular — no QR / LAN)")
        print("1) Keep this SSH session open")
        if page:
            print(f"2) On your iPhone Safari open:\n      {page}")
        else:
            print("2) No public URL yet — run: zsh ~/tetherless/server/mac-ssh.sh api")
            print("   then re-run session (needs the trycloudflare link)")
        print("3) Tap Open Telegram → approve")
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
                write_login_token(url)
                if url != last_url:
                    last_url = url
                    if page:
                        print(f"Waiting… open {page}")
                    else:
                        print("Approve link:")
                        print(url)
                    print()
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
        clear_login_token()
        await app.disconnect()


async def login_code(api_id: int, api_hash: str):
    from pyrogram import Client

    print()
    print("Phone + code login (often flaky)…")
    print("Use numeric Login code from official Telegram chat — not my.telegram.org web codes.")
    print()

    def phone_code_callback() -> str:
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
    public_base = resolve_public_base(existing)

    if want_code:
        me, session = await login_code(api_id, api_hash)
    else:
        if not public_base:
            print(
                "WARN: no MAC_PUBLIC_BASE / trycloudflare URL — start API first:\n"
                "  zsh ~/tetherless/server/mac-ssh.sh api\n"
                "Then re-run session so Safari can use https://…/tg-login",
                file=sys.stderr,
            )
        try:
            me, session = await login_link(api_id, api_hash, public_base)
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
