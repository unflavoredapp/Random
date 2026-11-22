#!/usr/bin/env node
// Brand: FastDecrypt · https://fastdecrypt.bot · Telegram @FastDecryptAI (fastdecrypt.ai)
// Legacy DELvEK · https://delvek.net still works when TELEGRAM_BOT_USERNAME is not FastDecrypt*.
"use strict";
/**
 * Telegram decrypt bot — FastDecrypt (@FastDecryptAI) or DELvEK (@DELvEKBot).
 * Site: https://fastdecrypt.bot · free App Store / TestFlight IPAs.
 *
 * Host ops (WebSSH): zsh server/mac-ssh.sh start | status | logs | session
 *
 * IPA delivery: Premium user session (≤4 GB) or Bot API fallback.
 * Cloud cache: file_id + local copy for instant re-send.
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");
const https = require("https");
const crypto = require("crypto");
const { spawn, spawnSync } = require("child_process");
const fairplayBackends = require("./fairplayBackends");
const ipatoolExtras = require("./mac-ipatool-extras");
const ipaCache = require("./mac-tg-ipa-cache");
const urlLog = require("./mac-tg-url-log");
const userLog = require("./mac-tg-user-log");
const {
  renderProgressBanner,
  renderDownloadThumb,
  renderVersionPickerBanner,
  renderLibraryListBanner,
  renderLibraryAppBanner,
} = require("./mac-tg-progress-banner");
const publicDl = require("./mac-tg-public-dl");
const cordBrand = require("./mac-tg-cord-brand");
const tgVip = require("./mac-tg-vip");

/** token → version sharp-card carousel state (before decrypt progress card). */
const pendingVerPicks = new Map();
/** chatId → token — so a plain number reply can pick from the open carousel. */
const activeVerPickByChat = new Map();
function pruneVerPicks() {
  const now = Date.now();
  for (const [k, v] of pendingVerPicks) {
    if (!v || v.expires < now) {
      pendingVerPicks.delete(k);
      if (v && v.chatId) activeVerPickByChat.delete(v.chatId);
    }
  }
}

/** token → App Store name-search results (pick when several matches). */
const pendingAppPicks = new Map();
function pruneAppPicks() {
  const now = Date.now();
  for (const [k, v] of pendingAppPicks) {
    if (!v || v.expires < now) pendingAppPicks.delete(k);
  }
}

const API_ROOT = String(process.env.TELEGRAM_API_ROOT || "https://api.telegram.org").replace(/\/+$/, "");
const LOCAL_API =
  process.env.TELEGRAM_LOCAL_API === "1" ||
  /localhost|127\.0\.0\.1/i.test(API_ROOT);
const TG_DOC_MAX = Math.max(
  1,
  Number(process.env.TELEGRAM_UPLOAD_MAX_MB || (LOCAL_API ? 2000 : 50))
) * 1024 * 1024;
/** Telegram Premium hard cap for a single document. */
const TG_PREMIUM_DOC_MAX = 4 * 1024 * 1024 * 1024;
const TG_GETFILE_MAX = LOCAL_API
  ? Math.max(TG_DOC_MAX, TG_PREMIUM_DOC_MAX)
  : 20 * 1024 * 1024;

const BOT_TOKEN = String(process.env.TELEGRAM_BOT_TOKEN || "").trim();
/** Filled from getMe() at boot — env override is only a bootstrap hint. */
let BOT_USERNAME = String(process.env.TELEGRAM_BOT_USERNAME || "").replace(/^@/, "");
let BOT_ID = 0;
/** Optional lockdown — omit TELEGRAM_LOCKDOWN (default) so anyone can message. */
const LOCKDOWN = process.env.TELEGRAM_LOCKDOWN === "1";
const ALLOWED = String(process.env.TELEGRAM_ALLOWED_IDS || "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);
/** VIP buyers contact (@username without @). FastDecrypt → set TELEGRAM_VIP_CONTACT. */
const VIP_CONTACT = String(
  process.env.TELEGRAM_VIP_CONTACT || process.env.DELVEK_VIP_CONTACT || "mrzefie"
).replace(/^@/, "");
const WORK = process.env.MAC_TG_WORK_DIR || path.join(os.tmpdir(), "tetherless-mac-tg");
const DROP = process.env.MAC_TG_DROP_DIR || path.join(os.homedir(), "tetherless-drop");
const PREMIUM_UPLOAD = path.join(__dirname, "mac-tg-premium-upload.py");

if (!BOT_TOKEN) {
  console.error("Set TELEGRAM_BOT_TOKEN in ~/.tetherless-mac.env");
  process.exit(1);
}

fs.mkdirSync(WORK, { recursive: true });
fs.mkdirSync(DROP, { recursive: true });

function apiUrl(method) {
  return `${API_ROOT}/bot${BOT_TOKEN}/${method}`;
}

function httpJson(url, body) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body || {});
    const u = new URL(url);
    const lib = u.protocol === "http:" ? http : https;
    const req = lib.request(
      {
        hostname: u.hostname,
        port: u.port || (u.protocol === "http:" ? 80 : 443),
        path: u.pathname + u.search,
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(data),
        },
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          try {
            resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
          } catch (e) {
            reject(e);
          }
        });
      }
    );
    req.on("error", reject);
    req.write(data);
    req.end();
  });
}

function tgApi(method, body) {
  return httpJson(apiUrl(method), body);
}

function sanitizeFilePart(s) {
  return String(s || "")
    .replace(/[^\w.+-]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 60) || "App";
}

