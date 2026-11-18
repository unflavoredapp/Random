#!/usr/bin/env node
// Brand: Tetherless · https://tetherless.dev
"use strict";
/**
 * Tetherless Telegram → UnfairPlay decrypt bot (Mac host).
 *
 * Start from the **desktop Terminal** (GUI session) so ipatool can read Keychain:
 *   source /users/client/.tetherless-mac.env
 *   node server/mac-tg-bot.js
 *
 * Large IPA delivery (Premium does NOT raise Bot API limits):
 *   • Cloud api.telegram.org → ~50 MB
 *   • Local Bot API (TELEGRAM_API_ROOT) → up to 2000 MB via file://
 *   • Premium user MTProto (TELEGRAM_API_ID + session) → up to 4 GB
 *
 * App Store links → ipatool download + UnfairPlay.
 * TestFlight / any encrypted IPA → send the .ipa here, or drop it in the drop folder.
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const http = require("http");
const https = require("https");
const { spawnSync } = require("child_process");
const fairplayBackends = require("./fairplayBackends");

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
const BOT_USERNAME = String(process.env.TELEGRAM_BOT_USERNAME || "TetherLessDecryptBot").replace(/^@/, "");
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

function buildCaption({ name, bid, version, minIos, storeUrl, mb }) {
  const lines = [];
  if (bid) lines.push(`📁 <code>${escapeHtml(bid)}</code>`);
  const verBits = [];
  if (version) verBits.push(`Version: ${escapeHtml(version)}`);
  if (minIos) verBits.push(`${escapeHtml(minIos)}+`);
  if (verBits.length) lines.push(`⚙️ ${verBits.join(" · ")}`);
  if (storeUrl) lines.push(`🔗 <a href="${escapeHtml(storeUrl)}">App Store Link</a>`);
  if (!lines.length) lines.push(`<b>${escapeHtml(name || "App")}</b> · ${mb} MB · Tetherless`);
  else lines.push(`📦 ${mb} MB · Tetherless`);
  return lines.join("\n");
}

function escapeHtml(s) {
  return String(s || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function sendDocumentBotApi(chatId, filePath, fileName, caption) {
  const abs = path.resolve(filePath);
  const args = ["-sS", "-X", "POST", apiUrl("sendDocument"), "-F", `chat_id=${chatId}`, "-F", `parse_mode=HTML`];
  if (caption) {
    args.push("-F", `caption=${caption}`);
  }
  // Local Bot API: pass file:// so uploads can exceed 50 MB (up to ~2000 MB).
  if (LOCAL_API) {
    args.push("-F", `document=file://${abs}`);
  } else {
    args.push(
      "-F",
      `document=@${abs};type=application/octet-stream;filename=${fileName}`
    );
  }
  // When using file://, still set a display name via an attach if supported — local API
  // keeps the basename; copy to nicely named path before calling when possible.
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

function sendDocumentPremium(chatId, filePath, fileName, caption) {
  const env = {
    ...process.env,
    TG_UPLOAD_CHAT_ID: String(chatId),
    TG_UPLOAD_FILE: path.resolve(filePath),
    TG_UPLOAD_FILENAME: fileName,
    TG_UPLOAD_CAPTION: caption || "",
  };
  const r = spawnSync("python3", [PREMIUM_UPLOAD], {
    encoding: "utf8",
    maxBuffer: 8 * 1024 * 1024,
    env,
  });
  if (r.error) return { ok: false, description: String(r.error.message || r.error) };
  const out = String(r.stdout || "").trim();
  const err = String(r.stderr || "").trim();
  if (r.status !== 0) {
    return { ok: false, description: (err || out || `premium upload exit ${r.status}`).slice(0, 300) };
  }
  try {
    return JSON.parse(out || "{}");
  } catch {
    return { ok: true, description: out.slice(0, 200) };
  }
}

async function sendDocument(chatId, filePath, fileName, caption) {
  const stat = fs.statSync(filePath);
  const mb = (stat.size / 1024 / 1024).toFixed(1);

  // Premium user MTProto for big IPAs (up to 4 GB). Bot API cloud stays ~50 MB;
  // local Bot API can take ≤2000 MB without a user session.
  const forcePremium = process.env.TELEGRAM_PREMIUM_UPLOAD === "1";
  const overCloud = stat.size > 49 * 1024 * 1024;
  const needPremium = forcePremium || (overCloud && !LOCAL_API) || stat.size > TG_DOC_MAX;
  if (premiumUploadConfigured() && needPremium) {
    if (stat.size > 4 * 1024 * 1024 * 1024) {
      return {
        ok: false,
        description: `IPA is ${mb} MB — over Telegram Premium’s 4 GB document cap. Saved: ${filePath}`,
        tooLarge: true,
      };
    }
    console.log(`[job] uploading via Premium user MTProto (${mb} MB)…`);
    const prem = sendDocumentPremium(chatId, filePath, fileName, caption);
    if (prem && prem.ok) return prem;
    console.warn("[job] premium upload failed:", prem && prem.description);
    // Fall through to Bot API / local API when premium fails.
  }

  if (stat.size > TG_DOC_MAX) {
    const hint = premiumUploadConfigured()
      ? "Premium upload failed and file exceeds Bot API limit."
      : LOCAL_API
        ? `Local Bot API cap is ~${Math.round(TG_DOC_MAX / 1024 / 1024)} MB.`
        : "Cloud Bot API caps ~50 MB (Telegram Premium does not raise bot uploads). Set TELEGRAM_API_ROOT to a local Bot API (2 GB) or TELEGRAM_API_ID/HASH/SESSION for Premium user upload (4 GB).";
    return {
      ok: false,
      description: `IPA is ${mb} MB — ${hint} Saved on Mac: ${filePath}`,
      tooLarge: true,
      bytes: stat.size,
    };
  }

  return sendDocumentBotApi(chatId, filePath, fileName, caption);
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
  const up = premiumUploadConfigured()
    ? "Premium user ≤4 GB"
    : LOCAL_API
      ? `local Bot API ≤${Math.round(TG_DOC_MAX / 1024 / 1024)} MB`
      : "cloud Bot API ≤50 MB";
  return (
    `*Tetherless*\n` +
    `Decrypt App Store / TestFlight IPAs on this Mac.\n\n` +
    `• unfairplay: \`${uf}\`\n` +
    `• enrollment model: \`${model}\`\n` +
    `• host: \`${st.host || "mac"}\`\n` +
    `• upload: \`${up}\`\n\n` +
    `Send an App Store link, or a \`.ipa\` / \`decrypt App.ipa\` from \`${DROP}\`.`
  );
}

function startKeyboard() {
  return {
    inline_keyboard: [
      [
        { text: "How it works", callback_data: "help" },
        { text: "Status", callback_data: "status" },
      ],
      [{ text: "TestFlight help", callback_data: "testflight" }],
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

async function decryptLocalIpa(chatId, ipaPath, label) {
  if (!fs.existsSync(ipaPath) || fs.statSync(ipaPath).size < 100) {
    throw new Error("IPA not found or empty: " + ipaPath);
  }
  const dir = fs.mkdtempSync(path.join(WORK, "job-"));
  const enc = path.join(dir, "encrypted-source.ipa");
  fs.copyFileSync(ipaPath, enc);
  try {
    await tgApi("sendMessage", { chat_id: chatId, text: "Queued on Tetherless…" });
    const say = (t) => console.log("[job]", t);
    const result = await fairplayBackends.tryRemoteBackends({
      url: "https://apps.apple.com/app/id0",
      dir,
      say,
      vreq: "",
    });
    if (!result || !result.file || !fs.existsSync(result.file)) {
      throw new Error("Decrypt produced no IPA");
    }
    await deliverResult(chatId, result, { label });
  } finally {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  }
}

async function decryptStoreUrl(chatId, link, vreq) {
  const dir = fs.mkdtempSync(path.join(WORK, "job-"));
  try {
    await tgApi("sendMessage", { chat_id: chatId, text: "Queued on Tetherless…" });
    const say = (t) => console.log("[job]", t);
    const result = await fairplayBackends.tryRemoteBackends({
      url: link,
      dir,
      say,
      vreq,
    });
    if (!result || !result.file || !fs.existsSync(result.file)) {
      throw new Error("Decrypt produced no IPA");
    }
    await deliverResult(chatId, result, { storeUrl: link, versionHint: vreq });
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
  const name = opts.label || ipaMeta.name || result.name || "App";
  const version = opts.versionHint || ipaMeta.version || "";
  const bid = ipaMeta.bid || "";
  const minIos = ipaMeta.minIos || "";
  const storeUrl = opts.storeUrl || "";
  const mb = (fs.statSync(result.file).size / 1024 / 1024).toFixed(1);
  const fileName = buildIpaFileName({ name, version });
  const caption = buildCaption({ name, bid, version, minIos, storeUrl, mb });

  const keepDir = path.join(WORK, "out");
  fs.mkdirSync(keepDir, { recursive: true });
  const keep = path.join(keepDir, fileName);
  try {
    fs.rmSync(keep, { force: true });
  } catch {
    /* ignore */
  }
  fs.copyFileSync(result.file, keep);

  const sent = await sendDocument(chatId, keep, fileName, caption);
  if (!sent || !sent.ok) {
    const why = (sent && sent.description) || "Telegram attach failed";
    console.warn("[job] sendDocument:", why);
    await tgApi("sendMessage", {
      chat_id: chatId,
      text:
        `Decrypted (${mb} MB) but Telegram upload failed:\n${String(why).slice(0, 400)}\n\n` +
        `Saved on Mac:\n\`${keep}\``,
      parse_mode: "Markdown",
    });
  } else {
    console.log("[job] sent IPA to Telegram:", keep);
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
      "• App Store link → download encrypted IPA → UnfairPlay decrypt → IPA back here\n" +
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

async function boot() {
  await tgApi("setMyCommands", {
    commands: [
      { command: "start", description: "Tetherless start screen" },
      { command: "help", description: "How decrypt works" },
      { command: "status", description: "Backend / model status" },
    ],
  }).catch(() => {});
  const st = fairplayBackends.backendStatus();
  console.log(
    `Tetherless TG bot @${BOT_USERNAME} · host=${st.host} · unfairplay=${!!(st.unfairplay && st.unfairplay.ready)} · model=${!!(st.enrollmentModel && st.enrollmentModel.ready)}`
  );
  console.log(`API ${API_ROOT} · local=${LOCAL_API} · uploadMaxMB=${Math.round(TG_DOC_MAX / 1024 / 1024)} · premiumUser=${premiumUploadConfigured()}`);
  console.log(`Drop folder for TestFlight IPAs: ${DROP}`);
  console.log("Start from desktop Terminal so ipatool Keychain works. Ctrl+C to stop.");
  setInterval(() => {
    poll().catch(() => {});
  }, 2000);
  poll().catch(() => {});
}

boot().catch((e) => {
  console.error(e);
  process.exit(1);
});
