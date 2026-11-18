#!/usr/bin/env python3
# Brand: Tetherless · https://tetherless.dev
"""
One-time: create a Pyrogram StringSession for Premium IPA uploads (≤4 GB).

  python3 -m pip install --user pyrogram tgcrypto
  python3 server/mac-tg-session-setup.py

Paste api_id / api_hash from https://my.telegram.org, then phone + login code.
Prints TELEGRAM_SESSION=... to add to ~/.tetherless-mac.env
"""
from __future__ import annotations

import asyncio
import sys


async def main() -> None:
    try:
        from pyrogram import Client
        from pyrogram.session import StringSession
    except Exception:
        print("Install: python3 -m pip install --user pyrogram tgcrypto", file=sys.stderr)
        sys.exit(1)

    api_id = int(input("TELEGRAM_API_ID: ").strip())
    api_hash = input("TELEGRAM_API_HASH: ").strip()
    async with Client(
        name="tetherless_session_setup",
        api_id=api_id,
        api_hash=api_hash,
        in_memory=True,
    ) as app:
        # Export after interactive login prompts from Pyrogram.
        session = await app.export_session_string()
    print("\nAdd these to ~/.tetherless-mac.env:\n")
    print(f"TELEGRAM_API_ID={api_id}")
    print(f"TELEGRAM_API_HASH={api_hash}")
    print(f"TELEGRAM_SESSION={session}")
    print("TELEGRAM_PREMIUM_UPLOAD=1")
    print("\nRestart Start-Tetherless-Bot.command after saving.")


if __name__ == "__main__":
    asyncio.run(main())
