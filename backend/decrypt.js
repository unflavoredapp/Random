"use strict";
/**
 * Telegram userbot → @FastDecryptBot bridge for AirShare / TetherLess decrypt.
 *
 * Expected by site.js:
 *   create({ db, secret }) → {
 *     bot, validUrl, busy, queueLen,
 *     request(url, dir, say, tryCache, vreq),
 *     versions(url, page),
 *     status, setKeys, sendCode, signIn, useSession, logout
 *   }
 *
 * Needs the `telegram` (GramJS) package. Without it, create() throws so site.js
 * disables decrypt with a warning (same as before).
 */

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const BUILD = "tetherless-decrypt-2";
const BOT = process.env.DECRYPT_BOT || "FastDecryptBot";
const MAX_GB = Number(process.env.DECRYPT_MAX_GB) || 1.5;
const REQUEST_MS = (Number(process.env.DECRYPT_TIMEOUT_MIN) || 12) * 60 * 1000;
const VERSION_MS = 90 * 1000;

function create({ db, secret }) {
  if (!db) throw new Error("decrypt.create needs db");
  const encKey = deriveKey(secret);

  db.exec(`CREATE TABLE IF NOT EXISTS tg_decrypt(
    id INTEGER PRIMARY KEY CHECK (id = 1),
    api_id TEXT, api_hash TEXT, session TEXT, phone TEXT, updated_at TEXT
  )`);
  if (!db.prepare("SELECT 1 FROM tg_decrypt WHERE id=1").get()) {
    db.prepare("INSERT INTO tg_decrypt(id,api_id,api_hash,session,phone,updated_at) VALUES(1,'','','','',?)")
      .run(new Date().toISOString());
  }

  let TelegramClient = null, StringSession = null, Api = null, libErr = null;
  try {
    // Prefer the dedicated install dir used in production, then local node_modules.
    const modulePaths = [
      "/opt/airshare-telegram/node_modules/telegram",
      path.join(__dirname, "..", "node_modules", "telegram"),
      "telegram",
    ];
    let mod = null, resolved = null, last = null;
    for (const c of modulePaths) {
      try { resolved = require.resolve(c); mod = require(c); break; } catch (e) { last = e; }
    }
    if (!mod) throw last || new Error("telegram package missing");
    TelegramClient = mod.TelegramClient;
    if (!TelegramClient) throw new Error("telegram.TelegramClient missing");
    Api = mod.Api;
    try {
      StringSession = require(path.join(path.dirname(resolved), "sessions")).StringSession;
    } catch {
      StringSession = require("telegram/sessions").StringSession;
    }
  } catch (e) {
    libErr = e.message || String(e);
  }

  const row = () => db.prepare("SELECT api_id,api_hash,session,phone FROM tg_decrypt WHERE id=1").get() || {};
  const save = (patch) => {
    const cur = row();
    const next = Object.assign({}, cur, patch, { updated_at: new Date().toISOString() });
    db.prepare("UPDATE tg_decrypt SET api_id=?, api_hash=?, session=?, phone=?, updated_at=? WHERE id=1")
      .run(next.api_id || "", next.api_hash || "", next.session || "", next.phone || "", next.updated_at);
  };

  let client = null;
  let pending = null; // { phoneCodeHash, phone }
  let queue = Promise.resolve();
  let active = 0;
  let waiting = 0;

  function validUrl(u) {
    return /^https:\/\/(?:apps|itunes)\.apple\.com\//i.test(String(u || "").trim());
  }

  async function status() {
    const r = row();
    const hasKeys = !!(r.api_id && (r.api_hash || encKey));
    let authed = false, who = {}, error = libErr || "";
    if (TelegramClient && r.session) {
      try {
        const c = await ensureClient();
        const me = await c.getMe();
        authed = true;
        who = { name: [me.firstName, me.lastName].filter(Boolean).join(" "), username: me.username || "" };
      } catch (e) {
        error = e.message || String(e);
      }
    }
    return {
      lib: !!TelegramClient,
      authed,
      who,
      bot: BOT,
      hasKeys: !!(r.api_id && r.api_hash),
      apiId: r.api_id ? String(r.api_id) : "",
      error,
      build: BUILD,
      maxGb: MAX_GB,
    };
  }

  async function setKeys(apiId, apiHash) {
    if (!TelegramClient) return libErr || "telegram package missing";
    const id = String(apiId || "").trim();
    const hash = String(apiHash || "").trim();
    if (!/^\d{4,12}$/.test(id)) return "api_id looks wrong.";
    if (hash && !/^[0-9a-f]{32}$/i.test(hash)) return "api_hash should be 32 hex characters.";
    if (!hash && !row().api_hash) return "api_hash required.";
    save({ api_id: id, api_hash: hash || row().api_hash });
    await dropClient();
    return null;
  }

  async function sendCode(phone) {
    if (!TelegramClient) return { error: libErr || "telegram package missing" };
    const p = String(phone || "").replace(/\s+/g, "");
    if (!/^\+\d{8,16}$/.test(p)) return { error: "Use international format, e.g. +15551234567." };
    try {
      const c = await ensureClient({ allowEmptySession: true });
      const res = await c.invoke(new Api.auth.SendCode({
        phoneNumber: p,
        apiId: Number(row().api_id),
        apiHash: row().api_hash,
        settings: new Api.CodeSettings({}),
      }));
      pending = { phoneCodeHash: res.phoneCodeHash, phone: p };
      save({ phone: p });
      const viaApp = String(res.type?.className || "").toLowerCase().includes("app");
      return { ok: true, viaApp };
    } catch (e) {
      return { error: e.errorMessage || e.message || String(e) };
    }
  }

  async function signIn(code, password) {
    if (!TelegramClient) return { error: libErr || "telegram package missing" };
    try {
      const c = await ensureClient({ allowEmptySession: true });
      if (password) {
        await c.signInWithPassword({ apiId: Number(row().api_id), apiHash: row().api_hash }, { password: String(password) });
      } else {
        if (!pending) return { error: "Send a code first." };
        try {
          await c.invoke(new Api.auth.SignIn({
            phoneNumber: pending.phone,
            phoneCodeHash: pending.phoneCodeHash,
            phoneCode: String(code || "").trim(),
          }));
        } catch (e) {
          if (e.errorMessage === "SESSION_PASSWORD_NEEDED" || /PASSWORD/i.test(e.message || "")) {
            return { need2fa: true };
          }
          throw e;
        }
      }
      save({ session: c.session.save() });
      pending = null;
      return { ok: true };
    } catch (e) {
      return { error: e.errorMessage || e.message || String(e) };
    }
  }

  async function useSession(session) {
    if (!TelegramClient) return libErr || "telegram package missing";
    const s = String(session || "").trim();
    if (s.length < 20) return "Session string looks too short.";
    save({ session: s });
    await dropClient();
    try {
      await ensureClient();
      const me = await client.getMe();
      if (!me) return "Session didn't authorize.";
      return null;
    } catch (e) {
      return e.message || String(e);
    }
  }

  async function logout() {
    try { if (client) await client.invoke(new Api.auth.LogOut()); } catch { /* ignore */ }
    await dropClient();
    save({ session: "", phone: "" });
    pending = null;
  }

  async function dropClient() {
    try { if (client) await client.disconnect(); } catch { /* ignore */ }
    client = null;
  }

  async function ensureClient({ allowEmptySession } = {}) {
    if (!TelegramClient) throw new Error(libErr || "telegram package missing");
    const r = row();
    if (!r.api_id || !r.api_hash) throw new Error("Add Telegram api_id and api_hash in Admin › Telegram.");
    if (!r.session && !allowEmptySession) throw new Error("Log in to Telegram in Admin › Telegram first.");
    if (client) return client;
    const session = new StringSession(r.session || "");
    const c = new TelegramClient(session, Number(r.api_id), r.api_hash, {
      connectionRetries: 5,
      deviceModel: "TetherLess",
      appVersion: BUILD,
      systemVersion: "Node",
    });
    await c.connect();
    if (r.session && !(await c.checkAuthorization())) {
      throw new Error("Telegram session expired. Log in again in Admin › Telegram.");
    }
    client = c;
    return c;
  }

  function busy() { return active > 0; }
  function queueLen() { return waiting; }

  function enqueue(fn) {
    waiting++;
    const run = queue.then(async () => {
      waiting = Math.max(0, waiting - 1);
      active++;
      try { return await fn(); }
      finally { active = Math.max(0, active - 1); }
    });
    queue = run.catch(() => {});
    return run;
  }

  async function request(url, dir, say, tryCache, vreq) {
    if (!validUrl(url)) throw new Error("Paste an App Store link.");
    if (typeof tryCache === "function") {
      const hit = tryCache();
      if (hit) return hit;
    }
    return enqueue(() => talkToBot({ url, dir, say, vreq, mode: "decrypt" }));
  }

  async function versions(url, page) {
    if (!validUrl(url)) throw new Error("Paste an App Store link.");
    return enqueue(async () => {
      const say = () => {};
      const dir = fs.mkdtempSync(path.join(require("os").tmpdir(), "dec-ver-"));
      try {
        const r = await talkToBot({ url, dir, say, vreq: "", mode: "versions", page: page || 1 });
        return r.versions || { items: [], page: 1, pages: 1, total: 0 };
      } finally {
        try { fs.rmSync(dir, { recursive: true, force: true }); } catch { /* ignore */ }
      }
    });
  }

  async function talkToBot({ url, dir, say, vreq, mode, page }) {
    const c = await ensureClient();
    say("Opening @" + BOT);
    const entity = await c.getEntity(BOT);
    const since = Math.floor(Date.now() / 1000) - 2;
    const text = vreq ? `${url}\n${vreq}` : url;
    await c.sendMessage(entity, { message: text });
    say(mode === "versions" ? "Asking for versions…" : (vreq ? "Requesting version " + vreq : "Waiting on @" + BOT));

    const deadline = Date.now() + (mode === "versions" ? VERSION_MS : REQUEST_MS);
    let lastProgress = "";
    const versions = [];
    let file = null, name = "App", dlUrl = null;

    while (Date.now() < deadline) {
      await sleep(1500);
      const msgs = await c.getMessages(entity, { limit: 12 });
      for (const m of msgs) {
        if (!m || (m.date && m.date < since)) continue;
        const body = (m.message || "").trim();
        if (body && body !== lastProgress) {
          lastProgress = body;
          const short = body.replace(/\s+/g, " ").slice(0, 120);
          if (/queue|wait|download|decrypt|process|fetch|upload|%|version/i.test(short)) say(short);
        }

        // Inline / reply keyboard buttons often list versions.
        const buttons = flattenButtons(m);
        for (const b of buttons) {
          const t = String(b.text || b.data || "");
          const ver = parseVersionLabel(t);
          if (ver && !versions.some(v => v.version === ver)) {
            versions.push({ version: ver, label: t, id: String(b.data || ver) });
          }
          if (mode === "decrypt" && vreq && versionMatches(t, vreq)) {
            try {
              await m.click({ text: b.text });
              say("Selected " + vreq);
            } catch { /* ignore */ }
          }
        }

        // Document / IPA attachment
        if (m.media && (m.media.document || m.document)) {
          const doc = m.media.document || m.document;
          const fname = docFileName(doc) || "app.ipa";
          if (/\.ipa$/i.test(fname) || (doc.mimeType || "").includes("zip") || (doc.size || 0) > 1e6) {
            if (mode === "versions") continue;
            const maxBytes = MAX_GB * 1e9;
            if (doc.size && doc.size > maxBytes) throw new Error(`IPA is larger than ${MAX_GB} GB.`);
            say("Downloading IPA from Telegram…");
            const dest = path.join(dir, "in.ipa");
            await c.downloadMedia(m, { outputFile: dest });
            if (!fs.existsSync(dest) || fs.statSync(dest).size < 100) throw new Error("Telegram download was empty.");
            file = dest;
            name = fname.replace(/\.ipa$/i, "") || "App";
            return { file, name };
          }
        }

        // HTTPS download link in message text or entities
        const links = extractLinks(m);
        for (const link of links) {
          if (/\.ipa(\?|$)/i.test(link) || /download|ipa|cdn|storage/i.test(link)) {
            if (mode === "versions") continue;
            dlUrl = link;
            name = guessName(body) || "App";
            return { url: dlUrl, name };
          }
        }
      }

      if (mode === "versions" && versions.length) {
        const pageSize = 20;
        const p = Math.max(1, page || 1);
        const pages = Math.max(1, Math.ceil(versions.length / pageSize));
        const items = versions.slice((p - 1) * pageSize, p * pageSize).map((v, i) => ({
          version: v.version,
          label: v.label,
          id: v.id || v.version,
          index: (p - 1) * pageSize + i,
        }));
        return { versions: { items, page: p, pages, total: versions.length } };
      }
    }

    if (mode === "versions") {
      return { versions: { items: [], page: 1, pages: 1, total: 0 } };
    }
    throw new Error("@" + BOT + " didn't return an IPA in time. Try again, or use on-device decrypt.");
  }

  return {
    bot: BOT,
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
  };
}

