// Brand: Tetherless · https://tetherless.dev
"use strict";
/**
 * Backend encrypted-IPA fetch — device keeps FairPlay local.
 *
 * The iPhone mints Store credentials + SAP ActionSignature (ipatool-style), then
 * POSTs the signed commerce request here. This host talks to Apple / CDN and
 * returns the encrypted IPA so on-device volumeStore HTTP 403s can be bypassed
 * without looping through Phone Worker / Telegram (same phone Store path).
 *
 *   POST /api/store/fetch-ipa   { adamId, endpoints?, bodyPlistBase64, headers, externalVersionId? }
 *   GET  /api/store/ipa/:id     → application/octet-stream
 */

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const os = require("os");
const https = require("https");
const http = require("http");

const BUILD = "tetherless-store-fetch-1";
const MAX_GB = Number(process.env.STORE_FETCH_MAX_GB) || 1.5;
const TTL_MS = (Number(process.env.STORE_FETCH_TTL_MIN) || 20) * 60 * 1000;
const CONFIGURATOR_UA =
  "Configurator/2.15 (Macintosh; OS X 11.0.0; 16A5288f) AppleWebKit/0605.2.7.5";

/** @type {Map<string, { file: string, meta: any, expires: number, uid: string }>} */
const jobs = new Map();

function cleanup() {
  const now = Date.now();
  for (const [id, j] of jobs) {
    if (j.expires > now) continue;
    jobs.delete(id);
    try {
      fs.rmSync(j.file, { force: true });
    } catch {
      /* ignore */
    }
  }
}
setInterval(cleanup, 60_000).unref?.();

function defaultEndpoints(guid) {
  const g = encodeURIComponent(String(guid || "").trim() || "0");
  return [
    `https://p25-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=${g}`,
    `https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct?guid=${g}`,
    "https://downloaddispatch.itunes.apple.com/r/redownload",
  ];
}

