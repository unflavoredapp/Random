// Brand: Tetherless · https://tetherless.dev
"use strict";
/**
 * FairPlay decrypt backends for the site decrypt queue.
 *
 * Tools (install separately on the host / LAN):
 *   1. phone          — existing iPhone Phone Worker (FairPlay on-device)
 *   2. fairplay-decrypt — EthanArbuckle/fairplay-decrypt CLI (Linux/macOS)
 *   3. ipadecrypt     — londek/ipadecrypt CLI (download + decrypt)
 *   4. ipa-decrypter  — ac0d3r/ipa-decrypter HTTP server
 *   5. unfaird        — jailbroken-device daemon (LAN fallback)
 *
 * Env:
 *   DECRYPT_BACKENDS=phone,fairplay-decrypt,ipadecrypt,ipa-decrypter,unfaird
 *   FAIRPLAY_DECRYPT_BIN=/usr/local/bin/decrypt.py   (or python -m path)
 *   FAIRPLAY_DECRYPT_PYTHON=python3
 *   FAIRPLAY_CREDENTIAL_BIN=/var/lib/tetherless/credential.bin
 *   FAIRPLAY_IPATOOL_BIN=ipatool   (optional pre-download for fairplay-decrypt)
 *   IPADECRYPT_BIN=ipadecrypt
 *   IPA_DECRYPTER_URL=http://127.0.0.1:8787
 *   IPA_DECRYPTER_TOKEN=           (optional Bearer)
 *   UNFAIRD_URL=http://192.168.1.20:6347
 *   UNFAIRD_TOKEN=                 (optional)
 *
 * This module shells out / HTTP-calls those tools — it does not embed their crypto.
 */

const { spawn } = require("child_process");
const fs = require("fs");
const path = require("path");
const https = require("https");
const http = require("http");
const { URL } = require("url");

const DEFAULT_BACKENDS = ["phone"];

function configuredBackends() {
  const raw = String(process.env.DECRYPT_BACKENDS || "phone")
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  const allowed = new Set([
    "phone",
    "fairplay-decrypt",
    "ipadecrypt",
    "ipa-decrypter",
    "unfaird",
  ]);
  const list = raw.filter((b) => allowed.has(b));
  return list.length ? list : DEFAULT_BACKENDS.slice();
}

function backendStatus() {
  const backends = configuredBackends();
  return {
    backends,
    phone: { ready: true, note: "iPhone Phone Worker (DECRYPT_WORKER_TOKEN)" },
    "fairplay-decrypt": {
      ready: !!(process.env.FAIRPLAY_CREDENTIAL_BIN && fs.existsSync(process.env.FAIRPLAY_CREDENTIAL_BIN)),
      bin: process.env.FAIRPLAY_DECRYPT_BIN || "decrypt.py",
      credential: process.env.FAIRPLAY_CREDENTIAL_BIN || "",
      note: "Needs FAIRPLAY_CREDENTIAL_BIN + FAIRPLAY_DECRYPT_BIN (or python decrypt.py)",
    },
    ipadecrypt: {
      ready: !!which(process.env.IPADECRYPT_BIN || "ipadecrypt"),
      bin: process.env.IPADECRYPT_BIN || "ipadecrypt",
      note: "Install londek/ipadecrypt on PATH or set IPADECRYPT_BIN",
    },
    "ipa-decrypter": {
      ready: !!process.env.IPA_DECRYPTER_URL,
      url: process.env.IPA_DECRYPTER_URL || "",
      note: "Set IPA_DECRYPTER_URL to ac0d3r/ipa-decrypter base URL",
    },
    unfaird: {
      ready: !!process.env.UNFAIRD_URL,
      url: process.env.UNFAIRD_URL || "",
      note: "Set UNFAIRD_URL to jailbroken unfaird (default port 6347)",
    },
  };
}

function which(cmd) {
  if (!cmd) return "";
  if (cmd.includes("/") && fs.existsSync(cmd)) return cmd;
  const paths = String(process.env.PATH || "")
    .split(path.delimiter)
    .filter(Boolean);
  for (const p of paths) {
    const full = path.join(p, cmd);
    try {
      fs.accessSync(full, fs.constants.X_OK);
      return full;
    } catch {
      /* continue */
    }
  }
  return "";
}

