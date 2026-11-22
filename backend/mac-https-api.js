#!/usr/bin/env node
// Brand: Tetherless · https://tetherless.dev
"use strict";
/**
 * Tetherless Mac backup decrypt HTTPS API (App → Decrypt site URL).
 *
 * Run via WebSSH (dedicated keychain) behind Cloudflare tunnel:
 *   zsh server/mac-ssh.sh api
 *   source ~/.tetherless-mac.env
 *   node server/mac-https-api.js
 *   # other terminal: cloudflared tunnel --url http://127.0.0.1:8787
 *
 * Then in the iOS app: FairPlay Decrypt → Decrypt site URL → https://….trycloudflare.com/
 *
 * Auth: accepts the app's Bearer token when MAC_API_OPEN=1 (default on Mac backup).
 * Optional: MAC_API_BEARER=secret to require that exact token instead.
 */
const http = require("http");
const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { spawn, spawnSync } = require("child_process");
const fairplayBackends = require("./fairplayBackends");
const publicDl = require("./mac-tg-public-dl");
const ipatoolExtras = require("./mac-ipatool-extras");

const PORT = Number(process.env.MAC_API_PORT || 8787);
const OPEN = String(process.env.MAC_API_OPEN || "1") !== "0";
const REQUIRE = String(process.env.MAC_API_BEARER || "").trim();
const WORK = process.env.MAC_API_WORK_DIR || path.join(os.tmpdir(), "tetherless-mac-api");
const BUILD = "tetherless-mac-https-api-3-tg-admin";
const AUTH_PY = path.join(__dirname, "mac-tg-auth-web.py");

