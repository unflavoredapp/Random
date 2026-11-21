// Brand: FastDecrypt · https://fastdecrypt.bot
"use strict";
/**
 * Per-user usage log for the Mac Telegram bot.
 *
 * Records telegram id + @username (and chat id) for every inbound message /
 * callback so WebSSH `logs` and ~/tetherless-user-log show who used the bot.
 *
 * Layout:
 *   ~/tetherless-user-log/users.json     — one row per user (counts, last seen)
 *   ~/tetherless-user-log/events-YYYY-MM-DD.jsonl — append-only event stream
 */
const fs = require("fs");
const os = require("os");
const path = require("path");

const LOG_DIR =
  process.env.MAC_TG_USER_LOG_DIR || path.join(os.homedir(), "tetherless-user-log");
const USERS_PATH = path.join(LOG_DIR, "users.json");
const MAX_EVENT_DAYS = Math.max(
  7,
  Math.min(90, Number(process.env.MAC_TG_USER_LOG_DAYS || 30) || 30)
);

function ensure() {
  fs.mkdirSync(LOG_DIR, { recursive: true });
}

function dayStamp(ms) {
  const d = new Date(ms || Date.now());
  const y = d.getUTCFullYear();
  const m = String(d.getUTCMonth() + 1).padStart(2, "0");
  const day = String(d.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

function eventsPath(ms) {
  return path.join(LOG_DIR, `events-${dayStamp(ms)}.jsonl`);
}

function loadUsers() {
  ensure();
  try {
    const j = JSON.parse(fs.readFileSync(USERS_PATH, "utf8"));
    if (!j || typeof j !== "object") return { version: 1, users: {} };
    if (!j.users || typeof j.users !== "object") j.users = {};
    return j;
  } catch {
    return { version: 1, users: {} };
  }
}

function saveUsers(db) {
  ensure();
  const tmp = USERS_PATH + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(db, null, 2));
  fs.renameSync(tmp, USERS_PATH);
}

function fromUser(raw) {
  const u = raw && typeof raw === "object" ? raw : {};
  const id = u.id != null ? String(u.id) : "";
  const username = String(u.username || "")
    .replace(/^@/, "")
    .slice(0, 64);
  const name = [u.first_name, u.last_name]
    .map((s) => String(s || "").trim())
    .filter(Boolean)
    .join(" ")
    .slice(0, 120);
  return { id, username, name };
}

function summarizeAction(kind, detail) {
  const k = String(kind || "event").slice(0, 32);
  const d = String(detail || "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, 160);
  return d ? `${k}:${d}` : k;
}

/**
 * Log one inbound interaction. Safe to call from hot paths — never throws.
 */
function logUse({ from, chatId, kind, detail } = {}) {
  try {
    const user = fromUser(from);
    if (!user.id && !chatId) return null;
    const now = Date.now();
    const action = summarizeAction(kind, detail);
    const entry = {
      at: now,
      iso: new Date(now).toISOString(),
      userId: user.id || String(chatId || ""),
      username: user.username || "",
      name: user.name || "",
      chatId: chatId != null ? String(chatId) : "",
      action,
    };

    ensure();
    fs.appendFileSync(eventsPath(now), JSON.stringify(entry) + "\n");

    const db = loadUsers();
    const key = entry.userId;
    const prev = db.users[key] || {};
    db.users[key] = {
      userId: key,
      username: user.username || prev.username || "",
      name: user.name || prev.name || "",
      lastChatId: entry.chatId || prev.lastChatId || "",
      uses: Number(prev.uses || 0) + 1,
      firstAt: prev.firstAt || now,
      lastAt: now,
      lastAction: action,
    };
    saveUsers(db);

    const who = user.username
      ? `@${user.username}`
      : user.name
        ? user.name
        : `id:${key}`;
    console.log(`[user] ${who} id=${key} chat=${entry.chatId || "-"} · ${action}`);
    return entry;
  } catch (e) {
    console.warn("[user-log]", (e && e.message) || e);
    return null;
  }
}

function logMessage(msg) {
  if (!msg) return null;
  const chatId = msg.chat && msg.chat.id;
  const doc = msg.document;
  if (doc && /\.ipa$/i.test(String(doc.file_name || ""))) {
    return logUse({
      from: msg.from,
      chatId,
      kind: "ipa",
      detail: doc.file_name || "App.ipa",
    });
  }
  const text = String(msg.text || "").trim();
  if (!text) {
    return logUse({ from: msg.from, chatId, kind: "message", detail: "" });
  }
  if (/^\/\w+/i.test(text)) {
    const cmd = text.split(/\s+/)[0].replace(/@\w+$/i, "").toLowerCase();
    return logUse({ from: msg.from, chatId, kind: "cmd", detail: cmd });
  }
  if (/apps\.apple\.com|itunes\.apple\.com/i.test(text)) {
    return logUse({ from: msg.from, chatId, kind: "store_url", detail: text.slice(0, 120) });
  }
  if (/testflight\.apple\.com/i.test(text)) {
    return logUse({ from: msg.from, chatId, kind: "testflight", detail: text.slice(0, 120) });
  }
  return logUse({ from: msg.from, chatId, kind: "text", detail: text.slice(0, 80) });
}

function logCallback(cq) {
  if (!cq) return null;
  const chatId = cq.message && cq.message.chat && cq.message.chat.id;
  return logUse({
    from: cq.from,
    chatId,
    kind: "callback",
    detail: String(cq.data || "").slice(0, 80),
  });
}

function listUsers() {
  const users = loadUsers().users || {};
  return Object.values(users).sort((a, b) => Number(b.lastAt || 0) - Number(a.lastAt || 0));
}

/** Best-effort prune of old event files (keeps users.json forever). */
function pruneOldEvents() {
  try {
    ensure();
    const cutoff = Date.now() - MAX_EVENT_DAYS * 86400000;
    for (const name of fs.readdirSync(LOG_DIR)) {
      const m = /^events-(\d{4}-\d{2}-\d{2})\.jsonl$/.exec(name);
      if (!m) continue;
      const dayMs = Date.parse(`${m[1]}T00:00:00Z`);
      if (!Number.isFinite(dayMs) || dayMs >= cutoff) continue;
      fs.rmSync(path.join(LOG_DIR, name), { force: true });
    }
  } catch {
    /* ignore */
  }
}

module.exports = {
  LOG_DIR,
  logUse,
  logMessage,
  logCallback,
  listUsers,
  pruneOldEvents,
};