function runCmd(bin, args, { cwd, timeoutMs = 20 * 60 * 1000, env } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, {
      cwd,
      env: { ...process.env, ...(env || {}) },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      try {
        child.kill("SIGKILL");
      } catch {
        /* ignore */
      }
      reject(new Error(`Timed out: ${bin} ${args.join(" ")}`));
    }, timeoutMs);
    child.stdout.on("data", (d) => {
      stdout += d.toString("utf8");
    });
    child.stderr.on("data", (d) => {
      stderr += d.toString("utf8");
    });
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve({ stdout, stderr, code });
      else
        reject(
          new Error(
            `${bin} exited ${code}: ${(stderr || stdout).trim().slice(0, 400) || "no output"}`
          )
        );
    });
  });
}

function httpRequest(urlString, { method = "GET", headers = {}, body, timeoutMs = 120000 } = {}) {
  return new Promise((resolve, reject) => {
    let u;
    try {
      u = new URL(urlString);
    } catch (e) {
      return reject(e);
    }
    const lib = u.protocol === "https:" ? https : http;
    const req = lib.request(
      {
        protocol: u.protocol,
        hostname: u.hostname,
        port: u.port || (u.protocol === "https:" ? 443 : 80),
        path: u.pathname + u.search,
        method,
        headers,
        timeout: timeoutMs,
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const buf = Buffer.concat(chunks);
          resolve({ status: res.statusCode || 0, headers: res.headers, body: buf });
        });
      }
    );
    req.on("timeout", () => {
      req.destroy();
      reject(new Error("HTTP timeout"));
    });
    req.on("error", reject);
    if (body) req.write(body);
    req.end();
  });
}

function adamFromStoreUrl(url) {
  const m = /\bid(\d{5,12})\b/i.exec(String(url || ""));
  return m ? m[1] : "";
}

/**
 * Try non-phone backends in order. Returns { file, name } or null to fall through to phone.
 * Throws only when a configured backend hard-fails and no further backends remain
 * (caller still may try phone).
 */
async function tryRemoteBackends({ url, dir, say, vreq, skip = [] }) {
  const backends = configuredBackends().filter((b) => b !== "phone" && !skip.includes(b));
  if (!backends.length) return null;

  const errors = [];
  for (const backend of backends) {
    try {
      say(`Trying FairPlay backend: ${backend}…`);
      let result = null;
      if (backend === "fairplay-decrypt") {
        result = await runFairplayDecrypt({ url, dir, say, vreq });
      } else if (backend === "ipadecrypt") {
        result = await runIpadecrypt({ url, dir, say, vreq });
      } else if (backend === "ipa-decrypter") {
        result = await runIpaDecrypter({ url, dir, say, vreq });
      } else if (backend === "unfaird") {
        result = await runUnfaird({ url, dir, say, vreq });
      }
      if (result && result.file && fs.existsSync(result.file)) {
        say(`Backend ${backend} produced IPA…`);
        result.backend = backend;
        return result;
      }
      errors.push(`${backend}: empty result`);
    } catch (e) {
      const msg = e && e.message ? e.message : String(e);
      errors.push(`${backend}: ${msg}`);
      say(`Backend ${backend} failed — ${msg.slice(0, 120)}`);
    }
  }
  if (errors.length && !configuredBackends().includes("phone")) {
    throw new Error("All FairPlay backends failed: " + errors.join(" | "));
  }
  return null;
}

