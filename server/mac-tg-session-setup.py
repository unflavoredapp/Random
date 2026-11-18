#!/usr/bin/env python3
# Brand: Tetherless · https://tetherless.dev
"""
One-time: create a Pyrogram StringSession so the Mac bot uploads IPAs as *you*
(Telegram Premium → ≤4 GB docs + cloud storage).

WebSSH:
  zsh ~/tetherless/server/mac-ssh.sh session

Or:
  python3 -m pip install --user pyrogram tgcrypto
  python3 server/mac-tg-session-setup.py

Needs api_id / api_hash from https://my.telegram.org (same account that has Premium).
Writes TELEGRAM_* into ~/.tetherless-mac.env automatically.
"""
from __future__ import annotations

import asyncio
import os
import re
import sys
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
    # Process env wins
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
    text = "\n".join(new_lines).rstrip() + "\n"
    path.write_text(text, encoding="utf-8")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return path


async def main() -> None:
    try:
        from pyrogram import Client
    except Exception:
        print("Install: python3 -m pip install --user pyrogram tgcrypto", file=sys.stderr)
        sys.exit(1)

    existing = read_existing()
    api_id_s = existing.get("TELEGRAM_API_ID") or input("TELEGRAM_API_ID (my.telegram.org): ").strip()
    api_hash = existing.get("TELEGRAM_API_HASH") or input("TELEGRAM_API_HASH: ").strip()
    if not api_id_s or not api_hash:
        print("api_id and api_hash are required.", file=sys.stderr)
        sys.exit(1)
    api_id = int(api_id_s)

    print("Logging in as your Telegram user (Premium account)…")
    print("Enter phone (international) and login code when prompted.")
    async with Client(
        name="tetherless_session_setup",
        api_id=api_id,
        api_hash=api_hash,
        in_memory=True,
    ) as app:
        me = await app.get_me()
        session = await app.export_session_string()
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
