// Brand: Tetherless · https://tetherless.dev
"use strict";
/**
 * Telegram-cloud IPA cache for the Mac decrypt bot.
 *
 * First decrypt uploads the clear IPA once; we store Telegram's file_id (and a
 * local disk copy). Later requests for the same adam/version re-send by file_id
 * — no ipatool / re-decrypt — so it feels instant.
 */
const fs = require("fs");
const os = require("os");
const path = require("path");

const CACHE_DIR =
  process.env.MAC_TG_IPA_CACHE_DIR || path.join(os.homedir(), "tetherless-ipa-cache");
const ENC_DIR =
  process.env.MAC_TG_ENC_CACHE_DIR || path.join(CACHE_DIR, "encrypted");
const INDEX_PATH = path.join(CACHE_DIR, "index.json");

function ensure() {
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  fs.mkdirSync(ENC_DIR, { recursive: true });
  if (!fs.existsSync(INDEX_PATH)) {
    fs.writeFileSync(INDEX_PATH, JSON.stringify({ version: 1, items: {} }, null, 2));
  }
}

/** Prefer hardlink (instant); fall back to copy. */
function linkOrCopy(src, dest) {
  if (!src || !fs.existsSync(src)) throw new Error("linkOrCopy: missing source");
  try {
    fs.rmSync(dest, { force: true });
  } catch {
    /* ignore */
  }
  try {
    fs.linkSync(src, dest);
  } catch {
    fs.copyFileSync(src, dest);
  }
}

function load() {
  ensure();
  try {
    const j = JSON.parse(fs.readFileSync(INDEX_PATH, "utf8"));
    if (!j || typeof j !== "object") return { version: 1, items: {} };
    if (!j.items || typeof j.items !== "object") j.items = {};
    return j;
  } catch {
    return { version: 1, items: {} };
  }
}

function save(db) {
  ensure();
  const tmp = INDEX_PATH + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(db, null, 2));
  fs.renameSync(tmp, INDEX_PATH);
}

function adamFromStoreUrl(url) {
  const m = /\bid(\d{5,12})\b/i.exec(String(url || ""));
  return m ? m[1] : "";
}

function keyFor(adam, version) {
  const a = String(adam || "").trim();
  const v = String(version || "").trim() || "latest";
  return `${a}|${v}`;
}

function get(adam, version) {
  if (!adam) return null;
  const db = load();
  const exact = db.items[keyFor(adam, version)];
  if (exact && (exact.fileId || (exact.diskPath && fs.existsSync(exact.diskPath)))) {
    return exact;
  }
  if (version && String(version) !== "latest") return null;
  // Prefer newest "latest" or any version for this adam when asking latest.
  const prefix = `${adam}|`;
  let best = null;
  for (const [k, item] of Object.entries(db.items)) {
    if (!k.startsWith(prefix)) continue;
    if (!item || !(item.fileId || (item.diskPath && fs.existsSync(item.diskPath)))) continue;
    if (!best || (item.savedAt || 0) > (best.savedAt || 0)) best = item;
  }
  return best;
}

function getByStoreUrl(storeUrl, version) {
  return get(adamFromStoreUrl(storeUrl), version);
}

function put(entry) {
  const adam = String(entry.adam || "").trim();
  if (!adam) return null;
  const version = String(entry.version || "").trim() || "latest";
  const db = load();
  const item = {
    adam,
    version,
    bid: entry.bid || "",
    name: entry.name || "App",
    minIos: entry.minIos || "",
    storeUrl: entry.storeUrl || "",
    fileName: entry.fileName || "",
    caption: entry.caption || "",
    fileId: entry.fileId || "",
    fileUniqueId: entry.fileUniqueId || "",
    // Premium user upload: bot re-sends via copyMessage(fromChatId, messageId).
    messageId: entry.messageId || 0,
    fromChatId: entry.fromChatId || "",
    bytes: entry.bytes || 0,
    diskPath: entry.diskPath || "",
    iconPath: entry.iconPath || "",
    savedAt: Date.now(),
  };
  db.items[keyFor(adam, version)] = item;
  // Also index as latest when this is the newest for that adam.
  db.items[keyFor(adam, "latest")] = { ...item, version: item.version };
  save(db);
  return item;
}

