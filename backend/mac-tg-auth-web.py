#!/usr/bin/env python3
# Brand: FastDecrypt · https://fastdecrypt.bot
"""
Web-admin auth helper for Premium user session (decrypt.team-style).

Commands (argv[1]):
  status | set-keys | send-code | sign-in | use-session | logout

Reads/writes ~/.tetherless-mac.env and ~/tetherless-run/tg-auth-state.json.
Prints one JSON object to stdout.
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import sys
from pathlib import Path


def env_paths() -> list[Path]:
    home = Path.home()
    return [home / ".tetherless-mac.env", Path("/users/client/.tetherless-mac.env")]


def run_dir() -> Path:
    return Path(os.environ.get("MAC_SSH_RUN_DIR") or (Path.home() / "tetherless-run"))


def state_path() -> Path:
    return run_dir() / "tg-auth-state.json"


def read_env_file() -> dict[str, str]:
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
    return out


def read_env() -> dict[str, str]:
    # Prefer on-disk Mac env (web Save keys) over inherited process env —
    # Node may pass stale/non-int TELEGRAM_API_ID through spawn.
    out = read_env_file()
    for k in (
        "TELEGRAM_API_ID",
        "TELEGRAM_API_HASH",
        "TELEGRAM_SESSION",
        "TELEGRAM_SESSION_STRING",
        "TELEGRAM_PREMIUM_UPLOAD",
        "TELEGRAM_UPLOAD_CHANNEL",
        "TELEGRAM_BOT_USERNAME",
    ):
        if k in out and out[k]:
            continue
        if os.environ.get(k):
            out[k] = os.environ[k].strip()
    return out


def parse_api_id(raw) -> int:
    s = str(raw or "").strip().strip("'").strip('"')
    if not s or not s.isdigit():
        raise ValueError("api_id must be digits from my.telegram.org")
    return int(s)


def resolve_keys(body=None) -> tuple[int, str]:
    body = body or {}
    env = read_env()
    api_id_raw = body.get("api_id") or env.get("TELEGRAM_API_ID") or ""
    api_hash = str(body.get("api_hash") or env.get("TELEGRAM_API_HASH") or "").strip()
    # Placeholder from the web UI means "keep saved hash".
    if api_hash.lower().startswith("saved"):
        api_hash = str(env.get("TELEGRAM_API_HASH") or "").strip()
    api_id = parse_api_id(api_id_raw)
    if len(api_hash) < 16:
        raise ValueError("api_hash required — Save keys first")
    return api_id, api_hash


def upsert_env(updates: dict[str, str]) -> Path:
    path = next((p for p in env_paths() if p.is_file()), env_paths()[0])
    path.parent.mkdir(parents=True, exist_ok=True)
    lines: list[str] = path.read_text(encoding="utf-8", errors="replace").splitlines() if path.is_file() else []
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


def clear_env_keys(keys: list[str]) -> None:
    path = next((p for p in env_paths() if p.is_file()), None)
    if not path:
        return
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    keep = []
    for line in lines:
        m = re.match(r"^([A-Za-z0-9_]+)=", line.strip())
        if m and m.group(1) in keys:
            continue
        keep.append(line)
    path.write_text("\n".join(keep).rstrip() + "\n", encoding="utf-8")


def load_state() -> dict:
    p = state_path()
    if not p.is_file():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_state(obj: dict) -> None:
    p = state_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(obj) + "\n", encoding="utf-8")


def clear_state() -> None:
    try:
        state_path().unlink(missing_ok=True)  # type: ignore[call-arg]
    except TypeError:
        try:
            if state_path().is_file():
                state_path().unlink()
        except OSError:
            pass
    except OSError:
        pass


def emit(obj: dict) -> None:
    print(json.dumps(obj), flush=True)


def read_stdin_json() -> dict:
    raw = sys.stdin.read() or "{}"
    try:
        return json.loads(raw)
    except Exception:
        return {}


async def whoami(session: str, api_id: int, api_hash: str):
    from pyrogram import Client

    async with Client(
        name="fastdecrypt_auth_who",
        api_id=int(api_id),
        api_hash=str(api_hash),
        session_string=session,
        in_memory=True,
    ) as app:
        me = await app.get_me()
        return {
            "id": me.id,
            "name": " ".join(
                x
                for x in [getattr(me, "first_name", None) or "", getattr(me, "last_name", None) or ""]
                if x
            ).strip(),
            "username": getattr(me, "username", None) or "",
            "premium": bool(getattr(me, "is_premium", False)),
        }


async def cmd_status() -> dict:
    env = read_env()
    api_id = (env.get("TELEGRAM_API_ID") or "").strip()
    api_hash = (env.get("TELEGRAM_API_HASH") or "").strip()
    session = (env.get("TELEGRAM_SESSION") or env.get("TELEGRAM_SESSION_STRING") or "").strip()
    bot = (env.get("TELEGRAM_BOT_USERNAME") or "FastDecryptAI").lstrip("@")
    channel = (env.get("TELEGRAM_UPLOAD_CHANNEL") or "").strip()
    out = {
        "ok": True,
        "authed": False,
        "hasKeys": bool(api_id and api_hash),
        "apiId": api_id,
        "hasHash": bool(api_hash),
        "bot": bot,
        "channel": channel,
        "pendingPhone": (load_state().get("phone") or ""),
        "who": {},
    }
    if not (api_id and api_hash and session):
        return out
    try:
        who = await whoami(session, parse_api_id(api_id), api_hash)
        out["authed"] = True
        out["who"] = who
    except Exception as e:
        out["error"] = f"Session present but invalid: {e}"[:200]
    return out


async def cmd_set_keys(body: dict) -> dict:
    try:
        api_id, api_hash = resolve_keys(body)
    except ValueError as e:
        return {"ok": False, "error": str(e)}
    upsert_env({"TELEGRAM_API_ID": str(api_id), "TELEGRAM_API_HASH": api_hash})
    return {"ok": True, "message": "Saved API keys", "apiId": str(api_id)}


async def cmd_send_code(body: dict) -> dict:
    try:
        api_id, api_hash = resolve_keys(body)
    except ValueError as e:
        return {"ok": False, "error": str(e)}
    # Persist whatever the form sent so the next bot restart sees keys.
    upsert_env({"TELEGRAM_API_ID": str(api_id), "TELEGRAM_API_HASH": api_hash})
    phone = str(body.get("phone") or "").strip().replace(" ", "")
    if not phone.startswith("+") or len(phone) < 8:
        return {"ok": False, "error": "Phone must include country code, e.g. +15551234567"}

    from pyrogram import Client
    from pyrogram.raw import functions, types

    app = Client(
        name="fastdecrypt_auth_code",
        api_id=int(api_id),
        api_hash=str(api_hash),
        in_memory=True,
    )
    await app.connect()
    try:
        # Invoke raw SendCode so api_id is always a real int at the TL layer
        # (avoids pyrogram "required argument is not an integer").
        sent = await app.invoke(
            functions.auth.SendCode(
                phone_number=phone,
                api_id=int(api_id),
                api_hash=str(api_hash),
                settings=types.CodeSettings(),
            )
        )
        phone_code_hash = getattr(sent, "phone_code_hash", None) or ""
        if not phone_code_hash:
            return {"ok": False, "error": "Telegram did not return phone_code_hash"}
        tmp_session = await app.export_session_string()
        save_state(
            {
                "phone": phone,
                "phone_code_hash": phone_code_hash,
                "tmp_session": tmp_session,
                "api_id": int(api_id),
                "api_hash": str(api_hash),
            }
        )
        return {
            "ok": True,
            "message": "Code sent — check the official Telegram chat (Login code: digits), not my.telegram.org web codes.",
            "phone": phone,
        }
    except Exception as e:
        return {"ok": False, "error": str(e)[:240]}
    finally:
        await app.disconnect()


async def cmd_sign_in(body: dict) -> dict:
    st = load_state()
    try:
        api_id, api_hash = resolve_keys({**st, **(body or {})})
    except ValueError as e:
        return {"ok": False, "error": str(e)}
    phone = str(body.get("phone") or st.get("phone") or "").strip().replace(" ", "")
    code = str(body.get("code") or "").strip().replace(" ", "")
    password = str(body.get("password") or "").strip()
    phone_code_hash = str(st.get("phone_code_hash") or "").strip()
    tmp_session = str(st.get("tmp_session") or "").strip() or None
    if not phone or not phone_code_hash:
        return {"ok": False, "error": "Send code first"}
    if not code and not password:
        return {"ok": False, "error": "Enter the login code"}

    from pyrogram import Client
    from pyrogram.errors import SessionPasswordNeeded, PhoneCodeInvalid, PhoneCodeExpired

    app = Client(
        name="fastdecrypt_auth_signin",
        api_id=int(api_id),
        api_hash=str(api_hash),
        session_string=tmp_session,
        in_memory=True,
    )
    await app.connect()
    try:
        try:
            if password and not code:
                await app.check_password(password)
            else:
                await app.sign_in(phone_number=phone, phone_code_hash=phone_code_hash, phone_code=code)
        except SessionPasswordNeeded:
            if not password:
                return {"ok": False, "needPassword": True, "error": "Two-step password required"}
            await app.check_password(password)
        except PhoneCodeInvalid:
            return {"ok": False, "error": "Invalid code"}
        except PhoneCodeExpired:
            clear_state()
            return {"ok": False, "error": "Code expired — send a new one"}

        me = await app.get_me()
        session = await app.export_session_string()
        upsert_env(
            {
                "TELEGRAM_API_ID": str(api_id),
                "TELEGRAM_API_HASH": api_hash,
                "TELEGRAM_SESSION": session,
                "TELEGRAM_PREMIUM_UPLOAD": "1",
            }
        )
        clear_state()
        who = {
            "id": me.id,
            "name": " ".join(
                x
                for x in [getattr(me, "first_name", None) or "", getattr(me, "last_name", None) or ""]
                if x
            ).strip(),
            "username": getattr(me, "username", None) or "",
            "premium": bool(getattr(me, "is_premium", False)),
        }
        return {"ok": True, "message": "Logged in", "who": who, "authed": True}
    except Exception as e:
        return {"ok": False, "error": str(e)[:240]}
    finally:
        await app.disconnect()


async def cmd_use_session(body: dict) -> dict:
    try:
        api_id, api_hash = resolve_keys(body)
    except ValueError as e:
        return {"ok": False, "error": str(e)}
    session = str(body.get("session") or "").strip()
    if len(session) < 20:
        return {"ok": False, "error": "Paste a full Pyrogram/Telethon session string"}
    try:
        who = await whoami(session, int(api_id), str(api_hash))
    except Exception as e:
        return {"ok": False, "error": f"Session invalid: {e}"[:200]}
    upsert_env(
        {
            "TELEGRAM_API_ID": str(api_id),
            "TELEGRAM_API_HASH": str(api_hash),
            "TELEGRAM_SESSION": session,
            "TELEGRAM_PREMIUM_UPLOAD": "1",
        }
    )
    clear_state()
    return {"ok": True, "message": "Session saved", "who": who, "authed": True}


async def cmd_logout() -> dict:
    clear_env_keys(["TELEGRAM_SESSION", "TELEGRAM_SESSION_STRING"])
    clear_state()
    return {"ok": True, "message": "Logged out (API keys kept)"}


async def main() -> None:
    cmd = (sys.argv[1] if len(sys.argv) > 1 else "status").strip().lower()
    body = read_stdin_json() if cmd != "status" else {}
    try:
        if cmd == "status":
            emit(await cmd_status())
        elif cmd == "set-keys":
            emit(await cmd_set_keys(body))
        elif cmd == "send-code":
            emit(await cmd_send_code(body))
        elif cmd == "sign-in":
            emit(await cmd_sign_in(body))
        elif cmd in ("use-session", "session"):
            emit(await cmd_use_session(body))
        elif cmd == "logout":
            emit(await cmd_logout())
        else:
            emit({"ok": False, "error": f"unknown command {cmd}"})
    except Exception as e:
        emit({"ok": False, "error": str(e)[:240]})
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