async function runFairplayDecrypt({ url, dir, say, vreq }) {
  const cred = process.env.FAIRPLAY_CREDENTIAL_BIN || "";
  if (!cred || !fs.existsSync(cred)) {
    throw new Error("FAIRPLAY_CREDENTIAL_BIN missing (16-byte credential.bin)");
  }
  const enc = path.join(dir, "encrypted-source.ipa");
  const out = path.join(dir, "fairplay-decrypt-out.ipa");
  try {
    fs.rmSync(out, { force: true });
  } catch {
    /* ignore */
  }

  // Prefer a pre-fetched encrypted IPA in dir; else ipatool download when configured.
  if (!fs.existsSync(enc) || fs.statSync(enc).size < 100) {
    const ipatool = which(process.env.FAIRPLAY_IPATOOL_BIN || "ipatool");
    if (!ipatool) {
      throw new Error(
        "fairplay-decrypt needs encrypted IPA at encrypted-source.ipa or FAIRPLAY_IPATOOL_BIN/ipatool on PATH"
      );
    }
    say("ipatool downloading encrypted IPA…");
    const adam = adamFromStoreUrl(url);
    const args = ["download", "--purchase", "-o", enc];
    if (adam) args.push("--adam-id", adam);
    else args.push(url);
    if (vreq) args.push("--external-version-id", String(vreq));
    await runCmd(ipatool, args, { cwd: dir });
  }

  const py = process.env.FAIRPLAY_DECRYPT_PYTHON || "python3";
  const bin = process.env.FAIRPLAY_DECRYPT_BIN || "";
  say("fairplay-decrypt decrypting…");
  if (bin && bin.endsWith(".py")) {
    await runCmd(py, [bin, enc, out, "--credential", cred], { cwd: dir });
  } else if (bin && which(bin)) {
    await runCmd(bin, [enc, out, "--credential", cred], { cwd: dir });
  } else if (which("decrypt.py")) {
    await runCmd(py, [which("decrypt.py"), enc, out, "--credential", cred], { cwd: dir });
  } else {
    throw new Error("Set FAIRPLAY_DECRYPT_BIN to fairplay-decrypt’s decrypt.py");
  }
  if (!fs.existsSync(out) || fs.statSync(out).size < 100) {
    throw new Error("fairplay-decrypt produced no IPA");
  }
  return { file: out, name: "App" };
}

async function runIpadecrypt({ url, dir, say, vreq }) {
  const bin = which(process.env.IPADECRYPT_BIN || "ipadecrypt");
  if (!bin) throw new Error("ipadecrypt not found — set IPADECRYPT_BIN");
  const out = path.join(dir, "ipadecrypt-out.ipa");
  try {
    fs.rmSync(out, { force: true });
  } catch {
    /* ignore */
  }
  say("ipadecrypt decrypt…");
  const args = ["decrypt", url, "--output", out, "--no-on-device"];
  if (vreq) args.push("--external-version-id", String(vreq));
  await runCmd(bin, args, { cwd: dir });
  // Some builds write next to CWD with a generated name — accept either.
  if (fs.existsSync(out) && fs.statSync(out).size > 100) {
    return { file: out, name: "App" };
  }
  const found = fs
    .readdirSync(dir)
    .filter((f) => f.endsWith(".ipa") && f !== "in.ipa")
    .map((f) => path.join(dir, f))
    .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs)[0];
  if (!found) throw new Error("ipadecrypt produced no IPA");
  return { file: found, name: path.basename(found, ".ipa") };
}

