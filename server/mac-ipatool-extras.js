// Brand: Tetherless · https://tetherless.dev
"use strict";
/**
 * ipatool extras for MacDuty adaptation:
 *   1) version history (ipatool + iTunes fallback)
 *   2) purchased library sync
 *   3) download % parsing helpers
 *   4) storefront override
 *   5) session watch / re-auth hint
 *   6) encrypted IPA prefetch queue
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const STATE_DIR =
  process.env.MAC_IPATOOL_STATE_DIR || path.join(os.homedir(), "tetherless-ipatool");
const PURCHASED_PATH = path.join(STATE_DIR, "purchased.json");
const PREFETCH_PATH = path.join(STATE_DIR, "prefetch-queue.json");

function ensureDir() {
  fs.mkdirSync(STATE_DIR, { recursive: true });
}

function stripAnsi(s) {
  return String(s || "").replace(/\u001b\[[0-9;]*m/g, "");
}

function which(cmd) {
  if (!cmd) return "";
  if (cmd.includes("/") && fs.existsSync(cmd)) return cmd;
  for (const p of String(process.env.PATH || "").split(path.delimiter).filter(Boolean)) {
    const full = path.join(p, cmd);
    try {
      fs.accessSync(full, fs.constants.X_OK);
      return full;
    } catch {
      /* continue */
    }
  }
  return "";
}

function ipatoolBin() {
  return which(process.env.FAIRPLAY_IPATOOL_BIN || "ipatool");
}

function unlockKeychain() {
  try {
    const fp = require("./fairplayBackends");
    if (typeof fp.unlockKeychain === "function") return fp.unlockKeychain();
  } catch {
    /* ignore */
  }
  return false;
}

function adamFromStoreUrl(url) {
  const m = /\bid(\d{5,12})\b/i.exec(String(url || ""));
  return m ? m[1] : "";
}

function countryFromStoreUrl(url) {
  const m = /apps\.apple\.com\/([a-z]{2})\//i.exec(String(url || ""));
  return (m && m[1] ? m[1] : "us").toLowerCase();
}

function resolveStorefront(explicit, url) {
  const fromEnv = String(process.env.FAIRPLAY_IPATOOL_STOREFRONT || "").trim().toLowerCase();
  const fromBody = String(explicit || "").trim().toLowerCase();
  const fromUrl = countryFromStoreUrl(url);
  return (fromBody || fromEnv || fromUrl || "us").slice(0, 2);
}

/** Parse a percent from ipatool / download log lines. */
function parseDownloadPercent(line) {
  const s = stripAnsi(line);
  let m = s.match(/(\d{1,3}(?:\.\d+)?)\s*%/);
  if (m) return Math.max(0, Math.min(99, Math.round(Number(m[1]))));
  m = s.match(/(\d+)\s*\/\s*(\d+)/);
  if (m && Number(m[2]) > 0) {
    return Math.max(0, Math.min(99, Math.round((Number(m[1]) / Number(m[2])) * 100)));
  }
  return null;
}

function mapProgressStage(msg) {
  const s = String(msg || "").toLowerCase();
  if (/auth|login|keychain/.test(s)) return 5;
  if (/purchas/.test(s)) return 12;
  if (/download|ipatool|encrypted/.test(s)) return 28;
  if (/cache hit/.test(s)) return 40;
  if (/decrypt|unfairplay|tetherless decrypt/.test(s)) return 62;
  if (/done|ready|produced/.test(s)) return 95;
  return null;
}

// ─── 1) Version history ───────────────────────────────────────────────

async function itunesCurrentVersion(adam, country) {
  const id = String(adam || "").trim();
  if (!id) return null;
  const cc = String(country || "us").toLowerCase();
  const url = `https://itunes.apple.com/lookup?id=${encodeURIComponent(id)}&country=${encodeURIComponent(cc)}`;
  const res = await fetch(url);
  const json = await res.json();
  const a = json && json.results && json.results[0];
  if (!a) return null;
  const ver = String(a.version || "1.0");
  return {
    title: String(a.trackName || "App").slice(0, 80),
    bundle: String(a.bundleId || ""),
    versions: [
      {
        v: ver,
        version: ver,
        label: ver,
        id: ver,
        index: 0,
        current: true,
        externalVersionId: "",
      },
    ],
  };
}

/**
 * Best-effort version list. ipatool history varies by version; always include iTunes current.
 */