function requestBuffer(url, { method = "GET", headers = {}, body, timeoutMs = 60_000, maxBytes } = {}) {
  return new Promise((resolve, reject) => {
    let parsed;
    try {
      parsed = new URL(url);
    } catch (e) {
      return reject(e);
    }
    const lib = parsed.protocol === "http:" ? http : https;
    const req = lib.request(
      {
        protocol: parsed.protocol,
        hostname: parsed.hostname,
        port: parsed.port || (parsed.protocol === "http:" ? 80 : 443),
        path: parsed.pathname + parsed.search,
        method,
        headers,
        timeout: timeoutMs,
      },
      (res) => {
        const chunks = [];
        let got = 0;
        res.on("data", (c) => {
          got += c.length;
          if (maxBytes && got > maxBytes) {
            req.destroy();
            return reject(new Error("Response too large."));
          }
          chunks.push(c);
        });
        res.on("end", () => {
          resolve({
            status: res.statusCode || 0,
            headers: res.headers || {},
            body: Buffer.concat(chunks),
          });
        });
      }
    );
    req.on("timeout", () => {
      req.destroy();
      reject(new Error("Upstream timeout."));
    });
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

function xmlUnescape(s) {
  return String(s || "")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

function parsePlistLoose(buf) {
  try {
    const plist = require("plist");
    return plist.parse(buf.toString("utf8"));
  } catch {
    /* optional dependency */
  }
  const text = buf.toString("utf8");
  if (!text.includes("<plist") && !text.includes("<dict")) return null;

  const failure = (text.match(/<key>failureType<\/key>\s*<string>([^<]*)<\/string>/i) || [])[1] || "";
  const customerMessage =
    (text.match(/<key>customerMessage<\/key>\s*<string>([^<]*)<\/string>/i) || [])[1] || "";
  const url = (text.match(/<key>URL<\/key>\s*<string>([^<]+)<\/string>/i) || [])[1] || "";
  const itemName =
    (text.match(/<key>itemName<\/key>\s*<string>([^<]*)<\/string>/i) || [])[1] || "";
  const bundleShortVersionString =
    (text.match(/<key>bundleShortVersionString<\/key>\s*<string>([^<]*)<\/string>/i) || [])[1] || "";
  const bundleVersion =
    (text.match(/<key>bundleVersion<\/key>\s*<string>([^<]*)<\/string>/i) || [])[1] || "";

  const sinfs = [];
  const sinfBlock = text.match(/<key>sinfs<\/key>\s*<array>([\s\S]*?)<\/array>/i);
  if (sinfBlock) {
    const rows = sinfBlock[1].split(/<dict>/i).slice(1);
    for (const row of rows) {
      const idRaw = (row.match(/<key>id<\/key>\s*<integer>([^<]+)<\/integer>/i) || [])[1];
      const data =
        (row.match(/<key>sinf<\/key>\s*<data>\s*([^<]+?)\s*<\/data>/i) || [])[1] ||
        (row.match(/<key>sinf<\/key>\s*<string>([^<]+)<\/string>/i) || [])[1];
      if (!data) continue;
      sinfs.push({
        id: idRaw != null ? Number(idRaw) : sinfs.length,
        data: data.replace(/\s+/g, ""),
      });
    }
  }

  return {
    failureType: xmlUnescape(failure),
    customerMessage: xmlUnescape(customerMessage),
    songList: url
      ? [
          {
            URL: xmlUnescape(url),
            sinfs,
            metadata: {
              itemName: xmlUnescape(itemName),
              bundleShortVersionString: xmlUnescape(bundleShortVersionString),
              bundleVersion: xmlUnescape(bundleVersion),
            },
          },
        ]
      : [],
  };
}

function firstSong(dict) {
  if (!dict || typeof dict !== "object") return null;
  const list = dict.songList || dict.songlist;
  if (Array.isArray(list) && list[0]) return list[0];
  return null;
}

function normalizeSinfs(raw) {
  if (!Array.isArray(raw)) return [];
  const out = [];
  for (let i = 0; i < raw.length; i++) {
    const row = raw[i] || {};
    let data = row.sinf != null ? row.sinf : row.data;
    if (Buffer.isBuffer(data)) data = data.toString("base64");
    else if (data && data.type === "Buffer" && Array.isArray(data.data)) {
      data = Buffer.from(data.data).toString("base64");
    } else if (typeof data === "string") {
      // already base64
    } else {
      continue;
    }
    const id = row.id != null ? Number(row.id) : i;
    if (!data) continue;
    out.push({ id, data: String(data).replace(/\s+/g, "") });
  }
  return out;
}

async function commerceOnce({ endpoint, body, headers }) {
  const hdrs = {
    "Content-Type": "application/x-apple-plist",
    Accept: "*/*",
    "User-Agent": headers["User-Agent"] || headers["user-agent"] || CONFIGURATOR_UA,
    ...headers,
  };
  // Node lowercases outbound? Keep both token casings if provided.
  const res = await requestBuffer(endpoint, {
    method: "POST",
    headers: hdrs,
    body,
    timeoutMs: 45_000,
    maxBytes: 8_000_000,
  });
  return res;
}

function downloadCdn(url, dest, headers) {
  const max = MAX_GB * 1e9;
  return new Promise((resolve, reject) => {
    let parsed;
    try {
      parsed = new URL(url);
    } catch (e) {
      return reject(e);
    }
    const lib = parsed.protocol === "http:" ? http : https;
    const req = lib.request(
      {
        protocol: parsed.protocol,
        hostname: parsed.hostname,
        port: parsed.port || (parsed.protocol === "http:" ? 80 : 443),
        path: parsed.pathname + parsed.search,
        method: "GET",
        headers: {
          "User-Agent": headers["User-Agent"] || headers["user-agent"] || CONFIGURATOR_UA,
          "Accept-Encoding": "identity",
        },
        timeout: 600_000,
      },
      (res) => {
        const status = res.statusCode || 0;
        if (status < 200 || status >= 300) {
          res.resume();
          return reject(new Error(`CDN download failed (HTTP ${status}).`));
        }
        const out = fs.createWriteStream(dest);
        let got = 0;
        res.on("data", (c) => {
          got += c.length;
          if (got > max) {
            req.destroy();
            out.destroy();
            try {
              fs.rmSync(dest, { force: true });
            } catch {
              /* ignore */
            }
            reject(new Error("CDN package exceeds size limit."));
          }
        });
        res.pipe(out);
        out.on("finish", () => {
          if (got < 100) {
            try {
              fs.rmSync(dest, { force: true });
            } catch {
              /* ignore */
            }
            return reject(new Error("CDN returned an empty package."));
          }
          resolve(got);
        });
        out.on("error", reject);
        res.on("error", reject);
      }
    );
    req.on("timeout", () => {
      req.destroy();
      reject(new Error("CDN download timeout."));
    });
    req.on("error", reject);
    req.end();
  });
}

async function fetchIpa(payload, { uid } = {}) {
  cleanup();
  const adamId = Number(payload.adamId);
  if (!Number.isFinite(adamId) || adamId <= 0) throw new Error("adamId required.");
  const bodyB64 = String(payload.bodyPlistBase64 || "");
  if (!bodyB64) throw new Error("bodyPlistBase64 required.");
  let body;
  try {
    body = Buffer.from(bodyB64, "base64");
  } catch {
    throw new Error("bodyPlistBase64 invalid.");
  }
  if (body.length < 32 || body.length > 2_000_000) throw new Error("Commerce body size rejected.");

  const headersIn = payload.headers && typeof payload.headers === "object" ? payload.headers : {};
  const headers = {};
  for (const [k, v] of Object.entries(headersIn)) {
    if (v == null) continue;
    const key = String(k);
    const val = String(v);
    if (!key || !val || val.length > 16_000) continue;
    // Never let the client override hop-by-hop.
    if (/^transfer-encoding$/i.test(key) || /^content-length$/i.test(key) || /^host$/i.test(key)) continue;
    headers[key] = val;
  }
  if (!headers["User-Agent"] && !headers["user-agent"]) headers["User-Agent"] = CONFIGURATOR_UA;

  const guid = String(payload.guid || headers["X-Guid"] || "").trim();
  const endpoints = Array.isArray(payload.endpoints) && payload.endpoints.length
    ? payload.endpoints.map(String).filter((u) => /^https:\/\/.+\.apple\.com\//i.test(u))
    : defaultEndpoints(guid);
  if (!endpoints.length) throw new Error("No usable Apple commerce endpoints.");

  let lastErr = "Store download failed.";
  let song = null;
  for (const endpoint of endpoints) {
    try {
      const res = await commerceOnce({ endpoint, body, headers });
      if (res.status === 204 || res.body.length === 0) {
        lastErr = `Empty store response (HTTP ${res.status}).`;
        continue;
      }
      if (res.status === 403) {
        lastErr = `Store rejected client identity (HTTP 403).`;
        continue;
      }
      if (res.status < 200 || res.status >= 300) {
        lastErr = `Store commerce HTTP ${res.status}.`;
        continue;
      }
      const dict = parsePlistLoose(res.body);
      if (!dict) {
        lastErr = "Non-plist App Store response from commerce.";
        continue;
      }
      const failure = dict.failureType != null ? String(dict.failureType) : "";
      if (failure === "2034" || failure === "2042" || failure === "1008") {
        lastErr = "Store token expired — remint Store Access on the phone, then retry.";
        continue;
      }
      if (failure === "9610") {
        lastErr = "License required for this Apple ID.";
        continue;
      }
      if (failure && failure !== "0") {
        lastErr = dict.customerMessage ? String(dict.customerMessage) : `Download failed (${failure}).`;
        continue;
      }
      song = firstSong(dict);
      if (!song || !song.URL) {
        lastErr = "App Store returned no download items.";
        continue;
      }
      break;
    } catch (e) {
      lastErr = e.message || String(e);
    }
  }
  if (!song || !song.URL) throw new Error(lastErr);

  const id = crypto.randomBytes(12).toString("hex");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "tetherless-store-"));
  const file = path.join(dir, `${adamId}.ipa`);
  const size = await downloadCdn(String(song.URL), file, headers);

  const meta = song.metadata && typeof song.metadata === "object" ? song.metadata : {};
  const version =
    meta.bundleShortVersionString || meta.bundleVersion || payload.externalVersionId || "";
  const name = meta.itemName || meta.softwareVersionExternalIdentifier || `app_${adamId}`;
  const sinfs = normalizeSinfs(song.sinfs);

  jobs.set(id, {
    file,
    uid: String(uid || ""),
    meta: {
      adamId,
      name: String(name).slice(0, 120),
      version: String(version).slice(0, 40),
      size,
      sinfs,
      metadata: meta,
    },
    expires: Date.now() + TTL_MS,
  });

  return {
    ok: true,
    id,
    adamId,
    name: String(name).slice(0, 120),
    version: String(version).slice(0, 40),
    size,
    sinfs,
    metadata: meta,
    build: BUILD,
  };
}

function attachRoutes(web, { jsonBody, fail, guard, needUser, actorId }) {
  const postGate = [];
  if (typeof guard === "function") postGate.push(guard);
  if (typeof needUser === "function") postGate.push(needUser);

  web.post("/api/store/fetch-ipa", ...postGate, jsonBody, async (req, res) => {
    try {
      const out = await fetchIpa(req.body || {}, { uid: req.uid || "" });
      return res.json(out);
    } catch (e) {
      return fail(res, 400, e.message || String(e));
    }
  });

  // GET must not use the JSON Content-Type guard (same pattern as /api/ipa/file).
  web.get("/api/store/ipa/:id", (req, res) => {
    cleanup();
    res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });
    const id = String(req.params.id || "");
    const job = jobs.get(id);
    const uid = typeof actorId === "function" ? actorId(req, res, false) : req.uid;
    if (!job || !uid || (job.uid && job.uid !== uid)) {
      return fail(res, 404, "IPA expired or not found.");
    }
    if (!fs.existsSync(job.file)) {
      jobs.delete(id);
      return fail(res, 404, "IPA file missing.");
    }
    const nm = String(job.meta.name || "app").replace(/[^\w.-]+/g, "_").slice(0, 60) || "app";
    res.set({
      "Content-Type": "application/octet-stream",
      "Content-Disposition": `attachment; filename="${nm}.ipa"`,
      "X-Store-Name": String(job.meta.name || ""),
      "X-Store-Version": String(job.meta.version || ""),
      "X-Store-Size": String(job.meta.size || 0),
    });
    return fs.createReadStream(job.file).on("error", () => res.end()).pipe(res);
  });
}

module.exports = { attachRoutes, fetchIpa, BUILD };
