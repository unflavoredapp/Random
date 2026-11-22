// Brand: FastDecrypt · https://fastdecrypt.bot
"use strict";
/**
 * Telegram timed VIP grants (countdown) + free daily quota / size cap.
 * Mirrors Discord VIP behavior from mac-discord-features.js.
 */
const fs = require("fs");
const os = require("os");
const path = require("path");

const VIP_IDS = new Set(
  String(process.env.TELEGRAM_VIP_IDS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
);
const ADMIN_IDS = new Set(
  String(process.env.TELEGRAM_ADMIN_IDS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
);

const FREE_DAILY = Math.max(
  1,
  Math.min(100, Number(process.env.TELEGRAM_FREE_DAILY || 3) || 3)
);
const FREE_MAX_BYTES =
  Math.max(0.1, Number(process.env.TELEGRAM_FREE_MAX_GB || 1) || 1) * 1024 * 1024 * 1024;

const VIP_DAY_CHOICES = [7, 30, 90, 180, 365];

const LOG_DIR =
  process.env.MAC_TG_USER_LOG_DIR || path.join(os.homedir(), "tetherless-user-log");
const QUOTA_PATH = path.join(LOG_DIR, "telegram-quota.json");
const VIP_GRANTS_PATH = path.join(LOG_DIR, "telegram-vip-grants.json");

const VIP_URL = String(
  process.env.FASTDECRYPT_VIP_URL ||
    process.env.TELEGRAM_VIP_URL ||
    "https://fastdecrypt.bot/vip"
).trim();

function dayKey(ms = Date.now()) {
  const d = new Date(ms);
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}-${String(
    d.getUTCDate()
  ).padStart(2, "0")}`;
}

function loadJson(fp, fallback) {
  try {
    return JSON.parse(fs.readFileSync(fp, "utf8"));
  } catch {
    return fallback;
  }
}

function saveJson(fp, db) {
  fs.mkdirSync(path.dirname(fp), { recursive: true });
  const tmp = fp + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(db, null, 2));
  fs.renameSync(tmp, fp);
}

function formatCountdown(ms) {
  const n = Math.max(0, Number(ms) || 0);
  if (n <= 0) return "expired";
  const sec = Math.floor(n / 1000);
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  if (d >= 2) return `${d}d ${h}h`;
  if (d === 1) return `1d ${h}h`;
  if (h >= 1) return `${h}h ${m}m`;
  return `${Math.max(1, m)}m`;
}

function loadVipGrants() {
  return loadJson(VIP_GRANTS_PATH, {});
}

function saveVipGrants(db) {
  saveJson(VIP_GRANTS_PATH, db);
}

function loadQuota() {
  return loadJson(QUOTA_PATH, {});
}

function saveQuota(db) {
  saveJson(QUOTA_PATH, db);
}

function vipGrant(userId) {
  const id = String(userId || "");
  if (!id) return null;
  if (VIP_IDS.has(id)) {
    return { permanent: true, expiresAt: null, days: null, source: "env" };
  }
  const db = loadVipGrants();
  const row = db[id];
  if (!row || !row.expiresAt) return null;
  if (Number(row.expiresAt) <= Date.now()) {
    delete db[id];
    saveVipGrants(db);
    return null;
  }
  return {
    permanent: false,
    expiresAt: Number(row.expiresAt),
    days: Number(row.days) || null,
    grantedBy: row.grantedBy || "",
    grantedAt: Number(row.grantedAt) || 0,
    source: "grant",
  };
}

function isVip(userId) {
  return !!vipGrant(userId);
}

function isAdmin(userId) {
  const id = String(userId || "");
  if (ADMIN_IDS.has(id)) return true;
  if (ADMIN_IDS.size === 0 && VIP_IDS.has(id)) return true;
  return false;
}

function grantVip(userId, days, grantedBy = "") {
  const id = String(userId || "").trim();
  const d = Math.round(Number(days));
  if (!/^\d{5,25}$/.test(id)) return { ok: false, error: "Bad Telegram user id." };
  if (!Number.isFinite(d) || d < 1 || d > 3650) {
    return { ok: false, error: "Days must be 1–3650." };
  }
  if (VIP_IDS.has(id)) {
    return { ok: false, error: "That user already has lifetime VIP (TELEGRAM_VIP_IDS)." };
  }
  const db = loadVipGrants();
  const prev = db[id];
  const now = Date.now();
  const base = prev && Number(prev.expiresAt) > now ? Number(prev.expiresAt) : now;
  const stacked = base > now;
  const expiresAt = base + d * 86400000;
  db[id] = {
    expiresAt,
    days: d,
    grantedBy: String(grantedBy || "").slice(0, 40),
    grantedAt: now,
  };
  for (const [k, v] of Object.entries(db)) {
    if (!v || Number(v.expiresAt) <= now) delete db[k];
  }
  saveVipGrants(db);
  return {
    ok: true,
    expiresAt,
    days: d,
    stacked,
    left: formatCountdown(expiresAt - now),
  };
}

function revokeVip(userId) {
  const id = String(userId || "").trim();
  const db = loadVipGrants();
  if (!db[id]) return { ok: false, error: "No timed VIP grant for that user." };
  delete db[id];
  saveVipGrants(db);
  return { ok: true };
}

function quotaStatus(userId) {
  const grant = vipGrant(userId);
  const day = dayKey();
  if (grant) {
    const leftMs = grant.permanent ? null : Math.max(0, grant.expiresAt - Date.now());
    return {
      vip: true,
      permanent: !!grant.permanent,
      unlimited: true,
      limit: null,
      used: 0,
      remaining: null,
      day,
      expiresAt: grant.expiresAt || null,
      leftMs,
      left: grant.permanent ? "lifetime" : formatCountdown(leftMs),
      maxBytes: null,
    };
  }
  const db = loadQuota();
  const used = Number((db[day] && db[day][String(userId)]) || 0);
  return {
    vip: false,
    permanent: false,
    unlimited: false,
    limit: FREE_DAILY,
    used,
    remaining: Math.max(0, FREE_DAILY - used),
    day,
    expiresAt: null,
    leftMs: null,
    left: null,
    maxBytes: FREE_MAX_BYTES,
  };
}

function quotaLabel(st) {
  if (!st) return "";
  if (st.vip) {
    if (st.permanent) return "VIP · lifetime · unlimited";
    return `VIP · ${st.left || "active"} left · unlimited`;
  }
  return `Free · ${st.remaining}/${st.limit} today · max ${(FREE_MAX_BYTES / (1024 * 1024 * 1024)).toFixed(0)} GB`;
}

function consumeQuota(userId) {
  const st = quotaStatus(userId);
  if (st.vip) return { ok: true, ...st };
  if (st.used >= st.limit) {
    return {
      ok: false,
      error: `Free limit: ${st.limit}/day. Get VIP: ${VIP_URL}`,
    };
  }
  const db = loadQuota();
  if (!db[st.day]) db[st.day] = {};
  db[st.day][String(userId)] = st.used + 1;
  for (const k of Object.keys(db)) {
    if (k !== st.day && k < dayKey(Date.now() - 3 * 86400000)) delete db[k];
  }
  saveQuota(db);
  return { ok: true, ...quotaStatus(userId) };
}

/** Free users: refuse IPAs over FREE_MAX_BYTES. VIP: always ok. */
function checkSizeAllowed(userId, bytes) {
  const st = quotaStatus(userId);
  if (st.vip) return { ok: true, ...st };
  const n = Number(bytes) || 0;
  if (n > FREE_MAX_BYTES) {
    const gb = (FREE_MAX_BYTES / (1024 * 1024 * 1024)).toFixed(0);
    return {
      ok: false,
      error: `Free tier max is ${gb} GB. Get VIP for larger IPAs: ${VIP_URL}`,
      ...st,
    };
  }
  return { ok: true, ...st };
}

module.exports = {
  VIP_IDS,
  ADMIN_IDS,
  FREE_DAILY,
  FREE_MAX_BYTES,
  VIP_DAY_CHOICES,
  VIP_URL,
  VIP_GRANTS_PATH,
  isVip,
  isAdmin,
  vipGrant,
  grantVip,
  revokeVip,
  formatCountdown,
  quotaStatus,
  quotaLabel,
  consumeQuota,
  checkSizeAllowed,
};