function readIpaMeta(ipaPath) {
  const meta = { name: "", bid: "", version: "", minIos: "" };
  try {
    const listed = spawnSync("unzip", ["-Z1", ipaPath], { encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
    const plistRel = String(listed.stdout || "")
      .split("\n")
      .map((l) => l.trim())
      .find((l) => /^Payload\/[^/]+\.app\/Info\.plist$/i.test(l));
    if (!plistRel) return meta;
    const raw = spawnSync("unzip", ["-p", ipaPath, plistRel], { encoding: "buffer", maxBuffer: 4 * 1024 * 1024 });
    if (raw.status !== 0 || !raw.stdout || !raw.stdout.length) return meta;
    const tmp = path.join(WORK, `plist-${Date.now()}.plist`);
    fs.writeFileSync(tmp, raw.stdout);
    const json = spawnSync("plutil", ["-convert", "json", "-o", "-", tmp], { encoding: "utf8", maxBuffer: 4 * 1024 * 1024 });
    try {
      fs.rmSync(tmp, { force: true });
    } catch {
      /* ignore */
    }
    if (json.status !== 0) return meta;
    const p = JSON.parse(json.stdout || "{}");
    meta.name = String(p.CFBundleDisplayName || p.CFBundleName || "").slice(0, 80);
    meta.bid = String(p.CFBundleIdentifier || "").slice(0, 120);
    meta.version = String(p.CFBundleShortVersionString || p.CFBundleVersion || "").slice(0, 40);
    meta.minIos = String(p.MinimumOSVersion || "").slice(0, 20);
  } catch {
    /* best-effort */
  }
  return meta;
}

function isFastDecryptBrand() {
  const brand = String(process.env.TELEGRAM_BOT_BRAND || "").trim();
  if (/fastdecrypt/i.test(brand)) return true;
  if (/fastdecrypt/i.test(BOT_USERNAME || "")) return true;
  const site = String(
    process.env.FASTDECRYPT_SITE_URL ||
      process.env.DELVEK_SITE_URL ||
      process.env.TETHERLESS_SITE_URL ||
      ""
  ).toLowerCase();
  return site.includes("fastdecrypt");
}

/** Public site — fastdecrypt.bot for FastDecrypt, delvek.net otherwise. */
function brandSiteDefault() {
  return isFastDecryptBrand() ? "https://fastdecrypt.bot" : "https://delvek.net";
}

/** IPA / banner mark — [FastDecrypt.Bot] or [DELvEK.NeT]. */
function brandIpaTag() {
  return isFastDecryptBrand() ? "FastDecrypt.Bot" : "DELvEK.NeT";
}

function buildIpaFileName({ name, version }) {
  const n = sanitizeFilePart(name);
  const v = version ? `_v${sanitizeFilePart(version)}` : "";
  return `${n}${v}-[${brandIpaTag()}].ipa`;
}

/** Apple external-version-id is a long digit string — not a marketing version. */
function isExternalVersionId(value) {
  return /^\d{6,}$/.test(String(value || "").trim());
}

/**
 * Caption / filename should show CFBundleShortVersionString (e.g. 8.12.0),
 * never the raw external-version-id used for ipatool (`840234580`).
 */
function displayAppVersion({ versionHint, versionLabel, ipaVersion } = {}) {
  const fromIpa = String(ipaVersion || "").trim();
  const fromLabel = String(versionLabel || "")
    .trim()
    .replace(/^⭐\s*Latest\s*·\s*/i, "")
    .replace(/^v/i, "")
    .trim();
  const fromHint = String(versionHint || "").trim().replace(/^v/i, "");
  if (fromIpa && !isExternalVersionId(fromIpa)) return fromIpa.slice(0, 40);
  if (fromLabel && !isExternalVersionId(fromLabel) && fromLabel.toLowerCase() !== "latest") {
    return fromLabel.slice(0, 40);
  }
  if (fromHint && !isExternalVersionId(fromHint) && fromHint.toLowerCase() !== "latest") {
    return fromHint.slice(0, 40);
  }
  if (fromIpa) return fromIpa.slice(0, 40);
  return "";
}

/** Progress-card stage lines — cruel reminders that you suck at sideloading. */
/**
 * Public terminal lines only — never echo raw backend say() (no host/model/ids/paths).
 * Looks real; is a safe mock of the stage the user already sees on the %.
 */
function mockTermLineForStage(stage, pct) {
  const s = String(stage || "").toLowerCase();
  const p = Math.max(0, Math.min(99, Math.round(Number(pct) || 0)));
  if (/fail|error/i.test(s)) return "error — job stopped";
  if (/upload|send/i.test(s)) return p >= 95 ? "packaging IPA…" : "uploading to Telegram…";
  if (/decrypt/i.test(s)) {
    if (p >= 70) return "trustC0re unlock OK";
    if (p >= 50) return "Tetherless decrypt…";
    return "Tetherless prepare…";
  }
  if (/download/i.test(s)) return "TetherTool download…";
  if (/fetch|start|work/i.test(s)) return p < 10 ? "$ job start" : "TetherTool fetch…";
  if (/done|ready/i.test(s)) return "done — IPA ready";
  return "working…";
}

function cleanTermLine(raw) {
  // Keep for callers that pass a short public stage label; strip anything leaky.
  const t = String(raw || "")
    .replace(/\u001b\[[0-9;]*[a-zA-Z]/g, "")
    .replace(/\r/g, "")
    .split("\n")
    .map((l) => l.replace(/[^\x20-\x7E]+/g, " ").replace(/\s+/g, " ").trim())
    .filter(Boolean)[0] || "";
  if (!t) return "";
  // Drop lines that look like real backend dumps (paths, ids, hosts, models).
  if (/[/\\]|(?:\bid=)|(?:model=)|(?:host)|(?:keychain)|(?:ssh)|(?:localhost)|(?:\d{6,})/i.test(t)) {
    return "";
  }
  return t
    .replace(/\bipatool\b/gi, "TetherTool")
    .replace(/\bunfairplay\b/gi, "Tetherless")
    .replace(/\bFairPlay\b/g, "trustC0re")
    .replace(/\bfairplay\b/gi, "trustC0re")
    .slice(0, 48);
}

/** Rewrite legacy Tetherless / DELvEK suffixes when re-sending from cache. */
function displayIpaFileName(name) {
  const raw = String(name || "App.ipa");
  const tag = brandIpaTag();
  if (/\.ipa$/i.test(raw)) {
    return raw
      .replace(/-Tetherless\.ipa$/i, `-[${tag}].ipa`)
      .replace(/-DELvEK\.ipa$/i, `-[${tag}].ipa`)
      .replace(/-FastDecrypt\.ipa$/i, `-[${tag}].ipa`)
      .replace(/-\[DELvEK\.NeT\]\.ipa$/i, `-[${tag}].ipa`)
      .replace(/-\[FastDecrypt\.bot\]\.ipa$/i, `-[${tag}].ipa`)
      .replace(/-\[FastDecrypt\.Bot\]\.ipa$/i, `-[${tag}].ipa`);
  }
  return buildIpaFileName({ name: raw.replace(/\.ipa$/i, "") });
}

/** IPA document caption — classic AppAssassin look (bundle · version · store). */
function buildCaption({ bid, version, minIos, storeUrl }) {
  const lines = [];
  if (bid) lines.push(`📁 <code>${escapeHtml(bid)}</code>`);
  const verBits = [];
  if (version) verBits.push(`Version: ${escapeHtml(version)}`);
  if (minIos) verBits.push(`${escapeHtml(minIos)}+`);
  if (verBits.length) lines.push(`⚙️ ${verBits.join(" · ")}`);
  if (storeUrl) lines.push(`🔗 <a href="${escapeHtml(storeUrl)}">App Store Link</a>`);
  return lines.join("\n");
}

/**
 * Live card caption under the app icon — URSA-style stack:
 *   App name
 *   #hashtag
 *   progress text
 *   percentage
 */
function progressCaption({ name, stage, pct, tag }) {
  const p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
  const sharp = String(tag || "delvek")
    .toLowerCase()
    .replace(/^#/, "")
    .replace(/[^a-z0-9_]+/g, "")
    .slice(0, 32) || "delvek";
  return [
    `<b>${escapeHtml(name || "App")}</b>`,
    `#${sharp}`,
    escapeHtml(stage || "Working…"),
    `<b>${p}%</b>`,
  ].join("\n");
}

function httpsUrl(raw, fallback) {
  let u = String(raw || "").trim();
  if (!u) u = fallback;
  if (!/^https?:\/\//i.test(u)) u = `https://${u.replace(/^\/+/, "")}`;
  return u.replace(/\/+$/, "") || fallback;
}

function botBrandName() {
  const env = String(process.env.TELEGRAM_BOT_BRAND || "").trim();
  if (env) return env;
  if (isFastDecryptBrand()) return "FastDecrypt";
  return "DELvEK";
}

function vipContactHandle() {
  return VIP_CONTACT || "mrzefie";
}

function userHasVip(chatId) {
  return tgVip.isVip(chatId);
}

async function refuseIfNoQuota(chatId) {
  const r = tgVip.consumeQuota(chatId);
  if (r.ok) return true;
  await tgApi("sendMessage", {
    chat_id: chatId,
    text: String(r.error || "Daily limit reached.").slice(0, 400),
    disable_web_page_preview: true,
  }).catch(() => {});
  return false;
}

function siteLinkButtons() {
  const site = httpsUrl(
    process.env.FASTDECRYPT_SITE_URL ||
      process.env.DELVEK_SITE_URL ||
      process.env.TETHERLESS_SITE_URL,
    brandSiteDefault()
  );
  const patch = httpsUrl(
    process.env.FASTDECRYPT_PATCH_URL ||
      process.env.DELVEK_PATCH_URL ||
      process.env.TETHERLESS_PATCH_URL,
    `${site}/`
  );
  // AppAssassin-style: Patch Help + Get VIP.
  // FastDecrypt → fastdecrypt.bot/vip; else seller DM unless DELVEK_VIP_URL is set.
  const vipUrl = (() => {
    const raw = String(
      process.env.FASTDECRYPT_VIP_URL ||
        process.env.DELVEK_VIP_URL ||
        process.env.TETHERLESS_VIP_URL ||
        ""
    ).trim();
    if (raw) return httpsUrl(raw, `${site}/vip`);
    if (isFastDecryptBrand()) return `${site.replace(/\/+$/, "")}/vip`;
    return `https://t.me/${vipContactHandle()}`;
  })();
  return [
    { text: "✨ Patch Help ↗️", url: patch.endsWith("/") ? patch : `${patch}/` },
    { text: "⭐ Get VIP ↗️", url: vipUrl },
  ];
}

/** Final IPA buttons: Patch/VIP + one Open in… (HTML dropdown on fastdecrypt.bot). */
function resultKeyboard(downloadUrl) {
  const rows = [siteLinkButtons()];
  const url = String(downloadUrl || "").trim();
  if (/^https:\/\//i.test(url)) {
    try {
      const openIn = require("./mac-open-in");
      const menu = openIn.menuUrl(url);
      if (menu) rows.push([{ text: "📲 Open in…", url: menu }]);
    } catch (e) {
      console.warn("[open-in]", (e && e.message) || e);
    }
  }
  return { inline_keyboard: rows };
}

function vipStatusText(chatId) {
  const who = vipContactHandle();
  const st = tgVip.quotaStatus(chatId);
  if (st.vip) {
    const when = st.permanent
      ? "Expires: <b>lifetime</b>"
      : `Time left: <b>${escapeHtml(st.left)}</b>`;
    return (
      `⭐ <b>VIP active</b>\n\n` +
      `${when}\n` +
      `Unlimited decrypts · older versions · no size cap.\n` +
      `Questions? Contact @${escapeHtml(who)}.`
    );
  }
  return (
    `🔐 You do not have VIP access. Contact <b>@${escapeHtml(who)}</b> to purchase VIP access.\n\n` +
    `Free today: <b>${st.remaining}/${st.limit}</b> · max ${(tgVip.FREE_MAX_BYTES / (1024 * 1024 * 1024)).toFixed(0)} GB each\n\n` +
    `VIP perks:\n` +
    `✅ Unlimited decrypts (countdown timer, not a daily cap)\n` +
    `✅ No file size restrictions\n` +
    `✅ TestFlight IPA drop + older versions\n` +
    `✅ Plans: 7 / 30 / 90 / 180 / 365 days`
  );
}

async function sendVip(chatId) {
  const vipBtn = siteLinkButtons().find((b) => /VIP/i.test(b.text)) || {
    text: "⭐ Get VIP ↗️",
    url: `https://t.me/${vipContactHandle()}`,
  };
  await tgApi("sendMessage", {
    chat_id: chatId,
    text: vipStatusText(chatId),
    parse_mode: "HTML",
    disable_web_page_preview: true,
    reply_markup: {
      inline_keyboard: [[{ text: vipBtn.text, url: vipBtn.url }]],
    },
  });
}

async function sendStatus(chatId) {
  const st =
    (fairplayBackends.backendStatus && fairplayBackends.backendStatus()) || {};
  const decryptReady = !!(st.unfairplay && st.unfairplay.ready);
  const modelReady = !!(st.enrollmentModel && st.enrollmentModel.ready);
  const clearN = ipaCache.list().length;
  const encN = ipaCache.listEncrypted().length;
  const premOn = preferPremiumUpload();
  const ch = premiumUploadChannel() || "";
  const sessLoaded = premiumUploadConfigured();
  const pub = publicDl.resolvePublicBase() || "";
  const uploadLine = premOn
    ? ch
      ? `☁️ Upload: Premium → channel <code>${escapeHtml(ch)}</code> → bot`
      : `☁️ Upload: Premium session OK · set <code>TELEGRAM_UPLOAD_CHANNEL</code> for large IPAs`
    : sessLoaded
      ? `☁️ Upload: Premium session loaded but disabled (<code>TELEGRAM_PREMIUM_UPLOAD=0</code>)`
      : pub
        ? `☁️ Upload: Bot API ≤50 MB · larger → HTTPS <code>${escapeHtml(pub)}/d/…</code>`
        : `☁️ Upload: Bot API ≤50 MB · run <code>mac-ssh.sh api</code> for HTTPS big-IPA links (or web login at /tg-login)`;
  const text =
    `<b>${escapeHtml(botBrandName())} status</b>\n\n` +
    `🤖 Bot: @${escapeHtml(BOT_USERNAME || "?")}\n` +
    `⚙️ Workers: ${activeWorkers}/${MAX_WORKERS} active` +
    (jobWaiters.length ? ` · ${jobWaiters.length} queued` : "") +
    `\n` +
    `🔓 Decrypt: ${decryptReady ? "ready" : "not ready"}\n` +
    `🧠 Model: ${modelReady ? "ready" : "not ready"}\n` +
    `📦 Cache: ${clearN} clear · ${encN} encrypted\n` +
    `${uploadLine}\n` +
    `⭐ ${escapeHtml(tgVip.quotaLabel(tgVip.quotaStatus(chatId)))}`;
  await tgApi("sendMessage", {
    chat_id: chatId,
    text,
    parse_mode: "HTML",
    disable_web_page_preview: true,
  });
}

async function sendVersionHelp(chatId) {
  await tgApi("sendMessage", {
    chat_id: chatId,
    text:
      `<b>/version</b> — pick an older build to decrypt.\n\n` +
      `Paste an App Store URL, then choose a version from the list.\n` +
      `Or send:\n` +
      `<code>/version https://apps.apple.com/…</code>\n\n` +
      `VIP unlocks older versions without the free-tier limits — /vip`,
    parse_mode: "HTML",
    disable_web_page_preview: true,
  });
}

/** Legacy Download-button tokens (pre card→IPA auto-finish). */
const pendingDownloads = new Map();

/**
 * Force Patch/Get VIP onto a bot-owned message.
 * Prefer editMessageReplyMarkup alone — editMessageCaption fails with
 * "message is not modified" when caption already matches and then drops markup.
 */
function tgAlreadyOk(desc) {
  return /message is not modified|exactly the same/i.test(String(desc || ""));
}

async function attachIpaChrome(chatId, messageId, { caption, replyMarkup } = {}) {
  const mid = Number(messageId);
  if (!chatId || !mid) return false;
  const markup = replyMarkup || resultKeyboard();

  const markupOnly = await tgApi("editMessageReplyMarkup", {
    chat_id: chatId,
    message_id: mid,
    reply_markup: markup,
  }).catch((e) => ({ ok: false, description: String((e && e.message) || e) }));
  // Tabs already on the IPA → success (do NOT spawn a "DELvEK" reply).
  if (markupOnly && (markupOnly.ok || tgAlreadyOk(markupOnly.description))) return true;

  if (caption) {
    const withCap = await tgApi("editMessageCaption", {
      chat_id: chatId,
      message_id: mid,
      caption,
      parse_mode: "HTML",
      reply_markup: markup,
    }).catch((e) => ({ ok: false, description: String((e && e.message) || e) }));
    if (withCap && (withCap.ok || tgAlreadyOk(withCap.description))) return true;
    console.warn(
      "[job] editMessageCaption failed:",
      (withCap && withCap.description) || "unknown"
    );
  }

  console.warn(
    "[job] editMessageReplyMarkup failed:",
    (markupOnly && markupOnly.description) || "unknown"
  );
  return false;
}

/** Bot API sendDocument by file_id — most reliable way to bake in inline tabs. */
async function sendIpaByFileId(chatId, fileId, caption, replyMarkup) {
  const markup = replyMarkup || resultKeyboard();
  const r = await tgApi("sendDocument", {
    chat_id: chatId,
    document: fileId,
    caption: caption || undefined,
    parse_mode: caption ? "HTML" : undefined,
    reply_markup: markup,
  }).catch((e) => ({ ok: false, description: String((e && e.message) || e) }));
  if (r && r.ok && r.result && r.result.message_id) {
    // edit* can drop tabs on large/Premium-bridged docs — ensure or reply with Patch/VIP.
    await ensureIpaButtonTabs(chatId, r.result.message_id, { caption, replyMarkup: markup });
  }
  return r;
}

async function ensureIpaButtonTabs(chatId, messageId, { caption, replyMarkup, allowReply } = {}) {
  const markup = replyMarkup || resultKeyboard();
  const mid = Number(messageId);
  if (await attachIpaChrome(chatId, mid, { caption, replyMarkup: markup })) return true;
  // Only reply when explicitly allowed — default OFF so we never duplicate
  // Patch/Get VIP under an IPA that already has (or almost has) the tabs.
  if (!allowReply) {
    console.warn(
      `[job] IPA tabs edit failed; skipping ${brandIpaTag()} reply to avoid duplicate`
    );
    return false;
  }
  const reply = await tgApi("sendMessage", {
    chat_id: chatId,
    text: brandIpaTag(),
    reply_to_message_id: mid,
    reply_markup: markup,
    disable_web_page_preview: true,
  }).catch((e) => ({ ok: false, description: String((e && e.message) || e) }));
  if (!(reply && reply.ok)) {
    console.warn("[job] button reply failed:", (reply && reply.description) || "unknown");
    return false;
  }
  return true;
}

function escapeHtml(s) {
  return String(s || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Apple system / first-party apps (TestFlight, etc.) — match AppAssassin refusal. */
function isAppleSystemApp(storeUrl, bid) {
  const b = String(bid || "").toLowerCase();
  if (b.startsWith("com.apple.")) return true;
  const adam = ipaCache.adamFromStoreUrl(storeUrl);
  // TestFlight, App Store, Find My, …
  const blocked = new Set([
    "899247664", // TestFlight
    "1231336508", // Apple Store
    "1146562112", // Apple TV
  ]);
  return !!(adam && blocked.has(adam));
}

function lookupStoreApp(storeUrl) {
  const adam = ipaCache.adamFromStoreUrl(storeUrl);
  const out = { adam, name: "", version: "", iconPath: "", trackViewUrl: storeUrl || "" };
  if (!adam) return out;
  try {
    const cc = ((/apps\.apple\.com\/([a-z]{2})\//i.exec(storeUrl) || [])[1] || "us").toLowerCase();
    const lookup = spawnSync(
      "curl",
      ["-fsSL", `https://itunes.apple.com/lookup?id=${adam}&country=${cc}`],
      { encoding: "utf8", maxBuffer: 2 * 1024 * 1024 }
    );
    if (lookup.status !== 0) return out;
    const j = JSON.parse(lookup.stdout || "{}");
    const r = j && j.results && j.results[0];
    if (!r) return out;
    out.name = String(r.trackName || r.trackCensoredName || "").trim();
    out.version = String(r.version || "").trim();
    if (r.trackViewUrl) out.trackViewUrl = String(r.trackViewUrl);
    const art = r.artworkUrl512 || r.artworkUrl100;
    if (art) {
      const dest = path.join(WORK, `icon-${adam}.jpg`);
      const artUrl = String(art)
        .replace(/\/\d+x\d+bb(\.[a-z]+)?$/i, "/256x256bb$1")
        .replace("100x100", "256x256");
      const dl = spawnSync("curl", ["-fsSL", "-o", dest, artUrl], { encoding: "utf8" });
      if (dl.status === 0 && fs.existsSync(dest) && fs.statSync(dest).size > 100) {
        out.iconPath = dest;
      }
    }
  } catch {
    /* ignore */
  }
  return out;
}

/** Countries to try for name search (FastDecrypt region list, capped). */
function searchCountries() {
  const raw = String(
    process.env.MAC_TG_SEARCH_COUNTRIES ||
      process.env.FAIRPLAY_IPATOOL_STOREFRONT ||
      "us,hk,jp,de,fr,au,ca,cn,pl,vn,ru"
  );
  const list = raw
    .split(/[,\s]+/)
    .map((s) => s.trim().toLowerCase())
    .filter((s) => /^[a-z]{2}$/.test(s));
  return (list.length ? list : ["us"]).slice(0, 8);
}

/**
 * Parse free-text "App Name" or "App Name 1.2.3" / "App Name v1.2.3".
 * Returns null when the text looks like a URL, command, or IPA path.
 */
function parseAppNameQuery(text) {
  let t = String(text || "").trim();
  if (!t) return null;
  if (/^https?:\/\//i.test(t) || isStoreUrl(t) || isTestFlightUrl(t)) return null;
  if (/^\/\w+/i.test(t)) return null;
  if (/\.ipa$/i.test(t)) return null;
  if (/^decrypt\s+/i.test(t)) return null;

  let version = "";
  let name = t;
  let m = t.match(
    /^(.+?)\s+(?:v|version)[=:\s]+([0-9][0-9A-Za-z._-]{0,29})\s*$/i
  );
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

/** Search App Store by name; prefer exact title matches, then fill from more regions. */
function searchAppsByName(term, { limit = 8 } = {}) {
  const q = String(term || "").trim();
  if (q.length < 2) return [];
  const byAdam = new Map();
  for (const cc of searchCountries()) {
    for (const hit of searchItunesCountry(q, cc, Math.min(12, limit + 4))) {
      if (!byAdam.has(hit.adam)) byAdam.set(hit.adam, hit);
    }
    if (byAdam.size >= limit) break;
  }
  const items = [...byAdam.values()];
  const want = q.toLowerCase();
  items.sort((a, b) => {
    const ae = a.name.toLowerCase() === want ? 0 : a.name.toLowerCase().startsWith(want) ? 1 : 2;
    const be = b.name.toLowerCase() === want ? 0 : b.name.toLowerCase().startsWith(want) ? 1 : 2;
    if (ae !== be) return ae - be;
    return a.name.localeCompare(b.name);
  });
  return items.slice(0, limit);
}

function pickBestAppMatch(items, name) {
  const list = Array.isArray(items) ? items : [];
  if (!list.length) return null;
  if (list.length === 1) return list[0];
  const want = String(name || "").trim().toLowerCase();
  const exact = list.filter((it) => it.name.toLowerCase() === want);
  if (exact.length === 1) return exact[0];
  // "Vinted" → "Vinted: Pre-loved marketplace"
  const titled = list.filter((it) => {
    const n = it.name.toLowerCase();
    return (
      n.startsWith(want + ":") ||
      n.startsWith(want + " -") ||
      n.startsWith(want + " –") ||
      n.startsWith(want + " —")
    );
  });
  if (titled.length === 1) return titled[0];
  return null;
}

async function beginDecryptFromStore(chatId, link, vreq) {
  rememberStoreUrl(chatId, link, vreq || "latest");
  if (vreq) {
    await withWorker(chatId, async () => {
      const resolved = await resolveExternalVersionId(link, vreq);
      await decryptStoreUrl(chatId, link, resolved);
    });
    return;
  }
  await offerVersionPick(chatId, link);
}

async function offerAppNamePick(chatId, items, { name, version } = {}) {
  pruneAppPicks();
  const token = crypto.randomBytes(4).toString("hex");
  const picks = (items || []).slice(0, 8);
  pendingAppPicks.set(token, {
    chatId,
    version: String(version || "").trim(),
    items: picks,
    expires: Date.now() + 15 * 60 * 1000,
  });
  const lines = picks.map((it, i) => {
    const ver = it.version ? ` · v${it.version}` : "";
    const bid = it.bid ? ` · <code>${escapeHtml(it.bid)}</code>` : "";
    return `${i + 1}. <b>${escapeHtml(it.name)}</b>${ver}${bid}`;
  });
  const rows = picks.map((it, i) => [
    {
      text: `${i + 1}. ${it.name}`.slice(0, 64),
      callback_data: `app:${token}:${i}`.slice(0, 64),
    },
  ]);
  await tgApi("sendMessage", {
    chat_id: chatId,
    text:
      `Several apps match “${escapeHtml(String(name || "").slice(0, 40))}” — pick one:\n\n` +
      lines.join("\n"),
    parse_mode: "HTML",
    disable_web_page_preview: true,
    reply_markup: { inline_keyboard: rows },
  });
}

async function handleAppNamePick(cq, data) {
  // app:<token>:<index>
  const parts = String(data || "").split(":");
  const token = parts[1] || "";
  const idx = Number(parts[2]);
  pruneAppPicks();
  const pending = pendingAppPicks.get(token);
  await tgApi("answerCallbackQuery", { callback_query_id: cq.id }).catch(() => {});
  if (!pending || !Array.isArray(pending.items)) {
    await tgApi("sendMessage", {
      chat_id: cq.message && cq.message.chat && cq.message.chat.id,
      text: "That search expired — send the app name again.",
    }).catch(() => {});
    return;
  }
  const chatId = pending.chatId;
  const pick = pending.items[idx];
  if (!pick || !pick.url) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text: "Invalid pick — send the app name again.",
    }).catch(() => {});
    return;
  }
  pendingAppPicks.delete(token);
  if (cq.message && cq.message.message_id) {
    await tgApi("deleteMessage", {
      chat_id: chatId,
      message_id: cq.message.message_id,
    }).catch(() => {});
  }
  await tgApi("sendMessage", {
    chat_id: chatId,
    text: `Decrypting <b>${escapeHtml(pick.name)}</b>…`,
    parse_mode: "HTML",
  }).catch(() => {});
  await beginDecryptFromStore(chatId, pick.url, pending.version || "");
}

async function handleAppNameMessage(chatId, text, messageId) {
  const parsed = parseAppNameQuery(text);
  if (!parsed) return false;
  const wait = await tgApi("sendMessage", {
    chat_id: chatId,
    text: `Searching App Store for “${parsed.name.slice(0, 40)}”…`,
  }).catch(() => null);
  const waitId = wait && wait.ok && wait.result && wait.result.message_id;
  let items = [];
  try {
    items = searchAppsByName(parsed.name, { limit: 8 });
  } catch (e) {
    console.warn("[search]", (e && e.message) || e);
  }
  if (waitId) {
    await tgApi("deleteMessage", { chat_id: chatId, message_id: waitId }).catch(() => {});
  }
  if (!items.length) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text:
        `No App Store apps found for “${parsed.name.slice(0, 40)}”.\n` +
        `Try another name, or paste an App Store link.`,
    });
    return true;
  }
  const best = pickBestAppMatch(items, parsed.name);
  await deleteUserMessage(chatId, messageId);
  if (best) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text:
        `Found <b>${escapeHtml(best.name)}</b>` +
        (parsed.version ? ` · v${escapeHtml(parsed.version)}` : "") +
        `…`,
      parse_mode: "HTML",
      disable_web_page_preview: true,
    }).catch(() => {});
    await beginDecryptFromStore(chatId, best.url, parsed.version || "");
    return true;
  }
  await offerAppNamePick(chatId, items, parsed);
  return true;
}

function fetchStoreIcon(storeUrl) {
  return lookupStoreApp(storeUrl).iconPath || "";
}

/**
 * Pull this build’s AppIcon out of the IPA (Payload/*.app).
 * Un-crushes Apple CgBI PNGs the same way the site decrypt queue does —
 * older versions keep their era’s icon instead of today’s App Store art.
 */
function extractIpaIcon(ipaPath, destPath) {
  const ipa = path.resolve(String(ipaPath || ""));
  const out = path.resolve(String(destPath || ""));
  if (!ipa || !out || !fs.existsSync(ipa)) return "";
  try {
    fs.mkdirSync(path.dirname(out), { recursive: true });
    const py = [
      "import zipfile,plistlib,sys,re,zlib,struct,os",
      "z=zipfile.ZipFile(sys.argv[1]);names=z.namelist()",
      "ip=[x for x in names if re.match(r'^Payload/[^/]+\\.app/Info\\.plist$',x)]",
      "if not ip: sys.exit(1)",
      "base=ip[0][:-len('Info.plist')];d=plistlib.loads(z.read(ip[0]))",
      "want=[]",
      "def grab(o):",
      " if isinstance(o,dict):",
      "  for k,v in o.items():",
      "   if k in('CFBundleIconFiles','CFBundleIconFile','CFBundleIconName'): want.extend(v if isinstance(v,list) else [v])",
      "   else: grab(v)",
      " elif isinstance(o,list):",
      "  for v in o: grab(v)",
      "grab(d)",
      "want=[os.path.splitext(str(w))[0] for w in want]+['AppIcon','Icon','iTunesArtwork']",
      "pn=[n for n in names if n.startswith(base) and n.count('/')==base.count('/') and n.lower().endswith(('.png','.jpg','.jpeg'))]",
      "c=[n for n in pn if any(os.path.basename(n).startswith(w) for w in want)]",
      "pool=c or [n for n in pn if re.search(r'(?i)appicon|icon|itunesartwork', os.path.basename(n))]",
      "if not pool: sys.exit(1)",
      "best=max(pool,key=lambda n:z.getinfo(n).file_size)",
      "b=z.read(best)",
      "ext=os.path.splitext(best)[1].lower()",
      "if ext in ('.jpg','.jpeg') or (len(b)>8 and b[8+4:8+8]!=b'CgBI'):",
      " open(sys.argv[2],'wb').write(b);sys.exit(0)",
      "def chunks(b):",
      " p=8",
      " while p<len(b):",
      "  l,t=struct.unpack('>I4s',b[p:p+8]);yield t,b[p+8:p+8+l];p+=12+l",
      "ch=list(chunks(b));ihdr=[d for t,d in ch if t==b'IHDR'][0]",
      "w,h=struct.unpack('>II',ihdr[:8])",
      "raw=zlib.decompress(b''.join(d for t,d in ch if t==b'IDAT'),-15)",
      "bpp=4;st=w*bpp;prev=bytearray(st);rows=[];p=0",
      "for y in range(h):",
      " f=raw[p];line=bytearray(raw[p+1:p+1+st]);p+=1+st",
      " for i in range(st):",
      "  a=line[i-bpp] if i>=bpp else 0;bb=prev[i];c2=prev[i-bpp] if i>=bpp else 0",
      "  if f==1:line[i]=(line[i]+a)&255",
      "  elif f==2:line[i]=(line[i]+bb)&255",
      "  elif f==3:line[i]=(line[i]+((a+bb)>>1))&255",
      "  elif f==4:",
      "   pa=abs(bb-c2);pb=abs(a-c2);pc=abs(a+bb-2*c2)",
      "   pr=a if (pa<=pb and pa<=pc) else (bb if pb<=pc else c2)",
      "   line[i]=(line[i]+pr)&255",
      " prev=line;o=bytearray(st)",
      " for x in range(0,st,4):",
      "  B,G,R,A=line[x],line[x+1],line[x+2],line[x+3]",
      "  if A and A<255: R=min(255,R*255//A);G=min(255,G*255//A);B=min(255,B*255//A)",
      "  o[x]=R;o[x+1]=G;o[x+2]=B;o[x+3]=A",
      " rows.append(b'\\x00'+bytes(o))",
      "def ck(t,d):",
      " c=struct.pack('>I',len(d))+t+d;return c+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)",
      "ih=struct.pack('>IIBBBBB',w,h,8,6,0,0,0)",
      "open(sys.argv[2],'wb').write(b'\\x89PNG\\r\\n\\x1a\\n'+ck(b'IHDR',ih)+ck(b'IDAT',zlib.compress(b''.join(rows),6))+ck(b'IEND',b''))",
    ].join("\n");
    const r = spawnSync("python3", ["-I", "-c", py, ipa, out], {
      timeout: 45000,
      encoding: "utf8",
      maxBuffer: 4 * 1024 * 1024,
    });
    if (r.status === 0 && fs.existsSync(out) && fs.statSync(out).size > 100) return out;
  } catch (e) {
    console.warn("[icon] extract failed:", (e && e.message) || e);
  }
  return "";
}

/**
 * Telegram document thumbnail: this build’s icon + white download arrow.
 * Prefer an IPA-extracted icon (older builds) over today’s App Store art.
 */
/** Stamp cord onto a loose icon file used for Telegram cards / thumbs. */
async function ensureCordIcon(iconPath) {
  const src = String(iconPath || "");
  if (!src || !fs.existsSync(src)) return "";
  // Already stamped this session.
  if (/\.cord\.png$/i.test(src) || /cord-thumb-src/i.test(src)) return src;
  const stampedDest = path.join(
    path.dirname(src),
    `${path.basename(src, path.extname(src))}.cord.png`
  );
  if (fs.existsSync(stampedDest) && fs.statSync(stampedDest).size > 100) return stampedDest;
  try {
    const stamped = await cordBrand.brandIconFile(src, stampedDest);
    if (stamped && fs.existsSync(stamped)) return stamped;
  } catch (e) {
    console.warn("[cord] ensure icon:", (e && e.message) || e);
  }
  return src;
}

async function buildIpaDocumentThumb(storeUrl, iconOverride) {
  let iconPath = "";
  if (iconOverride && fs.existsSync(iconOverride)) iconPath = iconOverride;
  if (!iconPath && storeUrl) iconPath = fetchStoreIcon(storeUrl) || "";
  // Always stamp cord onto whatever Telegram will show as the document thumb.
  iconPath = (await ensureCordIcon(iconPath)) || iconPath;
  const dest = path.join(
    os.tmpdir(),
    `delvek-ipa-thumb-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.jpg`
  );
  const rendered = await renderDownloadThumb({
    iconPath: iconPath || "",
    dest,
    size: 320,
  });
  if (rendered && fs.existsSync(rendered)) return rendered;
  return iconPath || "";
}

function sendPhotoBotApi(chatId, photoPath, caption, replyMarkup) {
  const abs = path.resolve(photoPath);
  // --form-string keeps newlines/HTML in captions (plain -F breaks them).
  const args = [
    "-sS",
    "-X",
    "POST",
    apiUrl("sendPhoto"),
    "--form-string",
    `chat_id=${chatId}`,
    "--form-string",
    "parse_mode=HTML",
    "-F",
    `photo=@${abs};type=image/jpeg`,
  ];
  if (caption) {
    args.push("--form-string", `caption=${caption}`);
  }
  if (replyMarkup) {
    args.push("--form-string", `reply_markup=${JSON.stringify(replyMarkup)}`);
  }
  const r = spawnSync("curl", args, { encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  if (r.error) return Promise.reject(r.error);
  if (r.status !== 0) {
    return Promise.resolve({
      ok: false,
      description: (r.stderr || r.stdout || `curl exit ${r.status}`).trim().slice(0, 300),
    });
  }
  try {
    return Promise.resolve(JSON.parse(r.stdout || "{}"));
  } catch (e) {
    return Promise.resolve({ ok: false, description: String(r.stdout || e.message).slice(0, 300) });
  }
}

/**
 * Smooth % buffer (same idea as Discord): display eases +1–2 toward the real
 * target and slowly creeps ahead so the sharp card never looks stuck.
 */
function createPctBuffer({ paint, intervalMs = 550 }) {
  let target = 0;
  let display = 0;
  let ceiling = 8;
  let timer = null;
  let painting = false;
  let lastPainted = -1;
  let stopped = false;

  const paintSafe = async (p) => {
    if (painting || stopped) return;
    if (p === lastPainted) return;
    painting = true;
    lastPainted = p;
    try {
      await paint(p);
    } catch {
      /* ignore edit races */
    } finally {
      painting = false;
    }
  };

  const tick = () => {
    if (stopped) return;
    let aim = target;
    if (display >= target && display < ceiling) aim = Math.min(ceiling, display + 1);
    if (display < aim) {
      const gap = aim - display;
      display = Math.min(aim, display + (gap >= 10 ? 2 : 1));
    }
    display = Math.max(0, Math.min(100, display));
    paintSafe(display).catch(() => {});
  };

  const ensureTimer = () => {
    if (stopped || timer) return;
    timer = setInterval(tick, intervalMs);
  };

  return {
    setTarget(pct, phaseCeil) {
      if (stopped) return;
      const p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
      target = Math.max(target, p);
      if (phaseCeil != null) {
        ceiling = Math.max(ceiling, Math.min(99, Math.round(Number(phaseCeil) || ceiling)));
      }
      ceiling = Math.max(ceiling, Math.min(99, target));
      ensureTimer();
      tick();
    },
    async flush(to = 100) {
      if (stopped) return;
      target = Math.max(target, to);
      ceiling = Math.max(ceiling, to);
      while (display < to && !stopped) {
        display = Math.min(to, display + 3);
        await paintSafe(display);
        await new Promise((r) => setTimeout(r, 180));
      }
      this.stop();
    },
    stop() {
      stopped = true;
      if (timer) clearInterval(timer);
      timer = null;
    },
    get display() {
      return display;
    },
  };
}

function phaseCeilForStage(stage) {
  const s = String(stage || "");
  if (/upload|send|brand/i.test(s)) return 99;
  if (/decrypt/i.test(s)) return 92;
  if (/download/i.test(s)) return 55;
  if (/fetch|start/i.test(s)) return 14;
  return 96;
}

/** Replace the progress card photo (URSA-style banner updates). */
function editMessageMediaBotApi(chatId, messageId, photoPath, caption, replyMarkup) {
  const abs = path.resolve(photoPath);
  const media = JSON.stringify({
    type: "photo",
    media: "attach://photo",
    caption: caption || "",
    parse_mode: "HTML",
  });
  const args = [
    "-sS",
    "-X",
    "POST",
    apiUrl("editMessageMedia"),
    "--form-string",
    `chat_id=${chatId}`,
    "--form-string",
    `message_id=${messageId}`,
    "--form-string",
    `media=${media}`,
    "-F",
    `photo=@${abs};type=image/jpeg`,
  ];
  if (replyMarkup) {
    args.push("--form-string", `reply_markup=${JSON.stringify(replyMarkup)}`);
  }
  const r = spawnSync("curl", args, { encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  if (r.error) return Promise.reject(r.error);
  if (r.status !== 0) {
    return Promise.resolve({
      ok: false,
      description: (r.stderr || r.stdout || `curl exit ${r.status}`).trim().slice(0, 300),
    });
  }
  try {
    return Promise.resolve(JSON.parse(r.stdout || "{}"));
  } catch (e) {
    return Promise.resolve({ ok: false, description: String(r.stdout || e.message).slice(0, 300) });
  }
}

/** One editable Telegram card: URSA-style banner only (no caption under the photo). */
function createProgressCard(chatId) {
  let messageId = 0;
  let hasPhoto = false;
  let name = "App";
  let version = "";
  let storeUrl = "";
  let iconPath = "";
  let bannerPath = "";
  let lastEdit = 0;
  let lastPct = -1;
  let lastStage = "";
  let termLog = []; // rolling backend lines for the transparent terminal
  let closed = false; // after IPA promote / clear — block late paints from resurrecting the card
  // Serialize paints — parallel start()+fromBackendLine used to send two photos.
  let paintChain = Promise.resolve();

  function bannerFile() {
    if (!bannerPath) {
      bannerPath = path.join(WORK, `progress-${chatId}-${Date.now()}.jpg`);
    }
    return bannerPath;
  }

  function pushTerm(line) {
    const t = cleanTermLine(line);
    if (!t) return false;
    if (termLog.length && termLog[termLog.length - 1] === t) return false;
    termLog.push(t);
    if (termLog.length > 8) termLog = termLog.slice(-8);
    return true;
  }

  /** Stage-driven mock log — never dumps raw backend say(). */
  function pushMockStage(stage, pct) {
    return pushTerm(mockTermLineForStage(stage, pct));
  }

  async function makeBanner(stage, pct, { done } = {}) {
    if (done) pushMockStage("done", 100);
    return renderProgressBanner({
      name,
      version,
      stage: stage || lastStage || "",
      logLines: termLog.length
        ? termLog.slice()
        : [mockTermLineForStage(stage || lastStage || "Fetching…", pct)],
      pct: done ? 100 : pct,
      iconPath,
      dest: bannerFile(),
      tag: isFastDecryptBrand() ? "fastdecrypt" : "delvek",
      brand: brandIpaTag(),
      done: !!done,
    });
  }

  async function clearPhotoCaption() {
    if (!messageId || !hasPhoto || closed) return;
    await tgApi("editMessageCaption", {
      chat_id: chatId,
      message_id: messageId,
      caption: "",
    }).catch(() => {});
  }

  async function paintBanner(stage, pct) {
    const run = async () => {
      if (closed) return false;
      const img = await makeBanner(stage, pct);
      if (closed) return false;
      if (!img) {
        // Prefer silence over duplicating banner text as a caption.
        console.warn("[job] banner render failed — leaving prior card");
        return false;
      }
      if (!messageId) {
        const sent = await sendPhotoBotApi(chatId, img, "");
        if (closed) {
          // Uploaded after close — delete the stray photo.
          if (sent && sent.ok && sent.result && sent.result.message_id) {
            await tgApi("deleteMessage", {
              chat_id: chatId,
              message_id: sent.result.message_id,
            }).catch(() => {});
          }
          return false;
        }
        if (sent && sent.ok && sent.result) {
          messageId = sent.result.message_id;
          hasPhoto = true;
          return true;
        }
        console.warn("[job] sendPhoto banner failed:", (sent && sent.description) || "unknown");
        return false;
      }
      if (hasPhoto) {
        let edited = await editMessageMediaBotApi(chatId, messageId, img, "");
        if (!(edited && edited.ok)) {
          // Retry once; never fall back to text caption (duplicates the banner).
          await new Promise((r) => setTimeout(r, 400));
          if (closed) return false;
          edited = await editMessageMediaBotApi(chatId, messageId, img, "");
        }
        if (edited && edited.ok) {
          await clearPhotoCaption();
          return true;
        }
        console.warn("[job] editMessageMedia failed:", (edited && edited.description) || "unknown");
        return false;
      }
      return false;
    };
    const done = paintChain.then(run, run);
    paintChain = done.catch(() => {});
    return done;
  }

  const pctBuf = createPctBuffer({
    intervalMs: 550,
    paint: async (p) => {
      if (closed) return;
      lastPct = p;
      lastEdit = Date.now();
      console.log("[job]", lastStage || "Working…", `${p}%`);
      await paintBanner(lastStage || "Working…", p);
    },
  });

  return {
    get name() {
      return name;
    },
    get version() {
      return version;
    },
    get storeUrl() {
      return storeUrl;
    },
    get messageId() {
      return messageId;
    },
    async start(link, hintName, opts = {}) {
      storeUrl = link || "";
      const meta = link ? lookupStoreApp(link) : { name: "", iconPath: "", version: "" };
      // Prefer short App Store title (drop “- Play Music Offline” style suffixes for the card).
      const rawName = hintName || meta.name || "App";
      name = String(rawName).split(/\s+[—\-–]\s+/)[0].trim() || rawName;
      // Marketing version for the right-side label (not external-version-id).
      const hintVer = String(opts.version || opts.versionLabel || "").trim().replace(/^v/i, "");
      if (hintVer && !isExternalVersionId(hintVer)) version = hintVer;
      else if (meta.version && !isExternalVersionId(meta.version)) version = meta.version;
      iconPath = (meta.iconPath && fs.existsSync(meta.iconPath) && meta.iconPath) || "";
      if (iconPath) iconPath = (await ensureCordIcon(iconPath)) || iconPath;
      lastStage = "Fetching…";
      lastPct = 4;
      pushMockStage("Fetching…", 4);
      const ok = await paintBanner("Fetching…", 4);
      pctBuf.setTarget(4, 14);
      if (ok) return;
      // Single fallback photo — still no caption text under it.
      if (!messageId && iconPath) {
        const sent = await sendPhotoBotApi(chatId, iconPath, "");
        if (sent && sent.ok && sent.result) {
          messageId = sent.result.message_id;
          hasPhoto = true;
        }
      }
    },
    /** Update marketing version on the right-side card label and repaint. */
    async setVersion(nextVer, stage, pct) {
      if (closed) return;
      const v = String(nextVer || "").trim().replace(/^v/i, "");
      if (!v || isExternalVersionId(v)) return;
      if (v === version) return;
      version = v;
      if (stage) {
        lastStage = stage;
        pushMockStage(stage, pctBuf.display || lastPct || 0);
      }
      if (pct != null) {
        const raw = Math.max(0, Math.min(99, Math.round(Number(pct) || 0)));
        pctBuf.setTarget(raw, phaseCeilForStage(stage || lastStage));
      } else {
        await paintBanner(lastStage || "Working…", Math.max(0, pctBuf.display || lastPct || 0));
      }
    },
    /** Swap to an IPA-extracted icon (this build’s artwork) and repaint. */
    async setIcon(nextIcon, stage, pct) {
      if (closed) return;
      let next = String(nextIcon || "");
      if (!next || !fs.existsSync(next)) return;
      next = (await ensureCordIcon(next)) || next;
      iconPath = next;
      if (stage) {
        lastStage = stage;
        pushMockStage(stage, pctBuf.display || lastPct || 0);
      }
      if (pct != null) {
        const raw = Math.max(0, Math.min(99, Math.round(Number(pct) || 0)));
        pctBuf.setTarget(raw, phaseCeilForStage(stage || lastStage));
      } else {
        await paintBanner(lastStage || "Working…", Math.max(0, pctBuf.display || lastPct || 0));
      }
    },
    get iconPath() {
      return iconPath;
    },
    async setStage(stage, pct) {
      if (closed) return;
      const raw = Math.max(0, Math.min(99, Math.round(Number(pct) || 0)));
      if (stage) {
        if (stage !== lastStage) lastStage = stage;
        pushMockStage(stage, Math.max(pctBuf.display || 0, raw));
      }
      pctBuf.setTarget(raw, phaseCeilForStage(stage || lastStage));
    },
    /**
     * Map backend say() → stage/% only. Terminal shows safe mock lines —
     * never the raw backend text (hosts, models, ids, paths).
     */
    async fromBackendLine(line) {
      const t = String(line || "");
      let stage = lastStage || "Working…";
      let pct = 12;
      if (/ipatool|download|encrypted IPA cache/i.test(t)) {
        stage = "Downloading…";
        pct = 28;
      } else if (/unfairplay|decrypt|FairPlay|model|Tetherless decrypt/i.test(t)) {
        stage = "Decrypting…";
        pct = 58;
      } else if (/produced|done/i.test(t)) {
        stage = "Decrypting…";
        pct = 78;
      } else if (/upload/i.test(t)) {
        stage = "Uploading…";
        pct = 82;
      }
      return this.setStage(stage, pct);
    },
    async setUploadPct(pct) {
      // Map file upload 0–100% into card band 80–99 (after decrypt ~72–78).
      const p = 80 + Math.round((Math.max(0, Math.min(100, pct)) / 100) * 19);
      return this.setStage("Uploading…", p);
    },
    /** Ease displayed % up to `to` before promoting the card to an IPA. */
    async flush(to = 100) {
      if (closed) return;
      await pctBuf.flush(to);
      lastPct = to;
    },
    /**
     * Release the progress photo without deleting it (after it became the IPA).
     * Drains paint queue first so a late Uploading… paint can't resurrect the card.
     */
    async release() {
      closed = true;
      pctBuf.stop();
      await paintChain.catch(() => {});
      messageId = 0;
      hasPhoto = false;
      if (bannerPath) {
        try {
          fs.rmSync(bannerPath, { force: true });
        } catch {
          /* ignore */
        }
        bannerPath = "";
      }
    },
    async clear() {
      closed = true;
      pctBuf.stop();
      await paintChain.catch(() => {});
      if (messageId) {
        await tgApi("deleteMessage", { chat_id: chatId, message_id: messageId }).catch(() => {});
        messageId = 0;
        hasPhoto = false;
      }
      if (bannerPath) {
        try {
          fs.rmSync(bannerPath, { force: true });
        } catch {
          /* ignore */
        }
        bannerPath = "";
      }
    },
    /** Drop the live card (used when a new IPA bubble replaced it). */
    async finish() {
      await this.clear();
    },
    async fail(err) {
      pctBuf.stop();
      if (closed) {
        await tgApi("sendMessage", {
          chat_id: chatId,
          text: `❌ ${String(err || "failed").slice(0, 160)}`,
        }).catch(() => {});
        return;
      }
      lastStage = "Failed";
      // Allow 0% on failure only.
      lastPct = -1;
      lastPct = 0;
      pushMockStage("Failed", 0);
      const img = await makeBanner("Failed", 0);
      if (img && messageId && hasPhoto) {
        await editMessageMediaBotApi(chatId, messageId, img, "");
        // Failure detail as a separate short message — keep banner caption-free.
        await tgApi("sendMessage", {
          chat_id: chatId,
          text: `❌ ${String(err || "failed").slice(0, 160)}`,
          reply_to_message_id: messageId,
        }).catch(() => {});
        return;
      }
      await tgApi("sendMessage", {
        chat_id: chatId,
        text: `❌ ${String(err || "failed").slice(0, 160)}`,
      }).catch(() => {});
    },
  };
}

/**
 * Turn the done sharp-card photo into the IPA document in-place.
 * Same message_id — IPA sits behind the Download control, no extra bubble.
 */
function editMessageToDocumentBotApi(
  chatId,
  messageId,
  filePath,
  fileName,
  caption,
  { thumbPath, replyMarkup, fileId } = {}
) {
  const mid = Number(messageId);
  if (!chatId || !mid) {
    return Promise.resolve({ ok: false, description: "missing card message" });
  }
  const mediaObj = {
    type: "document",
    caption: caption || "",
    parse_mode: "HTML",
  };
  const args = [
    "-sS",
    "-X",
    "POST",
    apiUrl("editMessageMedia"),
    "--form-string",
    `chat_id=${chatId}`,
    "--form-string",
    `message_id=${mid}`,
  ];
  if (replyMarkup) {
    args.push("--form-string", `reply_markup=${JSON.stringify(replyMarkup)}`);
  }

  if (fileId) {
    mediaObj.media = fileId;
    if (thumbPath && fs.existsSync(thumbPath)) {
      mediaObj.thumbnail = "attach://thumb";
    }
    args.push("--form-string", `media=${JSON.stringify(mediaObj)}`);
    if (thumbPath && fs.existsSync(thumbPath)) {
      args.push("-F", `thumb=@${path.resolve(thumbPath)};type=image/jpeg`);
    }
  } else {
    const abs = path.resolve(filePath || "");
    if (!abs || !fs.existsSync(abs)) {
      return Promise.resolve({ ok: false, description: "IPA missing on disk" });
    }
    mediaObj.media = "attach://document";
    if (thumbPath && fs.existsSync(thumbPath)) {
      mediaObj.thumbnail = "attach://thumb";
    }
    args.push("--form-string", `media=${JSON.stringify(mediaObj)}`);
    if (LOCAL_API) {
      args.push("-F", `document=file://${abs}`);
    } else {
      args.push(
        "-F",
        `document=@${abs};type=application/octet-stream;filename=${fileName || path.basename(abs)}`
      );
    }
    if (thumbPath && fs.existsSync(thumbPath)) {
      args.push("-F", `thumb=@${path.resolve(thumbPath)};type=image/jpeg`);
    }
  }

  const r = spawnSync("curl", args, { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  if (r.error) return Promise.reject(r.error);
  if (r.status !== 0) {
    return Promise.resolve({
      ok: false,
      description: (r.stderr || r.stdout || `curl exit ${r.status}`).trim().slice(0, 300),
    });
  }
  try {
    return Promise.resolve(JSON.parse(r.stdout || "{}"));
  } catch (e) {
    return Promise.resolve({ ok: false, description: String(r.stdout || e.message).slice(0, 300) });
  }
}

function sendDocumentBotApi(chatId, filePath, fileName, caption, { thumbPath, replyMarkup } = {}) {
  const abs = path.resolve(filePath);
  // --form-string for caption/reply_markup so HTML + JSON aren't mangled by -F.
  const args = [
    "-sS",
    "-X",
    "POST",
    apiUrl("sendDocument"),
    "-F",
    `chat_id=${chatId}`,
    "--form-string",
    "parse_mode=HTML",
  ];
  if (caption) args.push("--form-string", `caption=${caption}`);
  if (replyMarkup) args.push("--form-string", `reply_markup=${JSON.stringify(replyMarkup)}`);
  if (thumbPath && fs.existsSync(thumbPath)) {
    args.push("-F", `thumbnail=@${path.resolve(thumbPath)};type=image/jpeg`);
  }
  if (LOCAL_API) {
    args.push("-F", `document=file://${abs}`);
  } else {
    args.push(
      "-F",
      `document=@${abs};type=application/octet-stream;filename=${fileName}`
    );
  }
  const r = spawnSync("curl", args, { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  if (r.error) return Promise.reject(r.error);
  if (r.status !== 0) {
    return Promise.resolve({
      ok: false,
      description: (r.stderr || r.stdout || `curl exit ${r.status}`).trim().slice(0, 300),
    });
  }
  try {
    return Promise.resolve(JSON.parse(r.stdout || "{}"));
  } catch (e) {
    return Promise.resolve({ ok: false, description: String(r.stdout || e.message).slice(0, 300) });
  }
}

function premiumUploadConfigured() {
  return !!(
    process.env.TELEGRAM_API_ID &&
    process.env.TELEGRAM_API_HASH &&
    (process.env.TELEGRAM_SESSION || process.env.TELEGRAM_SESSION_STRING) &&
    fs.existsSync(PREMIUM_UPLOAD)
  );
}

/**
 * Staging peers for Premium user uploads.
 * Prefer a private channel (TELEGRAM_UPLOAD_CHANNEL) where the bot is admin —
 * Premium account posts the IPA there, then the bot copyMessage's it to the user.
 * Falls back to DM with the bot (legacy).
 */
function premiumUploadChannel() {
  return String(
    process.env.TELEGRAM_UPLOAD_CHANNEL ||
      process.env.TELEGRAM_PREMIUM_CHANNEL ||
      ""
  ).trim();
}

function premiumPeerCandidates() {
  const out = [];
  const channel = premiumUploadChannel();
  if (channel) {
    if (/^-?\d+$/.test(channel)) out.push(channel);
    else out.push(channel.startsWith("@") ? channel : `@${channel.replace(/^@/, "")}`);
  }
  // Legacy fallback: Premium user → bot DM (only works cleanly when requester == Premium account).
  if (BOT_ID) out.push(String(BOT_ID));
  const uname = String(BOT_USERNAME || "").trim().replace(/^@/, "");
  if (uname) out.push(`@${uname}`);
  return [...new Set(out)];
}

function premiumPeer() {
  return premiumPeerCandidates()[0] || "";
}

function premiumChannelConfigured() {
  return !!premiumUploadChannel();
}

function premiumFailDescription(raw) {
  let s = String(raw || "unknown");
  // Unwrap nested JSON from older spawn paths: {"ok":false,"description":"..."}
  try {
    const j = JSON.parse(s);
    if (j && j.description) s = String(j.description);
  } catch {
    /* plain text */
  }
  return s.replace(/^'|'$/g, "").slice(0, 220);
}

/**
 * Upload via Premium user session (async — does not freeze the bot event loop).
 * Streams progress lines from Python and optional heartbeats to the chat.
 */
function sendDocumentPremiumOnce(chatId, filePath, fileName, caption, peer, { thumbPath, replyMarkup, onProgress } = {}) {
  const env = {
    ...process.env,
    // Upload as you → bot id / @Bot so the file appears in this chat (not Saved Messages).
    TG_UPLOAD_CHAT_ID: peer,
    TG_UPLOAD_BOT_ID: BOT_ID ? String(BOT_ID) : "",
    TG_UPLOAD_BOT_USERNAME: BOT_USERNAME || "",
    TG_UPLOAD_FILE: path.resolve(filePath),
    TG_UPLOAD_FILENAME: fileName,
    TG_UPLOAD_CAPTION: caption || "",
    TG_UPLOAD_THUMB: thumbPath && fs.existsSync(thumbPath) ? path.resolve(thumbPath) : "",
    TG_UPLOAD_REPLY_MARKUP: replyMarkup ? JSON.stringify(replyMarkup) : "",
  };
  const timeoutMs = Math.max(
    120000,
    Number(process.env.TELEGRAM_PREMIUM_UPLOAD_TIMEOUT_MS || 20 * 60 * 1000)
  );
  const mbTotal = (fs.statSync(filePath).size / 1024 / 1024).toFixed(1);
  console.log(`[job] Premium upload → peer=${peer} file=${fileName} (${mbTotal} MB)`);

  return new Promise((resolve) => {
    const child = spawn("python3", ["-u", PREMIUM_UPLOAD], {
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let settled = false;
    let lastPct = -1;
    const started = Date.now();

    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearInterval(ticker);
      clearTimeout(killer);
      try {
        child.kill("SIGKILL");
      } catch {
        /* ignore */
      }
      resolve(result);
    };

    const killer = setTimeout(() => {
      finish({
        ok: false,
        description: `Premium upload timed out after ${Math.round(timeoutMs / 60000)} min (peer=${peer})`,
      });
    }, timeoutMs);

    const ticker = setInterval(() => {
      const sec = Math.round((Date.now() - started) / 1000);
      if (typeof onProgress === "function") {
        onProgress(`still uploading… ${sec}s · ${mbTotal} MB → ${peer}`);
      }
    }, 15000);

    const handleLine = (line) => {
      const s = String(line || "").trim();
      if (!s) return;
      try {
        const j = JSON.parse(s);
        if (j && j.progress && j.total) {
          const pct = Math.min(99, Math.floor((100 * Number(j.current || 0)) / Number(j.total)));
          if (pct >= lastPct + 5 || pct >= 99) {
            lastPct = pct;
            const curMb = (Number(j.current || 0) / 1024 / 1024).toFixed(1);
            if (typeof onProgress === "function") {
              onProgress(`uploading ${pct}% (${curMb}/${mbTotal} MB)`);
            }
          }
          return;
        }
        if (j && typeof j.ok === "boolean") {
          // Keep staging chat_id from Python (channel / bot DM) — do NOT overwrite
          // with the requester chatId (that broke copyMessage for other users).
          if (j.ok && j.chat_id == null) j.chat_id = String(chatId);
          if (!j.ok && j.description) j.description = premiumFailDescription(j.description);
          finish(j);
          return;
        }
      } catch {
        /* non-JSON log line */
      }
      stdout += s + "\n";
    };

    let buf = "";
    child.stdout.on("data", (chunk) => {
      buf += chunk.toString("utf8");
      const parts = buf.split(/\r?\n/);
      buf = parts.pop() || "";
      for (const p of parts) handleLine(p);
    });
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", (err) => {
      finish({ ok: false, description: String((err && err.message) || err) });
    });
    child.on("close", (code) => {
      if (settled) return;
      if (buf.trim()) handleLine(buf);
      if (settled) return;
      const out = stdout.trim();
      const err = stderr.trim();
      if (code === 0) {
        try {
          const lines = out.split(/\n/).filter(Boolean);
          const parsed = JSON.parse(lines[lines.length - 1] || "{}");
          if (parsed && parsed.ok && parsed.chat_id == null) parsed.chat_id = String(chatId);
          finish(parsed && typeof parsed.ok === "boolean" ? parsed : { ok: true, chat_id: String(chatId) });
          return;
        } catch {
          finish({ ok: true, description: out.slice(0, 200), chat_id: String(chatId) });
          return;
        }
      }
      finish({
        ok: false,
        description: premiumFailDescription(err || out || `premium upload exit ${code}`),
      });
    });
  });
}

async function sendDocumentPremium(chatId, filePath, fileName, caption, opts = {}) {
  const peers = premiumPeerCandidates();
  if (!peers.length) {
    return {
      ok: false,
      description:
        "Bot id/username unknown — Premium upload needs getMe(). Check TELEGRAM_BOT_TOKEN.",
    };
  }
  let last = null;
  for (let i = 0; i < peers.length; i++) {
    const peer = peers[i];
    if (i > 0 && typeof opts.onProgress === "function") {
      opts.onProgress(`retry Premium peer ${peer}…`);
    }
    last = await sendDocumentPremiumOnce(chatId, filePath, fileName, caption, peer, opts);
    if (last && last.ok) return last;
    const why = premiumFailDescription(last && last.description);
    console.warn(`[job] Premium peer ${peer} failed:`, why);
    // Only retry on resolve/username misses; other errors (auth, network) won't help.
    if (!/username not found|peer|resolve|get_chat|invalid peer/i.test(why)) break;
  }
  return last || { ok: false, description: "Premium upload failed" };
}

function preferPremiumUpload() {
  // Default ON whenever a Premium user session is configured — bots can't use
  // Premium storage; the user account uploads ≤4 GB into Telegram cloud.
  // Set TELEGRAM_PREMIUM_UPLOAD=0 to force Bot API instead.
  if (!premiumUploadConfigured()) return false;
  const flag = String(process.env.TELEGRAM_PREMIUM_UPLOAD || "1").trim();
  return flag !== "0" && flag.toLowerCase() !== "false" && flag.toLowerCase() !== "off";
}

async function sendDocument(chatId, filePath, fileName, caption, extras = {}) {
  const stat = fs.statSync(filePath);
  const mb = (stat.size / 1024 / 1024).toFixed(1);
  const card = extras.card || null;
  const say =
    typeof extras.onProgress === "function"
      ? extras.onProgress
      : card
        ? async (t) => {
            const m = /(\d+)\s*%/.exec(String(t || ""));
            if (m) await card.setUploadPct(Number(m[1]));
            else if (/upload/i.test(String(t || ""))) await card.setStage("Uploading…", 78);
          }
        : async () => {
            /* quiet — progress lives on the card */
          };

  // Always prefer Premium *user* MTProto when session is set (unlimited cloud + ≤4 GB).
  if (preferPremiumUpload()) {
    if (stat.size > 4 * 1024 * 1024 * 1024) {
      return {
        ok: false,
        description: `IPA is ${mb} MB — over Telegram Premium’s 4 GB document cap. Saved: ${filePath}`,
        tooLarge: true,
      };
    }
    const peer = premiumPeer() || "unset";
    const stageViaChannel = premiumChannelConfigured();
    console.log(
      `[job] uploading via Premium session (${mb} MB) → ${peer}` +
        (stageViaChannel ? " (secret channel)" : " (bot DM fallback)")
    );
    if (card) await card.setStage("Uploading…", 76);
    else await say(`uploading via Premium → ${peer} (${mb} MB)…`);
    // Stage via Premium user MTProto into the secret channel (or bot DM).
    // Bot then copyMessage's from the staging chat into the requester chat and
    // re-sends by file_id so Patch/Get VIP tabs stick.
    const markup = extras.replyMarkup || resultKeyboard();
    const prem = await sendDocumentPremium(chatId, filePath, fileName, caption || "", {
      thumbPath: extras.thumbPath,
      replyMarkup: markup,
      onProgress: (t) => {
        say(t);
      },
    });
    if (prem && prem.ok && prem.message_id) {
      const stagedId = Number(prem.message_id);
      const stageChat = String(prem.chat_id || peer || "");
      const keepStage =
        String(process.env.TELEGRAM_UPLOAD_CHANNEL_KEEP || "").trim() === "1";
      let copied = null;
      for (let attempt = 0; attempt < 6; attempt++) {
        if (attempt) await new Promise((r) => setTimeout(r, 700 * attempt));
        // Copy FROM staging chat (channel / Premium↔bot DM) TO the requester.
        copied = await tgApi("copyMessage", {
          chat_id: chatId,
          from_chat_id: stageChat,
          message_id: stagedId,
        }).catch((e) => ({ ok: false, description: String((e && e.message) || e) }));
        if (!(copied && copied.ok && copied.result && copied.result.message_id)) continue;

        const bridgeMid = copied.result.message_id;
        const fileId =
          (copied.result.document && copied.result.document.file_id) ||
          (copied.result.video && copied.result.video.file_id) ||
          String(prem.file_id || "") ||
          "";

        let finalMid = bridgeMid;
        let finalResult = copied.result;

        if (fileId) {
          const resent = await sendIpaByFileId(chatId, fileId, caption || "", markup);
          if (resent && resent.ok && resent.result && resent.result.message_id) {
            await tgApi("deleteMessage", { chat_id: chatId, message_id: bridgeMid }).catch(() => {});
            finalMid = resent.result.message_id;
            finalResult = resent.result;
          } else {
            console.warn(
              "[job] sendDocument(file_id) failed:",
              (resent && resent.description) || "unknown"
            );
            await ensureIpaButtonTabs(chatId, bridgeMid, {
              caption: caption || "",
              replyMarkup: markup,
            });
            if (caption) {
              await tgApi("editMessageCaption", {
                chat_id: chatId,
                message_id: bridgeMid,
                caption,
                parse_mode: "HTML",
                reply_markup: markup,
              }).catch(() => {});
            }
          }
        } else {
          await ensureIpaButtonTabs(chatId, bridgeMid, {
            caption: caption || "",
            replyMarkup: markup,
          });
          if (caption) {
            await tgApi("editMessageCaption", {
              chat_id: chatId,
              message_id: bridgeMid,
              caption,
              parse_mode: "HTML",
              reply_markup: markup,
            }).catch(() => {});
          }
        }

        if (!keepStage && stageChat) {
          await tgApi("deleteMessage", {
            chat_id: stageChat,
            message_id: stagedId,
          }).catch(() => {});
        }
        console.log(
          "[job] bot produced IPA with tabs",
          finalMid,
          fileId ? "via file_id" : "via copy",
          `stage=${stageChat}`
        );
        return {
          ok: true,
          premium: true,
          bot_resent: true,
          staged_via_channel: stageViaChannel,
          message_id: finalMid,
          chat_id: String(chatId),
          result: finalResult,
        };
      }
      // Channel/bot can't copy — leave staged file; don't dump raw Premium bubble on user.
      console.warn(
        "[job] bot copyMessage from stage failed:",
        (copied && copied.description) || "unknown",
        `stage=${stageChat} mid=${stagedId}`
      );
      return {
        ok: false,
        description:
          `Premium uploaded to stage (${stageChat}) but bot couldn't copy to this chat. ` +
          `Add @${BOT_USERNAME || "FastDecryptAI"} as admin on TELEGRAM_UPLOAD_CHANNEL. ` +
          `Saved on Mac: ${filePath}`,
        tooLarge: true,
        bytes: stat.size,
      };
    }
    if (prem && prem.ok) {
      return {
        ...prem,
        premium: true,
        message_id: prem.message_id,
        chat_id: prem.chat_id || chatId,
        result: {
          message_id: prem.message_id,
          document: null,
        },
      };
    }
    console.warn("[job] premium session upload failed:", prem && prem.description);
    // Fall through to Bot API only for small files; large ones cannot use cloud Bot API.
    if (stat.size > 49 * 1024 * 1024 && !LOCAL_API) {
      return {
        ok: false,
        description:
          `Premium session upload failed: ${String((prem && prem.description) || "unknown").slice(0, 180)}. ` +
          `Saved on Mac: ${filePath}`,
        tooLarge: true,
        bytes: stat.size,
      };
    }
  }

  if (stat.size > TG_DOC_MAX) {
    const hint = premiumUploadConfigured()
      ? premiumChannelConfigured()
        ? "Premium+channel upload failed — check @bot is admin on TELEGRAM_UPLOAD_CHANNEL."
        : "Premium session is loaded — set TELEGRAM_UPLOAD_CHANNEL to a private channel (add @bot as admin), then restart."
      : LOCAL_API
        ? `Local Bot API cap is ~${Math.round(TG_DOC_MAX / 1024 / 1024)} MB.`
        : "Cloud Bot API caps ~50 MB. On Mac: zsh server/mac-ssh.sh session 'https://t.me/+YOUR_INVITE' (Premium login + staging channel), add @bot as channel admin, restart";
    return {
      ok: false,
      description: `IPA is ${mb} MB — ${hint}. Saved on Mac: ${filePath}`,
      tooLarge: true,
      bytes: stat.size,
    };
  }

  const markup = extras.replyMarkup || resultKeyboard();
  const botSent = await sendDocumentBotApi(chatId, filePath, fileName, caption, {
    ...extras,
    replyMarkup: markup,
  });
  if (botSent && botSent.ok && botSent.result && botSent.result.message_id) {
    const fileId = (botSent.result.document && botSent.result.document.file_id) || "";
    if (fileId) {
      const resent = await sendIpaByFileId(chatId, fileId, caption || "", markup);
      if (resent && resent.ok && resent.result && resent.result.message_id) {
        await tgApi("deleteMessage", {
          chat_id: chatId,
          message_id: botSent.result.message_id,
        }).catch(() => {});
        return resent;
      }
    }
    await ensureIpaButtonTabs(chatId, botSent.result.message_id, {
      caption: caption || "",
      replyMarkup: markup,
    });
  }
  return botSent;
}

function downloadTelegramFile(filePathOnTg, dest) {
  return new Promise((resolve, reject) => {
    const url = LOCAL_API
      ? // Local Bot API may return absolute paths from getFile.
        (filePathOnTg.startsWith("/")
          ? null
          : `${API_ROOT}/file/bot${BOT_TOKEN}/${filePathOnTg}`)
      : `${API_ROOT}/file/bot${BOT_TOKEN}/${filePathOnTg}`;
    if (!url && filePathOnTg.startsWith("/")) {
      fs.copyFile(filePathOnTg, dest, (err) => (err ? reject(err) : resolve(dest)));
      return;
    }
    const file = fs.createWriteStream(dest);
    const lib = String(url).startsWith("http:") ? http : https;
    lib
      .get(url, (res) => {
        if (res.statusCode !== 200) {
          reject(new Error(`Telegram file HTTP ${res.statusCode}`));
          res.resume();
          return;
        }
        res.pipe(file);
        file.on("finish", () => file.close(() => resolve(dest)));
      })
      .on("error", reject);
  });
}

function chatAllowed(chatId) {
  // Public by default. Only restrict when TELEGRAM_LOCKDOWN=1 + ALLOWED_IDS set.
  if (!LOCKDOWN || !ALLOWED.length) return true;
  return ALLOWED.includes(String(chatId));
}

function isStoreUrl(t) {
  return /^https:\/\/(?:apps|itunes)\.apple\.com\//i.test(String(t || "").trim());
}

function isTestFlightUrl(t) {
  return /testflight\.apple\.com/i.test(String(t || ""));
}

function startScreenText() {
  // AppAssassin-style /start welcome.
  return (
    `👋 Welcome! This bot can decrypt iOS apps from the App Store.\n\n` +
    `📌 <b>To get started:</b>\n` +
    `• Send an App Store link <b>or just the app name</b> (e.g. <code>Vinted</code>).\n` +
    `• Optional version: <code>Vinted 26.45.0</code> or <code>Vinted v26.45.0</code>.\n` +
    `• Free users get ${tgVip.FREE_DAILY} decryptions per day (up to ${(tgVip.FREE_MAX_BYTES / (1024 * 1024 * 1024)).toFixed(0)} GB each).\n` +
    `• ⭐ VIP is timed (7 / 30 / 90 / 180 / 365 days) — unlimited while active, with a countdown on /vip.\n` +
    `• ⭐ VIP: no size cap · older versions · TestFlight IPA drop.\n` +
    `• Use /vip to check time remaining or how to upgrade.\n` +
    `🌍 Supported App Store regions: HK, US, CA, PL, CN, AU, DE, FR, VN, JP, RU`
  );
}

/** Best-effort: remove the user's pasted URL from the private chat. */
async function deleteUserMessage(chatId, messageId) {
  const mid = Number(messageId);
  if (!chatId || !mid) return false;
  for (let attempt = 0; attempt < 3; attempt++) {
    if (attempt) await new Promise((r) => setTimeout(r, 350 * attempt));
    const r = await tgApi("deleteMessage", {
      chat_id: chatId,
      message_id: mid,
    }).catch((e) => ({ ok: false, description: String((e && e.message) || e) }));
    if (r && r.ok) return true;
    console.warn(
      "[chat] deleteMessage failed:",
      (r && r.description) || "unknown",
      `attempt=${attempt + 1}`
    );
  }
  return false;
}

function rememberStoreUrl(chatId, link, vreq) {
  const meta = lookupStoreApp(link);
  return urlLog.add(chatId, {
    storeUrl: link,
    version: vreq || "latest",
    name: meta.name || "",
    adam: urlLog.adamFromStoreUrl(link) || ipaCache.adamFromStoreUrl(link),
  });
}

/**
 * Resolve a typed version (marketing "8.12.0" or numeric external id) to the
 * external-version-id ipatool expects. Empty → latest.
 */
async function resolveExternalVersionId(link, vreq) {
  const raw = String(vreq || "").trim();
  if (!raw) return "";
  if (/^\d{6,}$/.test(raw)) return raw;
  try {
    const listed = await ipatoolExtras.listVersions({ url: link });
    const versions = (listed && listed.versions) || [];
    const hit = versions.find(
      (v) =>
        String(v.v || "") === raw ||
        String(v.version || "") === raw ||
        String(v.label || "") === raw ||
        String(v.externalVersionId || v.external_id || "") === raw
    );
    if (hit) {
      return String(hit.externalVersionId || hit.external_id || "").trim();
    }
  } catch (e) {
    console.warn("[versions] resolve failed:", (e && e.message) || e);
  }
  // Fall through — ipatool may accept marketing version on some builds.
  return raw;
}

/** Versions painted on each sharp-card page (numbered 1…N for typed replies). */
const VER_PAGE_SIZE = 8;
const VERSION_ICON_DIR =
  process.env.MAC_TG_VERSION_ICON_DIR ||
  path.join(os.homedir(), "tetherless-ipa-cache", "version-icons");

function versionIconCachePath(adam, extOrVer) {
  const a = String(adam || "app").replace(/[^\w.-]+/g, "_") || "app";
  const v = String(extOrVer || "latest").replace(/[^\w.-]+/g, "_") || "latest";
  return path.join(VERSION_ICON_DIR, a, `${v}.png`);
}

function rememberVersionIcon(adam, keys, iconPath) {
  if (!adam || !iconPath || !fs.existsSync(iconPath)) return "";
  try {
    fs.mkdirSync(path.join(VERSION_ICON_DIR, String(adam).replace(/[^\w.-]+/g, "_") || "app"), {
      recursive: true,
    });
    let saved = "";
    for (const key of keys || []) {
      const k = String(key || "").trim();
      if (!k) continue;
      const dest = versionIconCachePath(adam, k);
      try {
        fs.copyFileSync(iconPath, dest);
        saved = dest;
      } catch {
        /* ignore */
      }
    }
    return saved || iconPath;
  } catch {
    return iconPath;
  }
}

/**
 * Resolve THIS build’s icon for the version sharp card:
 * cached icon → clear IPA cache → encrypted IPA cache → extract.
 */
function resolveVersionBuildIcon(adam, pick, fallbackIcon) {
  const keys = [
    pick && pick.ext,
    pick && pick.marketing,
    pick && pick.marketing && `v${pick.marketing}`,
  ].filter(Boolean);
  for (const key of keys) {
    const cached = versionIconCachePath(adam, key);
    if (fs.existsSync(cached) && fs.statSync(cached).size > 100) return cached;
  }

  // Clear IPA cache entry (by marketing version).
  try {
    const hit =
      (pick && pick.marketing && ipaCache.get(adam, pick.marketing)) ||
      (pick && pick.ext && ipaCache.get(adam, pick.ext)) ||
      null;
    if (hit) {
      if (hit.iconPath && fs.existsSync(hit.iconPath)) {
        return rememberVersionIcon(adam, keys, hit.iconPath);
      }
      if (hit.diskPath && fs.existsSync(hit.diskPath)) {
        const dest = versionIconCachePath(adam, pick.ext || pick.marketing || "x");
        const got = extractIpaIcon(hit.diskPath, dest);
        if (got) return rememberVersionIcon(adam, keys, got);
      }
    }
  } catch {
    /* ignore */
  }

  // Encrypted IPA cache for this build.
  try {
    for (const key of [pick && pick.marketing, pick && pick.ext, "latest"]) {
      if (!key) continue;
      const enc = ipaCache.getEncryptedPath(adam, key);
      if (!enc) continue;
      // Don't use "latest" encrypted for non-current older rows — wrong icon.
      if (key === "latest" && pick && !pick.current) continue;
      const dest = versionIconCachePath(adam, pick.ext || pick.marketing || key);
      const got = extractIpaIcon(enc, dest);
      if (got) return rememberVersionIcon(adam, keys, got);
    }
  } catch {
    /* ignore */
  }

  return (fallbackIcon && fs.existsSync(fallbackIcon) && fallbackIcon) || "";
}

/** Pull missing build icons from encrypted IPA (ipatool) then refresh the card. */
function warmVersionIconsForPage(pending, slice) {
  const adam = pending.adam || ipaCache.adamFromStoreUrl(pending.url) || "";
  if (!adam || !slice || !slice.length) return;
  const missing = slice.filter((p) => !p.iconPath || !fs.existsSync(p.iconPath));
  if (!missing.length) return;

  const run = async () => {
    let changed = false;
    for (const pick of missing.slice(0, VER_PAGE_SIZE)) {
      // Still the same carousel page?
      if (!pendingVerPicks.has(pending.token)) return;
      if ((pending.page || 0) !== (pending._warmingPage ?? (pending.page || 0))) return;
      try {
        const dir = fs.mkdtempSync(path.join(WORK, "iconwarm-"));
        try {
          if (typeof fairplayBackends.unlockKeychain === "function") {
            fairplayBackends.unlockKeychain();
          }
          await fairplayBackends.ensureEncryptedSource({
            url: pending.url,
            dir,
            say: () => {},
            vreq: pick.ext || "",
          });
          const enc = path.join(dir, "encrypted-source.ipa");
          if (!fs.existsSync(enc)) continue;
          const dest = versionIconCachePath(adam, pick.ext || pick.marketing || "x");
          const got = extractIpaIcon(enc, dest);
          if (got) {
            pick.iconPath = rememberVersionIcon(
              adam,
              [pick.ext, pick.marketing],
              got
            );
            changed = true;
            console.log("[icon] warmed version", pick.marketing || pick.ext, pick.iconPath);
          }
        } finally {
          try {
            fs.rmSync(dir, { recursive: true, force: true });
          } catch {
            /* ignore */
          }
        }
      } catch (e) {
        console.warn("[icon] warm failed:", (e && e.message) || e);
      }
    }
    if (changed && pendingVerPicks.has(pending.token) && pending.messageId) {
      await paintVersionCarousel(pending, pending.page || 0, {
        messageId: pending.messageId,
        warm: false,
      }).catch(() => {});
    }
  };

  pending._warmingPage = pending.page || 0;
  Promise.resolve()
    .then(run)
    .catch((e) => console.warn("[icon] warm:", (e && e.message) || e));
}

function versionCarouselPages(pending) {
  return Math.max(1, Math.ceil((pending.picks || []).length / VER_PAGE_SIZE));
}

function versionCarouselSlice(pending, page) {
  const pages = versionCarouselPages(pending);
  const p = Math.max(0, Math.min(pages - 1, page));
  const start = p * VER_PAGE_SIZE;
  return {
    page: p,
    pages,
    start,
    slice: (pending.picks || []).slice(start, start + VER_PAGE_SIZE),
  };
}

/** Nav only — versions are on the sharp card; user replies with a number. */
function versionPickKeyboard(token, pending, page) {
  const { pages, page: p } = versionCarouselSlice(pending, page);
  const latestLabel = pending.mode === "library" ? "⬇ Latest" : "⭐ Latest";
  const rows = [[{ text: latestLabel, callback_data: `ver:${token}:L`.slice(0, 64) }]];
  const nav = [];
  if (p > 0) {
    nav.push({ text: "◀ Back", callback_data: `ver:${token}:p:${p - 1}`.slice(0, 64) });
  }
  nav.push({
    text: `${p + 1}/${pages}`,
    callback_data: `ver:${token}:p:${p}`.slice(0, 64),
  });
  if (p < pages - 1) {
    nav.push({ text: "Next ▶", callback_data: `ver:${token}:p:${p + 1}`.slice(0, 64) });
  }
  rows.push(nav);
  return { inline_keyboard: rows };
}

async function renderVersionCarouselPage(pending, page) {
  const { page: p, pages, slice } = versionCarouselSlice(pending, page);
  const adam = pending.adam || ipaCache.adamFromStoreUrl(pending.url) || "";
  const dest = path.join(
    WORK,
    `${pending.mode === "library" ? "libpick" : "verpick"}-${pending.chatId}-${
      pending.token || "x"
    }-p${p}-${Date.now()}.jpg`
  );
  // Attach each build’s real icon when we have/can extract it.
  for (const pick of slice) {
    if (pick.iconPath && fs.existsSync(pick.iconPath)) continue;
    pick.iconPath = resolveVersionBuildIcon(adam, pick, pending.iconPath || "");
  }
  const versions = slice.map((pick, idx) => ({
    n: idx + 1,
    label: pick.marketing || String(pick.label || "").replace(/^⭐\s*Latest\s*·\s*/i, "") || "—",
    current: !!pick.current,
    iconPath: pick.iconPath || "",
  }));
  if (pending.mode === "library") {
    return renderLibraryAppBanner({
      title: pending.title,
      bid: pending.bid || "",
      iconPath: pending.iconPath || "",
      versions,
      page: p + 1,
      pages,
      total: pending.picks.length,
      dest,
    });
  }
  return renderVersionPickerBanner({
    title: pending.title,
    iconPath: pending.iconPath || "",
    versions,
    page: p + 1,
    pages,
    total: pending.picks.length,
    dest,
  });
}

async function paintVersionCarousel(pending, page, { messageId, warm = true } = {}) {
  const { page: p, slice } = versionCarouselSlice(pending, page);
  pending.page = p;
  pending.expires = Date.now() + 20 * 60 * 1000;
  const reply_markup = versionPickKeyboard(pending.token, pending, p);
  // Caption stays minimal — versions + build icons are painted on the card.
  const caption =
    pending.mode === "library"
      ? `<b>${escapeHtml(pending.title || "App")}</b>\n` +
        `Reply with a number to pull · or Next / Back`
      : `<b>${escapeHtml(pending.title || "App")}</b>\n` +
        `Reply with a number · or Next / Back`;

  let ok = false;
  const img = await renderVersionCarouselPage(pending, p);
  if (img && fs.existsSync(img)) {
    if (messageId) {
      const edited = await editMessageMediaBotApi(
        pending.chatId,
        messageId,
        img,
        caption,
        reply_markup
      );
      if (edited && edited.ok) {
        pending.hasPhoto = true;
        pending.messageId = messageId;
        ok = true;
      }
    } else {
      const sent = await sendPhotoBotApi(pending.chatId, img, caption, reply_markup);
      if (sent && sent.ok && sent.result && sent.result.message_id) {
        pending.hasPhoto = true;
        pending.messageId = sent.result.message_id;
        ok = true;
      }
    }
  }

  if (!ok) {
    // Text fallback.
    const lines = versionCarouselSlice(pending, p).slice.map(
      (pick, idx) => `${idx + 1}. ${pick.label}`
    );
    const heading = pending.mode === "library" ? "LIBRARY" : "VERSIONS";
    const hint =
      pending.mode === "library"
        ? "_Reply with a number to pull_"
        : "_Reply with a number_";
    const text = `*${heading}*\n${pending.title}\n\n${lines.join("\n")}\n\n${hint}`;
    if (messageId && !pending.hasPhoto) {
      await tgApi("editMessageText", {
        chat_id: pending.chatId,
        message_id: messageId,
        text,
        parse_mode: "Markdown",
        reply_markup,
      }).catch(() => {});
    } else {
      await tgApi("sendMessage", {
        chat_id: pending.chatId,
        text,
        parse_mode: "Markdown",
        reply_markup,
      });
    }
  }

  // Fetch missing older build icons from encrypted IPAs, then refresh the card.
  // Library pulls from cache only — don't kick ipatool icon warm.
  if (warm && pending.mode !== "library") warmVersionIconsForPage(pending, slice);
  return ok;
}

/** Timbrd/Bilin/iosdump — version sharp-card carousel before decrypt progress card. */
async function offerVersionPick(chatId, link) {
  pruneVerPicks();
  // Close any prior carousel for this chat.
  const prevTok = activeVerPickByChat.get(chatId);
  if (prevTok && pendingVerPicks.has(prevTok)) {
    const prev = pendingVerPicks.get(prevTok);
    if (prev && prev.messageId) {
      await tgApi("deleteMessage", {
        chat_id: chatId,
        message_id: prev.messageId,
      }).catch(() => {});
    }
    pendingVerPicks.delete(prevTok);
  }
  activeVerPickByChat.delete(chatId);

  const wait = await tgApi("sendMessage", {
    chat_id: chatId,
    text: "Loading versions…",
  }).catch(() => null);
  const waitId = wait && wait.ok && wait.result && wait.result.message_id;

  let listed;
  try {
    listed = await ipatoolExtras.listVersions({ url: link });
  } catch (e) {
    console.warn("[versions] list failed:", (e && e.message) || e);
    listed = { title: "App", versions: [] };
  }
  const versions = Array.isArray(listed.versions) ? listed.versions : [];
  const storeMeta = lookupStoreApp(link);
  const title = String(
    (listed && listed.title) || storeMeta.name || "App"
  )
    .replace(/[*_`\[\]]/g, "")
    .trim() || "App";

  if (waitId) {
    await tgApi("deleteMessage", { chat_id: chatId, message_id: waitId }).catch(() => {});
  }

  // No history feeds → decrypt latest immediately (same as before).
  if (!versions.length) {
    await withWorker(chatId, async () => {
      await decryptStoreUrl(chatId, link, "");
    });
    return;
  }

  const adamForCache = storeMeta.adam || ipaCache.adamFromStoreUrl(link) || "";
  let picks = versions.map((v, i) => {
    const ver = String(v.v || v.version || v.label || "—").slice(0, 24);
    const ext = String(v.externalVersionId || v.external_id || "").trim();
    const marketing = isExternalVersionId(ver) ? "" : ver;
    let label = v.current ? `⭐ Latest · ${ver}` : `v${ver}`;
    // Speed markers: clear cache = instant pull; encrypted = skip CDN on decrypt.
    try {
      const clearHit =
        (marketing && ipaCache.get(adamForCache, marketing)) ||
        (ext && ipaCache.get(adamForCache, ext));
      const encHit =
        (marketing && ipaCache.getEncryptedPath(adamForCache, marketing)) ||
        (ext && ipaCache.getEncryptedPath(adamForCache, ext)) ||
        (v.current && ipaCache.getEncryptedPath(adamForCache, "latest"));
      if (clearHit) label = `💾 ${label}`;
      else if (encHit) label = `⬇ ${label}`;
    } catch {
      /* ignore */
    }
    return {
      i,
      label: label.slice(0, 64),
      ext,
      marketing,
      current: !!v.current,
    };
  });
  // Free tier: latest only (VIP unlocks full history).
  if (!tgVip.isVip(chatId)) {
    const latest = picks.find((p) => p.current) || picks[0];
    picks = latest ? [latest] : [];
  }
  // Warm encrypted cache for latest in the background (feature 2) when missing.
  try {
    const extras = require("./mac-ipatool-extras");
    const latest = picks.find((p) => p.current) || picks[0];
    const verKey = (latest && (latest.marketing || latest.ext)) || "latest";
    const enc =
      adamForCache &&
      (ipaCache.getEncryptedPath(adamForCache, verKey) ||
        ipaCache.getEncryptedPath(adamForCache, "latest"));
    if (!enc && adamForCache) {
      extras.enqueuePrefetch({ url: link, version: (latest && latest.ext) || "", priority: 3 });
    }
  } catch {
    /* ignore */
  }

  const token = crypto.randomBytes(5).toString("hex");
  const pending = {
    token,
    chatId,
    url: link,
    adam: storeMeta.adam || ipaCache.adamFromStoreUrl(link) || "",
    title,
    iconPath: storeMeta.iconPath || "",
    picks,
    page: 0,
    hasPhoto: false,
    messageId: 0,
    expires: Date.now() + 20 * 60 * 1000,
  };
  pendingVerPicks.set(token, pending);
  activeVerPickByChat.set(chatId, token);

  await paintVersionCarousel(pending, 0);
}

async function startDecryptFromVersionPick(pending, { vreq, versionLabel, label, pick }) {
  const chatId = pending.chatId;
  pendingVerPicks.delete(pending.token);
  activeVerPickByChat.delete(chatId);
  if (pending.messageId) {
    await tgApi("deleteMessage", {
      chat_id: chatId,
      message_id: pending.messageId,
    }).catch(() => {});
  }

  if (
    pending.mode !== "library" &&
    pick &&
    !pick.current &&
    !tgVip.isVip(chatId)
  ) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text: `Older versions need VIP — /vip\n${tgVip.VIP_URL}`,
      disable_web_page_preview: true,
    }).catch(() => {});
    return;
  }

  // /library AppName pick → re-send cached decrypted IPA (no re-decrypt).
  if (pending.mode === "library") {
    let entry =
      (pick && pick.entry) ||
      (versionLabel && pending.adam && ipaCache.get(pending.adam, versionLabel)) ||
      null;
    if (!entry && pick && pick.marketing && pending.adam) {
      entry = ipaCache.get(pending.adam, pick.marketing);
    }
    if (!entry && pending.adam) {
      // Latest cached for this adam.
      entry = ipaCache.get(pending.adam, "latest");
    }
    if (!entry) {
      await tgApi("sendMessage", {
        chat_id: chatId,
        text: "That build isn’t in the library cache anymore — paste the Apple Store URL to decrypt again.",
      }).catch(() => {});
      return;
    }
    await withWorker(chatId, async () => {
      await sendCachedEntry(chatId, entry);
    });
    console.log(
      "[library] pulled",
      label || versionLabel || entry.version || "latest",
      "→ cache send"
    );
    return;
  }

  rememberStoreUrl(chatId, pending.url, versionLabel || "latest");
  await withWorker(chatId, async () => {
    await decryptStoreUrl(chatId, pending.url, vreq || "", {
      versionLabel: versionLabel || "",
    });
  });
  console.log("[versions] picked", label || versionLabel || "latest", "→ decrypt card");
}

/** Typed number while a version carousel is open (1…pageSize on the current card). */
async function tryHandleVersionNumberReply(chatId, text, messageId) {
  pruneVerPicks();
  const token = activeVerPickByChat.get(chatId);
  if (!token) return false;
  const pending = pendingVerPicks.get(token);
  if (!pending || pending.chatId !== chatId) {
    activeVerPickByChat.delete(chatId);
    return false;
  }
  const raw = String(text || "").trim();
  if (!/^\d{1,2}$/.test(raw)) return false;
  const n = Number(raw);
  const { slice } = versionCarouselSlice(pending, pending.page || 0);
  if (n < 1 || n > slice.length) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text: `Reply with 1–${slice.length} for this page (or tap Next / Back).`,
      reply_to_message_id: messageId || undefined,
    }).catch(() => {});
    return true;
  }
  const pick = slice[n - 1];
  await deleteUserMessage(chatId, messageId);
  await startDecryptFromVersionPick(pending, {
    vreq: pick.ext || "",
    versionLabel: pick.marketing || "",
    label: pick.marketing ? `v${pick.marketing}` : pick.label,
    pick,
  });
  return true;
}

async function handleVersionPick(cq, data) {
  const chatId = cq.message && cq.message.chat && cq.message.chat.id;
  const parts = data.split(":");
  // ver:<token>:L | ver:<token>:p:<page>
  const token = parts[1] || "";
  const kind = parts[2] || "";
  const arg = parts[3] || "";
  pruneVerPicks();
  const pending = pendingVerPicks.get(token);
  if (!pending || pending.chatId !== chatId) {
    await tgApi("answerCallbackQuery", {
      callback_query_id: cq.id,
      text: "Version list expired — paste the link again",
      show_alert: true,
    }).catch(() => {});
    return;
  }

  // Flip the sharp card to another page of versions.
  if (kind === "p") {
    const pages = versionCarouselPages(pending);
    const page = Math.max(0, Math.min(pages - 1, Number(arg) || 0));
    await tgApi("answerCallbackQuery", { callback_query_id: cq.id }).catch(() => {});
    const mid = (cq.message && cq.message.message_id) || pending.messageId;
    await paintVersionCarousel(pending, page, { messageId: mid });
    return;
  }

  if (kind === "L") {
    const latestPick =
      (pending.picks || []).find((p) => p && p.current) || (pending.picks || [])[0] || null;
    await tgApi("answerCallbackQuery", {
      callback_query_id: cq.id,
      text: pending.mode === "library" ? "Pulling Latest…" : "Decrypting Latest…",
    }).catch(() => {});
    await startDecryptFromVersionPick(pending, {
      vreq: pending.mode === "library" ? "" : "",
      versionLabel: (latestPick && latestPick.marketing) || "",
      label: "Latest",
      pick: latestPick,
    });
    return;
  }

  await tgApi("answerCallbackQuery", {
    callback_query_id: cq.id,
    text: "Reply with a number on the card",
    show_alert: true,
  }).catch(() => {});
}

async function sendHistoryList(chatId) {
  const items = urlLog.list(chatId, 20);
  if (!items.length) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text:
        "History is empty — paste an App Store URL.\n" +
        "Links are deleted from chat but kept here so you can tap to decrypt again.",
    });
    return;
  }
  const lines = items.map((it, i) => {
    const label = it.name || `App ${it.adam || "?"}`;
    const ver = it.version && it.version !== "latest" ? ` v${it.version}` : "";
    const when = it.at ? new Date(it.at).toLocaleString() : "";
    return `${i + 1}. *${label.replace(/[*_`]/g, "")}*${ver}${when ? ` · ${when}` : ""}`;
  });
  const rows = items.slice(0, 12).map((it) => {
    const label = String(it.name || it.adam || "App")
      .split(/\s+[—\-–]\s+/)[0]
      .slice(0, 28);
    const ver = it.version && it.version !== "latest" ? ` v${it.version}` : "";
    return [
      {
        text: `🔁 ${label}${ver}`.slice(0, 64),
        callback_data: `hist:${it.id}`.slice(0, 64),
      },
    ];
  });
  await tgApi("sendMessage", {
    chat_id: chatId,
    text:
      `*History* — tap to decrypt again\n\n` +
      lines.join("\n") +
      `\n\n_Tap a button to decrypt again_`,
    parse_mode: "Markdown",
    reply_markup: { inline_keyboard: rows },
  });
}

async function sendStart(chatId) {
  await tgApi("sendMessage", {
    chat_id: chatId,
    text: startScreenText(),
    parse_mode: "HTML",
    disable_web_page_preview: true,
  });
}

async function sendCacheList(chatId) {
  const items = ipaCache.list().slice(0, 30);
  if (!items.length) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text: "Cache is empty — paste an App Store URL to start.",
    });
    return;
  }
  const lines = items.map((it, i) => {
    const mb = it.bytes ? `${(it.bytes / 1024 / 1024).toFixed(1)} MB` : "?";
    const cloud = it.fileId || it.messageId ? "☁️" : "💾";
    return `${i + 1}. ${cloud} *${(it.name || "App").replace(/[*_`]/g, "")}* · v${it.version || "?"} · ${mb}`;
  });
  await tgApi("sendMessage", {
    chat_id: chatId,
    text: `*Cache* (${items.length})\n\n` + lines.join("\n"),
    parse_mode: "Markdown",
  });
}

/**
 * Resolve a durable icon for a library cache entry (iconPath → IPA extract → store).
 */
function resolveLibraryEntryIcon(entry, adam, fallbackIcon) {
  if (!entry) return (fallbackIcon && fs.existsSync(fallbackIcon) && fallbackIcon) || "";
  if (entry.iconPath && fs.existsSync(entry.iconPath) && fs.statSync(entry.iconPath).size > 100) {
    return entry.iconPath;
  }
  if (entry.diskPath && fs.existsSync(entry.diskPath)) {
    const dest = versionIconCachePath(
      adam || entry.adam || "app",
      entry.version || path.basename(entry.diskPath, ".ipa") || "x"
    );
    const got = extractIpaIcon(entry.diskPath, dest);
    if (got) {
      try {
        entry.iconPath = got;
      } catch {
        /* ignore */
      }
      return got;
    }
  }
  return (fallbackIcon && fs.existsSync(fallbackIcon) && fallbackIcon) || "";
}

/**
 * Group decrypted IPA cache entries into library apps (by adam).
 * Skips external-version-id noise and the synthetic "latest" key.
 */
function libraryAppsFromCache() {
  const byAdam = new Map();
  for (const it of ipaCache.list()) {
    if (!it || !it.adam) continue;
    const ver = String(it.version || "")
      .trim()
      .replace(/^v/i, "");
    if (!ver || ver.toLowerCase() === "latest" || isExternalVersionId(ver)) continue;
    let app = byAdam.get(it.adam);
    if (!app) {
      app = {
        adam: it.adam,
        name: it.name || "App",
        bid: it.bid || "",
        storeUrl: it.storeUrl || "",
        iconPath: "",
        versions: [],
        entries: new Map(),
        latest: "",
        _latestAt: 0,
      };
      byAdam.set(it.adam, app);
    }
    if (!app.versions.includes(ver)) app.versions.push(ver);
    app.entries.set(ver, it);
    if (it.name) app.name = it.name;
    if (it.bid) app.bid = it.bid;
    if (it.storeUrl) app.storeUrl = it.storeUrl;
    if (it.iconPath && fs.existsSync(it.iconPath)) app.iconPath = it.iconPath;
    const savedAt = Number(it.savedAt) || 0;
    if (!app.latest || savedAt >= app._latestAt) {
      app.latest = ver;
      app._latestAt = savedAt;
    }
  }
  return [...byAdam.values()]
    .map((app) => {
      const versions = [...app.versions].sort((a, b) => {
        // Prefer newest-saved first via latest; otherwise lexicographic reverse.
        if (a === app.latest) return -1;
        if (b === app.latest) return 1;
        return String(b).localeCompare(String(a), undefined, { numeric: true, sensitivity: "base" });
      });
      let iconPath = app.iconPath || "";
      if (!iconPath || !fs.existsSync(iconPath)) {
        for (const ver of versions) {
          const entry = app.entries.get(ver);
          iconPath = resolveLibraryEntryIcon(entry, app.adam, "");
          if (iconPath) break;
        }
      }
      if ((!iconPath || !fs.existsSync(iconPath)) && app.storeUrl) {
        iconPath = fetchStoreIcon(app.storeUrl) || iconPath;
      }
      return {
        adam: app.adam,
        name: app.name,
        bid: app.bid,
        storeUrl: app.storeUrl,
        iconPath: iconPath || "",
        versions,
        entries: app.entries,
        latest: app.latest || versions[0] || "",
        decrypted: versions.length,
      };
    })
    .sort((a, b) =>
      String(a.name || "").localeCompare(String(b.name || ""), undefined, {
        sensitivity: "base",
      })
    );
}

function findLibraryApp(apps, query) {
  const q = String(query || "")
    .trim()
    .toLowerCase();
  if (!q) return null;
  const exact = apps.find((a) => String(a.name || "").toLowerCase() === q);
  if (exact) return exact;
  const starts = apps.filter((a) => String(a.name || "").toLowerCase().startsWith(q));
  if (starts.length === 1) return starts[0];
  if (starts.length > 1) return { ambiguous: starts };
  const contains = apps.filter((a) => String(a.name || "").toLowerCase().includes(q));
  if (contains.length === 1) return contains[0];
  if (contains.length > 1) return { ambiguous: contains };
  const byBid = apps.find((a) => String(a.bid || "").toLowerCase() === q);
  if (byBid) return byBid;
  const byAdam = apps.find((a) => String(a.adam || "") === q.replace(/^id/i, ""));
  if (byAdam) return byAdam;
  return null;
}

async function sendLibrary(chatId, query) {
  const apps = libraryAppsFromCache();
  const q = String(query || "").trim();

  if (!apps.length) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text:
        "Library is empty — paste an App Store URL to decrypt an app, then /library will list it here.",
    });
    return;
  }

  if (q) {
    const hit = findLibraryApp(apps, q);
    if (!hit) {
      await tgApi("sendMessage", {
        chat_id: chatId,
        text:
          `No library match for “${q.slice(0, 40)}”.\n` +
          `Try /library for the full list, or paste an Apple Store URL.`,
      });
      return;
    }
    if (hit.ambiguous) {
      const names = hit.ambiguous
        .slice(0, 8)
        .map((a) => `• ${a.name}`)
        .join("\n");
      await tgApi("sendMessage", {
        chat_id: chatId,
        text: `Several matches for “${q.slice(0, 40)}”:\n${names}\n\nType /library ExactName`,
      });
      return;
    }

    // Close any prior version/library carousel for this chat.
    pruneVerPicks();
    const prevTok = activeVerPickByChat.get(chatId);
    if (prevTok && pendingVerPicks.has(prevTok)) {
      const prev = pendingVerPicks.get(prevTok);
      if (prev && prev.messageId) {
        await tgApi("deleteMessage", {
          chat_id: chatId,
          message_id: prev.messageId,
        }).catch(() => {});
      }
      pendingVerPicks.delete(prevTok);
    }
    activeVerPickByChat.delete(chatId);

    const picks = hit.versions.map((ver, i) => {
      const entry =
        (hit.entries && hit.entries.get(ver)) || ipaCache.get(hit.adam, ver) || null;
      const iconPath = resolveLibraryEntryIcon(entry, hit.adam, hit.iconPath || "");
      return {
        i,
        label: `v${ver}`,
        marketing: ver,
        ext: "",
        current: ver === hit.latest,
        iconPath,
        entry,
      };
    });

    let iconPath = hit.iconPath || "";
    if (!iconPath || !fs.existsSync(iconPath)) {
      iconPath =
        (picks.find((p) => p.iconPath && fs.existsSync(p.iconPath)) || {}).iconPath || "";
    }
    if ((!iconPath || !fs.existsSync(iconPath)) && hit.storeUrl) {
      iconPath = fetchStoreIcon(hit.storeUrl) || iconPath;
    }

    const token = crypto.randomBytes(5).toString("hex");
    const pending = {
      token,
      chatId,
      mode: "library",
      url: hit.storeUrl || "",
      adam: hit.adam || "",
      title: hit.name || "App",
      bid: hit.bid || "",
      iconPath: iconPath || "",
      picks,
      page: 0,
      hasPhoto: false,
      messageId: 0,
      expires: Date.now() + 20 * 60 * 1000,
    };
    pendingVerPicks.set(token, pending);
    activeVerPickByChat.set(chatId, token);
    await paintVersionCarousel(pending, 0, { warm: false });
    return;
  }

  const totalBuilds = apps.reduce((s, a) => s + (a.decrypted || 0), 0);
  const page = apps.slice(0, 8);
  const dest = path.join(WORK, `library-list-${chatId}-${Date.now()}.jpg`);
  const img = await renderLibraryListBanner({
    apps: page.map((a) => ({
      name: a.name,
      decrypted: a.decrypted,
      latest: a.latest,
    })),
    totalBuilds,
    totalApps: apps.length,
    dest,
  });
  const caption =
    `<b>LIBRARY</b> · ${apps.length} apps · ${totalBuilds} decrypted\n` +
    `Type <code>/library AppName</code> · reply with a number to pull`;
  if (img && fs.existsSync(img)) {
    const sent = await sendPhotoBotApi(chatId, img, caption);
    try {
      fs.rmSync(img, { force: true });
    } catch {
      /* ignore */
    }
    if (sent && sent.ok) return;
  }
  const lines = page.map(
    (a) => `• *${(a.name || "App").replace(/[*_`]/g, "")}* · ${a.decrypted} decrypted`
  );
  const more =
    apps.length > page.length ? `\n_…and ${apps.length - page.length} more — /library Name_` : "";
  await tgApi("sendMessage", {
    chat_id: chatId,
    text:
      `*LIBRARY* (${apps.length} apps · ${totalBuilds} decrypted)\n\n` +
      lines.join("\n") +
      more +
      `\n\n_/library AppName · reply with a number to pull_`,
    parse_mode: "Markdown",
  });
}

async function decryptLocalIpa(chatId, ipaPath, label) {
  if (!fs.existsSync(ipaPath) || fs.statSync(ipaPath).size < 100) {
    throw new Error("IPA not found or empty: " + ipaPath);
  }
  if (!(await refuseIfNoQuota(chatId))) return;
  const encBytes = fs.statSync(ipaPath).size;
  const sizeGate = tgVip.checkSizeAllowed(chatId, encBytes);
  if (!sizeGate.ok) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text: String(sizeGate.error || "File too large for free tier.").slice(0, 400),
    }).catch(() => {});
    return;
  }
  const card = createProgressCard(chatId);
  await card.start("", label || path.basename(ipaPath, ".ipa") || "App");
  await card.setStage("Decrypting…", 20);
  const dir = fs.mkdtempSync(path.join(WORK, "job-"));
  const enc = path.join(dir, "encrypted-source.ipa");
  fs.copyFileSync(ipaPath, enc);
  try {
    const say = (t) => {
      card.fromBackendLine(t);
    };
    const result = await fairplayBackends.tryRemoteBackends({
      url: "https://apps.apple.com/app/id0",
      dir,
      say,
      vreq: "",
    });
    if (!result || !result.file || !fs.existsSync(result.file)) {
      throw new Error("Decrypt produced no IPA");
    }
    await card.setStage("Uploading…", 74);
    await deliverResult(chatId, result, { label, card });
  } catch (e) {
    await card.fail((e && e.message) || e);
    throw markReported(e);
  } finally {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  }
}

async function sendCachedEntry(chatId, entry, { quiet } = {}) {
  if (!entry) return false;
  const hasDisk = entry.diskPath && fs.existsSync(entry.diskPath);
  const hasFileId = !!entry.fileId;
  if (!hasDisk && !hasFileId) return false;

  // Prefer marketing version from Info.plist when cache stored an external-version-id.
  let version = displayAppVersion({ versionHint: entry.version });
  let bid = entry.bid || "";
  let minIos = entry.minIos || "";
  if ((!version || isExternalVersionId(entry.version)) && hasDisk) {
    const meta = readIpaMeta(entry.diskPath);
    version = displayAppVersion({
      versionHint: entry.version,
      ipaVersion: meta.version,
    });
    if (!bid && meta.bid) bid = meta.bid;
    if (!minIos && meta.minIos) minIos = meta.minIos;
  }

  // Prefer disk when cached name still says Tetherless / bare DELvEK / raw ext-id.
  const cachedName = String(entry.fileName || "");
  const tagRe = String(brandIpaTag()).replace(/\./g, "\\.");
  const needsDelvekName =
    /Tetherless\.ipa$/i.test(cachedName) ||
    (/DELvEK\.ipa$/i.test(cachedName) && !/\[DELvEK\.NeT\]\.ipa$/i.test(cachedName)) ||
    (/FastDecrypt\.ipa$/i.test(cachedName) && !/\[FastDecrypt\.(?:bot|Bot)\]\.ipa$/i.test(cachedName)) ||
    (isFastDecryptBrand() && /\[DELvEK\.NeT\]\.ipa$/i.test(cachedName));
  const needsVersionRename =
    !!version && new RegExp(`_v\\d{6,}-\\[${tagRe}\\]\\.ipa$`, "i").test(cachedName);
  let fileName;
  if ((needsDelvekName || needsVersionRename) && version) {
    const baseName =
      entry.name ||
      String(cachedName).replace(/_v[\w.-]*-\[(?:DELvEK\.NeT|FastDecrypt\.(?:bot|Bot))\]\.ipa$/i, "") ||
      "App";
    fileName = buildIpaFileName({ name: baseName, version });
  } else {
    fileName = displayIpaFileName(
      needsDelvekName && hasDisk
        ? path.basename(entry.diskPath)
        : entry.fileName || (hasDisk ? path.basename(entry.diskPath) : "App.ipa")
    );
  }
  const caption = buildCaption({
    bid,
    version,
    minIos,
    storeUrl: entry.storeUrl,
  });

  const card = createProgressCard(chatId);
  if (!quiet) {
    await card.start(entry.storeUrl || "", entry.name || "App", {
      version: entry.version || "",
    });
    await card.setStage("Sending…", 90);
  }

  // Re-brand cached IPAs that predate cord stamping (idempotent via TLCordBranded).
  if (hasDisk) {
    try {
      const branded = await cordBrand.brandIpa(entry.diskPath);
      if (branded && branded.ok && branded.branded > 0) {
        console.log("[cord] branded cached", branded.branded, path.basename(entry.diskPath));
      }
    } catch (e) {
      console.warn("[cord] cache brand:", (e && e.message) || e);
    }
  }

  let iconPath =
    (entry.iconPath && fs.existsSync(entry.iconPath) && entry.iconPath) || "";
  if (hasDisk) {
    const iconDest = path.join(
      path.dirname(entry.diskPath),
      `${path.basename(entry.diskPath, ".ipa")}.icon.png`
    );
    iconPath =
      extractIpaIcon(entry.diskPath, iconDest) ||
      (fs.existsSync(iconDest) && iconDest) ||
      iconPath ||
      "";
  }
  // Stamp cord on the Telegram card / thumb source even if IPA extract missed.
  if (iconPath && fs.existsSync(iconPath)) {
    try {
      const stampedDest = path.join(
        path.dirname(iconPath),
        `${path.basename(iconPath, path.extname(iconPath))}.cord.png`
      );
      const stamped = await cordBrand.brandIconFile(iconPath, stampedDest);
      if (stamped) iconPath = stamped;
    } catch {
      /* keep unbranded */
    }
  }
  if (iconPath && typeof card.setIcon === "function") {
    await card.setIcon(iconPath, "Sending…", 90);
  }

  const pending = {
    diskPath: hasDisk ? entry.diskPath : "",
    // Skip stale file_id when we must rename via disk.
    fileId: needsDelvekName && hasDisk ? "" : entry.fileId || "",
    fileName,
    caption,
    storeUrl: entry.storeUrl || "",
    adam: entry.adam || "",
    version: entry.version || "",
    bid: entry.bid || "",
    name: entry.name || "",
    minIos: entry.minIos || "",
    bytes: entry.bytes || 0,
    iconPath: iconPath || "",
  };
  const sent = await deliverIpaAsDocument(chatId, pending, { card });
  if (sent && sent.ok) {
    console.log("[cache] hit card→IPA", entry.adam, entry.version || "latest");
    return true;
  }
  await card.fail(premiumFailDescription((sent && sent.description) || "cache send failed"));
  return true;
}

async function trySendCached(chatId, storeUrl, vreq) {
  const entry = ipaCache.getByStoreUrl(storeUrl, vreq);
  if (!entry) return false;
  return sendCachedEntry(chatId, entry);
}

async function decryptStoreUrl(chatId, link, vreq, opts = {}) {
  if (isAppleSystemApp(link, "")) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text: "⛔ Apple system apps are not supported for decryption.",
    });
    return;
  }
  if (!(await refuseIfNoQuota(chatId))) return;
  if (await trySendCached(chatId, link, vreq)) return;

  const card = createProgressCard(chatId);
  const dir = fs.mkdtempSync(path.join(WORK, "job-"));
  const versionLabel = String(opts.versionLabel || "").trim();

  try {
    // SSH sessions need the dedicated keychain unlocked before ipatool.
    if (typeof fairplayBackends.unlockKeychain === "function") {
      fairplayBackends.unlockKeychain();
    }
    if (typeof fairplayBackends.preflightDecrypt === "function") {
      const pre = fairplayBackends.preflightDecrypt({});
      if (!pre.ok) throw new Error(pre.error);
    }
    // Establish the single progress photo BEFORE any backend say() ticks —
    // starting prep in parallel used to race and send duplicate banners.
    await card.start(link, "", { versionLabel });
    await card.setStage("Fetching…", 8);

    await fairplayBackends.ensureEncryptedSource({
      url: link,
      dir,
      say: (t) => {
        card.fromBackendLine(t);
      },
      vreq,
    });

    // Capture this build’s icon from the encrypted IPA (older versions differ).
    const encPath = path.join(dir, "encrypted-source.ipa");
    const adam = ipaCache.adamFromStoreUrl(link) || "";
    let buildIcon = "";
    if (fs.existsSync(encPath)) {
      const iconDest = path.join(dir, `icon-build-${Date.now()}.png`);
      buildIcon = extractIpaIcon(encPath, iconDest);
      if (buildIcon) {
        buildIcon =
          rememberVersionIcon(adam, [vreq, versionLabel], buildIcon) || buildIcon;
        await card.setIcon(buildIcon, "Downloading…", 40);
        console.log("[icon] captured from encrypted IPA", buildIcon);
      }
    }

    const say = (t) => {
      card.fromBackendLine(t);
    };
    const result = await fairplayBackends.tryRemoteBackends({
      url: link,
      dir,
      say: (t) => {
        say(t);
      },
      vreq,
    });
    if (!result || !result.file || !fs.existsSync(result.file)) {
      throw new Error("Decrypt produced no IPA");
    }
    // Prefer clear IPA icon if encrypted extract missed (Assets.car-only apps).
    if (!buildIcon || !fs.existsSync(buildIcon)) {
      const iconDest = path.join(dir, `icon-clear-${Date.now()}.png`);
      buildIcon = extractIpaIcon(result.file, iconDest) || buildIcon;
      if (buildIcon) {
        buildIcon =
          rememberVersionIcon(adam, [vreq, versionLabel], buildIcon) || buildIcon;
        await card.setIcon(buildIcon, "Uploading…", 74);
      }
    } else {
      rememberVersionIcon(adam, [vreq, versionLabel], buildIcon);
    }
    await card.setStage("Uploading…", 74);
    await deliverResult(chatId, result, {
      storeUrl: link,
      versionHint: vreq,
      versionLabel,
      iconPath: buildIcon || card.iconPath || "",
      card,
    });
  } catch (e) {
    await card.fail((e && e.message) || e);
    throw markReported(e);
  } finally {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  }
}

async function deliverResult(chatId, result, opts = {}) {
  try {
    const bytes = fs.statSync(result.file).size;
    const sizeGate = tgVip.checkSizeAllowed(chatId, bytes);
    if (!sizeGate.ok) {
      const msg = String(sizeGate.error || "File too large for free tier.").slice(0, 400);
      if (opts.card) await opts.card.fail(msg);
      else {
        await tgApi("sendMessage", { chat_id: chatId, text: msg }).catch(() => {});
      }
      return;
    }
  } catch {
    /* ignore size probe */
  }
  const ipaMeta = readIpaMeta(result.file);
  const name = opts.label || ipaMeta.name || result.name || (opts.card && opts.card.name) || "App";
  // Prefer Info.plist / picker marketing version — never show external-version-id gibberish.
  const version = displayAppVersion({
    versionHint: opts.versionHint,
    versionLabel: opts.versionLabel,
    ipaVersion: ipaMeta.version,
  });
  const bid = ipaMeta.bid || "";
  const minIos = ipaMeta.minIos || "";
  const storeUrl = opts.storeUrl || "";
  const card = opts.card || null;
  if (card && version) {
    await card.setVersion(version).catch(() => {});
  }
  if (isAppleSystemApp(storeUrl, bid)) {
    if (card) await card.fail("Apple system apps are not supported.");
    else {
      await tgApi("sendMessage", {
        chat_id: chatId,
        text: "⛔ Apple system apps are not supported for decryption.",
      });
    }
    return;
  }
  const bytes = fs.statSync(result.file).size;
  const mb = (bytes / 1024 / 1024).toFixed(1);
  const fileName = buildIpaFileName({ name, version });
  const caption = buildCaption({ bid, version, minIos, storeUrl });
  const adam = ipaCache.adamFromStoreUrl(storeUrl) || "";

  // Durable Mac copy for cache / re-send.
  const keep = ipaCache.diskPathFor(adam || "app", version || "latest", fileName);
  try {
    ipaCache.linkOrCopy(result.file, keep);
  } catch {
    fs.copyFileSync(result.file, keep);
  }

  // Stamp Mach-O cord onto decrypted app icons before thumbs / upload.
  try {
    if (card) await card.setStage("Branding icon…", 88);
    const branded = await cordBrand.brandIpa(keep);
    if (branded && branded.ok && branded.branded > 0) {
      console.log("[cord] branded", branded.branded, "icon file(s) in", path.basename(keep));
    } else if (branded && branded.error) {
      console.warn("[cord] brand skipped:", branded.error);
    }
  } catch (e) {
    console.warn("[cord] brand failed:", (e && e.message) || e);
  }

  // Persist this build’s icon next to the IPA for thumbs / re-sends.
  let iconPath = "";
  const iconDest = path.join(path.dirname(keep), `${path.basename(keep, ".ipa")}.icon.png`);
  // Prefer cord-branded flat AppIcon from the IPA; fall back to store art / extract.
  iconPath = extractIpaIcon(keep, iconDest) || "";
  if (!iconPath && opts.iconPath && fs.existsSync(opts.iconPath)) {
    iconPath = opts.iconPath;
  }
  if (iconPath && fs.existsSync(iconPath)) {
    try {
      const stamped = await cordBrand.brandIconFile(iconPath, iconDest);
      if (stamped) iconPath = stamped;
    } catch {
      /* keep prior icon */
    }
  }
  if (iconPath && adam) {
    const durableIcon = path.join(path.dirname(keep), `${path.basename(keep, ".ipa")}.icon.png`);
    if (path.resolve(iconPath) !== path.resolve(durableIcon)) {
      try {
        fs.copyFileSync(iconPath, durableIcon);
        iconPath = durableIcon;
      } catch {
        /* keep temp path */
      }
    }
  }
  if (iconPath && card && typeof card.setIcon === "function") {
    await card.setIcon(iconPath, "Uploading…", 92);
  }

  if (adam) {
    ipaCache.put({
      adam,
      version,
      bid,
      name,
      minIos,
      storeUrl,
      fileName,
      caption,
      bytes,
      diskPath: keep,
      iconPath: iconPath || "",
    });
    console.log("[cache] stored disk-ready", adam, version || "latest", keep);
  }

  if (card) await card.setStage("Uploading…", 92);
  if (card && typeof card.flush === "function") {
    await card.flush(100).catch(() => {});
  }

  // Can't upload through Telegram (cloud Bot ~50 MB / Premium 4 GB) → HTTPS download.
  // Skips broken Premium-session login entirely when MAC_PUBLIC_BASE / api tunnel is up.
  if (needsHttpsIpaLink(bytes)) {
    const linkSent = await deliverOversizedViaLink(chatId, {
      diskPath: keep,
      fileName,
      caption,
      name,
      bytes,
      storeUrl,
    }, { card });
    if (!linkSent || !linkSent.ok) {
      const why = (linkSent && linkSent.description) || "download link failed";
      if (card) await card.fail(why);
      else {
        await tgApi("sendMessage", {
          chat_id: chatId,
          text:
            `Decrypted (${mb} MB) but Telegram can't host this file and HTTPS link failed.\n` +
            `${String(why).slice(0, 300)}\n\nSaved on Mac:\n\`${keep}\``,
          parse_mode: "Markdown",
        });
      }
    }
    return;
  }

  // Sharp card → IPA document (same message). Download-arrow thumb = native TG download.
  const sent = await deliverIpaAsDocument(chatId, {
    diskPath: keep,
    fileName,
    caption,
    storeUrl,
    adam,
    version,
    bid,
    name,
    minIos,
    bytes,
    iconPath: iconPath || "",
  }, { card });

  if (!sent || !sent.ok) {
    const why = (sent && sent.description) || "Telegram attach failed";
    console.warn("[job] deliver IPA:", why);
    if (card) await card.fail(why);
    else {
      await tgApi("sendMessage", {
        chat_id: chatId,
        text:
          `Decrypted (${mb} MB) but Telegram upload failed:\n${String(why).slice(0, 400)}\n\n` +
          `Saved on Mac:\n\`${keep}\``,
        parse_mode: "Markdown",
      });
    }
  }
}

/** True when Bot/Premium Telegram upload can't carry this IPA (use HTTPS /d/ link). */
function needsHttpsIpaLink(bytes) {
  const n = Number(bytes) || 0;
  if (n > TG_PREMIUM_DOC_MAX) return true;
  if (LOCAL_API) return false;
  if (n <= TG_DOC_MAX) return false;
  // Over cloud Bot ~50 MB and no working Premium user session → public download.
  return !preferPremiumUpload();
}

/**
 * IPA too large for Telegram upload → tokenized HTTPS download on the Mac API
 * (mac-ssh.sh api + MAC_PUBLIC_BASE=https://fastdecrypt.bot). No Premium session required.
 */
async function deliverOversizedViaLink(chatId, pending, { card } = {}) {
  const bytes = pending.bytes || 0;
  const mb = (bytes / (1024 * 1024)).toFixed(1);
  const fileName = displayIpaFileName(pending.fileName || "App.ipa");
  let staged;
  try {
    staged = publicDl.stageIpa(pending.diskPath, { fileName, bytes });
  } catch (e) {
    return { ok: false, description: String((e && e.message) || e).slice(0, 200) };
  }
  const url = publicDl.downloadUrlFor(staged.token);
  if (!url) {
    return {
      ok: false,
      description:
        "Run: zsh ~/tetherless/server/mac-ssh.sh api  (uses https://fastdecrypt.bot — proxy /d/ to this Mac)",
    };
  }
  const caption = pending.caption || "";
  const reason =
    bytes > TG_PREMIUM_DOC_MAX
      ? "Too large for Telegram’s 4 GB file cap."
      : "Too large for Telegram Bot upload (~50 MB) — download from the Mac instead.";
  const text =
    `<b>${escapeHtml(pending.name || "App")}</b> · ${escapeHtml(mb)} MB\n` +
    `${reason}\n\n` +
    `⬇️ <a href="${escapeHtml(url)}">Download IPA</a>\n` +
    `<code>${escapeHtml(url)}</code>\n\n` +
    (caption ? `${caption}\n\n` : "") +
    `<i>Link expires in ~${Math.round(publicDl.TTL_MS / 60000)} minutes.</i>`;

  const openMarkup = resultKeyboard(url);
  const mid = card && card.messageId;
  if (mid) {
    // Keep the sharp card photo; put the link as caption + Patch/VIP + Open in.
    await tgApi("editMessageCaption", {
      chat_id: chatId,
      message_id: mid,
      caption: text,
      parse_mode: "HTML",
      reply_markup: openMarkup,
    }).catch(() => {});
    await ensureIpaButtonTabs(chatId, mid, { caption: text, replyMarkup: openMarkup });
    if (card && typeof card.flush === "function") await card.flush(100).catch(() => {});
    if (card && typeof card.release === "function") await card.release();
    console.log("[job] oversized IPA → download link on card", url);
    return { ok: true, url, inPlace: true };
  }

  const sent = await tgApi("sendMessage", {
    chat_id: chatId,
    text,
    parse_mode: "HTML",
    disable_web_page_preview: true,
    reply_markup: openMarkup,
  }).catch((e) => ({ ok: false, description: String((e && e.message) || e) }));
  if (card) await card.finish();
  if (!(sent && sent.ok)) {
    return { ok: false, description: (sent && sent.description) || "sendMessage failed" };
  }
  console.log("[job] oversized IPA → download link message", url);
  return { ok: true, url, result: sent.result };
}

async function cacheIpaDelivery(pending, { fileName, caption, fileId, fileUniqueId, messageId, fromChatId, bytes, diskPath }) {
  if (!pending || !pending.adam) return;
  ipaCache.put({
    adam: pending.adam,
    version: pending.version || "",
    bid: pending.bid || "",
    name: pending.name || "",
    minIos: pending.minIos || "",
    storeUrl: pending.storeUrl || "",
    fileName,
    caption,
    fileId: fileId || "",
    fileUniqueId: fileUniqueId || "",
    messageId: Number(messageId) || 0,
    fromChatId: String(fromChatId || ""),
    bytes: bytes || 0,
    diskPath: diskPath || "",
  });
}

/**
 * Turn the sharp progress card into the IPA document (same message).
 * Works with a fresh upload or an existing Telegram file_id.
 */
async function promoteCardToIpa(chatId, cardMid, { fileId, disk, fileName, caption, thumbPath, markup, card }) {
  if (!cardMid) return null;
  const edited = await editMessageToDocumentBotApi(chatId, cardMid, disk || "", fileName, caption, {
    thumbPath,
    replyMarkup: markup,
    fileId: fileId || "",
  });
  if (!(edited && edited.ok)) {
    console.warn(
      "[job] card→document edit failed:",
      (edited && edited.description) || "unknown"
    );
    return null;
  }
  // Large file_id edits often drop inline tabs — force Patch/VIP (reply fallback OK).
  await ensureIpaButtonTabs(chatId, cardMid, { caption, replyMarkup: markup });
  if (card && typeof card.flush === "function") await card.flush(100).catch(() => {});
  if (card && typeof card.release === "function") await card.release();
  console.log("[job] sharp card → IPA document", cardMid, fileName);
  return edited;
}

async function dropProgressCard(card, cardMid, chatId) {
  if (card && typeof card.finish === "function") {
    await card.finish();
    return;
  }
  if (cardMid) {
    await tgApi("deleteMessage", { chat_id: chatId, message_id: cardMid }).catch(() => {});
  }
}

/**
 * Finish delivery: sharp progress card disappears into the IPA document
 * (editMessageMedia photo→document — download-arrow thumb + Patch/VIP).
 * Large files: Premium-upload for a file_id, then edit the card with that id
 * and delete the temporary upload bubble.
 */
async function deliverIpaAsDocument(chatId, pending, { card, cardMessageId } = {}) {
  if (!pending) return { ok: false, description: "expired" };
  const fileName = displayIpaFileName(pending.fileName || path.basename(pending.diskPath || "App.ipa"));
  const caption =
    pending.caption ||
    buildCaption({
      bid: pending.bid,
      version: pending.version,
      minIos: pending.minIos,
      storeUrl: pending.storeUrl,
    });
  const cardMid =
    Number(cardMessageId || pending.cardMessageId || (card && card.messageId) || 0) || 0;
  const disk = pending.diskPath && fs.existsSync(pending.diskPath) ? pending.diskPath : "";
  const bytes = pending.bytes || (disk ? fs.statSync(disk).size : 0);
  // Stage HTTPS URL for Open-in (TrollStore / Feather / …) when public API is up.
  let openUrl = "";
  if (disk) {
    try {
      const staged = publicDl.stageIpa(disk, { fileName, bytes });
      openUrl = publicDl.downloadUrlFor(staged.token) || "";
    } catch {
      /* open-in optional */
    }
  }
  const markup = resultKeyboard(openUrl);
  let buildIcon = pending.iconPath && fs.existsSync(pending.iconPath) ? pending.iconPath : "";
  if (!buildIcon && disk) {
    const iconDest = path.join(
      os.tmpdir(),
      `delvek-ipa-icon-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.png`
    );
    buildIcon = extractIpaIcon(disk, iconDest);
  }
  const thumbPath = await buildIpaDocumentThumb(pending.storeUrl || "", buildIcon || "");

  // 1) Direct in-place when we already have file_id or the file fits Bot API.
  const canDirectEdit =
    cardMid && (pending.fileId || (disk && (LOCAL_API || bytes <= TG_DOC_MAX)));
  if (canDirectEdit) {
    const edited = await promoteCardToIpa(chatId, cardMid, {
      fileId: pending.fileId || "",
      disk: pending.fileId ? "" : disk,
      fileName,
      caption,
      thumbPath,
      markup,
      card,
    });
    if (edited) {
      const doc = edited.result && edited.result.document;
      await cacheIpaDelivery(pending, {
        fileName,
        caption,
        fileId: (doc && doc.file_id) || pending.fileId || "",
        fileUniqueId: (doc && doc.file_unique_id) || "",
        messageId: cardMid,
        fromChatId: chatId,
        bytes,
        diskPath: disk || pending.diskPath || "",
      });
      return { ok: true, result: edited.result, inPlace: true };
    }
  }

  // 2) Upload (Premium/Bot) to obtain a file_id, then promote the card.
  let fileId = pending.fileId || "";
  let uploadMid = 0;
  let uploadResult = null;

  if (!fileId && disk) {
    const sent = await sendDocument(chatId, disk, fileName, caption, {
      thumbPath,
      replyMarkup: markup,
      card: null, // don't drive progress paints during upload
    });
    if (!(sent && sent.ok)) {
      // Premium login often unavailable — fall back to public HTTPS IPA link.
      if (sent && sent.tooLarge) {
        return deliverOversizedViaLink(chatId, pending, { card });
      }
      return sent || { ok: false, description: "upload failed" };
    }
    uploadResult = sent;
    uploadMid =
      Number(sent.message_id || (sent.result && sent.result.message_id) || 0) || 0;
    fileId =
      (sent.result && sent.result.document && sent.result.document.file_id) || "";
  } else if (fileId) {
    const r = await sendIpaByFileId(chatId, fileId, caption, markup);
    if (!(r && r.ok)) {
      return r || { ok: false, description: "file_id send failed" };
    }
    uploadResult = r;
    uploadMid = Number(r.result && r.result.message_id) || 0;
    fileId = (r.result && r.result.document && r.result.document.file_id) || fileId;
  } else {
    return { ok: false, description: "IPA no longer on Mac — decrypt again" };
  }

  // Prefer: card becomes the IPA; delete the temporary upload bubble.
  if (cardMid && fileId) {
    const edited = await promoteCardToIpa(chatId, cardMid, {
      fileId,
      fileName,
      caption,
      thumbPath,
      markup,
      card,
    });
    if (edited) {
      if (uploadMid && uploadMid !== cardMid) {
        await tgApi("deleteMessage", { chat_id: chatId, message_id: uploadMid }).catch(() => {});
      }
      const doc = edited.result && edited.result.document;
      await cacheIpaDelivery(pending, {
        fileName,
        caption,
        fileId: (doc && doc.file_id) || fileId,
        fileUniqueId: (doc && doc.file_unique_id) || "",
        messageId: cardMid,
        fromChatId: chatId,
        bytes,
        diskPath: disk || pending.diskPath || "",
      });
      return { ok: true, result: edited.result, inPlace: true };
    }
  }

  // Couldn't promote — keep the upload bubble, drop the progress card, still force Patch/VIP.
  await dropProgressCard(card, cardMid, chatId);
  if (uploadMid) {
    await ensureIpaButtonTabs(chatId, uploadMid, { caption, replyMarkup: markup });
  }
  const doc = uploadResult && uploadResult.result && uploadResult.result.document;
  await cacheIpaDelivery(pending, {
    fileName,
    caption,
    fileId: (doc && doc.file_id) || fileId,
    fileUniqueId: (doc && doc.file_unique_id) || "",
    messageId: uploadMid,
    fromChatId: chatId,
    bytes,
    diskPath: disk || pending.diskPath || "",
  });
  return uploadResult || { ok: true, message_id: uploadMid };
}

/** @deprecated name — kept for legacy dl: callbacks */
async function sendPendingDownload(chatId, pending, opts) {
  return deliverIpaAsDocument(chatId, pending, opts);
}

function resolveDropPath(name) {
  const raw = String(name || "").trim().replace(/^decrypt\s+/i, "");
  if (!raw) return "";
  if (path.isAbsolute(raw) && raw.toLowerCase().endsWith(".ipa")) return raw;
  const base = path.basename(raw);
  const candidates = [
    path.join(DROP, base),
    path.join(DROP, raw),
    path.join(os.homedir(), "Downloads", base),
    path.join(os.homedir(), "Desktop", base),
  ];
  return candidates.find((p) => fs.existsSync(p)) || path.join(DROP, base);
}

let offset = 0;

/** Parallel decrypt workers — auto 2 on ≤16 GB Macs unless MAC_TG_WORKERS is set. */
const MAX_WORKERS = Math.max(
  1,
  Math.min(
    8,
    Number(
      process.env.MAC_TG_WORKERS ||
        (fairplayBackends.suggestedWorkers && fairplayBackends.suggestedWorkers(3)) ||
        3
    ) || 3
  )
);
let activeWorkers = 0;
const jobWaiters = [];
/** One live decrypt at a time per chat — stops duplicate sharp cards. */
const chatJobTail = new Map();

function markReported(err) {
  const e = err instanceof Error ? err : new Error(String(err || "failed"));
  e.reported = true;
  return e;
}

async function withWorker(chatId, fn) {
  const key = String(chatId || "");
  const run = async () => {
    if (activeWorkers >= MAX_WORKERS) {
      const place = activeWorkers + jobWaiters.length + 1;
      await tgApi("sendMessage", {
        chat_id: chatId,
        text: `Queued (#${place}) — ${activeWorkers}/${MAX_WORKERS} workers busy…`,
      }).catch(() => {});
      await new Promise((resolve) => jobWaiters.push(resolve));
    }
    activeWorkers++;
    console.log(`[job] worker start (${activeWorkers}/${MAX_WORKERS} active, ${jobWaiters.length} waiting)`);
    try {
      await fn();
    } catch (e) {
      const err = String((e && e.message) || e).slice(0, 200);
      console.warn("[job] failed:", err);
      // card.fail already posted ❌ — don't send a second "Failed:" bubble.
      if (!(e && e.reported)) {
        await tgApi("sendMessage", { chat_id: chatId, text: "Failed: " + err }).catch(() => {});
      }
    } finally {
      activeWorkers--;
      const next = jobWaiters.shift();
      if (next) next();
      console.log(`[job] worker done (${activeWorkers}/${MAX_WORKERS} active, ${jobWaiters.length} waiting)`);
    }
  };

  // Serialize per chat so a second paste / overlapping poll can't spawn two cards.
  const prev = chatJobTail.get(key) || Promise.resolve();
  const chained = prev.catch(() => {}).then(run);
  chatJobTail.set(key, chained);
  try {
    await chained;
  } finally {
    if (chatJobTail.get(key) === chained) chatJobTail.delete(key);
  }
}

async function handleCallback(cq) {
  const chatId = cq.message && cq.message.chat && cq.message.chat.id;
  const data = String(cq.data || "");
  if (!chatId) return;
  userLog.logCallback(cq);
  if (!chatAllowed(chatId)) {
    await tgApi("answerCallbackQuery", { callback_query_id: cq.id }).catch(() => {});
    await tgApi("sendMessage", { chat_id: chatId, text: "This bot is private." });
    return;
  }
  // Old menu buttons (help/status/cache/history/testflight) → quiet dismiss + start.
  if (
    data === "status" ||
    data === "cache" ||
    data === "history" ||
    data === "help" ||
    data === "testflight"
  ) {
    await tgApi("answerCallbackQuery", { callback_query_id: cq.id }).catch(() => {});
    await sendStart(chatId);
    return;
  }
  if (data.startsWith("ver:")) {
    await handleVersionPick(cq, data);
    return;
  }
  if (data.startsWith("app:")) {
    await handleAppNamePick(cq, data);
    return;
  }
  if (data.startsWith("hist:")) {
    const id = data.slice(5);
    const entry = urlLog.getById(chatId, id);
    if (!entry || !entry.storeUrl) {
      await tgApi("answerCallbackQuery", {
        callback_query_id: cq.id,
        text: "Not found in history",
        show_alert: true,
      }).catch(() => {});
      return;
    }
    await tgApi("answerCallbackQuery", {
      callback_query_id: cq.id,
      text: `Decrypting ${entry.name || entry.adam || "app"}…`,
    }).catch(() => {});
    const vreq = entry.version && entry.version !== "latest" ? entry.version : "";
    // Refresh log timestamp / bump to top
    urlLog.add(chatId, entry);
    await withWorker(chatId, async () => {
      const resolved = await resolveExternalVersionId(entry.storeUrl, vreq);
      await decryptStoreUrl(chatId, entry.storeUrl, resolved);
    });
    return;
  }
  if (data.startsWith("dl:")) {
    const token = data.slice(3);
    const pending = pendingDownloads.get(token);
    if (!pending) {
      await tgApi("answerCallbackQuery", {
        callback_query_id: cq.id,
        text: "Download expired — send the link again",
        show_alert: true,
      }).catch(() => {});
      return;
    }
    const cardMessageId =
      (cq.message && cq.message.message_id) || pending.cardMessageId || 0;
    await tgApi("answerCallbackQuery", {
      callback_query_id: cq.id,
      text: "Loading IPA…",
    }).catch(() => {});
    // Legacy ⬇️ Download on old done cards — same card→document finish.
    await withWorker(chatId, async () => {
      const sent = await deliverIpaAsDocument(chatId, pending, { cardMessageId });
      if (!sent || !sent.ok) {
        const why = premiumFailDescription((sent && sent.description) || "send failed");
        await tgApi("sendMessage", {
          chat_id: chatId,
          text: `❌ Download failed: ${String(why).slice(0, 200)}`,
          reply_to_message_id: cardMessageId || undefined,
        }).catch(() => {});
      }
    });
    return;
  }
  await tgApi("answerCallbackQuery", { callback_query_id: cq.id }).catch(() => {});
}

async function handleMessage(msg) {
  const chatId = msg.chat && msg.chat.id;
  if (!chatId) return;
  userLog.logMessage(msg);
  if (!chatAllowed(chatId)) {
    await tgApi("sendMessage", { chat_id: chatId, text: "This bot is private." });
    return;
  }

  const doc = msg.document;
  const docName = (doc && doc.file_name) || "";
  if (doc && /\.ipa$/i.test(docName)) {
    // Premium/cache echo: our clear IPA uploads come back as user documents — don't re-decrypt.
    if (/-(?:DELvEK|Tetherless|FastDecrypt|\[DELvEK\.NeT\]|\[FastDecrypt\.(?:bot|Bot)\])\.ipa$/i.test(docName)) {
      // Clear IPA echoes (bot/Premium upload) — don't re-decrypt.
      return;
    }
    if (!doc.file_id) return;
    if (doc.file_size && doc.file_size > TG_GETFILE_MAX) {
      await tgApi("sendMessage", {
        chat_id: chatId,
        text:
          `That IPA is ${((doc.file_size || 0) / 1024 / 1024).toFixed(1)} MB — too large to pull from Telegram.\n` +
          `Send a smaller build, or an App Store link instead.`,
      });
      return;
    }
    await withWorker(chatId, async () => {
      const meta = await tgApi("getFile", { file_id: doc.file_id });
      if (!meta.ok || !meta.result || !meta.result.file_path) {
        throw new Error((meta.description || "getFile failed").slice(0, 160));
      }
      const dest = path.join(WORK, `upload-${Date.now()}.ipa`);
      await downloadTelegramFile(meta.result.file_path, dest);
      await decryptLocalIpa(chatId, dest, path.basename(doc.file_name || "App.ipa", ".ipa"));
      try {
        fs.rmSync(dest, { force: true });
      } catch {
        /* ignore */
      }
    });
    return;
  }

  const text = String(msg.text || "").trim();
  if (!text) return;

  if (/^\/start\b/i.test(text)) {
    await sendStart(chatId);
    return;
  }

  if (/^\/vip(?:@\w+)?\b/i.test(text)) {
    await sendVip(chatId);
    return;
  }

  // Admin: /grantvip <days>  (reply to user)  OR  /grantvip <user_id> <days>
  if (/^\/grantvip(?:@\w+)?\b/i.test(text)) {
    if (!tgVip.isAdmin(chatId)) {
      await tgApi("sendMessage", { chat_id: chatId, text: "Admin only." });
      return;
    }
    const args = text.replace(/^\/grantvip(?:@\w+)?\s*/i, "").trim().split(/\s+/).filter(Boolean);
    let targetId = "";
    let days = 0;
    if (args.length >= 2 && /^\d{5,25}$/.test(args[0])) {
      targetId = args[0];
      days = Number(args[1]);
    } else if (args.length >= 1 && /^\d{1,4}$/.test(args[0])) {
      days = Number(args[0]);
      const replied = msg.reply_to_message && msg.reply_to_message.from;
      targetId = replied && !replied.is_bot ? String(replied.id) : "";
    }
    if (!targetId || !days) {
      await tgApi("sendMessage", {
        chat_id: chatId,
        text:
          "Usage:\n" +
          "<code>/grantvip &lt;user_id&gt; &lt;days&gt;</code>\n" +
          "or reply to a user: <code>/grantvip 30</code>\n" +
          "Days: 7 / 30 / 90 / 180 / 365",
        parse_mode: "HTML",
      });
      return;
    }
    const result = tgVip.grantVip(targetId, days, String(chatId));
    if (!result.ok) {
      await tgApi("sendMessage", { chat_id: chatId, text: result.error });
      return;
    }
    userLog.logUse({
      chatId,
      from: msg.from,
      kind: "grantvip",
      detail: `${targetId} ${days}d → ${result.left}`,
      platform: "telegram",
    });
    await tgApi("sendMessage", {
      chat_id: chatId,
      text:
        `⭐ VIP granted\n` +
        `User: <code>${escapeHtml(targetId)}</code>\n` +
        `Added: <b>${days} days</b>${result.stacked ? " (stacked)" : ""}\n` +
        `Time left: <b>${escapeHtml(result.left)}</b>`,
      parse_mode: "HTML",
    });
    return;
  }

  if (/^\/revokevip(?:@\w+)?\b/i.test(text)) {
    if (!tgVip.isAdmin(chatId)) {
      await tgApi("sendMessage", { chat_id: chatId, text: "Admin only." });
      return;
    }
    const arg = text.replace(/^\/revokevip(?:@\w+)?\s*/i, "").trim();
    let targetId = arg.split(/\s+/)[0] || "";
    if (!targetId && msg.reply_to_message && msg.reply_to_message.from) {
      targetId = String(msg.reply_to_message.from.id);
    }
    if (!/^\d{5,25}$/.test(targetId)) {
      await tgApi("sendMessage", {
        chat_id: chatId,
        text: "Usage: <code>/revokevip &lt;user_id&gt;</code> (or reply to a user)",
        parse_mode: "HTML",
      });
      return;
    }
    const result = tgVip.revokeVip(targetId);
    await tgApi("sendMessage", {
      chat_id: chatId,
      text: result.ok ? `Revoked timed VIP for <code>${escapeHtml(targetId)}</code>` : result.error,
      parse_mode: "HTML",
    });
    return;
  }

  if (/^\/status(?:@\w+)?\b/i.test(text)) {
    await sendStatus(chatId);
    return;
  }

  // /enc — previous decryption results (AppAssassin-style menu alias for /library).
  if (/^\/(?:enc|library)(?:@\w+)?(?:\s+(.+))?$/i.test(text)) {
    const q =
      (text.match(/^\/(?:enc|library)(?:@\w+)?(?:\s+(.+))?$/i) || [])[1] || "";
    await sendLibrary(chatId, q);
    return;
  }

  if (/^\/version(?:@\w+)?(?:\s+(.+))?$/i.test(text)) {
    const arg = String(
      (text.match(/^\/version(?:@\w+)?(?:\s+(.+))?$/i) || [])[1] || ""
    ).trim();
    const link = arg.split(/\s+/).find((t) => isStoreUrl(t));
    if (link) {
      await withWorker(chatId, async () => {
        const resolved = await resolveExternalVersionId(link, "");
        await decryptStoreUrl(chatId, link, resolved);
      });
      return;
    }
    await sendVersionHelp(chatId);
    return;
  }

  // Version sharp-card carousel: reply with 1…N to pick a build on the current page.
  if (await tryHandleVersionNumberReply(chatId, text, msg.message_id)) {
    return;
  }

  // Quiet ops: purchased sync / session / prefetch (WebSSH-friendly).
  if (/^\/(?:purchased|owned)(?:\s+(.+))?$/i.test(text)) {
    try {
      const extras = require("./mac-ipatool-extras");
      const q = (text.match(/^\/(?:purchased|owned)(?:\s+(.+))?$/i) || [])[1] || "";
      if (/^sync\b/i.test(q) || !extras.loadPurchased().items.length) {
        extras.syncPurchasedLibrary();
      }
      const items = extras.searchPurchased(/^sync\b/i.test(q) ? "" : q);
      const lines = items.slice(0, 20).map((it) => `• ${it.name} · id${it.adam}`);
      await tgApi("sendMessage", {
        chat_id: chatId,
        text:
          (lines.length ? lines.join("\n") : "No purchased apps cached.") +
          "\n\nSync: /purchased sync",
      });
    } catch (e) {
      await tgApi("sendMessage", {
        chat_id: chatId,
        text: String((e && e.message) || e).slice(0, 200),
      });
    }
    return;
  }
  if (/^\/session\b/i.test(text)) {
    try {
      const extras = require("./mac-ipatool-extras");
      const s = extras.sessionWatch({ force: true });
      await tgApi("sendMessage", {
        chat_id: chatId,
        text: s.ready
          ? `ipatool OK · ${s.email || s.name || "logged in"}`
          : `ipatool session missing\n${s.hint || s.error || ""}`,
      });
    } catch (e) {
      await tgApi("sendMessage", { chat_id: chatId, text: String(e.message || e).slice(0, 200) });
    }
    return;
  }
  if (/^\/speed\b/i.test(text)) {
    try {
      const extras = require("./mac-ipatool-extras");
      const st = extras.speedFeatureStatus();
      await tgApi("sendMessage", {
        chat_id: chatId,
        text: extras.formatSpeedStatusText(st),
        parse_mode: "Markdown",
      });
    } catch (e) {
      await tgApi("sendMessage", { chat_id: chatId, text: String(e.message || e).slice(0, 200) });
    }
    return;
  }
  if (/^\/prefetch(?:@\w+)?(?:\s+(.+))?$/i.test(text)) {
    try {
      const extras = require("./mac-ipatool-extras");
      const arg = String(
        (text.match(/^\/prefetch(?:@\w+)?(?:\s+(.+))?$/i) || [])[1] || ""
      ).trim();
      if (!arg) {
        const st = extras.prefetchStats();
        await tgApi("sendMessage", {
          chat_id: chatId,
          text:
            `*Prefetch*\n` +
            `queued ${st.queued || 0} · running ${st.running || 0} · done ${st.done || 0} · err ${st.error || 0}\n\n` +
            `Usage:\n` +
            `/prefetch https://apps.apple.com/…\n` +
            `/prefetch purchased`,
          parse_mode: "Markdown",
        });
        return;
      }
      if (/^purchased\b/i.test(arg)) {
        const limitMatch = arg.match(/\b(\d{1,2})\b/);
        const limit = Math.max(1, Math.min(30, Number(limitMatch && limitMatch[1]) || 12));
        const r = extras.enqueuePrefetchPurchased({ limit, priority: 1 });
        await tgApi("sendMessage", {
          chat_id: chatId,
          text:
            `Prefetch purchased → queued ${r.queued.length} · already cached ${r.skipped.length} · library ${r.purchased}`,
        });
        return;
      }
      const link = arg.split(/\s+/).find((t) => isStoreUrl(t));
      if (!link) {
        await tgApi("sendMessage", {
          chat_id: chatId,
          text: "Usage: /prefetch https://apps.apple.com/…  or  /prefetch purchased",
        });
        return;
      }
      const item = extras.enqueuePrefetch({ url: link, priority: 2 });
      await tgApi("sendMessage", {
        chat_id: chatId,
        text: `Prefetch queued · ${item.adam || link} (${item.status})`,
      });
    } catch (e) {
      await tgApi("sendMessage", { chat_id: chatId, text: String(e.message || e).slice(0, 200) });
    }
    return;
  }

  if (/^decrypt\s+/i.test(text) || (/^[\w./-]+\.ipa$/i.test(text) && !/^https?:/i.test(text))) {
    const ipaPath = resolveDropPath(text);
    await withWorker(chatId, async () => {
      await decryptLocalIpa(chatId, ipaPath, path.basename(ipaPath, ".ipa"));
    });
    return;
  }

  const link = text.split(/\s+/).find((t) => isStoreUrl(t) || isTestFlightUrl(t));
  if (!link) {
    // Free text → App Store name search (optional version), e.g. "Vinted" / "Vinted 26.45.0".
    if (await handleAppNameMessage(chatId, text, msg.message_id)) return;
    await tgApi("sendMessage", {
      chat_id: chatId,
      text:
        "Send an App Store link, or just the app name (optional version like `Vinted 26.45.0`).",
      parse_mode: "Markdown",
    });
    return;
  }

  if (isTestFlightUrl(link)) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text: "TestFlight invite links can’t be fetched — send the encrypted `.ipa` instead.",
    });
    return;
  }

  const verMatch = text.match(/\b(?:v|version)[:=\s]+([0-9][0-9A-Za-z._-]{0,29})\b/i);
  const vreq = verMatch ? verMatch[1] : "";
  // Clean chat: drop the pasted URL, keep it in History for re-decrypt.
  await deleteUserMessage(chatId, msg.message_id);
  // Typed version → decrypt that build. Bare link → version sharp-card carousel first.
  await beginDecryptFromStore(chatId, link, vreq);
}

/** Only one getUpdates in flight — overlapping polls re-delivered the same URL → duplicate cards. */
let pollBusy = false;

async function poll() {
  if (pollBusy) return;
  pollBusy = true;
  try {
    const r = await tgApi("getUpdates", {
      offset,
      timeout: 25,
      allowed_updates: ["message", "callback_query"],
    });
    if (!r.ok || !Array.isArray(r.result)) return;
    for (const u of r.result) {
      // Ack before dispatch so a concurrent poll can't fetch the same update.
      offset = Math.max(offset, (u.update_id || 0) + 1);
      // Don't await decrypt — withWorker serializes per chat; poll must keep cycling.
      Promise.resolve()
        .then(() =>
          u.callback_query
            ? handleCallback(u.callback_query)
            : u.message
              ? handleMessage(u.message)
              : null
        )
        .catch((e) => console.warn("update:", (e && e.message) || e));
    }
  } catch (e) {
    console.warn("poll:", (e && e.message) || e);
  } finally {
    pollBusy = false;
  }
}

async function resolveBotIdentity() {
  const envHint = BOT_USERNAME;
  try {
    const me = await tgApi("getMe");
    if (me && me.ok && me.result) {
      // Always prefer getMe over env — TELEGRAM_BOT_USERNAME typos 404 in Pyrogram.
      if (me.result.username) BOT_USERNAME = String(me.result.username).replace(/^@/, "");
      if (me.result.id) BOT_ID = Number(me.result.id) || 0;
    }
  } catch (e) {
    console.warn("getMe failed:", (e && e.message) || e);
  }
  if (envHint && BOT_USERNAME && envHint.toLowerCase() !== BOT_USERNAME.toLowerCase()) {
    console.warn(
      `TELEGRAM_BOT_USERNAME=${envHint} ignored — getMe says @${BOT_USERNAME} (id=${BOT_ID})`
    );
  }
  if (!BOT_ID) {
    console.warn(
      "WARN: bot id unknown — Premium uploads need getMe(). Check TELEGRAM_BOT_TOKEN."
    );
  }
  console.log(
    `Premium peers: ${premiumPeerCandidates().join(" → ") || "(none)"}`
  );
}

async function boot() {
  await resolveBotIdentity();
  userLog.pruneOldEvents();
  console.log(
    `User usage log: ${userLog.LOG_DIR} (${userLog.listUsers().length} users)`
  );
  // AppAssassin-style Menu: /status /enc /vip /version (+ start). /library kept as /enc alias only.
  await tgApi("deleteMyCommands", {}).catch(() => {});
  await tgApi("setMyCommands", {
    commands: [
      { command: "status", description: "Check active jobs and bot status" },
      { command: "enc", description: "Previous decryption results — Available to all" },
      { command: "vip", description: "View current vip status or time remaining" },
      { command: "version", description: "Use with url or app name to choose version" },
      { command: "start", description: `Start ${botBrandName()}` },
    ],
  }).catch(() => {});
  await tgApi("setChatMenuButton", {
    menu_button: { type: "commands" },
  }).catch(() => {});
  const st = fairplayBackends.backendStatus();
  const bannerMode = (() => {
    try {
      const src = fs.readFileSync(path.join(__dirname, "mac-tg-progress-banner.js"), "utf8");
      return /homescreenOverlaySvg/.test(src) ? "homescreen-circle" : "legacy";
    } catch {
      return "missing";
    }
  })();
  console.log(
    `${botBrandName()} TG bot @${BOT_USERNAME || "?"} id=${BOT_ID || "?"} · site=${brandSiteDefault()} · workers=${MAX_WORKERS} · decrypt=${!!(st.unfairplay && st.unfairplay.ready)} · model=${!!(st.enrollmentModel && st.enrollmentModel.ready)}`
  );
  console.log(
    `access=${LOCKDOWN && ALLOWED.length ? `lockdown(${ALLOWED.length} ids)` : "public"} · banner=${bannerMode}`
  );
  console.log(
    `API ${API_ROOT} · local=${LOCAL_API} · uploadMaxMB=${Math.round(TG_DOC_MAX / 1024 / 1024)} · premiumUser=${preferPremiumUpload()} · channel=${premiumUploadChannel() || "unset"} · peer=${premiumPeer() || "unset"}`
  );
  console.log(
    `IPA cloud cache: ${ipaCache.CACHE_DIR} (${ipaCache.list().length} clear, ${ipaCache.listEncrypted().length} encrypted)`
  );
  console.log(`Drop folder for TestFlight IPAs: ${DROP}`);
  console.log("WebSSH: zsh ~/tetherless/server/mac-ssh.sh start | status | logs | session | unlock");
  if (typeof fairplayBackends.unlockKeychain === "function") {
    const unlocked = fairplayBackends.unlockKeychain();
    console.log(unlocked ? "Keychain: unlocked (tetherless.keychain-db)" : "Keychain: skipped (set TETHERLESS_KEYCHAIN_PASSWORD)");
  }
  try {
    const extras = require("./mac-ipatool-extras");
    // 3) Purchased library — refresh if stale so owned → skip --purchase works.
    try {
      const purchased = extras.ensurePurchasedFresh();
      console.log(
        purchased.skipped
          ? `purchased library: ${purchased.items.length} (fresh)`
          : `purchased library: synced ${purchased.items.length}${
              purchased.ok ? "" : " · " + (purchased.error || "partial")
            }`
      );
    } catch (e) {
      console.warn("purchased sync:", (e && e.message) || e);
    }
    // 2) Encrypted prefetch loop (idle → busy interval when queue has work).
    extras.startPrefetchLoop();
    // 4) Session / keychain health.
    const sess = extras.sessionWatch({ force: true });
    console.log(
      sess.ready
        ? `ipatool session: ${sess.email || "ok"}`
        : `ipatool session: missing — ${sess.hint || sess.error || ""}`
    );
    // 1–6 dashboard line for WebSSH logs.
    try {
      const st = extras.speedFeatureStatus();
      console.log(
        `ipatool speed: cache clear=${st.encryptedCache.clear} enc=${st.encryptedCache.encrypted}` +
          ` · prefetch q=${st.prefetch.queued || 0}` +
          ` · purchased=${st.purchased.count}` +
          ` · session=${st.session.ready ? "ok" : "down"}` +
          ` · storefront=${st.storefront.env}` +
          ` · version-first=on` +
          ` · skip-purchase-if-owned=${st.bypasses.skipPurchaseWhenOwned ? "on" : "off"}`
      );
    } catch {
      /* ignore */
    }
  } catch (e) {
    console.warn("ipatool extras:", (e && e.message) || e);
  }
  // Kick the next poll when the previous finishes (no overlapping getUpdates).
  const pump = () => {
    poll()
      .catch(() => {})
      .finally(() => setTimeout(pump, 400));
  };
  pump();
}

boot().catch((e) => {
  console.error(e);
  process.exit(1);
});
