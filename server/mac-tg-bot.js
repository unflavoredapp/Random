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
 * App Store links → ipatool download + UnfairPlay.
 * TestFlight / any encrypted IPA → send the .ipa here, or drop it in the drop folder.
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const https = require("https");
const { spawnSync } = require("child_process");
const fairplayBackends = require("./fairplayBackends");

const TG_DOC_MAX = 49 * 1024 * 1024;
const TG_GETFILE_MAX = 20 * 1024 * 1024; // Bot API download limit

const BOT_TOKEN = String(process.env.TELEGRAM_BOT_TOKEN || "").trim();
const BOT_USERNAME = String(process.env.TELEGRAM_BOT_USERNAME || "TetherLessDecryptBot").replace(/^@/, "");
const ALLOWED = String(process.env.TELEGRAM_ALLOWED_IDS || "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);
const WORK = process.env.MAC_TG_WORK_DIR || path.join(os.tmpdir(), "tetherless-mac-tg");
const DROP = process.env.MAC_TG_DROP_DIR || path.join(os.homedir(), "tetherless-drop");

if (!BOT_TOKEN) {
  console.error("Set TELEGRAM_BOT_TOKEN in ~/.tetherless-mac.env");
  process.exit(1);
}

fs.mkdirSync(WORK, { recursive: true });
fs.mkdirSync(DROP, { recursive: true });

function tgApi(method, body) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body || {});
    const req = https.request(
      {
        hostname: "api.telegram.org",
        path: `/bot${BOT_TOKEN}/${method}`,
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

function sendDocument(chatId, filePath, caption) {
  const stat = fs.statSync(filePath);
  if (stat.size > TG_DOC_MAX) {
    return Promise.resolve({
      ok: false,
      description: `IPA is ${(stat.size / 1024 / 1024).toFixed(1)} MB — Telegram bots cap ~50 MB. Saved on Mac: ${filePath}`,
      tooLarge: true,
      bytes: stat.size,
    });
  }
  const r = spawnSync(
    "curl",
    [
      "-sS",
      "-X",
      "POST",
      `https://api.telegram.org/bot${BOT_TOKEN}/sendDocument`,
      "-F",
      `chat_id=${chatId}`,
      "-F",
      `caption=${caption || ""}`,
      "-F",
      `document=@${filePath};type=application/octet-stream;filename=${path.basename(filePath).replace(/[^\w.-]+/g, "_") || "App.ipa"}`,
    ],
    { encoding: "utf8", maxBuffer: 8 * 1024 * 1024 }
  );
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

function downloadTelegramFile(filePathOnTg, dest) {
  return new Promise((resolve, reject) => {
    const url = `https://api.telegram.org/file/bot${BOT_TOKEN}/${filePathOnTg}`;
    const file = fs.createWriteStream(dest);
    https
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

function isStoreUrl(u) {
  return /^https:\/\/(?:apps|itunes)\.apple\.com\//i.test(String(u || "").trim());
}

function isTestFlightUrl(u) {
  return /^https:\/\/testflight\.apple\.com\//i.test(String(u || "").trim());
}

function startScreenText() {
  const st = fairplayBackends.backendStatus();
  const modelOk = !!(st.enrollmentModel && st.enrollmentModel.ready);
  const unfairOk = !!(st.unfairplay && st.unfairplay.ready);
  return (
    `*Tetherless Decrypt*\n` +
    `FairPlay IPA decrypt on this host.\n\n` +
    `*App Store*\n` +
    `Paste an \`apps.apple.com\` link.\n\n` +
    `*TestFlight*\n` +
    `Invite links can’t be fetched by ipatool. Send the encrypted \`.ipa\` here (≤20 MB), or copy it to:\n` +
    `\`${DROP}\`\n` +
    `then send: \`decrypt YourApp.ipa\`\n\n` +
    `*Status*\n` +
    `UnfairPlay: ${unfairOk ? "ready" : "missing"} · Model: ${modelOk ? "ready" : "missing"} · Host: ${st.host || "?"}`
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
    // Point unfairplay at the local encrypted IPA (skip ipatool) via tryRemoteBackends dir.
    const result = await fairplayBackends.tryRemoteBackends({
      url: "https://apps.apple.com/app/id0", // placeholder; file already in dir
      dir,
      say,
      vreq: "",
    });
    if (!result || !result.file || !fs.existsSync(result.file)) {
      throw new Error("Decrypt produced no IPA");
    }
    await deliverResult(chatId, result, label);
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
    await deliverResult(chatId, result);
  } finally {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  }
}

async function deliverResult(chatId, result, label) {
  const mb = (fs.statSync(result.file).size / 1024 / 1024).toFixed(1);
  const name = label || result.name || "App";
  const caption = `${name} · ${mb} MB · Tetherless`.trim();
  const keepDir = path.join(WORK, "out");
  fs.mkdirSync(keepDir, { recursive: true });
  const keep = path.join(keepDir, `${Date.now()}-${String(name).replace(/[^\w.-]+/g, "_")}.ipa`);
  fs.copyFileSync(result.file, keep);
  const sent = await sendDocument(chatId, keep, caption);
  if (!sent || !sent.ok) {
    const why = (sent && sent.description) || "Telegram attach failed";
    console.warn("[job] sendDocument:", why);
    await tgApi("sendMessage", {
      chat_id: chatId,
      text: `Decrypted (${mb} MB) but Telegram upload failed: ${String(why).slice(0, 180)}\nSaved on Mac: ${keep}`,
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
        "Invite links (\`testflight.apple.com\`) can’t be downloaded with ipatool.",
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
      "• Optional: \`version: 1.2.3\` after a store link for an older build",
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

  // Document upload (TestFlight / encrypted IPA)
  const doc = msg.document;
  const docName = (doc && doc.file_name) || "";
  if (doc && /\.ipa$/i.test(docName)) {
    if (!doc.file_id) return;
    if (doc.file_size && doc.file_size > TG_GETFILE_MAX) {
      await tgApi("sendMessage", {
        chat_id: chatId,
        text:
          `That IPA is ${((doc.file_size || 0) / 1024 / 1024).toFixed(1)} MB — Telegram only lets bots download ≤20 MB.\n` +
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

  // Local drop: decrypt App.ipa
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