async function listVersions({ url, storefront } = {}) {
  const adam = adamFromStoreUrl(url);
  const cc = resolveStorefront(storefront, url);
  const itunes = await itunesCurrentVersion(adam, cc);
  const versions = (itunes && itunes.versions) || [];
  const bin = ipatoolBin();
  if (bin && adam) {
    unlockKeychain();
    // Newer ipatool: `ipatool download --app-id X --external-version-id` needs known ids.
    // Some builds expose `ipatool get-version-metadata` / history — probe softly.
    const probes = [
      ["list-versions", "--app-id", adam],
      ["get-version-metadata", "--app-id", adam],
      ["history", "--app-id", adam],
    ];
    for (const args of probes) {
      const r = spawnSync(bin, args, { encoding: "utf8", timeout: 45000, env: process.env });
      const out = stripAnsi(`${r.stdout || ""}\n${r.stderr || ""}`);
      if (r.status !== 0) continue;
      const found = [];
      const re = /(?:version|externalVersionId|external.version)["'\s:=]+([0-9][0-9A-Za-z._-]{0,29})/gi;
      let m;
      while ((m = re.exec(out))) {
        const id = m[1];
        if (!found.some((x) => x.id === id || x.v === id)) {
          found.push({
            v: id,
            version: id,
            label: id,
            id,
            index: found.length,
            current: false,
            externalVersionId: id,
          });
        }
      }
      if (found.length) {
        // Prefer iTunes current first, then history.
        const cur = versions[0];
        const merged = [];
        if (cur) merged.push({ ...cur, current: true, index: 0 });
        for (const f of found) {
          if (cur && (f.v === cur.v || f.id === cur.v)) continue;
          merged.push({ ...f, index: merged.length });
        }
        return {
          title: (itunes && itunes.title) || "App",
          bundle: (itunes && itunes.bundle) || "",
          versions: merged,
          source: "ipatool+" + args[0],
        };
      }
    }
  }
  return {
    title: (itunes && itunes.title) || "App",
    bundle: (itunes && itunes.bundle) || "",
    versions,
    source: "itunes",
  };
}

// ─── 2) Purchased library sync ────────────────────────────────────────

function loadPurchased() {
  ensureDir();
  try {
    return JSON.parse(fs.readFileSync(PURCHASED_PATH, "utf8"));
  } catch {
    return { updatedAt: 0, items: [] };
  }
}

function savePurchased(db) {
  ensureDir();
  const tmp = PURCHASED_PATH + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(db, null, 2));
  fs.renameSync(tmp, PURCHASED_PATH);
}

/**
 * Sync purchased apps via `ipatool` when available.
 * Falls back to keeping the last good cache.
 */
function syncPurchasedLibrary({ limit = 500 } = {}) {
  const bin = ipatoolBin();
  if (!bin) {
    const cur = loadPurchased();
    return { ok: false, error: "ipatool not on PATH", ...cur };
  }
  unlockKeychain();
  const attempts = [
    ["purchased", "--non-interactive"],
    ["list", "--purchased", "--non-interactive"],
    ["purchase", "list", "--non-interactive"],
  ];
  let raw = "";
  let used = "";
  for (const args of attempts) {
    const r = spawnSync(bin, args, { encoding: "utf8", timeout: 120000, env: process.env });
    const out = stripAnsi(`${r.stdout || ""}\n${r.stderr || ""}`);
    if (r.status === 0 && out.trim()) {
      raw = out;
      used = args.join(" ");
      break;
    }
  }
  if (!raw) {
    const cur = loadPurchased();
    return {
      ok: cur.items.length > 0,
      error: cur.items.length ? "" : "ipatool purchased list unavailable on this build",
      command: used || attempts[0].join(" "),
      ...cur,
    };
  }
  const items = [];
  // JSON array?
  try {
    const j = JSON.parse(raw);
    const arr = Array.isArray(j) ? j : j.items || j.apps || j.results || [];
    for (const row of arr) {
      const adam = String(row.adamId || row.appId || row.id || row.trackId || "").replace(/\D/g, "");
      if (!adam) continue;
      items.push({
        adam,
        name: String(row.name || row.trackName || row.title || "App").slice(0, 80),
        bundle: String(row.bundleId || row.bundle || ""),
        version: String(row.version || ""),
      });
      if (items.length >= limit) break;
    }
  } catch {
    // Line / table parse: look for adam ids.
    const lines = raw.split(/\r?\n/);
    for (const line of lines) {
      const m = line.match(/\b(\d{8,12})\b/);
      if (!m) continue;
      const adam = m[1];
      if (items.some((x) => x.adam === adam)) continue;
      const name = line.replace(adam, "").replace(/[|]+/g, " ").trim().slice(0, 80) || "App";
      items.push({ adam, name, bundle: "", version: "" });
      if (items.length >= limit) break;
    }
  }
  const db = { updatedAt: Date.now(), items, source: used };
  savePurchased(db);
  return { ok: true, ...db };
}

function searchPurchased(q) {
  const db = loadPurchased();
  const needle = String(q || "").trim().toLowerCase();
  if (!needle) return db.items.slice(0, 40);
  return db.items
    .filter(
      (it) =>
        it.adam.includes(needle) ||
        (it.name || "").toLowerCase().includes(needle) ||
        (it.bundle || "").toLowerCase().includes(needle)
    )
    .slice(0, 40);
}

// ─── 5) Session watch ─────────────────────────────────────────────────

