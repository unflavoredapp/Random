#!/usr/bin/env node
// Brand: Tetherless · https://tetherless.dev
"use strict";
/**
 * Minimal MacDuty Telegram → UnfairPlay decrypt bot.
 *
 * Start this from the **desktop Terminal** (GUI session) so ipatool can read
 * the Keychain. WebSSH cannot unlock the login keychain on these hosts.
 *
 *   source ~/.tetherless-mac.env
 *   node server/mac-tg-bot.js
 *
 * Requires: TELEGRAM_BOT_TOKEN, FAIRPLAY_HOST=mac, unfairplay + model, ipatool auth.
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const https = require("https");
const { spawnSync } = require("child_process");
const fairplayBackends = require("./fairplayBackends");
const TG_DOC_MAX = 49 * 1024 * 1024; // Bot API soft limit ~50MB

const BOT_TOKEN = String(process.env.TELEGRAM_BOT_TOKEN || "").trim();
const BOT_USERNAME = String(process.env.TELEGRAM_BOT_USERNAME || "TetherLessDecryptBot").replace(/^@/, "");
const ALLOWED = String(process.env.TELEGRAM_ALLOWED_IDS || "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);
const WORK = process.env.MAC_TG_WORK_DIR || path.join(os.tmpdir(), "tetherless-mac-tg");

if (!BOT_TOKEN) {
  console.error("Set TELEGRAM_BOT_TOKEN in ~/.tetherless-mac.env");
  process.exit(1);
}

fs.mkdirSync(WORK, { recursive: true });

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
  // curl multipart is reliable for large binaries; hand-rolled streams often truncate.
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

function chatAllowed(chatId) {
  if (!ALLOWED.length) return true;
  return ALLOWED.includes(String(chatId));
}

function validUrl(u) {
  return /^https:\/\/(?:apps|itunes)\.apple\.com\//i.test(String(u || "").trim());
}

let offset = 0;
let busy = false;

async function handleMessage(msg) {
  const chatId = msg.chat && msg.chat.id;
  if (!chatId) return;
  if (!chatAllowed(chatId)) {
    await tgApi("sendMessage", { chat_id: chatId, text: "This bot is private." });
    return;
  }
  const text = String(msg.text || "").trim();
  if (!text) return;
  if (/^\/(start|help)/i.test(text)) {
    await tgApi("sendMessage", {
      chat_id: chatId,
      text:
        "Send an App Store link (https://apps.apple.com/…). " +
        "This Mac FairPlay host downloads with ipatool and decrypts with UnfairPlay.",
    });
    return;
  }
  const link = text.split(/\s+/).find((t) => validUrl(t));
  if (!link) {
    await tgApi("sendMessage", { chat_id: chatId, text: "Paste a full apps.apple.com link." });
    return;
  }
  if (busy) {
    await tgApi("sendMessage", { chat_id: chatId, text: "Busy — try again in a minute." });
    return;
  }
  const verMatch = text.match(/\b(?:v|version)[:=\s]+([0-9][0-9A-Za-z._-]{0,29})\b/i);
  const vreq = verMatch ? verMatch[1] : "";
  busy = true;
  const dir = fs.mkdtempSync(path.join(WORK, "job-"));
  try {
    await tgApi("sendMessage", { chat_id: chatId, text: "Queued on Mac FairPlay host…" });
    const say = async (t) => {
      console.log("[job]", t);
    };
    const result = await fairplayBackends.tryRemoteBackends({
      url: link,
      dir,
      say,
      vreq,
    });
    if (!result || !result.file || !fs.existsSync(result.file)) {
      throw new Error("Decrypt produced no IPA");
    }
    const mb = (fs.statSync(result.file).size / 1024 / 1024).toFixed(1);
    const caption = `${result.name || "App"} · ${mb} MB · FairPlay decrypt`.trim();
    // Keep a copy outside the temp job dir (we delete dir in finally).
    const keepDir = path.join(WORK, "out");
    fs.mkdirSync(keepDir, { recursive: true });
    const keep = path.join(
      keepDir,
      `${Date.now()}-${(result.name || "App").replace(/[^\w.-]+/g, "_")}.ipa`
    );
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
  } catch (e) {
    const err = String((e && e.message) || e).slice(0, 200);
    console.warn("[job] failed:", err);
    await tgApi("sendMessage", { chat_id: chatId, text: "Failed: " + err }).catch(() => {});
  } finally {
    busy = false;
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  }
}

async function poll() {
  try {
    const r = await tgApi("getUpdates", {
      offset,
      timeout: 0,
      allowed_updates: ["message"],
    });
    if (!r.ok || !Array.isArray(r.result)) return;
    for (const u of r.result) {
      offset = Math.max(offset, (u.update_id || 0) + 1);
      if (u.message) await handleMessage(u.message);
    }
  } catch (e) {
    console.warn("poll:", (e && e.message) || e);
  }
}

const st = fairplayBackends.backendStatus();
console.log(
  `Mac TG bot @${BOT_USERNAME} · host=${st.host} · unfairplay=${!!(st.unfairplay && st.unfairplay.ready)} · model=${!!(st.enrollmentModel && st.enrollmentModel.ready)}`
);
console.log("Start from desktop Terminal so ipatool Keychain works. Ctrl+C to stop.");
setInterval(() => {
  poll().catch(() => {});
}, 2000);
poll().catch(() => {});
