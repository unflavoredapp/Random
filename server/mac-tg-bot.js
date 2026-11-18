#!/usr/bin/env node
// Brand: Tetherless · https://tetherless.dev
"use strict";
/**
 * Tetherless Telegram decrypt bot (Mac host).
 *
 * WebSSH only (dedicated keychain — no Mac desktop):
 *   zsh server/mac-ssh.sh start
 *   zsh server/mac-ssh.sh status | logs | session
 *
 * IPA delivery:
 *   • Default: your Premium *user* session (TELEGRAM_API_ID/HASH/SESSION) → ≤4 GB
 *     + Telegram cloud storage (bots cannot use Premium; the user account uploads)
 *   • Fallback: cloud Bot API ~50 MB, or local Bot API (TELEGRAM_API_ROOT) ≤2000 MB
 *
 * Telegram cloud cache: after the first decrypt we keep Telegram's file_id (+ a
 * local copy). The next request for the same app/version re-sends by file_id —
 * instant, no re-decrypt.
 *
 * App Store links → ipatool download + Tetherless decrypt.
 * TestFlight / any encrypted IPA → send the .ipa here, or drop it in the drop folder.
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");
const https = require("https");
const { spawn, spawnSync } = require("child_process");
const fairplayBackends = require("./fairplayBackends");
const ipaCache = require("./mac-tg-ipa-cache");

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
  return `${n}${v}-Tetherless.ipa`;
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

/** Live card caption under the app icon: name + stage + numeric %. */
function progressCaption({ name, stage, pct }) {
  const p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
  return [
    `<b>${escapeHtml(name || "App")}</b>`,
    `Tetherless`,
    `${escapeHtml(stage || "Working…")} · <b>${p}%</b>`,
  ].join("\n");
}

/** Final IPA buttons only: Patch · Get VIP. */
function resultKeyboard() {
  const site = String(process.env.TETHERLESS_SITE_URL || "https://tetherless.dev").replace(/\/+$/, "");
  const patch = String(process.env.TETHERLESS_PATCH_URL || `${site}/`).replace(/\/+$/, "") || site;
  const vip = String(process.env.TETHERLESS_VIP_URL || `${site}/vip`).replace(/\/+$/, "") || `${site}/vip`;
  return {
    inline_keyboard: [
      [
        { text: "🧩 Patch", url: patch },
        { text: "⭐ Get VIP", url: vip },
      ],
    ],
  };
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

/** One editable Telegram card: icon + name — Tetherless + loading bar → final meta/buttons. */
function createProgressCard(chatId) {
  let messageId = 0;
  let hasPhoto = false;
  let name = "App";
  let storeUrl = "";
  let lastEdit = 0;
  let lastPct = -1;
  let lastStage = "";

  async function paint(caption, replyMarkup) {
    if (!messageId) return;
    const body = {
      chat_id: chatId,
      message_id: messageId,
      parse_mode: "HTML",
      caption: hasPhoto ? caption : undefined,
      text: hasPhoto ? undefined : caption,
    };
    if (replyMarkup) body.reply_markup = replyMarkup;
    const method = hasPhoto ? "editMessageCaption" : "editMessageText";
    // When editing text messages, Telegram wants `text` not caption.
    if (!hasPhoto) {
      delete body.caption;
      body.text = caption;
    } else {
      delete body.text;
    }
    await tgApi(method, body).catch(() => {});
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
      const caption = progressCaption({ name, stage: "Fetching…", pct: 4 });
      if (meta.iconPath && fs.existsSync(meta.iconPath)) {
        const sent = await sendPhotoBotApi(chatId, meta.iconPath, caption);
        if (sent && sent.ok && sent.result) {
          messageId = sent.result.message_id;
          hasPhoto = true;
          return;
        }
        console.warn("[job] sendPhoto failed:", (sent && sent.description) || "unknown");
      } else {
        console.warn("[job] no store icon for progress card", link || "(none)");
      }
      const sent = await tgApi("sendMessage", {
        chat_id: chatId,
        text: caption,
        parse_mode: "HTML",
      });
      if (sent && sent.ok && sent.result) {
        messageId = sent.result.message_id;
        hasPhoto = false;
      }
    },
    async setStage(stage, pct) {
      const p = Math.max(0, Math.min(99, Math.round(Number(pct) || 0)));
      const now = Date.now();
      const stageChanged = stage && stage !== lastStage;
      if (!stageChanged && p < lastPct + 3 && now - lastEdit < 1800) return;
      lastEdit = now;
      lastPct = p;
      if (stage) lastStage = stage;
      console.log("[job]", stage || lastStage, `${p}%`);
      await paint(progressCaption({ name, stage: stage || lastStage, pct: p }));
    },
    /** Map backend say() lines into card stages. */
    async fromBackendLine(line) {
      const t = String(line || "");
      if (/ipatool|download/i.test(t)) return this.setStage("Downloading…", 28);
      if (/unfairplay|decrypt|FairPlay|model/i.test(t)) return this.setStage("Decrypting…", 55);
      if (/produced|done/i.test(t)) return this.setStage("Decrypting…", 72);
      if (/upload/i.test(t)) return this.setStage("Uploading…", 80);
      return this.setStage(lastStage || "Working…", Math.max(lastPct, 12));
    },
    async setUploadPct(pct) {
      const p = 75 + Math.round((Math.max(0, Math.min(100, pct)) / 100) * 24);
      return this.setStage("Uploading…", p);
    },
    async clear() {
      if (!messageId) return;
      await tgApi("deleteMessage", { chat_id: chatId, message_id: messageId }).catch(() => {});
      messageId = 0;
    },
    /** Drop the live card once the IPA (with caption) is sent — no duplicate meta post. */
    async finish() {
      await this.clear();
    },
    async fail(err) {
      const caption =
        `<b>${escapeHtml(name)}</b>\n` +
        `Tetherless\n` +
        `Failed · <b>0%</b>\n` +
        `❌ ${escapeHtml(String(err || "failed").slice(0, 160))}`;
      await paint(caption);
    },
  };
}