function runTgAuth(cmd, bodyObj) {
  return new Promise((resolve) => {
    const child = spawn("python3", [AUTH_PY, cmd], {
      env: process.env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    let out = "";
    let err = "";
    const killer = setTimeout(() => {
      try {
        child.kill("SIGKILL");
      } catch {
        /* ignore */
      }
    }, 120000);
    child.stdout.on("data", (c) => {
      out += c.toString("utf8");
    });
    child.stderr.on("data", (c) => {
      err += c.toString("utf8");
    });
    child.on("close", () => {
      clearTimeout(killer);
      const line = out.trim().split(/\n/).filter(Boolean).pop() || "";
      try {
        resolve(JSON.parse(line));
      } catch {
        resolve({
          ok: false,
          error: (err || out || "auth helper failed").toString().slice(0, 240),
        });
      }
    });
    child.on("error", (e) => {
      clearTimeout(killer);
      resolve({ ok: false, error: String((e && e.message) || e) });
    });
    try {
      child.stdin.write(JSON.stringify(bodyObj || {}));
      child.stdin.end();
    } catch {
      /* ignore */
    }
  });
}

function sendTgAdminHtml(res) {
  const html = `<!DOCTYPE html>
<html lang="en"><head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<meta name="color-scheme" content="dark"/>
<title>Telegram · FastDecrypt</title>
<style>
:root{--acc:#ff9a1f;--bg:#0b0b0b;--card:#141414;--line:#292929;--muted:#9a9a9a}
*{box-sizing:border-box}body{margin:0;font:16px/1.45 -apple-system,system-ui,sans-serif;background:var(--bg);color:#fff}
.w{max-width:560px;margin:0 auto;padding:18px 16px 48px}
h1{font-size:28px;margin:8px 0 14px}h2{font-size:13px;letter-spacing:1px;color:var(--muted);margin:22px 0 8px}
.box{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px 14px 16px;margin:0 0 12px}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:8px;background:#f33;vertical-align:middle}
.dot.ok{background:#2fd16b}label{display:block;margin:12px 0 4px;font-size:13px;color:var(--muted)}
input{width:100%;height:44px;padding:0 12px;border:1px solid #333;border-radius:11px;background:#0b0b0b;color:#fff;font:16px system-ui;outline:0}
input:focus{border-color:var(--acc)}.btn{appearance:none;border:0;border-radius:12px;background:var(--acc);color:#111;font:700 15px system-ui;padding:12px 16px;margin-top:12px;width:100%;cursor:pointer}
.btn.sec{background:transparent;border:1px solid #444;color:#ddd}.btn.danger{background:transparent;border:1px solid #7a2318;color:#f66;margin-top:18px}
.mm{color:var(--muted);font-size:12px;margin:8px 0 0}.flash{padding:10px 12px;border-radius:12px;border:1px solid #333;margin:10px 0;display:none}
.flash.on{display:block}.flash.bad{border-color:#f33;color:#f66}.flash.ok{border-color:#2f8f4a;color:#5fd17f}
details{margin-top:10px}summary{cursor:pointer;color:var(--acc);font-weight:600}
code{background:#111;border:1px solid #292929;border-radius:8px;padding:2px 7px}
</style></head><body><div class="w">
<h1>Telegram</h1>
<div class="box" id="status"><span class="dot" id="dot"></span><span id="statusText">Checking…</span>
<p class="mm" id="route"></p></div>
<div class="flash" id="flash"></div>

<h2>API KEYS</h2>
<div class="box">
<p class="mm">From my.telegram.org → API development tools.</p>
<label>api_id</label><input id="api_id" inputmode="numeric" autocomplete="off" placeholder="12345678"/>
<label>api_hash</label><input id="api_hash" autocomplete="off" placeholder="saved (enter to replace)"/>
<button class="btn" type="button" id="saveKeys">Save keys</button>
</div>

<h2>LOG IN</h2>
<div class="box">
<label>Phone (with country code)</label>
<input id="phone" type="tel" autocomplete="tel" placeholder="+15551234567"/>
<button class="btn" type="button" id="sendCode">Send code</button>
<label>Login code</label>
<input id="code" inputmode="numeric" autocomplete="one-time-code" placeholder="12345"/>
<label>2FA password (if enabled)</label>
<input id="password" type="password" autocomplete="current-password" placeholder="optional"/>
<button class="btn" type="button" id="signIn">Sign in</button>
<details><summary>Or paste a session string</summary>
<label>Session string</label>
<input id="session" autocomplete="off" placeholder="Pyrogram / Telethon string session"/>
<button class="btn sec" type="button" id="useSession">Save session</button>
</details>
<button class="btn danger" type="button" id="logout">Log out of Telegram</button>
<p class="mm">Codes arrive in the official <b>Telegram</b> chat as “Login code: …”, not my.telegram.org web codes. Large IPAs also work via HTTPS download when this session is missing.</p>
</div>
<p class="mm">build ${BUILD}</p>
</div>
<script>
(function(){
function $(id){return document.getElementById(id);}
function flash(msg,bad){var f=$('flash');f.textContent=msg||'';f.className='flash on '+(bad?'bad':'ok');}
function post(path,body){
  return fetch(path,{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(body||{})})
    .then(function(r){return r.json();});
}
function paint(s){
  var ok=!!(s&&s.authed);$('dot').className='dot'+(ok?' ok':'');
  if(ok){
    var w=s.who||{};
    var name=w.name||('id '+w.id)||'user';
    var un=w.username?(' @'+w.username):'';
    $('statusText').innerHTML='Connected as <b>'+name+'</b>'+un+(w.premium?' · Premium':'');
    $('route').textContent='Requests upload via @'+(s.bot||'FastDecryptAI')+(s.channel?(' · channel '+s.channel):'');
  }else{
    $('statusText').textContent='Not connected';
    $('route').textContent=s&&s.error?s.error:'Save keys, then Send code — or paste a session string.';
  }
  if(s&&s.apiId)$('api_id').value=s.apiId;
  if(s&&s.hasHash)$('api_hash').placeholder='saved (enter to replace)';
  if(s&&s.pendingPhone)$('phone').value=s.pendingPhone;
}
function refresh(){fetch('/tg-login/status').then(function(r){return r.json();}).then(paint).catch(function(){flash('Status failed',true);});}
function keysPayload(){return{api_id:$('api_id').value,api_hash:$('api_hash').value};}
$('saveKeys').onclick=function(){post('/tg-login/keys',keysPayload()).then(function(j){flash(j.message||j.error,!j.ok);refresh();});};
$('sendCode').onclick=function(){var b=keysPayload();b.phone=$('phone').value;post('/tg-login/send-code',b).then(function(j){flash(j.message||j.error,!j.ok);});};
$('signIn').onclick=function(){var b=keysPayload();b.phone=$('phone').value;b.code=$('code').value;b.password=$('password').value;post('/tg-login/sign-in',b).then(function(j){flash(j.message||j.error,!j.ok);if(j.ok)refresh();});};
$('useSession').onclick=function(){var b=keysPayload();b.session=$('session').value;post('/tg-login/session',b).then(function(j){flash(j.message||j.error,!j.ok);if(j.ok)refresh();});};
$('logout').onclick=function(){if(!confirm('Log out Premium session?'))return;post('/tg-login/logout',{}).then(function(j){flash(j.message||j.error,!j.ok);refresh();});};
refresh();
})();
</script></body></html>`;
  const body = Buffer.from(html, "utf8");
  res.writeHead(200, {
    "Content-Type": "text/html; charset=utf-8",
    "Content-Length": body.length,
    "Cache-Control": "no-store",
    "Access-Control-Allow-Origin": "*",
  });
  res.end(body);
}

fs.mkdirSync(WORK, { recursive: true });
fs.mkdirSync(path.join(WORK, "out"), { recursive: true });

/** @type {Map<string, any>} */
const jobs = new Map();
/** @type {Map<string, { file: string, name: string, expires: number }>} */
const uploads = new Map();

function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
    "Cache-Control": "no-store",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Authorization, Content-Type, X-AS-ADID, X-AS-Apple-ID, X-AS-Apple-ID-Account",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
  });
  res.end(body);
}