async function runIpaDecrypter({ url, dir, say }) {
  const base = String(process.env.IPA_DECRYPTER_URL || "").replace(/\/+$/, "");
  if (!base) throw new Error("IPA_DECRYPTER_URL not set");
  const token = process.env.IPA_DECRYPTER_TOKEN || "";
  const headers = {
    "Content-Type": "application/json",
    Accept: "application/json",
  };
  if (token) headers.Authorization = `Bearer ${token}`;

  say("ipa-decrypter queueing job…");
  // Compatible with common job APIs: POST /api/jobs { url } → { id }; poll GET /api/jobs/:id
  const create = await httpRequest(`${base}/api/jobs`, {
    method: "POST",
    headers,
    body: JSON.stringify({ url }),
    timeoutMs: 60000,
  });
  let job;
  try {
    job = JSON.parse(create.body.toString("utf8"));
  } catch {
    throw new Error(`ipa-decrypter create HTTP ${create.status}`);
  }
  if (create.status >= 400 || !job || !(job.id || job.jobId)) {
    throw new Error(
      (job && (job.error || job.message)) || `ipa-decrypter create HTTP ${create.status}`
    );
  }
  const id = String(job.id || job.jobId);
  const deadline = Date.now() + (Number(process.env.DECRYPT_TIMEOUT_MIN) || 20) * 60 * 1000;
  while (Date.now() < deadline) {
    await sleep(2500);
    const poll = await httpRequest(`${base}/api/jobs/${encodeURIComponent(id)}`, {
      method: "GET",
      headers,
      timeoutMs: 30000,
    });
    let st;
    try {
      st = JSON.parse(poll.body.toString("utf8"));
    } catch {
      continue;
    }
    const status = String(st.status || st.state || "").toLowerCase();
    if (st.message || st.msg) say(String(st.message || st.msg).slice(0, 120));
    if (status === "done" || status === "completed" || status === "success") {
      const dl =
        st.downloadUrl ||
        st.download_url ||
        (st.fileId ? `${base}/api/files/${st.fileId}` : `${base}/api/jobs/${id}/download`);
      say("ipa-decrypter downloading clear IPA…");
      const fileRes = await httpRequest(dl, {
        method: "GET",
        headers: token ? { Authorization: `Bearer ${token}` } : {},
        timeoutMs: 10 * 60 * 1000,
      });
      if (fileRes.status >= 400 || fileRes.body.length < 100) {
        throw new Error(`ipa-decrypter download HTTP ${fileRes.status}`);
      }
      const out = path.join(dir, "ipa-decrypter-out.ipa");
      fs.writeFileSync(out, fileRes.body);
      return { file: out, name: String(st.name || "App").slice(0, 80) };
    }
    if (status === "failed" || status === "error") {
      throw new Error(String(st.error || st.message || "ipa-decrypter job failed"));
    }
  }
  throw new Error("ipa-decrypter job timed out");
}

async function runUnfaird({ url, dir, say }) {
  const base = String(process.env.UNFAIRD_URL || "").replace(/\/+$/, "");
  if (!base) throw new Error("UNFAIRD_URL not set");
  const token = process.env.UNFAIRD_TOKEN || "";
  const headers = {
    "Content-Type": "application/json",
    Accept: "application/octet-stream, application/json",
  };
  if (token) headers.Authorization = `Bearer ${token}`;
  const adam = adamFromStoreUrl(url);
  say("unfaird decrypt…");
  // Health first (best-effort).
  try {
    await httpRequest(`${base}/health`, { method: "GET", timeoutMs: 5000 });
  } catch {
    /* optional */
  }
  const body = JSON.stringify({
    url,
    adamId: adam || undefined,
    bundleId: undefined,
  });
  const res = await httpRequest(`${base}/decrypt`, {
    method: "POST",
    headers: { ...headers, "Content-Type": "application/json" },
    body,
    timeoutMs: 20 * 60 * 1000,
  });
  const ctype = String((res.headers && res.headers["content-type"]) || "");
  if (res.status >= 400) {
    let err = `unfaird HTTP ${res.status}`;
    try {
      err = JSON.parse(res.body.toString("utf8")).error || err;
    } catch {
      /* ignore */
    }
    throw new Error(err);
  }
  if (ctype.includes("json")) {
    // Async job style
    let st;
    try {
      st = JSON.parse(res.body.toString("utf8"));
    } catch {
      throw new Error("unfaird returned invalid JSON");
    }
    if (st.downloadUrl || st.ipaUrl) {
      const fileRes = await httpRequest(st.downloadUrl || st.ipaUrl, {
        method: "GET",
        headers: token ? { Authorization: `Bearer ${token}` } : {},
        timeoutMs: 10 * 60 * 1000,
      });
      const out = path.join(dir, "unfaird-out.ipa");
      fs.writeFileSync(out, fileRes.body);
      return { file: out, name: String(st.name || "App").slice(0, 80) };
    }
    throw new Error(st.error || "unfaird JSON response had no IPA");
  }
  if (res.body.length < 100) throw new Error("unfaird returned empty body");
  const out = path.join(dir, "unfaird-out.ipa");
  fs.writeFileSync(out, res.body);
  return { file: out, name: "App" };
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

module.exports = {
  configuredBackends,
  backendStatus,
  tryRemoteBackends,
  adamFromStoreUrl,
};
