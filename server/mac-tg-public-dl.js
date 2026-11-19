// Brand: DELvEK · https://delvek.net
"use strict";
/**
 * Oversized IPA download staging (>Telegram 4 GB cap).
 * Bot writes tokenized files; mac-https-api serves GET /d/:token.
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");

const DL_DIR =
  process.env.MAC_TG_PUBLIC_DL_DIR ||
  path.join(os.homedir(), "tetherless-ipa-cache", "public-dl");
const TTL_MS = Math.max(10, Number(process.env.MAC_TG_PUBLIC_DL_TTL_MIN || 120) || 120) * 60 * 1000;

fs.mkdirSync(DL_DIR, { recursive: true });

function metaPath(token) {
  return path.join(DL_DIR, `${token}.json`);
}

function ipaPath(token) {
  return path.join(DL_DIR, `${token}.ipa`);
}

function stageIpa(srcPath, { fileName, bytes } = {}) {
  const abs = path.resolve(srcPath || "");
  if (!abs || !fs.existsSync(abs)) throw new Error("IPA missing for public download staging");
  const token = crypto.randomBytes(18).toString("hex");
  const dest = ipaPath(token);
  try {
    fs.linkSync(abs, dest);
  } catch {
    fs.copyFileSync(abs, dest);
  }
  const st = fs.statSync(dest);
  const meta = {
    token,
    fileName: String(fileName || path.basename(abs) || "App.ipa").replace(/[^\w.\-[\]() +]+/g, "_"),
    bytes: bytes || st.size,
    createdAt: Date.now(),
    expiresAt: Date.now() + TTL_MS,
  };
  fs.writeFileSync(metaPath(token), JSON.stringify(meta));
  return meta;
}

function getEntry(token) {
  const t = String(token || "").replace(/[^a-f0-9]/gi, "");
  if (t.length < 16) return null;
  const mp = metaPath(t);
  const fp = ipaPath(t);
  if (!fs.existsSync(mp) || !fs.existsSync(fp)) return null;
  let meta;
  try {
    meta = JSON.parse(fs.readFileSync(mp, "utf8"));
  } catch {
    return null;
  }
  if (!meta || (meta.expiresAt && meta.expiresAt < Date.now())) {
    try {
      fs.rmSync(fp, { force: true });
      fs.rmSync(mp, { force: true });
    } catch {
      /* ignore */
    }
    return null;
  }
  return { ...meta, file: fp };
}

function cleanExpired() {
  let n = 0;
  for (const name of fs.readdirSync(DL_DIR)) {
    if (!name.endsWith(".json")) continue;
    const token = name.slice(0, -5);
    if (!getEntry(token)) n++;
  }
  return n;
}

function publicBaseFromEnv() {
  const raw = String(
    process.env.MAC_PUBLIC_BASE ||
      process.env.DELVEK_DOWNLOAD_BASE ||
      process.env.TETHERLESS_DOWNLOAD_BASE ||
      ""
  ).trim();
  return raw.replace(/\/+$/, "");
}

/** Best-effort: last trycloudflare URL from cloudflared log. */
function publicBaseFromCloudflaredLog() {
  const candidates = [
    path.join(os.homedir(), "tetherless-run", "cloudflared.log"),
    path.join(os.homedir(), "tetherless-run", "cf.log"),
  ];
  for (const log of candidates) {
    if (!fs.existsSync(log)) continue;
    try {
      const txt = fs.readFileSync(log, "utf8");
      const matches = txt.match(/https:\/\/[a-zA-Z0-9.-]+\.trycloudflare\.com/g);
      if (matches && matches.length) return matches[matches.length - 1].replace(/\/+$/, "");
    } catch {
      /* ignore */
    }
  }
  return "";
}

function resolvePublicBase() {
  return publicBaseFromEnv() || publicBaseFromCloudflaredLog() || "";
}

function downloadUrlFor(token) {
  const base = resolvePublicBase();
  if (!base) return "";
  return `${base}/d/${token}`;
}

module.exports = {
  DL_DIR,
  TTL_MS,
  stageIpa,
  getEntry,
  cleanExpired,
  resolvePublicBase,
  downloadUrlFor,
};