function fail(res, code, error) {
  return json(res, code, { ok: false, error });
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch (e) {
        reject(e);
      }
    });
    req.on("error", reject);
  });
}

function actor(req) {
  const hdr = String(req.headers.authorization || "");
  const token = hdr.replace(/^Bearer\s+/i, "").trim();
  if (REQUIRE) {
    if (token !== REQUIRE) return null;
    return "bearer:" + crypto.createHash("sha256").update(token).digest("hex").slice(0, 16);
  }
  if (!OPEN) return null;
  // Backup mode: any bearer (or ADID) maps to a stable uid.
  const adid = String(req.headers["x-as-adid"] || "").trim();
  const seed = token || adid || req.socket.remoteAddress || "anon";
  return "mac:" + crypto.createHash("sha256").update(seed).digest("hex").slice(0, 16);
}

function validUrl(u) {
  return /^https:\/\/(?:apps|itunes)\.apple\.com\//i.test(String(u || "").trim());
}

/** Apple first-party apps — refuse before ipatool/unfairplay (opaque JS stack overflows). */
function isAppleSystemApp(storeUrl, bid) {
  const b = String(bid || "").toLowerCase();
  if (b.startsWith("com.apple.")) return true;
  const adam = ((/\bid(\d{5,12})\b/i.exec(String(storeUrl || "")) || [])[1] || "");
  const blocked = new Set([
    "899247664", // TestFlight
    "1231336508", // Apple Store
    "1146562112", // Apple TV
  ]);
  return !!(adam && blocked.has(adam));
}

const APPLE_SYSTEM_MSG =
  "Apple system apps (TestFlight, App Store, …) can’t be decrypted. Pick a third-party App Store title.";

function unlockKeychain() {
  const pass = String(process.env.TETHERLESS_KEYCHAIN_PASSWORD || "").trim();
  const kc = path.join(os.homedir(), "Library/Keychains/tetherless.keychain-db");
  if (!pass || !fs.existsSync(kc)) return;
  spawnSync("security", ["unlock-keychain", "-p", pass, kc], { stdio: "ignore" });
  spawnSync("security", ["list-keychains", "-d", "user", "-s", kc], { stdio: "ignore" });
  spawnSync("security", ["default-keychain", "-d", "user", "-s", kc], { stdio: "ignore" });
}

