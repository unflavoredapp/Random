#!/usr/bin/env python3
# Brand: Tetherless · https://tetherless.dev
"""
Upload a decrypted IPA as a *Telegram Premium user* (up to 4 GB).

Bot API cannot use Premium limits. This script uses Pyrogram MTProto with your
user account session.

One-time setup on the Mac (desktop Terminal):
  python3 -m pip install --user pyrogram tgcrypto
  # Create api_id / api_hash at https://my.telegram.org
  # Create a StringSession once, then put in ~/.tetherless-mac.env:
  #   TELEGRAM_API_ID=...
  #   TELEGRAM_API_HASH=...
  #   TELEGRAM_SESSION=1BVts...   # StringSession
  #   TELEGRAM_PREMIUM_UPLOAD=1

Invoked by mac-tg-bot.js with env:
  TG_UPLOAD_CHAT_ID, TG_UPLOAD_FILE, TG_UPLOAD_FILENAME, TG_UPLOAD_CAPTION
Prints JSON {ok:true} on success.
"""
from __future__ import annotations

import asyncio
import json
import os
import sys


def fail(msg: str, code: int = 1) -> None:
    print(json.dumps({"ok": False, "description": msg[:300]}))
    sys.exit(code)


async def main() -> None:
    try:
        from pyrogram import Client  # type: ignore
    except Exception:
        fail("Install pyrogram: python3 -m pip install --user pyrogram tgcrypto")

    api_id = int(os.environ.get("TELEGRAM_API_ID") or "0")
    api_hash = (os.environ.get("TELEGRAM_API_HASH") or "").strip()
    session = (
        os.environ.get("TELEGRAM_SESSION")
        or os.environ.get("TELEGRAM_SESSION_STRING")
        or ""
    ).strip()
    chat_id = (os.environ.get("TG_UPLOAD_CHAT_ID") or "").strip()
    path = (os.environ.get("TG_UPLOAD_FILE") or "").strip()
    filename = (os.environ.get("TG_UPLOAD_FILENAME") or os.path.basename(path) or "App.ipa").strip()
    caption = os.environ.get("TG_UPLOAD_CAPTION") or ""

    if not api_id or not api_hash or not session:
        fail("Set TELEGRAM_API_ID, TELEGRAM_API_HASH, TELEGRAM_SESSION")
    if not chat_id or not path or not os.path.isfile(path):
        fail("Missing TG_UPLOAD_CHAT_ID or TG_UPLOAD_FILE")

    # StringSession avoids interactive login on the MacDuty box.
    app = Client(
        name="tetherless_premium_upload",
        api_id=api_id,
        api_hash=api_hash,
        session_string=session,
        in_memory=True,
    )

    async with app:
        # Send as the Premium user into the same private chat the bot uses.
        # HTML caption matches Bot API parse_mode=HTML from mac-tg-bot.js.
        target = int(chat_id) if chat_id.lstrip("-").isdigit() else chat_id
        msg = await app.send_document(
            chat_id=target,
            document=path,
            file_name=filename,
            caption=caption[:1024] if caption else None,
            parse_mode="html",
            force_document=True,
        )
    # message_id lets the bot copyMessage later (instant cloud re-send).
    print(
        json.dumps(
            {
                "ok": True,
                "filename": filename,
                "message_id": getattr(msg, "id", None),
                "chat_id": chat_id,
            }
        )
    )


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as e:
        fail(str(e))