function sendDocumentBotApi(chatId, filePath, fileName, caption, { thumbPath, replyMarkup } = {}) {
  const abs = path.resolve(filePath);
  const args = ["-sS", "-X", "POST", apiUrl("sendDocument"), "-F", `chat_id=${chatId}`, "-F", `parse_mode=HTML`];
  if (caption) args.push("-F", `caption=${caption}`);
  if (replyMarkup) args.push("-F", `reply_markup=${JSON.stringify(replyMarkup)}`);
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
    // Stage via Premium WITH caption + Patch/Get VIP first (never bare — if bot
    // re-send fails the user still sees the classic IPA look). Then the bot
    // copyMessage’s it so the final document is from IPA Agent.
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
      for (let attempt = 0; attempt < 3; attempt++) {
        if (attempt) await new Promise((r) => setTimeout(r, 900 * attempt));
        copied = await tgApi("copyMessage", {
          chat_id: chatId,
          from_chat_id: chatId,
          message_id: stagedId,
          caption: caption || undefined,
          parse_mode: caption ? "HTML" : undefined,
          reply_markup: markup,
        }).catch((e) => ({ ok: false, description: String((e && e.message) || e) }));
        if (copied && copied.ok && copied.result) {
          await tgApi("deleteMessage", { chat_id: chatId, message_id: stagedId }).catch(() => {});
          console.log("[job] bot produced IPA via copyMessage", copied.result.message_id);
          return {
            ok: true,
            premium: true,
            bot_resent: true,
            message_id: copied.result.message_id,
            chat_id: String(chatId),
            result: copied.result,
          };
        }
      }
      // Keep Premium message — it already has caption + Patch/Get VIP.
      console.warn(
        "[job] bot copyMessage failed; keeping Premium IPA with caption/buttons:",
        (copied && copied.description) || "unknown"
      );
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

  return sendDocumentBotApi(chatId, filePath, fileName, caption, extras);
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
  if (!ALLOWED.length) return true;
  return ALLOWED.includes(String(chatId));
}

function isStoreUrl(t) {
  return /^https:\/\/(?:apps|itunes)\.apple\.com\//i.test(String(t || "").trim());
}

function isTestFlightUrl(t) {
  return /testflight\.apple\.com/i.test(String(t || ""));
}

