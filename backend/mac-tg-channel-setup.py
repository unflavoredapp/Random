#!/usr/bin/env python3
# Brand: FastDecrypt · https://fastdecrypt.bot
"""
Resolve a private channel invite (or @username / -100 id) and write
TELEGRAM_UPLOAD_CHANNEL into ~/.tetherless-mac.env.

Uses your existing Premium Pyrogram session (same as DELvEK / large IPA uploads).

  zsh ~/tetherless/server/mac-ssh.sh channel 'https://t.me/+e3BiOpG8QEw5MTEx'

Then add @FastDecryptAI as channel admin (Post messages) and restart the bot.
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
    for k in (
        "TELEGRAM_API_ID",
        "TELEGRAM_API_HASH",
        "TELEGRAM_SESSION",
        "TELEGRAM_SESSION_STRING",
        "TELEGRAM_BOT_USERNAME",
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


def normalize_peer(raw: str) -> str:
    s = (raw or "").strip()
    if not s:
        return ""
    # https://t.me/+HASH  /  t.me/joinchat/HASH  /  @name  /  -100…
    m = re.search(r"(?:https?://)?t\.me/\+([A-Za-z0-9_-]+)", s)
    if m:
        return f"https://t.me/+{m.group(1)}"
    m = re.search(r"(?:https?://)?t\.me/joinchat/([A-Za-z0-9_-]+)", s, re.I)
    if m:
        return f"https://t.me/joinchat/{m.group(1)}"
    if s.lstrip("-").isdigit():
        return s
    if s.startswith("@"):
        return s
    if re.fullmatch(r"[A-Za-z][A-Za-z0-9_]{3,}", s):
        return f"@{s}"
    return s


def channel_env_id(chat) -> str:
    """Bot API / copyMessage style id: -100xxxxxxxxxx for channels/supergroups."""
    cid = int(getattr(chat, "id", 0) or 0)
    if cid == 0:
        raise RuntimeError("chat has no id")
    # Pyrogram already returns -100… for channels; keep as-is.
    return str(cid)


async def resolve_chat(app, peer: str):
    # Prefer join (idempotent if already a member); fall back to get_chat.
    try:
        return await app.join_chat(peer)
    except Exception as join_err:
        try:
            return await app.get_chat(peer)
        except Exception as get_err:
            raise RuntimeError(
                f"Could not open channel ({peer}): join={join_err}; get={get_err}"
            ) from get_err


async def main() -> None:
    try:
        from pyrogram import Client
    except Exception:
        print("Install: python3 -m pip install --user pyrogram tgcrypto", file=sys.stderr)
        sys.exit(1)

    peer_raw = " ".join(sys.argv[1:]).strip()
    if not peer_raw:
        print(
            "Usage: python3 server/mac-tg-channel-setup.py 'https://t.me/+….…'",
            file=sys.stderr,
        )
        sys.exit(1)

    peer = normalize_peer(peer_raw)
    existing = read_existing()
    api_id_s = existing.get("TELEGRAM_API_ID") or ""
    api_hash = existing.get("TELEGRAM_API_HASH") or ""
    session = (
        existing.get("TELEGRAM_SESSION")
        or existing.get("TELEGRAM_SESSION_STRING")
        or ""
    )
    if not api_id_s or not api_hash or not session:
        print(
            "Missing TELEGRAM_API_ID / HASH / SESSION in ~/.tetherless-mac.env "
            "(reuse DELvEK session — no re-login if still valid).",
            file=sys.stderr,
        )
        sys.exit(1)

    bot_uname = (
        existing.get("TELEGRAM_BOT_USERNAME")
        or os.environ.get("TELEGRAM_BOT_USERNAME")
        or "FastDecryptAI"
    ).lstrip("@")

    print(f"Resolving staging channel via Premium session → {peer}")
    async with Client(
        name="fastdecrypt_channel_setup",
        api_id=int(api_id_s),
        api_hash=api_hash,
        session_string=session,
        in_memory=True,
    ) as app:
        chat = await resolve_chat(app, peer)
        chat_id = channel_env_id(chat)
        title = getattr(chat, "title", None) or getattr(chat, "first_name", None) or "?"
        ctype = getattr(getattr(chat, "type", None), "name", None) or str(
            getattr(chat, "type", "")
        )

    path = upsert_env(
        {
            "TELEGRAM_UPLOAD_CHANNEL": chat_id,
            "TELEGRAM_PREMIUM_UPLOAD": "1",
        }
    )
    print()
    print(f"Channel: {title} ({ctype})")
    print(f"TELEGRAM_UPLOAD_CHANNEL={chat_id}")
    print(f"Wrote into: {path}")
    print()
    print(f"Next: add @{bot_uname} as admin on that channel (Post messages), then:")
    print("  zsh ~/tetherless/server/mac-ssh.sh start")
    print("Confirm with /status → Upload: Premium → channel … → bot")


if __name__ == "__main__":
    asyncio.run(main())
