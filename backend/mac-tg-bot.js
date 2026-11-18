#!/usr/bin/env node
// Brand: DELvEK · https://delvek.net
"use strict";
/**
 * DELvEK Telegram decrypt bot (@DELvEKBot) — free App Store / TestFlight IPAs.
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
const { spawn, spawnSync } = require("child_process");
const fairplayBackends = require("./fairplayBackends");
const ipaCache = require("./mac-tg-ipa-cache");
const urlLog = require("./mac-tg-url-log");
const { renderProgressBanner, renderDownloadThumb } = require("./mac-tg-progress-banner");

const API_ROOT = String(process.env.TELEGRAM_API_ROOT || "https://api.telegram.org").replace(/\/+$/, "");
const LOCAL_API =
  process.env.TELEGRAM_LOCAL_API === "1" ||
  /localhost|127\.0\.0\.1/i.test(API_ROOT);
const TG_DOC_MAX = Math.max(
  1,
  Number(process.env.TELEGRAM_UPLOAD_MAX_MB || (LOCAL_API ? 2000 : 50))
) * 1024 * 1024;
const TG_GETFILE_MAX = LOCAL_API
  ? Math.max(TG_DOC_MAX, 4 * 1024 * 1024 * 1024)
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

function buildIpaFileName({ name, version }) {
  const n = sanitizeFilePart(name);
  const v = version ? `_v${sanitizeFilePart(version)}` : "";
  return `${n}${v}-[DELvEK.NeT].ipa`;
}

/** Progress-card stage lines — cruel reminders that you suck at sideloading. */
function cruelReminder(pct, _hint) {
  const lines = [
    "You suck at sideloading.",
    "Sideloading owns you.",
    "Still can't sideload? Cute.",
    "This is what skill issue looks like.",
    "AltStore is laughing at you.",
    "Maybe learn to sideload first.",
    "Decrypting because you can't.",
    "Almost done. You're still bad at this.",
    "IPA ready. Sideloading skill: zero.",
  ];
  const p = Math.max(0, Math.min(99, Math.round(Number(pct) || 0)));
  const i = Math.min(lines.length - 1, Math.floor(p / 12));
  return lines[i];
}