let _sessionCache = null;

function sessionWatch({ force = false } = {}) {
  const ttl = 30_000;
  if (!force && _sessionCache && Date.now() - _sessionCache.at < ttl) return _sessionCache.value;
  let auth = { ready: false, error: "ipatool unavailable" };
  try {
    const fp = require("./fairplayBackends");
    if (typeof fp.ipatoolAuthStatus === "function") {
      auth = fp.ipatoolAuthStatus({ force });
    }
  } catch (e) {
    auth = { ready: false, error: String((e && e.message) || e).slice(0, 120) };
  }
  const value = {
    ok: !!auth.ready,
    ready: !!auth.ready,
    email: auth.email || "",
    name: auth.name || "",
    error: auth.error || "",
    hint: auth.ready
      ? ""
      : "WebSSH: zsh ~/tetherless/server/mac-ssh.sh unlock && ipatool auth login",
    checkedAt: Date.now(),
  };
  _sessionCache = { at: Date.now(), value };
  return value;
}

// ─── 6) Encrypted prefetch queue ──────────────────────────────────────

function loadPrefetch() {
  ensureDir();
  try {
    return JSON.parse(fs.readFileSync(PREFETCH_PATH, "utf8"));
  } catch {
    return { items: [] };
  }
}

function savePrefetch(db) {
  ensureDir();
  const tmp = PREFETCH_PATH + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(db, null, 2));
  fs.renameSync(tmp, PREFETCH_PATH);
}

function enqueuePrefetch({ url, version, storefront, priority = 0 } = {}) {
  const adam = adamFromStoreUrl(url);
  if (!adam && !url) throw new Error("prefetch needs url or adam");
  const db = loadPrefetch();
  const key = `${adam || url}|${version || "latest"}|${resolveStorefront(storefront, url)}`;
  const existing = db.items.find((x) => x.key === key);
  if (existing) {
    existing.priority = Math.max(existing.priority || 0, priority);
    existing.updatedAt = Date.now();
    savePrefetch(db);
    return existing;
  }
  const item = {
    key,
    adam: adam || "",
    url: String(url || "").trim(),
    version: String(version || "").trim(),
    storefront: resolveStorefront(storefront, url),
    status: "queued",
    priority,
    error: "",
    createdAt: Date.now(),
    updatedAt: Date.now(),
  };
  db.items.push(item);
  db.items.sort((a, b) => (b.priority || 0) - (a.priority || 0) || a.createdAt - b.createdAt);
  savePrefetch(db);
  return item;
}

let _prefetchRunning = false;

async function runPrefetchOnce(say = () => {}) {
  if (_prefetchRunning) return { skipped: true };
  _prefetchRunning = true;
  try {
    const db = loadPrefetch();
    const next = db.items.find((x) => x.status === "queued" || x.status === "error");
    if (!next) return { idle: true };
    next.status = "running";
    next.updatedAt = Date.now();
    savePrefetch(db);
    try {
      const fp = require("./fairplayBackends");
      const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tetherless-prefetch-"));
      const url =
        next.url ||
        (next.adam ? `https://apps.apple.com/${next.storefront || "us"}/app/id${next.adam}` : "");
      say(`prefetch ${next.adam || url}…`);
      process.env.FAIRPLAY_IPATOOL_STOREFRONT = next.storefront || process.env.FAIRPLAY_IPATOOL_STOREFRONT || "";
      await fp.ensureEncryptedSource({
        url,
        dir,
        vreq: next.version || "",
        say,
      });
      next.status = "done";
      next.error = "";
      next.updatedAt = Date.now();
      savePrefetch(db);
      try {
        fs.rmSync(dir, { recursive: true, force: true });
      } catch {
        /* ignore */
      }
      return { ok: true, item: next };
    } catch (e) {
      next.status = "error";
      next.error = String((e && e.message) || e).slice(0, 200);
      next.updatedAt = Date.now();
      savePrefetch(db);
      return { ok: false, error: next.error, item: next };
    }
  } finally {
    _prefetchRunning = false;
  }
}

function listPrefetch() {
  return loadPrefetch().items;
}

function startPrefetchLoop() {
  if (String(process.env.MAC_IPATOOL_PREFETCH || "1") === "0") return;
  const tick = async () => {
    try {
      await runPrefetchOnce(() => {});
    } catch {
      /* ignore */
    }
    setTimeout(tick, Number(process.env.MAC_IPATOOL_PREFETCH_MS) || 45_000).unref?.();
  };
  setTimeout(tick, 15_000).unref?.();
}

module.exports = {
  STATE_DIR,
  resolveStorefront,
  parseDownloadPercent,
  mapProgressStage,
  listVersions,
  syncPurchasedLibrary,
  loadPurchased,
  searchPurchased,
  sessionWatch,
  enqueuePrefetch,
  runPrefetchOnce,
  listPrefetch,
  startPrefetchLoop,
  adamFromStoreUrl,
};