async function runJob(j) {
  const dir = fs.mkdtempSync(path.join(WORK, "job-"));
  j.status = "running";
  j.msg = "Starting";
  j.progress = 2;
  const session = ipatoolExtras.sessionWatch();
  if (!session.ready) {
    j.status = "error";
    j.error = session.error || session.hint || "ipatool session missing";
    j.msg = "Failed";
    return;
  }
  const say = (t) => {
    j.msg = String(t).slice(0, 140);
    const stage = ipatoolExtras.mapProgressStage(t);
    if (stage != null) j.progress = Math.max(j.progress || 0, stage);
    console.log("[api]", j.id, j.msg);
  };
  try {
    unlockKeychain();
    const result = await fairplayBackends.tryRemoteBackends({
      url: j.url,
      dir,
      say,
      vreq: j.vreq || "",
      storefront: j.storefront || "",
      onProgress: (pct, msg) => {
        j.progress = Math.max(j.progress || 0, Number(pct) || 0);
        if (msg) j.msg = String(msg).slice(0, 140);
      },
    });
    if (!result || !result.file || !fs.existsSync(result.file)) {
      throw new Error("Decrypt produced no IPA");
    }
    const up = crypto.randomBytes(16).toString("hex");
    const keep = path.join(WORK, "out", `${up}.ipa`);
    fs.copyFileSync(result.file, keep);
    const st = fs.statSync(keep);
    uploads.set(up, {
      file: keep,
      name: result.name || "App",
      expires: Date.now() + 60 * 60 * 1000,
    });
    Object.assign(j, {
      status: "done",
      msg: "Done",
      progress: 100,
      up,
      name: result.name || "App",
      bid: result.bid || "",
      ver: j.vreq || "",
      size: st.size,
    });
  } catch (e) {
    j.status = "error";
    j.error = fairplayBackends.friendlyIpatoolError(e).slice(0, 200);
    j.msg = "Failed";
    console.warn("[api] job failed:", j.error);
  } finally {
    try {
      fs.rmSync(dir, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  }
}

function cleanUploads() {
  const now = Date.now();
  for (const [id, u] of uploads) {
    if (u.expires < now) {
      try {
        fs.rmSync(u.file, { force: true });
      } catch {
        /* ignore */
      }
      uploads.delete(id);
    }
  }
}
setInterval(cleanUploads, 5 * 60 * 1000).unref();

async function handle(req, res) {
  const u = new URL(req.url || "/", `http://${req.headers.host || "127.0.0.1"}`);
  const p = u.pathname.replace(/\/+$/, "") || "/";

  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Headers": "Authorization, Content-Type, X-AS-ADID, X-AS-Apple-ID, X-AS-Apple-ID-Account",
      "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
    });
    return res.end();
  }

  if (p === "/" || p === "/health" || p === "/api/mac-host") {
    const fp = fairplayBackends.backendStatus();
    const resHost = fairplayBackends.hostResources ? fairplayBackends.hostResources() : null;
    const publicBase = publicDl.resolvePublicBase() || "";
    // Prefer the Host header when the phone hits us through the live tunnel.
    const viaHost = String(req.headers.host || "").trim();
    const liveBase =
      viaHost && !/^127\.0\.0\.1(?::|$)/i.test(viaHost) && !/^localhost(?::|$)/i.test(viaHost)
        ? `https://${viaHost.replace(/\/+$/, "")}`
        : "";
    const macApi = (liveBase || publicBase || "").replace(/\/+$/, "");
    const session = ipatoolExtras.sessionWatch();
    const purchased = ipatoolExtras.loadPurchased();
    return json(res, 200, {
      ok: true,
      service: "tetherless-mac-https-api",
      build: BUILD,
      host: fp.host,
      macHost: fp.host === "mac",
      unfairplay: !!(fp.unfairplay && fp.unfairplay.ready),
      model: !!(fp.enrollmentModel && fp.enrollmentModel.ready),
      publicBase: macApi || undefined,
      macApiUrl: macApi ? macApi + "/" : undefined,
      tgLogin: macApi ? `${macApi}/tg-login` : "/tg-login",
      buildTgAdmin: BUILD,
      ipatoolSession: session,
      purchasedCount: (purchased.items || []).length,
      purchasedUpdatedAt: purchased.updatedAt || 0,
      prefetch: ipatoolExtras.listPrefetch().filter((x) => x.status === "queued" || x.status === "running").length,
      resources: resHost
        ? {
            freeDiskGb: Number(resHost.freeDiskGb.toFixed(2)),
            totalMemGb: Number(resHost.totalMemGb.toFixed(2)),
            freeMemGb: Number(resHost.freeMemGb.toFixed(2)),
          }
        : undefined,
    });
  }

  // decrypt.team-style Premium user login (api keys / send code / paste session).
  if (p === "/tg-login" && req.method === "GET") {
    return sendTgAdminHtml(res);
  }
  if (p === "/tg-login/status" && req.method === "GET") {
    const st = await runTgAuth("status", {});
    return json(res, 200, { ...st, build: BUILD });
  }
  if (p === "/tg-login/keys" && req.method === "POST") {
    const body = await readBody(req).catch(() => ({}));
    return json(res, 200, await runTgAuth("set-keys", body));
  }
  if (p === "/tg-login/send-code" && req.method === "POST") {
    const body = await readBody(req).catch(() => ({}));
    return json(res, 200, await runTgAuth("send-code", body));
  }
  if (p === "/tg-login/sign-in" && req.method === "POST") {
    const body = await readBody(req).catch(() => ({}));
    return json(res, 200, await runTgAuth("sign-in", body));
  }
  if (p === "/tg-login/session" && req.method === "POST") {
    const body = await readBody(req).catch(() => ({}));
    return json(res, 200, await runTgAuth("use-session", body));
  }
  if (p === "/tg-login/logout" && req.method === "POST") {
    return json(res, 200, await runTgAuth("logout", {}));
  }

  // Open-in bridge: Discord Link buttons → custom schemes (TrollStore / Feather / …).
  const openMatch = /^\/open\/([a-z0-9-]+)$/i.exec(p);
  if (openMatch && req.method === "GET") {
    let openIn;
    try {
      openIn = require("./mac-open-in");
    } catch (e) {
      return fail(res, 500, "Open-in helper missing");
    }
    const targetId = openMatch[1];
    const ipa = openIn.sanitizeIpaUrl(u.searchParams.get("u") || u.searchParams.get("url") || "");
    if (!ipa || !openIn.targetById(targetId)) {
      return fail(res, 400, "Need /open/<trollstore|feather|esign|flarestore|shrubsign>?u=https://…ipa");
    }
    const html = openIn.bridgeHtml({ targetId, ipaHttps: ipa });
    res.writeHead(200, {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
    });
    res.end(html);
    return;
  }

  // Public tokenized IPA download (bot stages >4 GB files here).
  const dlMatch = /^\/d\/([a-f0-9]+)$/i.exec(p);
  if (dlMatch && req.method === "GET") {
    publicDl.cleanExpired();
    const entry = publicDl.getEntry(dlMatch[1]);
    if (!entry || !fs.existsSync(entry.file)) {
      return fail(res, 404, "Download expired — paste the App Store link again.");
    }
    const st = fs.statSync(entry.file);
    res.writeHead(200, {
      "Content-Type": "application/octet-stream",
      "Content-Length": st.size,
      "Content-Disposition": `attachment; filename="${String(entry.fileName || "App.ipa").replace(/"/g, "")}"`,
      "Cache-Control": "private, max-age=60",
      "Access-Control-Allow-Origin": "*",
    });
    fs.createReadStream(entry.file).pipe(res);
    return;
  }

  if (p === "/api/decrypt/backends" && req.method === "GET") {
    const fp = fairplayBackends.backendStatus();
    const publicBase = publicDl.resolvePublicBase() || "";
    const viaHost = String(req.headers.host || "").trim();
    const liveBase =
      viaHost && !/^127\.0\.0\.1(?::|$)/i.test(viaHost) && !/^localhost(?::|$)/i.test(viaHost)
        ? `https://${viaHost.replace(/\/+$/, "")}`
        : "";
    const macApi = (liveBase || publicBase || "").replace(/\/+$/, "");
    return json(res, 200, {
      ok: true,
      backends: fp.backends,
      status: { ...fp, publicBase: macApi || undefined, macApiUrl: macApi ? macApi + "/" : undefined },
      build: BUILD,
      publicBase: macApi || undefined,
      macApiUrl: macApi ? macApi + "/" : undefined,
    });
  }

  if (p === "/api/decrypt/quota" && req.method === "GET") {
    return json(res, 200, {
      ok: true,
      tier: "mac-backup",
      limit: null,
      used: 0,
      left: null,
      unlimited: true,
    });
  }

  if (p === "/api/decrypt/history" && req.method === "GET") {
    return json(res, 200, { ok: true, items: [] });
  }

  if (p === "/api/decrypt/history/delete" && req.method === "POST") {
    return json(res, 200, { ok: true });
  }

  if (p === "/api/decrypt/versions" && req.method === "POST") {
    const uid = actor(req);
    if (!uid) return fail(res, 401, "Unauthorized.");
    try {
      const body = await readBody(req);
      const url = String(body.url || "").trim();
      if (!validUrl(url)) return fail(res, 400, "Paste an App Store link.");
      const listed = await ipatoolExtras.listVersions({
        url,
        storefront: body.storefront || body.country || "",
      });
      const versions = listed.versions || [];
      return json(res, 200, {
        ok: true,
        title: listed.title || "App",
        bundle: listed.bundle || "",
        source: listed.source || "itunes",
        versions,
        items: versions,
        page: 1,
        pages: 1,
        total: versions.length,
      });
    } catch (e) {
      return fail(res, 502, String(e.message || e).slice(0, 160));
    }
  }

  if (p === "/api/ipatool/purchased" && req.method === "GET") {
    const uid = actor(req);
    if (!uid) return fail(res, 401, "Unauthorized.");
    const q = String(u.searchParams.get("q") || "").trim();
    const sync = u.searchParams.get("sync") === "1";
    if (sync) ipatoolExtras.syncPurchasedLibrary();
    const items = q ? ipatoolExtras.searchPurchased(q) : ipatoolExtras.loadPurchased().items;
    const db = ipatoolExtras.loadPurchased();
    return json(res, 200, {
      ok: true,
      updatedAt: db.updatedAt || 0,
      count: items.length,
      items: items.slice(0, 100),
    });
  }

  if (p === "/api/ipatool/purchased/sync" && req.method === "POST") {
    const uid = actor(req);
    if (!uid) return fail(res, 401, "Unauthorized.");
    const result = ipatoolExtras.syncPurchasedLibrary();
    return json(res, result.ok ? 200 : 502, { ok: !!result.ok, ...result });
  }

  if (p === "/api/ipatool/session" && req.method === "GET") {
    return json(res, 200, { ok: true, ...ipatoolExtras.sessionWatch({ force: u.searchParams.get("force") === "1" }) });
  }

  if (p === "/api/ipatool/prefetch" && req.method === "GET") {
    const uid = actor(req);
    if (!uid) return fail(res, 401, "Unauthorized.");
    return json(res, 200, { ok: true, items: ipatoolExtras.listPrefetch() });
  }

  if (p === "/api/ipatool/prefetch" && req.method === "POST") {
    const uid = actor(req);
    if (!uid) return fail(res, 401, "Unauthorized.");
    try {
      const body = await readBody(req);
      const url = String(body.url || "").trim();
      if (!validUrl(url)) return fail(res, 400, "Paste an App Store link.");
      const item = ipatoolExtras.enqueuePrefetch({
        url,
        version: body.version || "",
        storefront: body.storefront || body.country || "",
        priority: Number(body.priority) || 1,
      });
      return json(res, 200, { ok: true, item });
    } catch (e) {
      return fail(res, 400, String(e.message || e).slice(0, 160));
    }
  }

  if (p === "/api/decrypt" && req.method === "POST") {
    const uid = actor(req);
    if (!uid) return fail(res, 401, "Unauthorized.");
    try {
      const body = await readBody(req);
      const url = String(body.url || "").trim();
      const vreq = String(body.version || "").trim();
      const storefront = String(body.storefront || body.country || "").trim().toLowerCase();
      if (!validUrl(url)) return fail(res, 400, "Paste an App Store link.");
      if (vreq && !/^[0-9][0-9A-Za-z._-]{0,29}$/.test(vreq)) return fail(res, 400, "Bad version.");
      if (isAppleSystemApp(url, body.bundle || body.bid || "")) {
        return fail(res, 400, APPLE_SYSTEM_MSG);
      }
      const session = ipatoolExtras.sessionWatch();
      if (!session.ready) {
        return fail(res, 503, session.error || session.hint || "ipatool not logged in on Mac.");
      }
      for (const j of jobs.values()) {
        if (j.uid === uid && (j.status === "queued" || j.status === "running")) {
          return fail(res, 429, "You already have a decrypt running.");
        }
      }
      const id = crypto.randomBytes(12).toString("hex");
      const j = {
        id,
        uid,
        url,
        vreq,
        storefront,
        status: "queued",
        msg: "Queued on Mac…",
        progress: 1,
        error: "",
      };
      jobs.set(id, j);
      // Warm encrypted cache for this adam in the background for re-runs.
      try {
        ipatoolExtras.enqueuePrefetch({ url, version: vreq, storefront, priority: 0 });
      } catch {
        /* ignore */
      }
      runJob(j);
      return json(res, 200, {
        ok: true,
        id,
        quota: { ok: true, tier: "mac-backup", unlimited: true, left: null, used: 0, limit: null },
      });
    } catch (e) {
      return fail(res, 500, String(e.message || e).slice(0, 160));
    }
  }

  const jobMatch = /^\/api\/decrypt\/([a-f0-9]+)$/i.exec(p);
  if (jobMatch && req.method === "GET") {
    const uid = actor(req);
    if (!uid) return fail(res, 401, "Unauthorized.");
    const j = jobs.get(jobMatch[1]);
    if (!j || j.uid !== uid) return fail(res, 404, "Not found.");
    const out = {
      ok: true,
      status: j.status,
      msg: j.msg,
      error: j.error || "",
      progress: j.progress || 0,
    };
    if (j.status === "queued" || j.status === "running") out.queue = 0;
    if (j.status === "done") Object.assign(out, { up: j.up, name: j.name, bid: j.bid, ver: j.ver, size: j.size, progress: 100 });
    return json(res, 200, out);
  }

  const fileMatch = /^\/api\/ipa\/file\/([a-f0-9]+)$/i.exec(p);
  if (fileMatch && req.method === "GET") {
    const uid = actor(req);
    if (!uid) return fail(res, 401, "Unauthorized.");
    const up = uploads.get(fileMatch[1]);
    if (!up || !fs.existsSync(up.file)) return fail(res, 404, "The file expired. Decrypt it again.");
    const st = fs.statSync(up.file);
    res.writeHead(200, {
      "Content-Type": "application/octet-stream",
      "Content-Length": st.size,
      "Content-Disposition": `attachment; filename="${(up.name || "App").replace(/[^\w.-]+/g, "_")}.ipa"`,
      "Cache-Control": "private, max-age=60",
    });
    fs.createReadStream(up.file).pipe(res);
    return;
  }

  return fail(res, 404, "Not found.");
}

unlockKeychain();
const fp = fairplayBackends.backendStatus();
const server = http.createServer((req, res) => {
  handle(req, res).catch((e) => {
    console.warn(e);
    try {
      fail(res, 500, "Server error");
    } catch {
      /* ignore */
    }
  });
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`Tetherless Mac HTTPS API on http://127.0.0.1:${PORT}`);
  console.log(`host=${fp.host} decrypt=${!!(fp.unfairplay && fp.unfairplay.ready)} model=${!!(fp.enrollmentModel && fp.enrollmentModel.ready)}`);
  console.log("Expose with: cloudflared tunnel --url http://127.0.0.1:" + PORT);
  console.log("Then set iOS Decrypt site URL to that https://….trycloudflare.com/");
  try {
    ipatoolExtras.startPrefetchLoop();
    const sess = ipatoolExtras.sessionWatch({ force: true });
    console.log(
      sess.ready
        ? `ipatool session: ${sess.email || "ok"}`
        : `ipatool session: missing — ${sess.hint || sess.error || ""}`
    );
  } catch (e) {
    console.warn("ipatool extras:", e.message || e);
  }
});
