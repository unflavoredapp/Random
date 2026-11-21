#!/usr/bin/env python3
# Brand: FastDecrypt · https://fastdecrypt.bot
"""
Upload a decrypted IPA as a *Telegram Premium user* (up to 4 GB).

Bot API cannot use Premium limits. This script uses Pyrogram MTProto with your
user account session.

Preferred staging peer is a private channel (TELEGRAM_UPLOAD_CHANNEL) where the
bot is an admin — then the bot copyMessage's the file out to the requester.

Invoked by mac-tg-bot.js with env:
  TG_UPLOAD_CHAT_ID   — preferred peer (secret channel id/@, or bot id)
  TG_UPLOAD_BOT_ID    — fallback bot id from getMe
  TG_UPLOAD_BOT_USERNAME — fallback @username from getMe
  TG_UPLOAD_FILE, TG_UPLOAD_FILENAME, TG_UPLOAD_CAPTION
  TG_UPLOAD_THUMB (optional jpg), TG_UPLOAD_REPLY_MARKUP (optional JSON)
Prints JSON progress lines, then a final
  {ok:true, message_id, chat_id, file_id}  (chat_id = real staging chat id).
"""
from __future__ import annotations

import asyncio
import json
import os
import sys


def emit(obj: dict) -> None:
    print(json.dumps(obj), flush=True)


def fail(msg: str, code: int = 1) -> None:
    emit({"ok": False, "description": msg[:300]})
    sys.exit(code)


def peer_candidates() -> list:
    seen: set[str] = set()
    out: list = []

    def add(raw: str) -> None:
        s = (raw or "").strip()
        if not s or s in seen:
            return
        seen.add(s)
        if s.lstrip("-").isdigit():
            out.append(int(s))
        else:
            out.append(s if s.startswith("@") else f"@{s.lstrip('@')}")

    add(os.environ.get("TG_UPLOAD_CHAT_ID") or "")
    add(os.environ.get("TG_UPLOAD_BOT_ID") or "")
    add(os.environ.get("TG_UPLOAD_BOT_USERNAME") or "")
    return out


async def main() -> None:
    try:
        from pyrogram import Client  # type: ignore
        from pyrogram.types import InlineKeyboardButton, InlineKeyboardMarkup  # type: ignore
        try:
            from pyrogram import enums  # type: ignore

            PARSE_HTML = enums.ParseMode.HTML
        except Exception:
            # Older pyrogram accepted the string; never pass lowercase "html".
            PARSE_HTML = "HTML"
    except Exception:
        fail("Install pyrogram: python3 -m pip install --user pyrogram tgcrypto")

    api_id = int(os.environ.get("TELEGRAM_API_ID") or "0")
    api_hash = (os.environ.get("TELEGRAM_API_HASH") or "").strip()
    session = (
        os.environ.get("TELEGRAM_SESSION")
        or os.environ.get("TELEGRAM_SESSION_STRING")
        or ""
    ).strip()
    path = (os.environ.get("TG_UPLOAD_FILE") or "").strip()
    filename = (os.environ.get("TG_UPLOAD_FILENAME") or os.path.basename(path) or "App.ipa").strip()
    caption = os.environ.get("TG_UPLOAD_CAPTION") or ""
    thumb = (os.environ.get("TG_UPLOAD_THUMB") or "").strip()
    markup_raw = (os.environ.get("TG_UPLOAD_REPLY_MARKUP") or "").strip()
    peers = peer_candidates()

    if not api_id or not api_hash or not session:
        fail("Set TELEGRAM_API_ID, TELEGRAM_API_HASH, TELEGRAM_SESSION")
    if not peers or not path or not os.path.isfile(path):
        fail("Missing TG_UPLOAD_CHAT_ID/bot id or TG_UPLOAD_FILE")

    reply_markup = None
    if markup_raw:
        try:
            data = json.loads(markup_raw)
            rows = []
            for row in data.get("inline_keyboard") or []:
                buttons = []
                for b in row:
                    text = b.get("text") or ""
                    if b.get("url"):
                        buttons.append(InlineKeyboardButton(text, url=b["url"]))
                    elif b.get("callback_data"):
                        site = (
                            os.environ.get("FASTDECRYPT_SITE_URL")
                            or os.environ.get("DELVEK_SITE_URL")
                            or os.environ.get("TETHERLESS_SITE_URL")
                            or "https://fastdecrypt.bot"
                        )
                        buttons.append(InlineKeyboardButton(text, url=site))
                if buttons:
                    rows.append(buttons)
            if rows:
                reply_markup = InlineKeyboardMarkup(rows)
        except Exception:
            reply_markup = None

    app = Client(
        name="fastdecrypt_premium_upload",
        api_id=api_id,
        api_hash=api_hash,
        session_string=session,
        in_memory=True,
    )

    last_emit = 0.0

    async def progress(current: int, total: int) -> None:
        nonlocal last_emit
        now = asyncio.get_event_loop().time()
        if total <= 0:
            return
        if current < total and (now - last_emit) < 2.0:
            return
        last_emit = now
        emit({"progress": True, "current": int(current), "total": int(total)})

    async with app:
        target = None
        last_err = ""
        for peer in peers:
            try:
                chat = await app.get_chat(peer)
                target = peer
                peer_title = (
                    getattr(chat, "username", None)
                    or getattr(chat, "title", None)
                    or getattr(chat, "first_name", None)
                    or str(peer)
                )
                emit(
                    {
                        "progress": True,
                        "current": 0,
                        "total": max(1, os.path.getsize(path)),
                        "peer": peer_title,
                    }
                )
                break
            except Exception as e:
                last_err = f"{peer}: {e}"
                continue
        if target is None:
            fail(f"Cannot resolve Premium peer(s) {peers!r}: {last_err}")

        kwargs = {
            "chat_id": target,
            "document": path,
            "file_name": filename,
            "force_document": True,
            "progress": progress,
        }
        if caption.strip():
            kwargs["caption"] = caption[:1024]
            kwargs["parse_mode"] = PARSE_HTML
        if thumb and os.path.isfile(thumb):
            kwargs["thumb"] = thumb
        if reply_markup is not None:
            kwargs["reply_markup"] = reply_markup
        try:
            msg = await app.send_document(**kwargs)
        except Exception as e:
            # File bytes may already be on Telegram; retry caption as plain text.
            if "parse mode" in str(e).lower() and "caption" in kwargs:
                plain = (
                    caption.replace("<code>", "")
                    .replace("</code>", "")
                    .replace("<a href=\"", "")
                    .replace("\">", " ")
                    .replace("</a>", "")
                    .replace("&amp;", "&")
                    .replace("&lt;", "<")
                    .replace("&gt;", ">")
                    .replace("&quot;", '"')
                )
                kwargs.pop("parse_mode", None)
                kwargs["caption"] = plain[:1024]
                msg = await app.send_document(**kwargs)
            else:
                raise

    doc = getattr(msg, "document", None)
    file_id = getattr(doc, "file_id", None) if doc is not None else None
    # Prefer the real Telegram chat id (channel -100… / user id) for bot copyMessage.
    real_chat = getattr(getattr(msg, "chat", None), "id", None)
    emit(
        {
            "ok": True,
            "filename": filename,
            "message_id": getattr(msg, "id", None),
            "chat_id": str(real_chat if real_chat is not None else target),
            "file_id": file_id or "",
            "peer": str(target),
        }
    )


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as e:
        fail(str(e))
