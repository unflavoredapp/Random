// Brand: Tetherless · https://tetherless.dev
"use strict";
/**
 * Per-chat App Store URL history for the Mac Telegram bot.
 * User-pasted links are deleted from chat but kept here so /history
 * (or a History button) can re-decrypt the same adam/version.
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const ipaCache = require("./mac-tg-ipa-cache");

const LOG_DIR =
  process.env.MAC_TG_URL_LOG_DIR || path.join(os.homedir(), "tetherless-url-log");
const MAX_PER_CHAT = Math.max(10, Math.min(100, Number(process.env.MAC_TG_URL_LOG_MAX || 40) || 40));

function ensure() {
  fs.mkdirSync(LOG_DIR, { recursive: true });
}

function chatPath(chatId) {
  const id = String(chatId || "").replace(/[^\w.-]+/g, "_") || "unknown";
  return path.join(LOG_DIR, `${id}.json`);
}

function load(chatId) {
  ensure();
  const p = chatPath(chatId);
  try {
    const j = JSON.parse(fs.readFileSync(p, "utf8"));
    if (!j || !Array.isArray(j.items)) return { version: 1, items: [] };
    return j;
  } catch {
    return { version: 1, items: [] };
  }
}

function save(chatId, db) {
  ensure();
  const p = chatPath(chatId);
  const tmp = p + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(db, null, 2));
  fs.renameSync(tmp, p);
}

/**
 * Upsert a store-url history entry (newest first).
 */
function add(chatId, { storeUrl, version, name, adam } = {}) {
  const url = String(storeUrl || "").trim();
  if (!url) return null;
  const a = String(adam || ipaCache.adamFromStoreUrl(url) || "").trim();
  const ver = String(version || "").trim() || "latest";
  const db = load(chatId);
  const key = `${a}|${ver}|${url}`;
  db.items = (db.items || []).filter((it) => {
    const k = `${it.adam || ""}|${it.version || "latest"}|${it.storeUrl || ""}`;
    return k !== key;
  });
  const entry = {
    id: `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`,
    adam: a,
    version: ver,
    storeUrl: url,
    name: String(name || "").slice(0, 80),
    at: Date.now(),
  };
  db.items.unshift(entry);
  db.items = db.items.slice(0, MAX_PER_CHAT);
  save(chatId, db);
  return entry;
}

function list(chatId, limit) {
  const n = Math.max(1, Math.min(50, Number(limit) || 20));
  return load(chatId).items.slice(0, n);
}

function getById(chatId, id) {
  const want = String(id || "");
  return load(chatId).items.find((it) => it && it.id === want) || null;
}

function getByAdamVersion(chatId, adam, version) {
  const a = String(adam || "");
  const ver = String(version || "").trim() || "latest";
  return (
    load(chatId).items.find(
      (it) => String(it.adam || "") === a && String(it.version || "latest") === ver
    ) || null
  );
}

module.exports = {
  LOG_DIR,
  add,
  list,
  getById,
  getByAdamVersion,
  adamFromStoreUrl: ipaCache.adamFromStoreUrl,
};
