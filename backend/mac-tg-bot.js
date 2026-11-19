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
const crypto = require("crypto");
const { spawn, spawnSync } = require("child_process");
const fairplayBackends = require("./fairplayBackends");
const ipatoolExtras = require("./mac-ipatool-extras");
const ipaCache = require("./mac-tg-ipa-cache");
const urlLog = require("./mac-tg-url-log");
const {
  renderProgressBanner,
  renderDownloadThumb,
  renderVersionPickerBanner,
} = require("./mac-tg-progress-banner");
const publicDl = require("./mac-tg-public-dl");

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
 * Clean a backend say() / stage line for the progress-card terminal.
 * Public-facing names only: ipatool→TetherTool, unfairplay→Tetherless, FairPlay→trustC0re.
 */
function cleanTermLine(raw) {
  return String(raw || "")
    .replace(/\u001b\[[0-9;]*[a-zA-Z]/g, "")
    .replace(/\r/g, "")
    .split("\n")
    .map((l) =>
      l
        .replace(/[^\x20-\x7E]+/g, " ")
        .replace(/\s+/g, " ")
        .trim()
        .replace(/\bipatool\b/gi, "TetherTool")
        .replace(/\bunfairplay\b/gi, "Tetherless")
        .replace(/\bFairPlay\b/g, "trustC0re")
        .replace(/\bfairplay\b/gi, "trustC0re")
    )
    .filter(Boolean)[0] || "";
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

/** Legacy Download-button tokens (pre card→IPA auto-finish). */
const pendingDownloads = new Map();

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
    // edit* can drop tabs on large/Premium-bridged docs — ensure or reply with Patch/VIP.
    await ensureIpaButtonTabs(chatId, r.result.message_id, { caption, replyMarkup: markup });
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
async function buildIpaDocumentThumb(storeUrl, iconOverride) {
  let iconPath = "";
  if (iconOverride && fs.existsSync(iconOverride)) iconPath = iconOverride;
  if (!iconPath && storeUrl) iconPath = fetchStoreIcon(storeUrl) || "";
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

  async function makeBanner(stage, pct, { done } = {}) {
    if (done) pushTerm("done — IPA ready");
    return renderProgressBanner({
      name,
      version,
      stage: stage || lastStage || "",
      logLines: termLog.length ? termLog.slice() : [stage || lastStage || "starting…"],
      pct: done ? 100 : pct,
      iconPath,
      dest: bannerFile(),
      tag: "delvek",
      brand: "DELvEK.NeT",
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
      lastStage = "Fetching…";
      lastPct = 4;
      pushTerm("$ job start");
      pushTerm("Fetching…");
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
    /** Update marketing version on the right-side card label and repaint. */
    async setVersion(nextVer, stage, pct) {
      if (closed) return;
      const v = String(nextVer || "").trim().replace(/^v/i, "");
      if (!v || isExternalVersionId(v)) return;
      if (v === version) return;
      version = v;
      const p =
        pct != null
          ? Math.max(lastPct < 0 ? 0 : lastPct, Math.max(0, Math.min(99, Math.round(Number(pct) || 0))))
          : lastPct < 0
            ? 0
            : lastPct;
      lastPct = p;
      if (stage) lastStage = stage;
      await paintBanner(stage || lastStage || "Working…", p);
    },
    /** Swap to an IPA-extracted icon (this build’s artwork) and repaint. */
    async setIcon(nextIcon, stage, pct) {
      if (closed) return;
      const next = String(nextIcon || "");
      if (!next || !fs.existsSync(next)) return;
      iconPath = next;
      const p =
        pct != null
          ? Math.max(lastPct < 0 ? 0 : lastPct, Math.max(0, Math.min(99, Math.round(Number(pct) || 0))))
          : lastPct < 0
            ? 0
            : lastPct;
      lastPct = p;
      if (stage) lastStage = stage;
      await paintBanner(stage || lastStage || "Working…", p);
    },
    get iconPath() {
      return iconPath;
    },
    async setStage(stage, pct) {
      if (closed) return;
      // Never regress: upload heartbeats / stage floors (76–80) used to yank 90% → 70%.
      const raw = Math.max(0, Math.min(99, Math.round(Number(pct) || 0)));
      const p = Math.max(lastPct < 0 ? 0 : lastPct, raw);
      const now = Date.now();
      const stageChanged = stage && stage !== lastStage;
      const logged = stage ? pushTerm(stage) : false;
      // Paint sooner when the terminal gets a new line; still throttle pct-only spam.
      if (!stageChanged && !logged && p < lastPct + 3 && now - lastEdit < 1800) return;
      if (!stageChanged && logged && now - lastEdit < 700) {
        lastPct = p;
        return;
      }
      lastEdit = now;
      lastPct = p;
      if (stage) lastStage = stage;
      console.log("[job]", stage || lastStage, `${p}%`);
      await paintBanner(stage || lastStage, p);
    },
    /** Append backend say() to the terminal and nudge stage %. */
    async fromBackendLine(line) {
      const t = String(line || "");
      const logged = pushTerm(t);
      let stage = lastStage || "Working…";
      let pct = Math.max(lastPct < 0 ? 0 : lastPct, 12);
      if (/ipatool|download|encrypted IPA cache/i.test(t)) {
        stage = "Downloading…";
        pct = 28;
      } else if (/unfairplay|decrypt|FairPlay|model|Tetherless decrypt/i.test(t)) {
        stage = "Decrypting…";
        pct = 55;
      } else if (/produced|done/i.test(t)) {
        stage = "Decrypting…";
        pct = 72;
      } else if (/upload/i.test(t)) {
        stage = "Uploading…";
        pct = Math.max(lastPct, 80);
      }
      // Force a paint when we got a new terminal line (bypass setStage's skip).
      if (logged) {
        const raw = Math.max(0, Math.min(99, Math.round(Number(pct) || 0)));
        const p = Math.max(lastPct < 0 ? 0 : lastPct, raw);
        const now = Date.now();
        if (now - lastEdit < 650 && p < lastPct + 2 && stage === lastStage) {
          lastPct = p;
          return;
        }
        lastEdit = now;
        lastPct = p;
        lastStage = stage;
        console.log("[job]", stage, `${p}%`, cleanTermLine(t).slice(0, 60));
        await paintBanner(stage, p);
        return;
      }
      return this.setStage(stage, pct);
    },
    async setUploadPct(pct) {
      // Map file upload 0–100% into card band 80–99 (after decrypt ~72–78).
      const p = 80 + Math.round((Math.max(0, Math.min(100, pct)) / 100) * 19);
      return this.setStage("Uploading…", p);
    },
    /**
     * Release the progress photo without deleting it (after it became the IPA).
     * Drains paint queue first so a late Uploading… paint can't resurrect the card.
     */
    async release() {
      closed = true;
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
      pushTerm(`error: ${String(err || "failed").slice(0, 80)}`);
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
  // Single /start blurb — paste links only; no Mac ops / menu clutter.
  return (
    `Hi, I'm <b>DELvEK</b>, the decryption bot. I'm fully static and capable of decrypting ` +
    `iOS, iPadOS, macOS, tvOS, and visionOS 26/27 apps, and I'm cute too!\n\n` +
    `Just <b>paste an App Store link</b> here and I'll send the decrypted IPA.\n\n` +
    `Mention me in any group or chat with:\n` +
    `<code>@DELvEKBot &lt;App Store App Link&gt;</code>\n` +
    `to get a download link.\n\n` +
    `Free apps work with the Mac’s App Store session. Paid apps only if that Apple ID already owns them.\n\n` +
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
  const rows = [[{ text: "⭐ Latest", callback_data: `ver:${token}:L`.slice(0, 64) }]];
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
    `verpick-${pending.chatId}-${pending.token || "x"}-p${p}-${Date.now()}.jpg`
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
    `<b>${escapeHtml(pending.title || "App")}</b>\n` +
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
    const text = `*VERSIONS*\n${pending.title}\n\n${lines.join("\n")}\n\n_Reply with a number_`;
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
  if (warm) warmVersionIconsForPage(pending, slice);
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

  const picks = versions.map((v, i) => {
    const ver = String(v.v || v.version || v.label || "—").slice(0, 24);
    const ext = String(v.externalVersionId || v.external_id || "").trim();
    const marketing = isExternalVersionId(ver) ? "" : ver;
    const label = v.current ? `⭐ Latest · ${ver}` : `v${ver}`;
    return {
      i,
      label: label.slice(0, 64),
      ext,
      marketing,
      current: !!v.current,
    };
  });

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

async function startDecryptFromVersionPick(pending, { vreq, versionLabel, label }) {
  const chatId = pending.chatId;
  pendingVerPicks.delete(pending.token);
  activeVerPickByChat.delete(chatId);
  if (pending.messageId) {
    await tgApi("deleteMessage", {
      chat_id: chatId,
      message_id: pending.messageId,
    }).catch(() => {});
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
    await tgApi("answerCallbackQuery", {
      callback_query_id: cq.id,
      text: "Decrypting Latest…",
    }).catch(() => {});
    await startDecryptFromVersionPick(pending, {
      vreq: "",
      versionLabel: "",
      label: "Latest",
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
  const needsDelvekName =
    /Tetherless\.ipa$/i.test(cachedName) ||
    (/DELvEK\.ipa$/i.test(cachedName) && !/\[DELvEK\.NeT\]\.ipa$/i.test(cachedName));
  const needsVersionRename =
    !!version && /_v\d{6,}-\[DELvEK\.NeT\]\.ipa$/i.test(cachedName);
  let fileName;
  if ((needsDelvekName || needsVersionRename) && version) {
    const baseName =
      entry.name ||
      String(cachedName).replace(/_v[\w.-]*-\[DELvEK\.NeT\]\.ipa$/i, "") ||
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

  let iconPath =
    (entry.iconPath && fs.existsSync(entry.iconPath) && entry.iconPath) || "";
  if (!iconPath && hasDisk) {
    const iconDest = path.join(
      path.dirname(entry.diskPath),
      `${path.basename(entry.diskPath, ".ipa")}.icon.png`
    );
    iconPath =
      (fs.existsSync(iconDest) && iconDest) ||
      extractIpaIcon(entry.diskPath, iconDest) ||
      "";
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

  // Persist this build’s icon next to the IPA for thumbs / re-sends.
  let iconPath = "";
  if (opts.iconPath && fs.existsSync(opts.iconPath)) {
    iconPath = opts.iconPath;
  } else {
    const iconDest = path.join(path.dirname(keep), `${path.basename(keep, ".ipa")}.icon.png`);
    iconPath = extractIpaIcon(keep, iconDest);
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

  // Telegram Premium hard-caps documents at 4 GB — stage a Mac download link instead.
  if (bytes > TG_PREMIUM_DOC_MAX) {
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
            `Decrypted (${mb} MB) but over Telegram’s 4 GB cap and no public download base.\n` +
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

/**
 * IPA larger than Telegram’s 4 GB document cap → tokenized HTTPS download
 * (requires mac-ssh.sh api / cloudflared + MAC_PUBLIC_BASE or live tunnel URL).
 */
async function deliverOversizedViaLink(chatId, pending, { card } = {}) {
  const bytes = pending.bytes || 0;
  const gb = (bytes / (1024 ** 3)).toFixed(2);
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
        "Set MAC_PUBLIC_BASE to your trycloudflare URL (or run: zsh ~/tetherless/server/mac-ssh.sh api)",
    };
  }
  const caption = pending.caption || "";
  const text =
    `<b>${escapeHtml(pending.name || "App")}</b> · ${gb} GB\n` +
    `Too large for Telegram’s 4 GB file cap.\n\n` +
    `⬇️ <a href="${escapeHtml(url)}">Download IPA</a>\n` +
    `<code>${escapeHtml(url)}</code>\n\n` +
    (caption ? `${caption}\n\n` : "") +
    `<i>Link expires in ~${Math.round(publicDl.TTL_MS / 60000)} minutes.</i>`;

  const mid = card && card.messageId;
  if (mid) {
    // Keep the sharp card photo; put the link as caption + Patch/VIP.
    await tgApi("editMessageCaption", {
      chat_id: chatId,
      message_id: mid,
      caption: text,
      parse_mode: "HTML",
      reply_markup: resultKeyboard(),
    }).catch(() => {});
    await ensureIpaButtonTabs(chatId, mid, { caption: text, replyMarkup: resultKeyboard() });
    if (card && typeof card.release === "function") await card.release();
    console.log("[job] oversized IPA → download link on card", url);
    return { ok: true, url, inPlace: true };
  }

  const sent = await tgApi("sendMessage", {
    chat_id: chatId,
    text,
    parse_mode: "HTML",
    disable_web_page_preview: true,
    reply_markup: resultKeyboard(),
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
  const markup = resultKeyboard();
  const cardMid =
    Number(cardMessageId || pending.cardMessageId || (card && card.messageId) || 0) || 0;
  const disk = pending.diskPath && fs.existsSync(pending.diskPath) ? pending.diskPath : "";
  const bytes = pending.bytes || (disk ? fs.statSync(disk).size : 0);
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
  if (/^\/prefetch\s+/i.test(text)) {
    try {
      const extras = require("./mac-ipatool-extras");
      const link = text.split(/\s+/).find((t) => isStoreUrl(t));
      if (!link) {
        await tgApi("sendMessage", { chat_id: chatId, text: "Usage: /prefetch https://apps.apple.com/…" });
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
    await tgApi("sendMessage", {
      chat_id: chatId,
      text: "Paste an App Store link (paid apps must already be owned by this Apple ID).",
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
  rememberStoreUrl(chatId, link, vreq || "latest");
  // Typed version → decrypt that build. Bare link → version sharp-card carousel first.
  if (vreq) {
    await withWorker(chatId, async () => {
      const resolved = await resolveExternalVersionId(link, vreq);
      await decryptStoreUrl(chatId, link, resolved);
    });
    return;
  }
  await offerVersionPick(chatId, link);
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
  console.log("WebSSH: zsh ~/tetherless/server/mac-ssh.sh start | status | logs | session | unlock");
  if (typeof fairplayBackends.unlockKeychain === "function") {
    const unlocked = fairplayBackends.unlockKeychain();
    console.log(unlocked ? "Keychain: unlocked (tetherless.keychain-db)" : "Keychain: skipped (set TETHERLESS_KEYCHAIN_PASSWORD)");
  }
  try {
    const extras = require("./mac-ipatool-extras");
    extras.startPrefetchLoop();
    const sess = extras.sessionWatch({ force: true });
    console.log(
      sess.ready
        ? `ipatool session: ${sess.email || "ok"}`
        : `ipatool session: missing — ${sess.hint || sess.error || ""}`
    );
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