/** Rewrite legacy Tetherless / DELvEK suffixes when re-sending from cache. */
function displayIpaFileName(name) {
  const raw = String(name || "App.ipa");
  if (/\.ipa$/i.test(raw)) {
    return raw
      .replace(/-Tetherless\.ipa$/i, "-[DELvEK.NeT].ipa")
      .replace(/-DELvEK\.ipa$/i, "-[DELvEK.NeT].ipa")
      .replace(/-\[DELvEK\.NeT\]\.ipa$/i, "-[DELvEK.NeT].ipa");
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

function siteLinkButtons() {
  const site = httpsUrl(
    process.env.DELVEK_SITE_URL || process.env.TETHERLESS_SITE_URL,
    "https://delvek.net"
  );
  const patch = httpsUrl(
    process.env.DELVEK_PATCH_URL || process.env.TETHERLESS_PATCH_URL,
    `${site}/`
  );
  const vip = httpsUrl(
    process.env.DELVEK_VIP_URL || process.env.TETHERLESS_VIP_URL,
    `${site}/vip`
  );
  return [
    { text: "🧩 Patch", url: patch.endsWith("/") ? patch : `${patch}/` },
    { text: "⭐ Get VIP", url: vip },
  ];
}

/** Final IPA buttons only: Patch · Get VIP (inline tabs under the document). */
function resultKeyboard() {
  return { inline_keyboard: [siteLinkButtons()] };
}

/**
 * Done sharp-card buttons: Download puts the IPA behind this same card
 * (editMessageMedia photo→document — no second bubble).
 * callback_data must stay ≤64 bytes (`dl:` + short token).
 */
function doneCardKeyboard(downloadToken) {
  const rows = [];
  if (downloadToken) {
    rows.push([{ text: "⬇️ Download", callback_data: `dl:${downloadToken}` }]);
  }
  rows.push(siteLinkButtons());
  return { inline_keyboard: rows };
}

/** In-memory IPA handoff for Download taps on the done card (disk / file_id). */
const pendingDownloads = new Map();

function mintDownloadToken(payload) {
  const token = `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`.slice(0, 16);
  pendingDownloads.set(token, { ...payload, at: Date.now() });
  // Drop stale tokens (1h) so the map can't grow without bound.
  const cutoff = Date.now() - 60 * 60 * 1000;
  for (const [k, v] of pendingDownloads) {
    if (!v || (v.at && v.at < cutoff)) pendingDownloads.delete(k);
  }
  return token;
}

/**
 * Force Patch/Get VIP onto a bot-owned message.
 * Prefer editMessageReplyMarkup alone — editMessageCaption fails with
 * "message is not modified" when caption already matches and then drops markup.
 */
async function attachIpaChrome(chatId, messageId, { caption, replyMarkup } = {}) {
  const mid = Number(messageId);
  if (!chatId || !mid) return false;
  const markup = replyMarkup || resultKeyboard();

  const markupOnly = await tgApi("editMessageReplyMarkup", {
    chat_id: chatId,
    message_id: mid,
    reply_markup: markup,
  }).catch((e) => ({ ok: false, description: String((e && e.message) || e) }));
  if (markupOnly && markupOnly.ok) return true;

  if (caption) {
    const withCap = await tgApi("editMessageCaption", {
      chat_id: chatId,
      message_id: mid,
      caption,
      parse_mode: "HTML",
      reply_markup: markup,
    }).catch((e) => ({ ok: false, description: String((e && e.message) || e) }));
    if (withCap && withCap.ok) return true;
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
    // Belt-and-suspenders: some clients drop markup on the initial send.
    await attachIpaChrome(chatId, r.result.message_id, { caption, replyMarkup: markup });
  }
  return r;
}

async function ensureIpaButtonTabs(chatId, messageId, { caption, replyMarkup } = {}) {
  const markup = replyMarkup || resultKeyboard();
  const mid = Number(messageId);
  if (await attachIpaChrome(chatId, mid, { caption, replyMarkup: markup })) return true;
  // Visible fallback: reply under the IPA with the same tabs.
  const reply = await tgApi("sendMessage", {
    chat_id: chatId,
    text: "DELvEK",
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

function fetchStoreIcon(storeUrl) {
  return lookupStoreApp(storeUrl).iconPath || "";
}

/**
 * Telegram document thumbnail: app icon + white download arrow (done-card art).
 * Falls back to plain store icon if sharp thumb render fails.
 */
async function buildIpaDocumentThumb(storeUrl) {
  const iconPath = storeUrl ? fetchStoreIcon(storeUrl) : "";
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
  let storeUrl = "";
  let iconPath = "";
  let bannerPath = "";
  let lastEdit = 0;
  let lastPct = -1;
  let lastStage = "";
  // Serialize paints — parallel start()+fromBackendLine used to send two photos.
  let paintChain = Promise.resolve();

  function bannerFile() {
    if (!bannerPath) {
      bannerPath = path.join(WORK, `progress-${chatId}-${Date.now()}.jpg`);
    }
    return bannerPath;
  }

  async function makeBanner(stage, pct, { done } = {}) {
    return renderProgressBanner({
      name,
      // Card copy = cruel sideloading roast (real stage stays in logs).
      stage: done
        ? "IPA ready. Sideloading skill: zero."
        : cruelReminder(pct, stage || lastStage),
      pct: done ? 100 : pct,
      iconPath,
      dest: bannerFile(),
      tag: "delvek",
      brand: "DELVEK",
      done: !!done,
    });
  }

  async function clearPhotoCaption() {
    if (!messageId || !hasPhoto) return;
    await tgApi("editMessageCaption", {
      chat_id: chatId,
      message_id: messageId,
      caption: "",
    }).catch(() => {});
  }

  async function paintBanner(stage, pct) {
    const run = async () => {
      const img = await makeBanner(stage, pct);
      if (!img) {
        // Prefer silence over duplicating banner text as a caption.
        console.warn("[job] banner render failed — leaving prior card");
        return false;
      }
      if (!messageId) {
        const sent = await sendPhotoBotApi(chatId, img, "");
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

  return {
    get name() {
      return name;
    },
    get storeUrl() {
      return storeUrl;
    },
    async start(link, hintName) {
      storeUrl = link || "";
      const meta = link ? lookupStoreApp(link) : { name: "", iconPath: "" };
      // Prefer short App Store title (drop “- Play Music Offline” style suffixes for the card).
      const rawName = hintName || meta.name || "App";
      name = String(rawName).split(/\s+[—\-–]\s+/)[0].trim() || rawName;
      iconPath = (meta.iconPath && fs.existsSync(meta.iconPath) && meta.iconPath) || "";
      lastStage = "Fetching…";
      lastPct = 4;
      const ok = await paintBanner("Fetching…", 4);
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
    async setStage(stage, pct) {
      // Never regress: upload heartbeats / stage floors (76–80) used to yank 90% → 70%.
      const raw = Math.max(0, Math.min(99, Math.round(Number(pct) || 0)));
      const p = Math.max(lastPct < 0 ? 0 : lastPct, raw);
      const now = Date.now();
      const stageChanged = stage && stage !== lastStage;
      if (!stageChanged && p < lastPct + 3 && now - lastEdit < 1800) return;
      lastEdit = now;
      lastPct = p;
      if (stage) lastStage = stage;
      console.log("[job]", stage || lastStage, `${p}%`);
      await paintBanner(stage || lastStage, p);
    },
    /** Map backend say() lines into card stages. */
    async fromBackendLine(line) {
      const t = String(line || "");
      if (/ipatool|download|encrypted IPA cache/i.test(t)) return this.setStage("Downloading…", 28);
      if (/unfairplay|decrypt|FairPlay|model|Tetherless decrypt/i.test(t)) {
        return this.setStage("Decrypting…", 55);
      }
      if (/produced|done/i.test(t)) return this.setStage("Decrypting…", 72);
      // Floor only — setStage keeps progress monotonic (won't drop below current %).
      if (/upload/i.test(t)) return this.setStage("Uploading…", Math.max(lastPct, 80));
      return this.setStage(lastStage || "Working…", Math.max(lastPct, 12));
    },
    async setUploadPct(pct) {
      // Map file upload 0–100% into card band 80–99 (after decrypt ~72–78).
      const p = 80 + Math.round((Math.max(0, Math.min(100, pct)) / 100) * 19);
      return this.setStage("Uploading…", p);
    },
    async clear() {
      if (!messageId) return;
      await tgApi("deleteMessage", { chat_id: chatId, message_id: messageId }).catch(() => {});
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
    /**
     * Morph to download-arrow done art and KEEP the card.
     * IPA is not auto-sent — user taps ⬇️ Download IPA on this card.
     * @param {object} [ready] diskPath / fileId / caption / fileName for the tap
     */
    async finishReady(ready = {}) {
      const caption = ready.caption || "";
      try {
        const img = await makeBanner("Done", 100, { done: true });
        if (img && messageId && hasPhoto) {
          // Mint after we know messageId so Download can edit THIS card in-place.
          const token = mintDownloadToken({
            chatId: String(chatId),
            cardMessageId: Number(messageId) || 0,
            diskPath: ready.diskPath || "",
            fileId: ready.fileId || "",
            fileName: ready.fileName || "",
            caption,
            storeUrl: ready.storeUrl || storeUrl || "",
            adam: ready.adam || "",
            version: ready.version || "",
            bid: ready.bid || "",
            name: ready.name || name || "",
            minIos: ready.minIos || "",
            bytes: ready.bytes || 0,
          });
          const markup = doneCardKeyboard(token);
          let edited = await editMessageMediaBotApi(chatId, messageId, img, caption, markup);
          if (!(edited && edited.ok)) {
            await new Promise((r) => setTimeout(r, 400));
            edited = await editMessageMediaBotApi(chatId, messageId, img, caption, markup);
          }
          if (!(edited && edited.ok)) {
            // Media edit failed — still try markup + caption so Download works.
            if (caption) {
              await tgApi("editMessageCaption", {
                chat_id: chatId,
                message_id: messageId,
                caption,
                parse_mode: "HTML",
                reply_markup: markup,
              }).catch(() => {});
            } else {
              await tgApi("editMessageReplyMarkup", {
                chat_id: chatId,
                message_id: messageId,
                reply_markup: markup,
              }).catch(() => {});
            }
          }
          return true;
        }
      } catch (e) {
        console.warn("[job] finishReady failed:", String((e && e.message) || e).slice(0, 160));
      }
      // No live photo card — fall back to sending the IPA document directly.
      return false;
    },
    /** @deprecated Prefer finishReady — kept for fail-path callers that just need clear. */
    async finish() {
      await this.clear();
    },
    async fail(err) {
      lastStage = "Failed";
      // Allow 0% on failure only.
      lastPct = -1;
      lastPct = 0;
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
    args.push("--form-string", `media=${JSON.stringify(mediaObj)}`);
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
 * Peers for Premium user → bot chat (never the numeric *user* chat_id —
 * that lands in Saved Messages). Prefer bot id from getMe; @username is
 * fallback only (env typos like ipaagentbot often 404).
 */
function premiumPeerCandidates() {
  const out = [];
  if (BOT_ID) out.push(String(BOT_ID));
  const uname = String(BOT_USERNAME || "").trim().replace(/^@/, "");
  if (uname) out.push(`@${uname}`);
  return [...new Set(out)];
}

function premiumPeer() {
  return premiumPeerCandidates()[0] || "";
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
          if (j.ok) j.chat_id = String(chatId);
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
          if (parsed && parsed.ok) parsed.chat_id = String(chatId);
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
    console.log(`[job] uploading via Premium session (${mb} MB) → ${peer}`);
    if (card) await card.setStage("Uploading…", 76);
    else await say(`uploading via Premium → ${peer} (${mb} MB)…`);
    // Stage via Premium (user MTProto). User→bot messages usually have no inline
    // tabs. Bot copies to get a file_id, then sendDocument(file_id) WITH
    // Patch/Get VIP baked in (edit* alone is not enough on some clients).
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
      let copied = null;
      for (let attempt = 0; attempt < 6; attempt++) {
        if (attempt) await new Promise((r) => setTimeout(r, 700 * attempt));
        // Bare copy — caption/tabs come from the bot sendDocument(file_id) below.
        copied = await tgApi("copyMessage", {
          chat_id: chatId,
          from_chat_id: chatId,
          message_id: stagedId,
        }).catch((e) => ({ ok: false, description: String((e && e.message) || e) }));
        if (!(copied && copied.ok && copied.result && copied.result.message_id)) continue;

        const bridgeMid = copied.result.message_id;
        const fileId =
          (copied.result.document && copied.result.document.file_id) ||
          (copied.result.video && copied.result.video.file_id) ||
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

        await tgApi("deleteMessage", { chat_id: chatId, message_id: stagedId }).catch(() => {});
        console.log("[job] bot produced IPA with tabs", finalMid, fileId ? "via file_id" : "via copy");
        return {
          ok: true,
          premium: true,
          bot_resent: true,
          message_id: finalMid,
          chat_id: String(chatId),
          result: finalResult,
        };
      }
      // Last resort: keep Premium IPA + bot reply with Patch/Get VIP tabs.
      console.warn(
        "[job] bot copyMessage failed; keeping Premium IPA + button reply:",
        (copied && copied.description) || "unknown"
      );
      await ensureIpaButtonTabs(chatId, stagedId, { caption: caption || "", replyMarkup: markup });
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
      ? "Premium session upload failed / disabled and file exceeds Bot API limit."
      : LOCAL_API
        ? `Local Bot API cap is ~${Math.round(TG_DOC_MAX / 1024 / 1024)} MB.`
        : "Cloud Bot API caps ~50 MB. Wire your Premium user session: zsh server/mac-ssh.sh session";
    return {
      ok: false,
      description: `IPA is ${mb} MB — ${hint} Saved on Mac: ${filePath}`,
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
  // Single /start blurb — no status, no inline menu, no Mac ops text.
  return (
    `Hi, I'm <b>DELvEK</b>, the decryption bot. I'm fully static and capable of decrypting ` +
    `iOS, iPadOS, macOS, tvOS, and visionOS 26/27 apps, and I'm cute too!\n\n` +
    `You can use me in this chat. Just send the App Store application link, and I'll provide the decrypted file.\n\n` +
    `Mention me in any group or chat with:\n` +
    `<code>@DELvEKBot &lt;App Store App Link&gt;</code>\n` +
    `to get a download link.\n\n` +
    `There are subscription options that allow you to decrypt TestFlight betas, apps up to 4 GB, ` +
    `paid applications, older app versions, and select platforms - all without the 3 apps/day limit. ` +
    `An HTTP API is also available for automation. Contact @mrzefie to subscribe, or if you have other questions.\n\n` +
    `And for personal use, it's always free. Moreover, cached applications don't count towards your limit! ` +
    `However, using multiple accounts or engaging in other suspicious activity will result in a ban of all associated accounts.`
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

async function decryptLocalIpa(chatId, ipaPath, label) {
  if (!fs.existsSync(ipaPath) || fs.statSync(ipaPath).size < 100) {
    throw new Error("IPA not found or empty: " + ipaPath);
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
    throw e;
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

  // Prefer disk when cached name still says Tetherless / bare DELvEK.
  const cachedName = String(entry.fileName || "");
  const needsDelvekName =
    /Tetherless\.ipa$/i.test(cachedName) ||
    (/DELvEK\.ipa$/i.test(cachedName) && !/\[DELvEK\.NeT\]\.ipa$/i.test(cachedName));
  const fileName = displayIpaFileName(
    needsDelvekName && hasDisk
      ? path.basename(entry.diskPath)
      : entry.fileName || (hasDisk ? path.basename(entry.diskPath) : "App.ipa")
  );
  const caption = buildCaption({
    bid: entry.bid,
    version: entry.version,
    minIos: entry.minIos,
    storeUrl: entry.storeUrl,
  });

  const card = createProgressCard(chatId);
  if (!quiet) {
    await card.start(entry.storeUrl || "", entry.name || "App");
    await card.setStage("Ready…", 96);
  }

  const kept = await card.finishReady({
    diskPath: hasDisk ? entry.diskPath : "",
    // Skip stale file_id when we must rename via disk on Download tap.
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
  });
  if (kept) {
    console.log("[cache] hit done-card", entry.adam, entry.version || "latest");
    return true;
  }

  // Card missing — send document so cache still delivers.
  const pending = {
    diskPath: hasDisk ? entry.diskPath : "",
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
  };
  const sent = await sendPendingDownload(chatId, pending);
  if (sent && sent.ok) {
    await card.finish();
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

async function decryptStoreUrl(chatId, link, vreq) {
  if (isAppleSystemApp(link, "")) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text: "⛔ Apple system apps are not supported for decryption.",
    });
    return;
  }
  if (await trySendCached(chatId, link, vreq)) return;

  const card = createProgressCard(chatId);
  const dir = fs.mkdtempSync(path.join(WORK, "job-"));

  try {
    // Establish the single progress photo BEFORE any backend say() ticks —
    // starting prep in parallel used to race and send duplicate banners.
    await card.start(link);
    await card.setStage("Fetching…", 8);

    await fairplayBackends.ensureEncryptedSource({
      url: link,
      dir,
      say: (t) => {
        card.fromBackendLine(t);
      },
      vreq,
    });

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
    await card.setStage("Uploading…", 74);
    await deliverResult(chatId, result, { storeUrl: link, versionHint: vreq, card });
  } catch (e) {
    await card.fail((e && e.message) || e);
    throw e;
  } finally {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  }
}

async function deliverResult(chatId, result, opts = {}) {
  const ipaMeta = readIpaMeta(result.file);
  const name = opts.label || ipaMeta.name || result.name || (opts.card && opts.card.name) || "App";
  const version = opts.versionHint || ipaMeta.version || "";
  const bid = ipaMeta.bid || "";
  const minIos = ipaMeta.minIos || "";
  const storeUrl = opts.storeUrl || "";
  const card = opts.card || null;
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

  // Durable Mac copy — Download button sends this; no auto document bubble.
  const keep = ipaCache.diskPathFor(adam || "app", version || "latest", fileName);
  try {
    ipaCache.linkOrCopy(result.file, keep);
  } catch {
    fs.copyFileSync(result.file, keep);
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
    });
    console.log("[cache] stored disk-ready", adam, version || "latest", keep);
  }

  const ready = {
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
  };

  if (card) {
    const kept = await card.finishReady(ready);
    if (kept) {
      console.log("[job] done card ready — IPA waits on Download tap:", keep);
      return;
    }
  }

  // No progress card (or edit failed): send the document so the user still gets the IPA.
  const thumbPath = await buildIpaDocumentThumb(storeUrl);
  const sent = await sendDocument(chatId, keep, fileName, caption, {
    thumbPath,
    replyMarkup: resultKeyboard(),
  });
  if (!sent || !sent.ok) {
    const why = (sent && sent.description) || "Telegram attach failed";
    console.warn("[job] sendDocument:", why);
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
  } else {
    const doc = sent.result && sent.result.document;
    console.log("[job] sent IPA to Telegram (no card):", keep);
    if (adam && doc && doc.file_id) {
      ipaCache.put({
        adam,
        version,
        bid,
        name,
        minIos,
        storeUrl,
        fileName,
        caption,
        fileId: doc.file_id || "",
        fileUniqueId: doc.file_unique_id || "",
        messageId: (sent.result && sent.result.message_id) || 0,
        fromChatId: String(chatId),
        bytes,
        diskPath: keep,
      });
    }
  }
}

/**
 * Download tap: put the IPA behind the done card (same message → document).
 * Only opens a new bubble if in-place edit can't take the file (size / API).
 */
async function sendPendingDownload(chatId, pending, { cardMessageId } = {}) {
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
  const markup = resultKeyboard();
  const cardMid = Number(cardMessageId || pending.cardMessageId || 0) || 0;
  const disk = pending.diskPath && fs.existsSync(pending.diskPath) ? pending.diskPath : "";
  const bytes =
    pending.bytes ||
    (disk ? fs.statSync(disk).size : 0);
  const thumbPath = await buildIpaDocumentThumb(pending.storeUrl || "");

  // Prefer editing the sharp card into the IPA document (one message).
  const canEditInPlace =
    cardMid &&
    (pending.fileId || (disk && (LOCAL_API || bytes <= TG_DOC_MAX)));

  if (canEditInPlace) {
    const edited = await editMessageToDocumentBotApi(chatId, cardMid, disk, fileName, caption, {
      thumbPath,
      replyMarkup: markup,
      fileId: pending.fileId || "",
    });
    if (edited && edited.ok) {
      const doc = edited.result && edited.result.document;
      console.log("[job] IPA behind Download — card→document", cardMid, fileName);
      if (pending.adam) {
        ipaCache.put({
          adam: pending.adam,
          version: pending.version || "",
          bid: pending.bid || "",
          name: pending.name || "",
          minIos: pending.minIos || "",
          storeUrl: pending.storeUrl || "",
          fileName,
          caption,
          fileId: (doc && doc.file_id) || pending.fileId || "",
          fileUniqueId: (doc && doc.file_unique_id) || "",
          messageId: cardMid,
          fromChatId: String(chatId),
          bytes,
          diskPath: disk || pending.diskPath || "",
        });
      }
      await attachIpaChrome(chatId, cardMid, { caption, replyMarkup: markup });
      return { ok: true, result: edited.result, inPlace: true };
    }
    console.warn(
      "[job] card→document edit failed:",
      (edited && edited.description) || "unknown"
    );
  }

  // Fallback: new document bubble (large Premium files / edit unsupported).
  if (pending.fileId) {
    const r = await sendIpaByFileId(chatId, pending.fileId, caption, markup);
    if (r && r.ok) {
      if (cardMid) {
        await tgApi("deleteMessage", { chat_id: chatId, message_id: cardMid }).catch(() => {});
      }
      return r;
    }
  }
  if (!disk) return { ok: false, description: "IPA no longer on Mac — decrypt again" };

  const sent = await sendDocument(chatId, disk, fileName, caption, {
    thumbPath,
    replyMarkup: markup,
  });
  if (sent && sent.ok) {
    if (cardMid) {
      await tgApi("deleteMessage", { chat_id: chatId, message_id: cardMid }).catch(() => {});
    }
    const doc = sent.result && sent.result.document;
    const viaPremium = !!(sent.premium && sent.message_id);
    if (pending.adam) {
      ipaCache.put({
        adam: pending.adam,
        version: pending.version || "",
        bid: pending.bid || "",
        name: pending.name || "",
        minIos: pending.minIos || "",
        storeUrl: pending.storeUrl || "",
        fileName,
        caption,
        fileId: (doc && doc.file_id) || pending.fileId || "",
        fileUniqueId: (doc && doc.file_unique_id) || "",
        messageId: viaPremium ? Number(sent.message_id) || 0 : (sent.result && sent.result.message_id) || 0,
        fromChatId: viaPremium ? String(sent.chat_id || chatId) : String(chatId),
        bytes,
        diskPath: disk,
      });
    }
  }
  return sent || { ok: false, description: "upload failed" };
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

/** Parallel decrypt workers (default 3). Set MAC_TG_WORKERS=1 for serial. */
const MAX_WORKERS = Math.max(1, Math.min(8, Number(process.env.MAC_TG_WORKERS || 3) || 3));
let activeWorkers = 0;
const jobWaiters = [];

async function withWorker(chatId, fn) {
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
    await tgApi("sendMessage", { chat_id: chatId, text: "Failed: " + err }).catch(() => {});
  } finally {
    activeWorkers--;
    const next = jobWaiters.shift();
    if (next) next();
    console.log(`[job] worker done (${activeWorkers}/${MAX_WORKERS} active, ${jobWaiters.length} waiting)`);
  }
}

async function handleCallback(cq) {
  const chatId = cq.message && cq.message.chat && cq.message.chat.id;
  const data = String(cq.data || "");
  if (!chatId) return;
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
      await decryptStoreUrl(chatId, entry.storeUrl, vreq);
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
    await withWorker(chatId, async () => {
      const sent = await sendPendingDownload(chatId, pending, { cardMessageId });
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
  if (!chatAllowed(chatId)) {
    await tgApi("sendMessage", { chat_id: chatId, text: "This bot is private." });
    return;
  }

  const doc = msg.document;
  const docName = (doc && doc.file_name) || "";
  if (doc && /\.ipa$/i.test(docName)) {
    // Premium/cache echo: our clear IPA uploads come back as user documents — don't re-decrypt.
    if (/-(?:DELvEK|Tetherless|\[DELvEK\.NeT\])\.ipa$/i.test(docName)) {
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

  if (/^decrypt\s+/i.test(text) || (/^[\w./-]+\.ipa$/i.test(text) && !/^https?:/i.test(text))) {
    const ipaPath = resolveDropPath(text);
    await withWorker(chatId, async () => {
      await decryptLocalIpa(chatId, ipaPath, path.basename(ipaPath, ".ipa"));
    });
    return;
  }

  const link = text.split(/\s+/).find((t) => isStoreUrl(t) || isTestFlightUrl(t));
  if (!link) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text: "Paste an App Store link or send a `.ipa`.",
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
  rememberStoreUrl(chatId, link, vreq);
  await withWorker(chatId, async () => {
    await decryptStoreUrl(chatId, link, vreq);
  });
}

async function poll() {
  try {
    const r = await tgApi("getUpdates", {
      offset,
      timeout: 0,
      allowed_updates: ["message", "callback_query"],
    });
    if (!r.ok || !Array.isArray(r.result)) return;
    for (const u of r.result) {
      offset = Math.max(offset, (u.update_id || 0) + 1);
      if (u.callback_query) await handleCallback(u.callback_query);
      else if (u.message) await handleMessage(u.message);
    }
  } catch (e) {
    console.warn("poll:", (e && e.message) || e);
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
  // Only /start — clear any cached help/status/cache commands + default menu.
  await tgApi("deleteMyCommands", {}).catch(() => {});
  await tgApi("setMyCommands", {
    commands: [{ command: "start", description: "Start DELvEK" }],
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
    `DELvEK TG bot @${BOT_USERNAME || "?"} id=${BOT_ID || "?"} · workers=${MAX_WORKERS} · decrypt=${!!(st.unfairplay && st.unfairplay.ready)} · model=${!!(st.enrollmentModel && st.enrollmentModel.ready)}`
  );
  console.log(
    `access=${LOCKDOWN && ALLOWED.length ? `lockdown(${ALLOWED.length} ids)` : "public"} · banner=${bannerMode}`
  );
  console.log(
    `API ${API_ROOT} · local=${LOCAL_API} · uploadMaxMB=${Math.round(TG_DOC_MAX / 1024 / 1024)} · premiumUser=${preferPremiumUpload()} · peer=${premiumPeer() || "unset"}`
  );
  console.log(
    `IPA cloud cache: ${ipaCache.CACHE_DIR} (${ipaCache.list().length} clear, ${ipaCache.listEncrypted().length} encrypted)`
  );
  console.log(`Drop folder for TestFlight IPAs: ${DROP}`);
  console.log("WebSSH: zsh server/mac-ssh.sh start | status | logs | session");
  setInterval(() => {
    poll().catch(() => {});
  }, 2000);
  poll().catch(() => {});
}

boot().catch((e) => {
  console.error(e);
  process.exit(1);
});