function startScreenText() {
  const st = fairplayBackends.backendStatus();
  const uf = st.unfairplay && st.unfairplay.ready ? "ready" : "missing";
  const model = st.enrollmentModel && st.enrollmentModel.ready ? "ready" : "missing";
  const up = preferPremiumUpload()
    ? "your Premium session ≤4 GB + cloud storage"
    : premiumUploadConfigured()
      ? "Premium session present but TELEGRAM_PREMIUM_UPLOAD=0"
      : LOCAL_API
        ? `local Bot API ≤${Math.round(TG_DOC_MAX / 1024 / 1024)} MB`
        : "cloud Bot API ≤50 MB — run: mac-ssh.sh session";
  return (
    `*Tetherless*\n` +
    `Decrypt App Store / TestFlight IPAs on this Mac.\n\n` +
    `• decrypt: \`${uf}\`\n` +
    `• enrollment model: \`${model}\`\n` +
    `• host: \`${st.host || "mac"}\`\n` +
    `• upload: \`${up}\`\n` +
    `• cloud cache: \`${ipaCache.list().length} IPA(s)\` in \`${ipaCache.CACHE_DIR}\`\n\n` +
    `*Add an App Store URL to start.*\n\n` +
    `Send an App Store link, or a \`.ipa\` / \`decrypt App.ipa\` from \`${DROP}\`.\n` +
    `Repeat links re-send from Telegram cloud (instant). /cache lists saved IPAs.`
  );
}

function startKeyboard() {
  return {
    inline_keyboard: [
      [
        { text: "How it works", callback_data: "help" },
        { text: "Status", callback_data: "status" },
      ],
      [
        { text: "TestFlight help", callback_data: "testflight" },
        { text: "Cache", callback_data: "cache" },
      ],
    ],
  };
}

async function sendStart(chatId) {
  await tgApi("sendMessage", {
    chat_id: chatId,
    text: startScreenText(),
    parse_mode: "Markdown",
    reply_markup: startKeyboard(),
  });
}

