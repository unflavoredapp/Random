// Brand: Tetherless · https://tetherless.dev
"use strict";
/**
 * TetherLess decrypt backend — phone worker + optional own Telegram bot.
 *
 * Replaces the old GramJS → @FastDecryptBot bridge. FairPlay runs on the
 * signed-in iPhone; this module only queues jobs, waits for a worker upload,
 * and (optionally) drives a Bot API bot that creates the same jobs.
 *
 * Expected by site.js:
 *   create({ db, secret }) → {
 *     bot, validUrl, busy, queueLen,
 *     request(url, dir, say, tryCache, vreq, job?),
 *     versions(url, page),
 *     status, setKeys, sendCode, signIn, useSession, logout,
 *     attachWorkerRoutes(web, helpers),
 *     startTelegramBot(helpers)
 *   }
 */

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const https = require("https");
const fairplayBackends = require("./fairplayBackends");

const BUILD = "tetherless-fairplay-backends-1";
const BOT_USERNAME = (process.env.TELEGRAM_BOT_USERNAME || process.env.DECRYPT_BOT || "TetherLessDecryptBot").replace(/^@/, "");
const BOT_TOKEN = process.env.TELEGRAM_BOT_TOKEN || "";
const WORKER_TOKEN = process.env.DECRYPT_WORKER_TOKEN || "";
const ALLOWED_CHAT_IDS = String(process.env.TELEGRAM_ALLOWED_IDS || "")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);
const REQUEST_MS = (Number(process.env.DECRYPT_TIMEOUT_MIN) || 20) * 60 * 1000;
const MAX_GB = Number(process.env.DECRYPT_MAX_GB) || 1.5;

