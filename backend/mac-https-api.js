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
const { spawnSync } = require("child_process");
const fairplayBackends = require("./fairplayBackends");
const publicDl = require("./mac-tg-public-dl");

const PORT = Number(process.env.MAC_API_PORT || 8787);
const OPEN = String(process.env.MAC_API_OPEN || "1") !== "0";
const REQUIRE = String(process.env.MAC_API_BEARER || "").trim();
const WORK = process.env.MAC_API_WORK_DIR || path.join(os.tmpdir(), "tetherless-mac-api");
const BUILD = "tetherless-mac-https-api-1";

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
  const say = (t) => {
    j.msg = String(t).slice(0, 140);
    console.log("[api]", j.id, j.msg);
  };
  try {
    unlockKeychain();
    const result = await fairplayBackends.tryRemoteBackends({
      url: j.url,
      dir,
      say,
      vreq: j.vreq || "",
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
      up,
      name: result.name || "App",
      bid: result.bid || "",
      ver: j.vreq || "",
      size: st.size,
    });
  } catch (e) {
    j.status = "error";
    j.error = String((e && e.message) || e).slice(0, 200);
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
      resources: resHost
        ? {
            freeDiskGb: Number(resHost.freeDiskGb.toFixed(2)),
            totalMemGb: Number(resHost.totalMemGb.toFixed(2)),
            freeMemGb: Number(resHost.freeMemGb.toFixed(2)),
          }
        : undefined,
    });
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
      // Lightweight: current App Store version via iTunes lookup.
      const m = /\bid(\d{5,12})\b/i.exec(url);
      const id = m ? m[1] : "";
      const cc = ((/apps\.apple\.com\/([a-z]{2})\//i.exec(url) || [])[1] || "us").toLowerCase();
      const lookup = await fetch(`https://itunes.apple.com/lookup?id=${id}&country=${cc}`).then((r) => r.json());
      const a = lookup && lookup.results && lookup.results[0];
      if (!a) return fail(res, 404, "App not found.");
      const ver = String(a.version || "1.0");
      const row = { v: ver, version: ver, label: ver, id: ver, index: 0, current: true };
      return json(res, 200, {
        ok: true,
        title: String(a.trackName || "App").slice(0, 80),
        versions: [row],
        items: [row],
        page: 1,
        pages: 1,
        total: 1,
      });
    } catch (e) {
      return fail(res, 502, String(e.message || e).slice(0, 160));
    }
  }

  if (p === "/api/decrypt" && req.method === "POST") {
    const uid = actor(req);
    if (!uid) return fail(res, 401, "Unauthorized.");
    try {
      const body = await readBody(req);
      const url = String(body.url || "").trim();
      const vreq = String(body.version || "").trim();
      if (!validUrl(url)) return fail(res, 400, "Paste an App Store link.");
      if (vreq && !/^[0-9][0-9A-Za-z._-]{0,29}$/.test(vreq)) return fail(res, 400, "Bad version.");
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
        status: "queued",
        msg: "Queued",
        error: "",
      };
      jobs.set(id, j);
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
    const out = { ok: true, status: j.status, msg: j.msg, error: j.error || "" };
    if (j.status === "queued" || j.status === "running") out.queue = 0;
    if (j.status === "done") Object.assign(out, { up: j.up, name: j.name, bid: j.bid, ver: j.ver, size: j.size });
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
});
