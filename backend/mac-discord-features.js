// Brand: FastDecrypt · https://fastdecrypt.bot
"use strict";
/**
 * Discord extras: App Store name search, version list,
 * timed VIP grants (countdown), free daily quota, admin users.
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");
const userLog = require("./mac-tg-user-log");

/** Lifetime VIP (no expiry) — comma-separated Discord user ids. */
const VIP_IDS = new Set(
  String(process.env.DISCORD_VIP_IDS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
);
const ADMIN_IDS = new Set(
  String(process.env.DISCORD_ADMIN_IDS || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
);
const FREE_DAILY = Math.max(
  1,
  Math.min(100, Number(process.env.DISCORD_FREE_DAILY || 5) || 5)
);
/** @deprecated daily VIP quota removed — timed VIP is unlimited while active. */
const VIP_DAILY = 0;
const VIP_URL = String(
  process.env.FASTDECRYPT_VIP_URL ||
    process.env.DISCORD_VIP_URL ||
    "https://fastdecrypt.bot/vip"
).trim();

const VIP_DAY_CHOICES = [7, 30, 90, 180, 365];

const LOG_DIR =
  process.env.MAC_TG_USER_LOG_DIR || path.join(os.homedir(), "tetherless-user-log");
const QUOTA_PATH = path.join(LOG_DIR, "discord-quota.json");
const VIP_GRANTS_PATH = path.join(LOG_DIR, "discord-vip-grants.json");

const SEARCH_COUNTRIES = String(
  process.env.MAC_TG_SEARCH_COUNTRIES ||
    process.env.DISCORD_SEARCH_COUNTRIES ||
    "us,hk,jp,de,fr,au,ca"
)
  .split(",")
  .map((s) => s.trim().toLowerCase())
  .filter(Boolean);

/** token → pending app/version pick */
const pending = new Map();
const PICK_TTL_MS = 15 * 60 * 1000;

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

function loadQuota() {
  return loadJson(QUOTA_PATH, {});
}

function saveQuota(db) {
  saveJson(QUOTA_PATH, db);
}

function loadVipGrants() {
  return loadJson(VIP_GRANTS_PATH, {});
}

function saveVipGrants(db) {
  saveJson(VIP_GRANTS_PATH, db);
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
  // Bootstrap: if no admins configured, lifetime VIPs can admin.
  if (ADMIN_IDS.size === 0 && VIP_IDS.has(id)) return true;
  return false;
}

/**
 * Grant timed VIP. Extends from now (or stacks from current expiry if still active).
 * @returns {{ ok: true, expiresAt: number, days: number, stacked: boolean } | { ok: false, error: string }}
 */
function grantVip(userId, days, grantedBy = "") {
  const id = String(userId || "").trim();
  const d = Math.round(Number(days));
  if (!/^\d{5,25}$/.test(id)) return { ok: false, error: "Bad Discord user id." };
  if (!Number.isFinite(d) || d < 1 || d > 3650) {
    return { ok: false, error: "Days must be 1–3650." };
  }
  if (VIP_IDS.has(id)) {
    return { ok: false, error: "That user already has lifetime VIP (DISCORD_VIP_IDS)." };
  }
  const db = loadVipGrants();
  const prev = db[id];
  const now = Date.now();
  const base =
    prev && Number(prev.expiresAt) > now ? Number(prev.expiresAt) : now;
  const stacked = base > now;
  const expiresAt = base + d * 86400000;
  db[id] = {
    expiresAt,
    days: d,
    grantedBy: String(grantedBy || "").slice(0, 40),
    grantedAt: now,
  };
  // Drop expired rows
  for (const [k, v] of Object.entries(db)) {
    if (!v || Number(v.expiresAt) <= now) delete db[k];
  }
  saveVipGrants(db);
  return { ok: true, expiresAt, days: d, stacked, left: formatCountdown(expiresAt - now) };
}

function revokeVip(userId) {
  const id = String(userId || "").trim();
  const db = loadVipGrants();
  if (!db[id]) return { ok: false, error: "No timed VIP grant for that user." };
  delete db[id];
  saveVipGrants(db);
  return { ok: true };
}

function quotaLabel(st) {
  if (!st) return "";
  if (st.vip) {
    if (st.permanent) return "VIP · lifetime · unlimited decrypts";
    return `VIP · ${st.left || "active"} left · unlimited decrypts`;
  }
  return `Free · ${st.remaining}/${st.limit} decrypts left today`;
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
      expiresIso: grant.expiresAt ? new Date(grant.expiresAt).toISOString() : null,
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
    expiresIso: null,
  };
}

/** @returns {{ ok: true } | { ok: false, error: string }} */
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

function searchItunesCountry(term, country, limit) {
  const url =
    `https://itunes.apple.com/search?term=${encodeURIComponent(term)}` +
    `&entity=software&limit=${limit}&country=${encodeURIComponent(country)}`;
  const r = spawnSync("curl", ["-fsSL", "--max-time", "12", url], {
    encoding: "utf8",
    maxBuffer: 2 * 1024 * 1024,
  });
  if (r.status !== 0) return [];
  try {
    const j = JSON.parse(r.stdout || "{}");
    const rows = Array.isArray(j.results) ? j.results : [];
    return rows
      .filter((a) => a && a.trackId && a.trackName)
      .map((a) => {
        const adam = String(a.trackId);
        const cc = String(country || "us").toLowerCase();
        return {
          adam,
          name: String(a.trackName || a.trackCensoredName || "").trim().slice(0, 80),
          bid: String(a.bundleId || "").trim().slice(0, 120),
          version: String(a.version || "").trim().slice(0, 40),
          developer: String(a.artistName || "").trim().slice(0, 60),
          country: cc,
          url:
            String(a.trackViewUrl || "").trim() ||
            `https://apps.apple.com/${cc}/app/id${adam}`,
        };
      });
  } catch {
    return [];
  }
}

function searchAppsByName(term, { limit = 8 } = {}) {
  const q = String(term || "").trim();
  if (q.length < 2) return [];
  const byAdam = new Map();
  for (const cc of SEARCH_COUNTRIES) {
    for (const hit of searchItunesCountry(q, cc, Math.min(12, limit + 4))) {
      if (!byAdam.has(hit.adam)) byAdam.set(hit.adam, hit);
    }
    if (byAdam.size >= limit) break;
  }
  const items = [...byAdam.values()];
  const want = q.toLowerCase();
  items.sort((a, b) => {
    const ae =
      a.name.toLowerCase() === want ? 0 : a.name.toLowerCase().startsWith(want) ? 1 : 2;
    const be =
      b.name.toLowerCase() === want ? 0 : b.name.toLowerCase().startsWith(want) ? 1 : 2;
    if (ae !== be) return ae - be;
    return a.name.localeCompare(b.name);
  });
  return items.slice(0, limit);
}

function parseAppNameQuery(text) {
  const t = String(text || "").trim();
  if (!t || t.length < 2) return null;
  if (/^https?:\/\//i.test(t)) return null;
  if (/^\/\w+/i.test(t)) return null;
  let version = "";
  let name = t;
  let m = t.match(/^(.+?)\s+(?:v|version)[=:\s]+([0-9][0-9A-Za-z._-]{0,29})\s*$/i);
  if (m) {
    name = m[1].trim();
    version = m[2];
  } else {
    m = t.match(/^(.+?)\s+([0-9]+\.[0-9A-Za-z._-]{0,28})\s*$/);
    if (m && m[1].trim().length >= 2) {
      name = m[1].trim();
      version = m[2];
    }
  }
  name = name.replace(/\s+/g, " ").trim();
  if (name.length < 2 || name.length > 80) return null;
  return { name, version };
}

function prunePending() {
  const now = Date.now();
  for (const [k, v] of pending) {
    if (!v || v.expires < now) pending.delete(k);
  }
}

function putPending(payload) {
  prunePending();
  const token = crypto.randomBytes(4).toString("hex");
  pending.set(token, { ...payload, expires: Date.now() + PICK_TTL_MS });
  return token;
}

function getPending(token) {
  prunePending();
  return pending.get(String(token || "")) || null;
}

function takePending(token) {
  const p = getPending(token);
  if (p) pending.delete(String(token || ""));
  return p;
}

async function listVersionsForUrl(url) {
  try {
    const extras = require("./mac-ipatool-extras");
    return await extras.listVersions({ url });
  } catch (e) {
    console.warn("[discord] listVersions:", (e && e.message) || e);
    return { title: "App", versions: [] };
  }
}

/**
 * Free users: latest only. VIP: full history (capped).
 */
function versionChoices(listed, { vip, max = 20 } = {}) {
  const versions = Array.isArray(listed && listed.versions) ? listed.versions : [];
  if (!versions.length) return [];
  const mapped = versions.map((v, i) => {
    const ver = String(v.v || v.version || v.label || "—").slice(0, 24);
    const ext = String(v.externalVersionId || v.external_id || "").trim();
    const marketing = /^\d{6,}$/.test(ver) ? "" : ver;
    const current = !!v.current || i === 0;
    return {
      i,
      ver,
      ext,
      marketing,
      current,
      label: current ? `Latest · v${ver}` : `v${ver}`,
      vreq: ext || marketing || "",
    };
  });
  if (!vip) {
    const latest = mapped.find((x) => x.current) || mapped[0];
    return latest ? [latest] : [];
  }
  return mapped.slice(0, max);
}

function adminUsersSummary({ hours = 24, limit = 15 } = {}) {
  const since = Date.now() - hours * 3600 * 1000;
  const counts = new Map();
  try {
    const day = dayKey();
    const prev = dayKey(Date.now() - 86400000);
    for (const stamp of [prev, day]) {
      const fp = path.join(userLog.LOG_DIR, `events-${stamp}.jsonl`);
      if (!fs.existsSync(fp)) continue;
      const lines = fs.readFileSync(fp, "utf8").split("\n");
      for (const line of lines) {
        if (!line.trim()) continue;
        let j;
        try {
          j = JSON.parse(line);
        } catch {
          continue;
        }
        if (!j || j.platform !== "discord") continue;
        if (Number(j.at || 0) < since) continue;
        if (!/^decrypt/i.test(String(j.action || j.kind || ""))) continue;
        const id = String(j.discordId || j.userId || "").replace(/^discord:/, "");
        if (!id) continue;
        const prevRow = counts.get(id) || {
          id,
          username: j.username || "",
          name: j.name || "",
          n: 0,
        };
        prevRow.n += 1;
        if (j.username) prevRow.username = j.username;
        if (j.name) prevRow.name = j.name;
        counts.set(id, prevRow);
      }
    }
  } catch (e) {
    console.warn("[discord] admin users:", (e && e.message) || e);
  }
  const top = [...counts.values()].sort((a, b) => b.n - a.n).slice(0, limit);
  const all = userLog.listUsers().filter(
    (u) => u.platform === "discord" || String(u.userId || "").startsWith("discord:")
  );
  return { top, totalDiscordUsers: all.length, hours };
}

module.exports = {
  VIP_URL,
  FREE_DAILY,
  VIP_DAILY,
  VIP_DAY_CHOICES,
  VIP_GRANTS_PATH,
  isVip,
  isAdmin,
  vipGrant,
  grantVip,
  revokeVip,
  formatCountdown,
  quotaLabel,
  quotaStatus,
  consumeQuota,
  searchAppsByName,
  parseAppNameQuery,
  putPending,
  getPending,
  takePending,
  listVersionsForUrl,
  versionChoices,
  adminUsersSummary,
};