function create({ db /*, secret */ }) {
  if (!db) throw new Error("decrypt.create needs db");

  /** @type {Map<string, any>} */
  const waiters = new Map(); // jobId → { url, vreq, dir, say, resolve, reject, status, claimedBy, createdAt }
  let queue = Promise.resolve();
  let active = 0;
  let waiting = 0;
  let botOffset = 0;
  let botTimer = null;

  function validUrl(u) {
    return /^https:\/\/(?:apps|itunes)\.apple\.com\//i.test(String(u || "").trim());
  }

  function busy() {
    return active > 0 || [...waiters.values()].some((w) => w.status === "claimed");
  }

  function queueLen() {
    return waiting + [...waiters.values()].filter((w) => w.status === "queued").length;
  }

  function enqueue(fn) {
    waiting++;
    const run = queue.then(async () => {
      waiting = Math.max(0, waiting - 1);
      active++;
      try {
        return await fn();
      } finally {
        active = Math.max(0, active - 1);
      }
    });
    queue = run.catch(() => {});
    return run;
  }

  function authWorker(req) {
    const hdr = String(req.headers["x-decrypt-worker-token"] || req.headers["authorization"] || "");
    const token = hdr.replace(/^Bearer\s+/i, "").trim();
    if (!WORKER_TOKEN) {
      return { ok: false, error: "DECRYPT_WORKER_TOKEN is not set on the server." };
    }
    if (!token || token !== WORKER_TOKEN) {
      return { ok: false, error: "Unauthorized worker." };
    }
    return { ok: true };
  }

  /**
   * Called from site.js runDecrypt.
   * Default: Mac host → unfairplay on this machine; Linux → fairplay-decrypt
   * + unfairplay with copied secrets. Phone / unfaird only if listed in
   * DECRYPT_BACKENDS (not needed without jailbreak / TrollStore).
   */
  async function request(url, dir, say, tryCache, vreq, job) {
    if (!validUrl(url)) throw new Error("Paste an App Store link.");
    if (typeof tryCache === "function") {
      const hit = tryCache();
      if (hit) return hit;
    }
    return enqueue(async () => {
      const order = fairplayBackends.configuredBackends();
      const wantPhone = order.includes("phone");
      if (job) job.backends = order.slice();

      // Remote / CLI backends first (anything except phone).
      try {
        const remote = await fairplayBackends.tryRemoteBackends({
          url,
          dir,
          say,
          vreq: vreq || "",
        });
        if (remote && remote.file) {
          if (job) {
            job.msg = "Clear IPA from FairPlay backend…";
            job.worker = false;
            job.backend = remote.backend || "remote";
          }
          return { file: remote.file, name: remote.name || "App" };
        }
      } catch (e) {
        if (!wantPhone) throw e;
        say(
          "Remote FairPlay backends failed — falling back to iPhone worker… (" +
            (e.message || e).toString().slice(0, 100) +
            ")"
        );
      }

      if (!wantPhone) {
        throw new Error(
          "No FairPlay backend produced an IPA. Configure DECRYPT_BACKENDS and tool env vars (see server/fairplay-backends.md)."
        );
      }
      return waitForWorker({ url, dir, say, vreq: vreq || "", job });
    });
  }

  function waitForWorker({ url, dir, say, vreq, job }) {
    const id = (job && job.id) || crypto.randomBytes(12).toString("hex");
    say("Waiting for iPhone worker…");
    if (job) {
      job.msg = "Waiting for iPhone worker…";
      job.worker = true;
    }
    return new Promise((resolve, reject) => {
      const entry = {
        id,
        url,
        vreq,
        dir,
        say,
        job,
        resolve,
        reject,
        status: "queued",
        claimedBy: "",
        createdAt: Date.now(),
      };
      waiters.set(id, entry);
      const timer = setTimeout(() => {
        const cur = waiters.get(id);
        if (!cur || cur !== entry) return;
        waiters.delete(id);
        reject(
          new Error(
            "No iPhone worker claimed this job in time. Open TetherLess → Settings › Phone Worker, turn it on, and keep the app open."
          )
        );
      }, REQUEST_MS);
      entry.timer = timer;
    });
  }

  function claimNext(workerId) {
    const next = [...waiters.values()]
      .filter((w) => w.status === "queued")
      .sort((a, b) => a.createdAt - b.createdAt)[0];
    if (!next) return null;
    next.status = "claimed";
    next.claimedBy = workerId || "iphone";
    next.say("iPhone worker claimed job…");
    if (next.job) next.job.msg = "iPhone worker claimed job…";
    return {
      id: next.id,
      url: next.url,
      version: next.vreq || "",
    };
  }

  function progress(id, msg) {
    const w = waiters.get(String(id || ""));
    if (!w) return false;
    const text = String(msg || "").slice(0, 140);
    if (text) {
      w.say(text);
      if (w.job) w.job.msg = text;
    }
    return true;
  }

  function complete(id, filePath, name) {
    const w = waiters.get(String(id || ""));
    if (!w) return { ok: false, error: "Unknown or expired job." };
    clearTimeout(w.timer);
    waiters.delete(w.id);
    const dest = path.join(w.dir, "in.ipa");
    try {
      if (filePath !== dest) {
        fs.copyFileSync(filePath, dest);
        try {
          fs.rmSync(filePath, { force: true });
        } catch {
          /* ignore */
        }
      }
      const size = fs.statSync(dest).size;
      if (size < 100) throw new Error("Uploaded IPA was empty.");
      if (size > MAX_GB * 1e9) throw new Error(`IPA is larger than ${MAX_GB} GB.`);
      w.say("IPA received from iPhone…");
      if (w.job) w.job.msg = "IPA received from iPhone…";
      w.resolve({ file: dest, name: name || "App" });
      return { ok: true };
    } catch (e) {
      w.reject(e);
      return { ok: false, error: e.message || String(e) };
    }
  }

  function failJob(id, error) {
    const w = waiters.get(String(id || ""));
    if (!w) return { ok: false, error: "Unknown or expired job." };
    clearTimeout(w.timer);
    waiters.delete(w.id);
    w.reject(new Error(String(error || "Worker failed.").slice(0, 200)));
    return { ok: true };
  }

  /** Public iTunes current build — no FastDecrypt version scraping. */
  async function versions(url, page) {
    if (!validUrl(url)) throw new Error("Paste an App Store link.");
    const m = /\bid(\d{5,12})\b/i.exec(url);
    const empty = { versions: [], items: [], page: 1, pages: 1, total: 0 };
    if (!m) return empty;
    const r = await fetch(`https://itunes.apple.com/lookup?id=${m[1]}&country=us`, {
      signal: AbortSignal.timeout(8000),
      headers: { accept: "application/json" },
    });
    const j = r.ok ? await r.json() : null;
    const a = j && j.results && j.results[0];
    if (!a || !a.version) return empty;
    const ver = String(a.version);
    const row = {
      v: ver,
      version: ver,
      label: ver,
      id: ver,
      index: 0,
      current: true,
      min_ios: a.minimumOsVersion ? String(a.minimumOsVersion) : undefined,
    };
    const p = Math.max(1, page || 1);
    const list = p === 1 ? [row] : [];
    return { ok: true, title: String(a.trackName||"App").slice(0,80), versions: list, items: list, page: p, pages: 1, total: list.length };
  }

  function attachWorkerRoutes(web, { jsonBody, fail }) {
    // SideStore-style anisette server list for Store Access (client rotates on HTTP 403).
    web.get("/api/store/anisette-servers", (_req, res) => {
      const env = String(process.env.ANISETTE_SERVERS || process.env.ANISETTE_SERVER || "")
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean);
      const defaults = ["https://ani.jkcoxson.com", "https://ani.sidestore.io"];
      const seen = new Set();
      const servers = [];
      for (const s of [...env, ...defaults]) {
        const key = s.toLowerCase();
        if (seen.has(key)) continue;
        seen.add(key);
        servers.push(s);
      }
      return res.json({ ok: true, servers, build: BUILD });
    });

    // Public-ish status for configured FairPlay backends (no secrets).
    web.get("/api/decrypt/backends", (_req, res) => {
      const fp = fairplayBackends.backendStatus();
      return res.json({
        ok: true,
        backends: fp.backends,
        status: fp,
        workerConfigured: !!WORKER_TOKEN,
        build: BUILD,
      });
    });

    web.post("/api/decrypt/worker/claim", jsonBody, (req, res) => {
      const auth = authWorker(req);
      if (!auth.ok) return fail(res, 401, auth.error);
      const job = claimNext(String((req.body || {}).adid || "iphone").slice(0, 64));
      return res.json({ ok: true, job: job || null, build: BUILD });
    });

    web.post("/api/decrypt/worker/progress", jsonBody, (req, res) => {
      const auth = authWorker(req);
      if (!auth.ok) return fail(res, 401, auth.error);
      const b = req.body || {};
      if (!progress(b.id, b.msg)) return fail(res, 404, "Job not found.");
      return res.json({ ok: true });
    });

    web.post("/api/decrypt/worker/fail", jsonBody, (req, res) => {
      const auth = authWorker(req);
      if (!auth.ok) return fail(res, 401, auth.error);
      const b = req.body || {};
      const r = failJob(b.id, b.error);
      return r.ok ? res.json({ ok: true }) : fail(res, 404, r.error);
    });

    // Raw IPA body: POST /api/decrypt/worker/complete?id=&name=
    // Content-Type: application/octet-stream
    web.post("/api/decrypt/worker/complete", (req, res) => {
      const auth = authWorker(req);
      if (!auth.ok) return fail(res, 401, auth.error);
      const id = String(req.query.id || "");
      const name = String(req.query.name || "App").slice(0, 80);
      const w = waiters.get(id);
      if (!w) return fail(res, 404, "Job not found.");
      const tmp = path.join(w.dir, "worker-upload.ipa");
      const max = MAX_GB * 1e9;
      const out = fs.createWriteStream(tmp);
      let got = 0;
      let failed = false;
      req.on("data", (chunk) => {
        got += chunk.length;
        if (got > max) {
          failed = true;
          try {
            out.destroy();
            fs.rmSync(tmp, { force: true });
          } catch {
            /* ignore */
          }
          return fail(res, 400, `IPA is larger than ${MAX_GB} GB.`);
        }
        out.write(chunk);
      });
      req.on("end", () => {
        if (failed || res.headersSent) return;
        out.end(() => {
          if (got < 100) {
            try {
              fs.rmSync(tmp, { force: true });
            } catch {
              /* ignore */
            }
            return fail(res, 400, "Uploaded IPA was empty.");
          }
          const r = complete(id, tmp, name);
          return r.ok ? res.json({ ok: true }) : fail(res, 400, r.error);
        });
      });
      req.on("error", () => {
        failed = true;
        try {
          out.destroy();
        } catch {
          /* ignore */
        }
        if (!res.headersSent) fail(res, 500, "Upload failed.");
      });
    });
  }

  // --- Optional Telegram Bot API (own bot — not FastDecryptBot) ---

  function tgApi(method, body) {
    return new Promise((resolve, reject) => {
      if (!BOT_TOKEN) return reject(new Error("TELEGRAM_BOT_TOKEN not set"));
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

  function chatAllowed(chatId) {
    if (!ALLOWED_CHAT_IDS.length) return true;
    return ALLOWED_CHAT_IDS.includes(String(chatId));
  }

  function startTelegramBot(helpers) {
    if (!BOT_TOKEN) {
      console.warn("Decrypt TG bot: TELEGRAM_BOT_TOKEN not set — bot polling disabled.");
      return;
    }
    if (typeof helpers.createDecryptJob !== "function") {
      console.warn("Decrypt TG bot: createDecryptJob helper missing.");
      return;
    }
    if (botTimer) return;
    console.log(`Decrypt TG bot: polling as @${BOT_USERNAME}`);
    botTimer = setInterval(() => {
      pollBot(helpers).catch((e) => console.warn("TG bot poll:", e.message || e));
    }, 2000);
    if (botTimer.unref) botTimer.unref();
  }

  async function pollBot(helpers) {
    const r = await tgApi("getUpdates", {
      offset: botOffset,
      timeout: 0,
      allowed_updates: ["message"],
    });
    if (!r.ok || !Array.isArray(r.result)) return;
    for (const u of r.result) {
      botOffset = Math.max(botOffset, (u.update_id || 0) + 1);
      const msg = u.message;
      if (!msg || !msg.chat) continue;
      const chatId = msg.chat.id;
      if (!chatAllowed(chatId)) {
        await tgApi("sendMessage", {
          chat_id: chatId,
          text: "This bot is private.",
        }).catch(() => {});
        continue;
      }
      const text = String(msg.text || "").trim();
      if (!text) continue;
      if (/^\/(start|help)/i.test(text)) {
        await tgApi("sendMessage", {
          chat_id: chatId,
          text:
            "Send an App Store link (https://apps.apple.com/…). Your iPhone worker decrypts it on-device and I’ll send the IPA back.",
        }).catch(() => {});
        continue;
      }
      const link = text.split(/\s+/).find((t) => validUrl(t));
      if (!link) {
        await tgApi("sendMessage", {
          chat_id: chatId,
          text: "Paste a full apps.apple.com link.",
        }).catch(() => {});
        continue;
      }
      const verMatch = text.match(/\b(?:v|version)[:=\s]+([0-9][0-9A-Za-z._-]{0,29})\b/i);
      const version = verMatch ? verMatch[1] : "";
      try {
        await tgApi("sendMessage", {
          chat_id: chatId,
          text: "Queued for your iPhone worker…",
        });
        const result = await helpers.createDecryptJob({
          url: link,
          version,
          uid: "tg:" + chatId,
          ip: "telegram",
          notify: async (status, payload) => {
            if (status === "done" && payload && payload.filePath) {
              // site helper should upload via sendDocument if possible; else link.
              if (typeof helpers.sendIpaToChat === "function") {
                await helpers.sendIpaToChat(chatId, payload);
              } else {
                await tgApi("sendMessage", {
                  chat_id: chatId,
                  text: `Done: ${payload.name || "App"} — download from the site.`,
                });
              }
            } else if (status === "error") {
              await tgApi("sendMessage", {
                chat_id: chatId,
                text: "Failed: " + String((payload && payload.error) || "unknown"),
              });
            } else if (status === "progress" && payload && payload.msg) {
              // keep quiet on every progress tick — too noisy
            }
          },
        });
        if (result && result.error) {
          await tgApi("sendMessage", { chat_id: chatId, text: result.error });
        }
      } catch (e) {
        await tgApi("sendMessage", {
          chat_id: chatId,
          text: "Couldn’t queue: " + (e.message || e),
        }).catch(() => {});
      }
    }
  }

  // Admin stubs — GramJS userbot login removed; bot uses TELEGRAM_BOT_TOKEN.
  async function status() {
    const fp = fairplayBackends.backendStatus();
    const wantsPhone = fp.backends.includes("phone");
    const cred = fp.credential || {};
    let error = "";
    const model = fp.enrollmentModel || {};
    const unfair = fp.unfairplay || {};
    if (fp.requireCredential && !cred.ready && !model.ready && !unfair.ready) {
      error =
        cred.error ||
        "Set FAIRPLAY_CREDENTIAL_BIN / FAIRPLAY_ENROLLMENT_MODEL, or run on a Mac (FAIRPLAY_HOST=mac) with UnfairPlay setup — see server/fairplay-backends.md.";
    } else if (wantsPhone && !WORKER_TOKEN) {
      error = "Set DECRYPT_WORKER_TOKEN and enable Phone Worker in the iOS app (or drop phone from DECRYPT_BACKENDS).";
    } else if (!BOT_TOKEN) {
      error =
        "TELEGRAM_BOT_TOKEN optional. Prefer FAIRPLAY_HOST=mac + DECRYPT_BACKENDS=unfairplay on a rented Mac — see server/fairplay-backends.md.";
    }
    return {
      lib: true,
      mode: fp.backends.join("+") || (fp.host === "mac" ? "unfairplay" : "fairplay-decrypt+unfairplay"),
      host: fp.host || "linux",
      authed: !!BOT_TOKEN,
      who: BOT_TOKEN ? { name: "Bot API", username: BOT_USERNAME } : {},
      workerConfigured: !!WORKER_TOKEN,
      waiting: queueLen(),
      fairplay: fp,
      error,
      bot: BOT_USERNAME,
      build: BUILD,
    };
  }

  async function setKeys() {
    return "Bot API mode: set TELEGRAM_BOT_TOKEN in the environment (no my.telegram.org api_id).";
  }
  async function sendCode() {
    return { error: "Bot API mode — no userbot phone login. Use TELEGRAM_BOT_TOKEN." };
  }
  async function signIn() {
    return { error: "Bot API mode — no userbot sign-in." };
  }
  async function useSession() {
    return "Bot API mode — sessions are not used. Set TELEGRAM_BOT_TOKEN.";
  }
  async function logout() {
    return;
  }

  return {
    bot: BOT_USERNAME,
    validUrl,
    busy,
    queueLen,
    request,
    versions,
    status,
    setKeys,
    sendCode,
    signIn,
    useSession,
    logout,
    attachWorkerRoutes,
    startTelegramBot,
    tgApi: BOT_TOKEN ? tgApi : null,
  };
}

module.exports = { create, BUILD };