// --- helpers ---

function deriveKey(secret) {
  return crypto.createHash("sha256").update(String(secret || "tetherless")).digest();
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function flattenButtons(m) {
  const out = [];
  const rows = (m.replyMarkup && (m.replyMarkup.rows || m.replyMarkup.buttons)) || [];
  for (const row of rows) {
    const buttons = row.buttons || row || [];
    for (const b of buttons) out.push(b);
  }
  return out;
}

function parseVersionLabel(t) {
  const s = String(t || "");
  const m = s.match(/\b(\d+(?:\.\d+){1,3}(?:\.\d+)?)\b/);
  return m ? m[1] : "";
}

function versionMatches(label, want) {
  const a = String(want || "").trim();
  if (!a) return false;
  return String(label).includes(a) || parseVersionLabel(label) === a;
}

function docFileName(doc) {
  const attrs = doc.attributes || [];
  for (const a of attrs) {
    if (a.fileName) return a.fileName;
    if (a.className === "DocumentAttributeFilename" && a.fileName) return a.fileName;
  }
  return "";
}

function extractLinks(m) {
  const links = [];
  const text = m.message || "";
  const re = /https:\/\/[^\s<>"')]+/gi;
  let x;
  while ((x = re.exec(text))) links.push(x[0].replace(/[.,;]+$/, ""));
  const ents = m.entities || [];
  for (const e of ents) {
    if (e.url) links.push(e.url);
  }
  return [...new Set(links)];
}

function guessName(body) {
  const m = String(body || "").match(/(?:app|name)\s*[:\-]\s*([^\n]+)/i);
  return m ? m[1].trim().slice(0, 60) : "";
}

module.exports = { create };
