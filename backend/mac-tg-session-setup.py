#!/usr/bin/env python3
# Brand: FastDecrypt · https://fastdecrypt.bot
"""
Create a Pyrogram StringSession so the Mac bot uploads IPAs as *you*
(Telegram Premium → ≤4 GB docs + cloud storage).

WebSSH:
  zsh ~/tetherless/server/mac-ssh.sh session          # QR login (recommended)
  zsh ~/tetherless/server/mac-ssh.sh session --code   # phone + login code

Needs api_id / api_hash from https://my.telegram.org (same Premium account).
Writes TELEGRAM_* into ~/.tetherless-mac.env automatically.
"""
from __future__ import annotations

import asyncio
import base64
import os
import re
import sys
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


def print_qr(url: str) -> None:
    try:
        import qrcode  # type: ignore

        qr = qrcode.QRCode(border=1)
        qr.add_data(url)
        qr.make(fit=True)
        qr.print_ascii(invert=True)
    except Exception:
        print("(Install qrcode for ASCII QR: python3 -m pip install --user qrcode)")
        print(f"Open on phone Telegram: {url}")


async def login_qr(api_id: int, api_hash: str):
    from pyrogram import Client
    from pyrogram.errors import SessionPasswordNeeded
    from pyrogram.raw import functions, types

    app = Client(
        name="tetherless_session_setup_qr",
        api_id=api_id,
        api_hash=api_hash,
        in_memory=True,
    )
    await app.connect()
    try:
        print()
        print("QR login — no SMS / in-app code needed.")
        print("On your phone: Telegram → Settings → Devices → Link Desktop Device")
        print("Scan the QR below (refreshes automatically).")
        print()

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
                print("\n--- scan this QR ---\n")
                print_qr(url)
                print(f"\nOr open: {url}")
                print("Waiting for scan…\n")
                wait = max(5, min(25, int(getattr(r, "expires", time.time() + 30) - time.time() - 2)))
                await asyncio.sleep(wait)
                continue
            if isinstance(r, types.auth.LoginTokenMigrateTo):
                await app._switch_dc(r.dc_id)  # noqa: SLF001 — required for QR DC migrate
                continue
            if isinstance(r, types.auth.LoginTokenSuccess):
                break
            raise RuntimeError(f"Unexpected login token response: {type(r)!r}")

        me = await app.get_me()
        session = await app.export_session_string()
        return me, session
    finally:
        await app.disconnect()


async def login_code(api_id: int, api_hash: str):
    from pyrogram import Client

    print()
    print("Phone + code login…")
    print("Phone must be international, e.g. +15551234567")
    print()
    print("Where the APP login code appears (usually NOT SMS):")
    print("  Telegram app → official chat “Telegram” → “Login code: 12345” (digits)")
    print("IGNORE “Web login code” / my.telegram.org messages — those will not work here.")
    print("If nothing new appears after several tries, Ctrl+C and use QR:")
    print("  zsh ~/tetherless/server/mac-ssh.sh session")
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
        print("Install: python3 -m pip install --user pyrogram tgcrypto qrcode", file=sys.stderr)
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
            me, session = await login_qr(api_id, api_hash)
        except Exception as e:
            print(f"QR login failed ({e}). Falling back to phone code…", file=sys.stderr)
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