function remove(adam, version) {
  const db = load();
  delete db.items[keyFor(adam, version)];
  save(db);
}

function list() {
  const db = load();
  const seen = new Set();
  const out = [];
  for (const item of Object.values(db.items)) {
    if (!item || !item.adam) continue;
    const id = `${item.adam}|${item.version || "latest"}`;
    if (seen.has(id)) continue;
    seen.add(id);
    out.push(item);
  }
  return out.sort((a, b) => (b.savedAt || 0) - (a.savedAt || 0));
}

function diskPathFor(adam, version, fileName) {
  ensure();
  const safe = String(fileName || `${adam}-${version || "latest"}.ipa`).replace(/[^\w.-]+/g, "_");
  return path.join(CACHE_DIR, safe);
}

function encryptedDiskPath(adam, version) {
  ensure();
  const a = String(adam || "app").replace(/[^\w.-]+/g, "_") || "app";
  const v = String(version || "latest").replace(/[^\w.-]+/g, "_") || "latest";
  return path.join(ENC_DIR, `${a}_${v}.encrypted.ipa`);
}

/** Return path to a cached encrypted IPA (≥100 bytes), or "". */
function getEncryptedPath(adam, version) {
  if (!adam) return "";
  const exact = encryptedDiskPath(adam, version);
  if (fs.existsSync(exact) && fs.statSync(exact).size >= 100) return exact;
  const ver = String(version || "").trim() || "latest";
  if (ver !== "latest") return "";
  // latest: pick newest adam_*.encrypted.ipa by mtime
  let best = "";
  let bestM = 0;
  try {
    for (const name of fs.readdirSync(ENC_DIR)) {
      if (!name.startsWith(`${String(adam).replace(/[^\w.-]+/g, "_")}_`)) continue;
      if (!name.endsWith(".encrypted.ipa")) continue;
      const p = path.join(ENC_DIR, name);
      try {
        const st = fs.statSync(p);
        if (st.size >= 100 && st.mtimeMs >= bestM) {
          best = p;
          bestM = st.mtimeMs;
        }
      } catch {
        /* ignore */
      }
    }
  } catch {
    /* ignore */
  }
  return best;
}

/** Persist encrypted App Store IPA for reuse (skips ipatool next time). */
function putEncrypted(adam, version, srcPath) {
  if (!adam || !srcPath || !fs.existsSync(srcPath) || fs.statSync(srcPath).size < 100) {
    return "";
  }
  const ver = String(version || "").trim() || "latest";
  const dest = encryptedDiskPath(adam, ver);
  linkOrCopy(srcPath, dest);
  if (ver !== "latest") {
    try {
      linkOrCopy(srcPath, encryptedDiskPath(adam, "latest"));
    } catch {
      /* ignore */
    }
  }
  return dest;
}

function listEncrypted() {
  ensure();
  const out = [];
  try {
    for (const name of fs.readdirSync(ENC_DIR)) {
      if (!name.endsWith(".encrypted.ipa")) continue;
      const p = path.join(ENC_DIR, name);
      try {
        const st = fs.statSync(p);
        out.push({ path: p, name, bytes: st.size, mtimeMs: st.mtimeMs });
      } catch {
        /* ignore */
      }
    }
  } catch {
    /* ignore */
  }
  return out.sort((a, b) => (b.mtimeMs || 0) - (a.mtimeMs || 0));
}

module.exports = {
  CACHE_DIR,
  ENC_DIR,
  adamFromStoreUrl,
  get,
  getByStoreUrl,
  put,
  remove,
  list,
  diskPathFor,
  linkOrCopy,
  encryptedDiskPath,
  getEncryptedPath,
  putEncrypted,
  listEncrypted,
};