async function sendCacheList(chatId) {
  const items = ipaCache.list().slice(0, 30);
  if (!items.length) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text: "Tetherless cache is empty — paste an App Store URL to start.",
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
    text:
      `*Tetherless cache* (${items.length})\n` +
      `☁️ = Telegram cloud · 💾 = Mac disk only (will re-upload)\n\n` +
      lines.join("\n"),
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
  const markup = resultKeyboard();
  const card = createProgressCard(chatId);
  if (!quiet) {
    await card.start(entry.storeUrl || "", entry.name || "App");
    await card.setStage("Sending…", 40);
  }
  if (entry.fileId) {
    await card.setStage("Sending…", 70);
    const caption = buildCaption({
      bid: entry.bid,
      version: entry.version,
      minIos: entry.minIos,
      storeUrl: entry.storeUrl,
    });
    const r = await tgApi("sendDocument", {
      chat_id: chatId,
      document: entry.fileId,
      caption: caption || undefined,
      parse_mode: caption ? "HTML" : undefined,
      reply_markup: markup,
    });
    if (r && r.ok) {
      console.log("[cache] hit file_id", entry.adam, entry.version || "latest");
      await card.finish();
      return true;
    }
    console.warn("[cache] file_id send failed:", (r && r.description) || "unknown");
  }
  // Prefer fresh sendDocument with caption over copyMessage (copy keeps old empty captions).
  // Premium-user uploads: copyMessage from the original chat (no re-upload).
  if (entry.messageId && entry.fromChatId) {
    await card.setStage("Sending…", 70);
    const caption = buildCaption({
      bid: entry.bid,
      version: entry.version,
      minIos: entry.minIos,
      storeUrl: entry.storeUrl,
    });
    const r = await tgApi("copyMessage", {
      chat_id: chatId,
      from_chat_id: entry.fromChatId,
      message_id: entry.messageId,
      caption: caption || undefined,
      parse_mode: caption ? "HTML" : undefined,
      reply_markup: markup,
    });
    if (r && r.ok) {
      console.log("[cache] hit copyMessage", entry.adam, entry.version || "latest");
      await card.finish();
      return true;
    }
    console.warn("[cache] copyMessage failed:", (r && r.description) || "unknown");
  }
  // Fallback: re-upload from Mac disk cache (still skips decrypt).
  if (entry.diskPath && fs.existsSync(entry.diskPath)) {
    await card.setStage("Uploading…", 76);
    const fileName = entry.fileName || path.basename(entry.diskPath);
    const thumbPath = entry.storeUrl ? fetchStoreIcon(entry.storeUrl) : "";
    const caption = buildCaption({
      bid: entry.bid,
      version: entry.version,
      minIos: entry.minIos,
      storeUrl: entry.storeUrl,
    });
    const sent = await sendDocument(chatId, entry.diskPath, fileName, caption, {
      thumbPath,
      replyMarkup: markup,
      card,
    });
    if (sent && sent.ok) {
      const doc = sent.result && sent.result.document;
      const viaPremium = !!(sent.premium && sent.message_id);
      ipaCache.put({
        ...entry,
        caption,
        fileId: (doc && doc.file_id) || entry.fileId || "",
        fileUniqueId: (doc && doc.file_unique_id) || entry.fileUniqueId || "",
        messageId: viaPremium ? Number(sent.message_id) || 0 : entry.messageId || 0,
        fromChatId: viaPremium ? String(chatId) : entry.fromChatId || "",
      });
      console.log("[cache] hit disk re-upload", entry.diskPath);
      await card.finish();
      return true;
    }
    await card.fail(premiumFailDescription((sent && sent.description) || "upload failed"));
    // Cache hit was real — do not fall through into a full re-decrypt.
    return true;
  }
  return false;
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
  // Start Apple download / encrypted-cache hit while the progress card loads.
  let prepError = null;
  const prep = fairplayBackends
    .ensureEncryptedSource({
      url: link,
      dir,
      say: (t) => {
        card.fromBackendLine(t);
      },
      vreq,
    })
    .catch((e) => {
      prepError = e;
    });

  try {
    await card.start(link);
    await card.setStage("Fetching…", 8);
    await prep;
    if (prepError) throw prepError;

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
  const markup = resultKeyboard();
  const thumbPath = storeUrl ? fetchStoreIcon(storeUrl) : "";
  const adam = ipaCache.adamFromStoreUrl(storeUrl) || "";

  // Durable Mac copy used if Telegram file_id ever expires (prefer hardlink).
  const keep = ipaCache.diskPathFor(adam || "app", version || "latest", fileName);
  try {
    ipaCache.linkOrCopy(result.file, keep);
  } catch {
    fs.copyFileSync(result.file, keep);
  }

  if (card) await card.setStage("Uploading…", 78);
  const sent = await sendDocument(chatId, keep, fileName, caption, {
    thumbPath,
    replyMarkup: markup,
    card,
  });
  if (!sent || !sent.ok) {
    const why = (sent && sent.description) || "Telegram attach failed";
    console.warn("[job] sendDocument:", why);
    // Still index the disk copy so a later Premium/local upload can finish the cache.
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
    }
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
    console.log("[job] sent IPA to Telegram:", keep);
    if (adam) {
      const viaPremium = !!(sent.premium && sent.message_id);
      ipaCache.put({
        adam,
        version,
        bid,
        name,
        minIos,
        storeUrl,
        fileName,
        caption,
        fileId: (doc && doc.file_id) || "",
        fileUniqueId: (doc && doc.file_unique_id) || "",
        messageId: viaPremium ? Number(sent.message_id) || 0 : (sent.result && sent.result.message_id) || 0,
        fromChatId: viaPremium ? String(sent.chat_id || chatId) : String(chatId),
        bytes,
        diskPath: keep,
      });
      console.log(
        "[cache] stored",
        adam,
        version || "latest",
        doc && doc.file_id ? "file_id" : viaPremium ? "copyMessage" : "disk-only"
      );
    }
    if (card) await card.finish();
  }
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
let busy = false;

async function withBusy(chatId, fn) {
  if (busy) {
    await tgApi("sendMessage", { chat_id: chatId, text: "Busy — try again in a minute." });
    return;
  }
  busy = true;
  try {
    await fn();
  } catch (e) {
    const err = String((e && e.message) || e).slice(0, 200);
    console.warn("[job] failed:", err);
    await tgApi("sendMessage", { chat_id: chatId, text: "Failed: " + err }).catch(() => {});
  } finally {
    busy = false;
  }
}

async function handleCallback(cq) {
  const chatId = cq.message && cq.message.chat && cq.message.chat.id;
  const data = String(cq.data || "");
  if (!chatId) return;
  await tgApi("answerCallbackQuery", { callback_query_id: cq.id }).catch(() => {});
  if (!chatAllowed(chatId)) {
    await tgApi("sendMessage", { chat_id: chatId, text: "This bot is private." });
    return;
  }
  if (data === "status") {
    await sendStart(chatId);
    return;
  }
  if (data === "cache") {
    await sendCacheList(chatId);
    return;
  }
  if (data === "testflight") {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text:
        "*TestFlight on Tetherless*\n\n" +
        "1. Install the beta on a device / export the personalized encrypted IPA\n" +
        "2. Send that \`.ipa\` to this chat (≤20 MB via Telegram), *or*\n" +
        `3. Copy it to \`${DROP}\` and send: \`decrypt App.ipa\`\n\n` +
        "Invite links (`testflight.apple.com`) can’t be downloaded with ipatool.",
      parse_mode: "Markdown",
    });
    return;
  }
  await tgApi("sendMessage", {
    chat_id: chatId,
    text:
      "*How it works*\n" +
      "• App Store link → download encrypted IPA → Tetherless decrypt → IPA back here\n" +
      "• TestFlight / custom IPA → upload or drop folder → same decrypt\n" +
      "• Optional: `version: 1.2.3` after a store link for an older build\n" +
      "• Large IPAs: local Bot API (2 GB) or Premium user session (4 GB)",
    parse_mode: "Markdown",
  });
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
    if (/-Tetherless\.ipa$/i.test(docName)) {
      // If we somehow got a bot-visible file_id here, refresh cache for that adam later.
      return;
    }
    if (!doc.file_id) return;
    if (doc.file_size && doc.file_size > TG_GETFILE_MAX) {
      await tgApi("sendMessage", {
        chat_id: chatId,
        text:
          `That IPA is ${((doc.file_size || 0) / 1024 / 1024).toFixed(1)} MB — Telegram only lets bots download ≤20 MB on cloud API.\n` +
          `Copy it to \`${DROP}\` on the Mac and send: \`decrypt ${doc.file_name || "App.ipa"}\``,
        parse_mode: "Markdown",
      });
      return;
    }
    await withBusy(chatId, async () => {
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

  if (/^\/(start|help)\b/i.test(text)) {
    await sendStart(chatId);
    return;
  }

  if (/^\/status\b/i.test(text)) {
    await sendStart(chatId);
    return;
  }

  if (/^\/cache\b/i.test(text)) {
    await sendCacheList(chatId);
    return;
  }

  if (/^decrypt\s+/i.test(text) || (/^[\w./-]+\.ipa$/i.test(text) && !/^https?:/i.test(text))) {
    const ipaPath = resolveDropPath(text);
    await withBusy(chatId, async () => {
      await decryptLocalIpa(chatId, ipaPath, path.basename(ipaPath, ".ipa"));
    });
    return;
  }

  const link = text.split(/\s+/).find((t) => isStoreUrl(t) || isTestFlightUrl(t));
  if (!link) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text: "Paste an App Store link, send a `.ipa`, or type `decrypt App.ipa`. Send /start for the menu.",
    });
    return;
  }

  if (isTestFlightUrl(link)) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text:
        "TestFlight invite links can’t be fetched here.\n" +
        "Send the encrypted `.ipa`, or drop it in the Mac folder and send `decrypt App.ipa`.",
      reply_markup: {
        inline_keyboard: [[{ text: "TestFlight help", callback_data: "testflight" }]],
      },
    });
    return;
  }

  const verMatch = text.match(/\b(?:v|version)[:=\s]+([0-9][0-9A-Za-z._-]{0,29})\b/i);
  const vreq = verMatch ? verMatch[1] : "";
  await withBusy(chatId, async () => {
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
  await tgApi("setMyCommands", {
    commands: [
      { command: "start", description: "Tetherless start screen" },
      { command: "help", description: "How decrypt works" },
      { command: "status", description: "Backend / model status" },
      { command: "cache", description: "List cloud-cached IPAs" },
    ],
  }).catch(() => {});
  const st = fairplayBackends.backendStatus();
  console.log(
    `Tetherless TG bot @${BOT_USERNAME || "?"} id=${BOT_ID || "?"} · host=${st.host} · decrypt=${!!(st.unfairplay && st.unfairplay.ready)} · model=${!!(st.enrollmentModel && st.enrollmentModel.ready)}`
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
