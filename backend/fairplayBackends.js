// Brand: Tetherless · https://tetherless.dev
"use strict";
/**
 * FairPlay decrypt backends for the site decrypt queue.
 *
 * Preferred: run this Node server on a rented/enrolled Mac (Apple Silicon) and
 * decrypt there with Tetherless (internal backend id: unfairplay) — enroll once,
 * every job stays on that Mac. Optional: Linux host with a copied enrollment
 * model / credential.bin.
 *
 * Backends (no jailbreak / TrollStore / Phone Worker required):
 *   1. unfairplay       — Tetherless decrypt CLI (macOS arm64 or Linux; model or live Mac setup)
 *   2. fairplay-decrypt — EthanArbuckle CLI + 16-byte credential.bin
 *   3. ipadecrypt       — londek CLI
 *   4. ipa-decrypter    — ac0d3r HTTP/Docker
 *
 * Opt-in only: phone, unfaird
 *
 * Env:
 *   FAIRPLAY_HOST=mac|linux          (default: detect process.platform)
 *   DECRYPT_BACKENDS=…              (mac default: unfairplay; linux: fairplay-decrypt,unfairplay)
 *   FAIRPLAY_CREDENTIAL_BIN=/var/lib/tetherless/credential.bin
 *   FAIRPLAY_REQUIRE_CREDENTIAL=1   (linux / fairplay-decrypt; Mac unfairplay-only can skip)
 *   FAIRPLAY_DECRYPT_BIN=…
 *   FAIRPLAY_IPATOOL_BIN=ipatool
 *   UNFAIRPLAY_BIN=unfairplay
 *   UNFAIRPLAY_MODEL_DIR=…          (optional; else Mac uses default saved models)
 *   FAIRPLAY_ENROLLMENT_MODEL=…     (Linux copy of the model file)
 *
 * See server/fairplay-backends.md.
 *
 * This module shells out / HTTP-calls those tools — it does not embed their crypto.
 */

const { spawn, spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const https = require("https");
const http = require("http");
const { URL } = require("url");

/** Unlock dedicated tetherless keychain so ipatool can read the Apple ID over SSH. */
function unlockKeychain() {
  const pass = String(process.env.TETHERLESS_KEYCHAIN_PASSWORD || "").trim();
  const kc = path.join(os.homedir(), "Library/Keychains/tetherless.keychain-db");
  if (!pass || !fs.existsSync(kc)) return false;
  spawnSync("security", ["unlock-keychain", "-p", pass, kc], { stdio: "ignore" });
  spawnSync("security", ["list-keychains", "-d", "user", "-s", kc], { stdio: "ignore" });
  spawnSync("security", ["default-keychain", "-d", "user", "-s", kc], { stdio: "ignore" });
  spawnSync("security", ["set-keychain-settings", "-t", "21600", "-l", kc], { stdio: "ignore" });
  return true;
}

function hostResources() {
  const totalMem = os.totalmem();
  const freeMem = os.freemem();
  let freeDisk = 0;
  let totalDisk = 0;
  try {
    // df -kP works on macOS/Linux; pick the volume for $HOME.
    const home = os.homedir();
    const out = spawnSync("df", ["-kP", home], { encoding: "utf8" });
    const line = String(out.stdout || "")
      .trim()
      .split("\n")
      .pop();
    const parts = String(line || "").split(/\s+/);
    // Filesystem 1024-blocks Used Available Capacity Mounted
    if (parts.length >= 4) {
      totalDisk = Number(parts[1] || 0) * 1024;
      freeDisk = Number(parts[3] || 0) * 1024;
    }
  } catch {
    /* ignore */
  }
  return {
    totalMem,
    freeMem,
    totalDisk,
    freeDisk,
    totalMemGb: totalMem / (1024 ** 3),
    freeMemGb: freeMem / (1024 ** 3),
    freeDiskGb: freeDisk / (1024 ** 3),
  };
}

/** Suggested parallel decrypt workers for this Mac (16 GB → 2). */
function suggestedWorkers(fallback = 3) {
  const env = Number(process.env.MAC_TG_WORKERS || 0);
  if (env >= 1) return Math.max(1, Math.min(8, env));
  const gb = hostResources().totalMemGb;
  if (gb > 0 && gb <= 18) return 2;
  if (gb <= 36) return 3;
  return Math.max(1, Math.min(8, fallback));
}

/**
 * Refuse jobs that clearly won't fit (need ~2.5× IPA for enc+dec+temp).
 * @param {{ bytes?: number, minFreeGb?: number }} opts
 */
function preflightDecrypt(opts = {}) {
  const res = hostResources();
  const minFreeGb = Number(opts.minFreeGb || process.env.MAC_TG_MIN_FREE_DISK_GB || 8) || 8;
  const bytes = Number(opts.bytes || 0) || 0;
  const need = bytes > 0 ? bytes * 2.5 : minFreeGb * 1024 ** 3;
  if (res.freeDisk > 0 && res.freeDisk < Math.max(need, minFreeGb * 1024 ** 3)) {
    const free = res.freeDiskGb.toFixed(1);
    const want = (need / 1024 ** 3).toFixed(1);
    return {
      ok: false,
      error: `Not enough free disk on this Mac (${free} GB free, need ~${want} GB). Free space in ~/tetherless-ipa-cache and try again.`,
      resources: res,
    };
  }
  if (bytes > 0 && res.totalMem > 0 && bytes > res.totalMem * 0.85) {
    return {
      ok: false,
      error: `IPA is ~${(bytes / 1024 ** 3).toFixed(1)} GB — too large for this Mac’s ${(res.totalMemGb).toFixed(0)} GB RAM (unfairplay may OOM).`,
      resources: res,
    };
  }
  return { ok: true, resources: res };
}

function friendlyDecryptError(err) {
  const s = String((err && err.message) || err || "");
  if (/timed out|Timeout/i.test(s)) {
    return "Decrypt timed out on this Mac — try again, or free RAM/disk and re-run.";
  }
  if (/ENOMEM|out of memory|Cannot allocate|killed|SIGKILL|signal 9/i.test(s)) {
    return "Decrypt ran out of memory on this Mac. Close other jobs or use a smaller app.";
  }
  if (/No space|ENOSPC|not enough free disk/i.test(s)) {
    return "Mac disk is full — free space under ~/tetherless-ipa-cache and retry.";
  }
  return "";
}

function friendlyIpatoolError(err) {
  const decryptHint = friendlyDecryptError(err);
  if (decryptHint) return decryptHint;
  const s = String((err && err.message) || err || "");
  if (/maximum call stack|call stack size exceeded|RangeError/i.test(s)) {
    return "Mac decrypt hit a Store/progress bug — update the Mac host and retry.";
  }
  if (/keyring|keychain|failed to get account|failed to get item|specified item could not be found/i.test(s)) {
    return (
      "App Store login missing on Mac (ipatool keychain). " +
      "WebSSH: zsh ~/tetherless/server/mac-ssh.sh unlock && ipatool auth login"
    );
  }
  if (/two[- ]?factor|2fa|verification code|trusted device|enter the code/i.test(s)) {
    return "App Store needs 2FA on this Mac — finish ipatool auth login over WebSSH, then retry.";
  }
  if (/rate.?limit|too many requests|429|try again later|slow down/i.test(s)) {
    return "App Store rate-limited ipatool — wait a minute and paste the link again.";
  }
  if (/version.*(not found|unavailable|invalid)|external.version|no matching version/i.test(s)) {
    return "That app version isn’t available for this Apple ID — try latest or another owned version.";
  }
  if (/network|connection reset|tls|timeout|temporary failure|EOF|ECONNRESET|ENETUNREACH|EAI_AGAIN/i.test(s)) {
    return "App Store download hiccup (network). Retrying usually works — paste the link again.";
  }
  // Paid / license / purchase failures — never dump STDQ / guest-bridge noise to chat.
  if (
    /failed to purchase|purchase item|STDQ|license|not owned|do not own|haven't purchased|have not purchased|no current price|payment|volumePurchase|store request|guest bridge|unknown format obj|password token|auth.*fail|forbidden|access denied/i.test(
      s
    )
  ) {
    return (
      "Not owned by this Apple ID — free apps need a working Mac login; " +
      "paid apps only work if that Apple ID already purchased them. Paste an App Store link you own."
    );
  }
  // Keep other failures short for the progress-card ❌ bubble.
  const oneLine = s.replace(/\s+/g, " ").trim();
  if (oneLine.length > 180) return oneLine.slice(0, 177) + "…";
  return oneLine || "App Store download failed";
}

/** True when a failed ipatool run is worth an automatic retry. */
function isTransientIpatoolFailure(err) {
  const s = String((err && err.message) || err || "");
  return /network|connection reset|tls|timeout|temporary|EOF|ECONNRESET|ENETUNREACH|EAI_AGAIN|rate.?limit|429|try again later|hiccup/i.test(
    s
  );
}

/** True when --purchase failed but a plain download may still work (already owned). */
function isPurchaseAlreadyOwnedFailure(err) {
  const s = String((err && err.message) || err || "");
  return /already.*(purchased|owned)|have already|duplicate.*purchase|item is free|no current price/i.test(s);
}

function ipatoolBin() {
  return which(process.env.FAIRPLAY_IPATOOL_BIN || "ipatool");
}

/** @type {{ at: number, value: ReturnType<typeof ipatoolAuthStatusUncached> } | null} */
let _ipatoolAuthCache = null;

/**
 * Best-effort `ipatool auth info` — used before downloads + in backend status.
 * @returns {{ ready: boolean, email?: string, name?: string, raw?: string, error?: string }}
 */
function ipatoolAuthStatus(opts = {}) {
  const ttl = Number(opts.ttlMs || 20000);
  const force = !!opts.force;
  if (!force && _ipatoolAuthCache && Date.now() - _ipatoolAuthCache.at < ttl) {
    return _ipatoolAuthCache.value;
  }
  const value = ipatoolAuthStatusUncached();
  _ipatoolAuthCache = { at: Date.now(), value };
  return value;
}

function ipatoolAuthStatusUncached() {
  const bin = ipatoolBin();
  if (!bin) return { ready: false, error: "ipatool not on PATH" };
  unlockKeychain();
  const r = spawnSync(bin, ["auth", "info"], {
    encoding: "utf8",
    timeout: 20000,
    env: process.env,
  });
  const out = stripAnsi(`${r.stdout || ""}\n${r.stderr || ""}`).trim();
  if (r.status !== 0) {
    return {
      ready: false,
      error: friendlyIpatoolError(out || `ipatool auth info exited ${r.status}`),
      raw: out.slice(0, 240),
    };
  }
  const email =
    (out.match(/email[:\s]+([^\s]+@[^\s]+)/i) ||
      out.match(/([a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,})/i) ||
      [])[1] || "";
  const name = (out.match(/name[:\s]+(.+)/i) || [])[1]?.trim() || "";
  return { ready: true, email, name, raw: out.slice(0, 240) };
}

const DEFAULT_CREDENTIAL_PATH = "/var/lib/tetherless/credential.bin";
const DEFAULT_ENROLLMENT_PATH = "/var/lib/tetherless/fairplay-enrollment.bin";

/** @returns {"mac"|"linux"} */
function hostMode() {
  const raw = String(process.env.FAIRPLAY_HOST || "").trim().toLowerCase();
  if (raw === "mac" || raw === "macos" || raw === "darwin") return "mac";
  if (raw === "linux") return "linux";
  return process.platform === "darwin" ? "mac" : "linux";
}

function defaultBackends() {
  // Mac host: Tetherless can use the live enrollment / default model dir — no Linux hop.
  return hostMode() === "mac" ? ["unfairplay"] : ["fairplay-decrypt", "unfairplay"];
}

function requireCredential() {
  const raw = String(process.env.FAIRPLAY_REQUIRE_CREDENTIAL ?? "").trim().toLowerCase();
  if (raw === "0" || raw === "false" || raw === "no" || raw === "off") return false;
  if (raw === "1" || raw === "true" || raw === "yes" || raw === "on") return true;
  // Default on for Linux; off for Mac unfairplay-only (enrollment lives on the box).
  return hostMode() !== "mac";
}

function credentialPath() {
  const fromEnv = String(process.env.FAIRPLAY_CREDENTIAL_BIN || "").trim();
  if (fromEnv) return fromEnv;
  if (fs.existsSync(DEFAULT_CREDENTIAL_PATH)) return DEFAULT_CREDENTIAL_PATH;
  return fromEnv || DEFAULT_CREDENTIAL_PATH;
}

/** @returns {{ ok: true, path: string, bytes: number } | { ok: false, error: string, path: string }} */
function validateCredentialBin() {
  const p = credentialPath();
  if (!p) {
    return { ok: false, path: "", error: "FAIRPLAY_CREDENTIAL_BIN is not set." };
  }
  if (!fs.existsSync(p)) {
    return { ok: false, path: p, error: `credential.bin missing at ${p}` };
  }
  let st;
  try {
    st = fs.statSync(p);
  } catch (e) {
    return { ok: false, path: p, error: e.message || String(e) };
  }
  if (!st.isFile()) {
    return { ok: false, path: p, error: `${p} is not a file` };
  }
  if (st.size !== 16) {
    return {
      ok: false,
      path: p,
      error: `credential.bin must be exactly 16 bytes (got ${st.size}) — mint via Tetherless decrypt on an enrolled Mac`,
    };
  }
  return { ok: true, path: p, bytes: 16 };
}

function homeDir() {
  return String(process.env.HOME || process.env.USERPROFILE || "").trim();
}

/** Local copies from MacDuty / Tetherless decrypt setup (never commit these files). */
function localEnrollmentCandidates() {
  const home = homeDir();
  const out = [];
  if (home) {
    out.push(path.join(home, "unfairplay", "models", "fairplay-enrollment.bin"));
    // MacDuty sudo-setup often lands models under the managed account home.
    out.push(path.join(home, "Library", "Application Support", "unfairplay", "models"));
  }
  out.push(DEFAULT_ENROLLMENT_PATH);
  return out;
}

function firstExistingEnrollmentFile() {
  for (const p of localEnrollmentCandidates()) {
    try {
      if (!p || !fs.existsSync(p)) continue;
      const st = fs.statSync(p);
      if (st.isFile() && st.size > 32) return p;
      if (st.isDirectory()) {
        const hit = fs.readdirSync(p).find((name) => {
          try {
            const f = path.join(p, name);
            return fs.statSync(f).isFile() && fs.statSync(f).size > 32 && name.endsWith(".bin");
          } catch {
            return false;
          }
        });
        if (hit) return path.join(p, hit);
      }
    } catch {
      /* continue */
    }
  }
  return "";
}

function enrollmentModelPath() {
  const fromEnv = String(process.env.FAIRPLAY_ENROLLMENT_MODEL || "").trim();
  if (fromEnv) return fromEnv;
  const found = firstExistingEnrollmentFile();
  if (found) return found;
  return DEFAULT_ENROLLMENT_PATH;
}

function enrollmentModelReady() {
  const p = enrollmentModelPath();
  try {
    return !!(p && fs.existsSync(p) && fs.statSync(p).isFile() && fs.statSync(p).size > 32);
  } catch {
    return false;
  }
}

function unfairplayModelDir() {
  const fromEnv = String(process.env.UNFAIRPLAY_MODEL_DIR || "").trim();
  if (fromEnv) return fromEnv;
  const home = homeDir();
  if (!home) return "";
  const macDefault = path.join(home, "Library", "Application Support", "unfairplay", "models");
  const localCopy = path.join(home, "unfairplay", "models");
  try {
    if (fs.existsSync(macDefault) && fs.statSync(macDefault).isDirectory()) return macDefault;
  } catch {
    /* ignore */
  }
  try {
    if (fs.existsSync(localCopy) && fs.statSync(localCopy).isDirectory()) return localCopy;
  } catch {
    /* ignore */
  }
  return "";
}

function unfairplayModelDirReady() {
  const d = unfairplayModelDir();
  if (!d) return false;
  try {
    if (!fs.existsSync(d)) return false;
    const st = fs.statSync(d);
    if (st.isFile()) return st.size > 32;
    if (!st.isDirectory()) return false;
    return fs.readdirSync(d).some((name) => {
      try {
        return fs.statSync(path.join(d, name)).isFile() && fs.statSync(path.join(d, name)).size > 32;
      } catch {
        return false;
      }
    });
  } catch {
    return false;
  }
}

/** True when Tetherless decrypt can run: explicit model, model dir, or Mac host (default saved models). */
function unfairplaySecretsReady() {
  return enrollmentModelReady() || unfairplayModelDirReady() || hostMode() === "mac";
}

function configuredBackends() {
  const fallback = defaultBackends().join(",");
  const raw = String(process.env.DECRYPT_BACKENDS || fallback)
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  const allowed = new Set([
    "fairplay-decrypt",
    "unfairplay",
    "ipadecrypt",
    "ipa-decrypter",
    "phone",
    "unfaird",
  ]);
  const list = raw.filter((b) => allowed.has(b));
  return list.length ? list : defaultBackends();
}

function backendStatus() {
  const backends = configuredBackends();
  const cred = validateCredentialBin();
  const modelPath = enrollmentModelPath();
  const modelOk = enrollmentModelReady();
  const modelDir = unfairplayModelDir();
  const host = hostMode();
  const unfairReady = !!which(process.env.UNFAIRPLAY_BIN || "unfairplay") && unfairplaySecretsReady();
  return {
    backends,
    host,
    macHost: host === "mac",
    linuxOnly: host === "linux" && !backends.includes("phone") && !backends.includes("unfaird"),
    requireCredential: requireCredential(),
    credential: cred.ok
      ? { ready: true, path: cred.path, bytes: cred.bytes }
      : { ready: false, path: cred.path, error: cred.error },
    enrollmentModel: modelOk
      ? { ready: true, path: modelPath }
      : {
          ready: host === "mac" || unfairplayModelDirReady(),
          path: modelOk ? modelPath : modelDir || modelPath,
          error: modelOk
            ? ""
            : host === "mac"
              ? "Mac host — Tetherless will use its default saved model dir after local setup"
              : unfairplayModelDirReady()
                ? ""
                : `enrollment model missing at ${modelPath}`,
        },
    "fairplay-decrypt": {
      ready: cred.ok,
      bin: process.env.FAIRPLAY_DECRYPT_BIN || "decrypt.py",
      credential: cred.path || "",
      note: cred.ok
        ? `credential.bin OK (16 bytes) · ${host}`
        : cred.error || "Needs 16-byte FAIRPLAY_CREDENTIAL_BIN",
    },
    unfairplay: {
      ready: unfairReady,
      bin: process.env.UNFAIRPLAY_BIN || "unfairplay",
      note:
        host === "mac"
          ? "Preferred on Mac — setup once on this host, decrypt every job here"
          : "Linux binary — needs FAIRPLAY_ENROLLMENT_MODEL or UNFAIRPLAY_MODEL_DIR",
    },
    ipadecrypt: {
      ready: !!which(process.env.IPADECRYPT_BIN || "ipadecrypt"),
      bin: process.env.IPADECRYPT_BIN || "ipadecrypt",
      note: "londek/ipadecrypt on PATH",
    },
    "ipa-decrypter": {
      ready: !!process.env.IPA_DECRYPTER_URL,
      url: process.env.IPA_DECRYPTER_URL || "",
      note: "ac0d3r/ipa-decrypter Docker/HTTP",
    },
    phone: {
      ready: true,
      note: "Opt-in only — not needed for Mac/Linux offline decrypt",
    },
    unfaird: {
      ready: !!process.env.UNFAIRD_URL,
      url: process.env.UNFAIRD_URL || "",
      note: "Opt-in jailbreak daemon — skip",
    },
    ipatool: (() => {
      const bin = ipatoolBin();
      if (!bin) {
        return { ready: false, bin: "ipatool", error: "ipatool not on PATH", note: "Needed to fetch encrypted IPAs" };
      }
      const auth = ipatoolAuthStatus();
      return {
        ready: !!auth.ready,
        bin,
        email: auth.email || "",
        name: auth.name || "",
        error: auth.error || "",
        note: auth.ready
          ? `Logged in${auth.email ? " as " + auth.email : ""}`
          : auth.error || "Run: ipatool auth login (after mac-ssh.sh unlock)",
      };
    })(),
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

function runCmd(bin, args, { cwd, timeoutMs = 20 * 60 * 1000, env, onLine } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, {
      cwd,
      env: { ...process.env, ...(env || {}) },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let lineBuf = "";
    const feed = (chunk, stream) => {
      const text = chunk.toString("utf8");
      if (stream === "out") stdout += text;
      else stderr += text;
      if (typeof onLine !== "function") return;
      lineBuf += text;
      const parts = lineBuf.split(/\r?\n/);
      lineBuf = parts.pop() || "";
      for (const line of parts) {
        const clean = stripAnsi(line).trim();
        if (clean) {
          try {
            onLine(clean);
          } catch {
            /* ignore */
          }
        }
      }
    };
    const timer = setTimeout(() => {
      try {
        child.kill("SIGKILL");
      } catch {
        /* ignore */
      }
      reject(new Error(`Timed out after ${Math.round(timeoutMs / 60000)}m: ${path.basename(bin)}`));
    }, timeoutMs);
    child.stdout.on("data", (d) => feed(d, "out"));
    child.stderr.on("data", (d) => feed(d, "err"));
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    child.on("close", (code, signal) => {
      clearTimeout(timer);
      if (lineBuf && typeof onLine === "function") {
        const clean = stripAnsi(lineBuf).trim();
        if (clean) {
          try {
            onLine(clean);
          } catch {
            /* ignore */
          }
        }
      }
      if (code === 0) resolve({ stdout, stderr, code });
      else {
        const detail = stripAnsi(stderr || stdout).trim().slice(0, 400) || signal || "no output";
        const raw = new Error(`${bin} exited ${code}: ${detail}`);
        reject(new Error(friendlyIpatoolError(raw) || raw.message));
      }
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

function resolveIpatoolStorefront(explicit, url) {
  try {
    const x = require("./mac-ipatool-extras");
    return x.resolveStorefront(explicit, url);
  } catch {
    const fromEnv = String(process.env.FAIRPLAY_IPATOOL_STOREFRONT || "").trim().toLowerCase();
    const fromBody = String(explicit || "").trim().toLowerCase();
    const m = /apps\.apple\.com\/([a-z]{2})\//i.exec(String(url || ""));
    return (fromBody || fromEnv || (m && m[1]) || "us").slice(0, 2);
  }
}

/** Only pass --country when the caller/env set it explicitly (ipatool builds vary). */
function explicitIpatoolStorefront(explicit) {
  const fromBody = String(explicit || "").trim().toLowerCase().slice(0, 2);
  const fromEnv = String(process.env.FAIRPLAY_IPATOOL_STOREFRONT || "").trim().toLowerCase().slice(0, 2);
  if (fromBody) return fromBody;
  if (fromEnv) return fromEnv;
  return "";
}

/** ipatool ≥2.x uses --app-id (not legacy --adam-id). */
function ipatoolDownloadArgs(encPath, { url, vreq, purchase = true, storefront } = {}) {
  const adam = adamFromStoreUrl(url);
  const platform = String(process.env.FAIRPLAY_IPATOOL_PLATFORM || "iphone").trim();
  const sf = explicitIpatoolStorefront(storefront);
  const args = ["download", "--non-interactive", "-o", encPath];
  if (purchase) args.splice(1, 0, "--purchase");
  if (platform) args.push("--platform", platform);
  if (sf && String(process.env.FAIRPLAY_IPATOOL_COUNTRY_FLAG || "1") !== "0") {
    args.push("--country", sf);
  }
  if (adam) args.push("--app-id", adam);
  else args.push(String(url || "").trim());
  if (vreq) args.push("--external-version-id", String(vreq));
  return args;
}

/** Pick the newest .ipa in dir (ipatool sometimes ignores -o filename). */
function newestIpaInDir(dir, preferPath) {
  if (preferPath && fs.existsSync(preferPath) && fs.statSync(preferPath).size >= 100) {
    return preferPath;
  }
  let best = "";
  let bestM = 0;
  try {
    for (const f of fs.readdirSync(dir)) {
      if (!/\.ipa$/i.test(f)) continue;
      const full = path.join(dir, f);
      try {
        const st = fs.statSync(full);
        if (st.size < 100) continue;
        if (st.mtimeMs >= bestM) {
          bestM = st.mtimeMs;
          best = full;
        }
      } catch {
        /* ignore */
      }
    }
  } catch {
    /* ignore */
  }
  return best;
}

function loadIpaCache() {
  try {
    return require("./mac-tg-ipa-cache");
  } catch {
    return null;
  }
}

/**
 * Ensure dir/encrypted-source.ipa exists:
 *   1) already in job dir
 *   2) encrypted disk cache (skip Apple download)
 *   3) ipatool download (auth preflight · retries · collect IPA) → encrypted cache
 */
async function ensureEncryptedSource({ url, dir, say, vreq, storefront, onProgress } = {}) {
  const enc = path.join(dir, "encrypted-source.ipa");
  if (fs.existsSync(enc) && fs.statSync(enc).size >= 100) return enc;

  const adam = adamFromStoreUrl(url);
  const ver = String(vreq || "").trim() || "latest";
  const sf = explicitIpatoolStorefront(storefront) || resolveIpatoolStorefront(storefront, url);
  const report = (pct, msg) => {
    if (typeof onProgress === "function") {
      try {
        onProgress(pct, msg);
      } catch {
        /* ignore */
      }
    }
  };
  let extras = null;
  try {
    extras = require("./mac-ipatool-extras");
  } catch {
    /* optional */
  }

  const ipaCache = loadIpaCache();
  if (ipaCache && adam) {
    const hit = ipaCache.getEncryptedPath(adam, ver);
    if (hit) {
      say("encrypted IPA cache hit — skipping App Store download…");
      report(40, "encrypted cache hit");
      ipaCache.linkOrCopy(hit, enc);
      return enc;
    }
  }

  const ipatool = ipatoolBin();
  if (!ipatool) {
    throw new Error(
      "Need encrypted IPA at encrypted-source.ipa or FAIRPLAY_IPATOOL_BIN/ipatool on PATH"
    );
  }
  // Keychain re-locks; unlock before every App Store download over SSH.
  if (unlockKeychain()) say("keychain unlocked…");

  const auth = ipatoolAuthStatus({ force: true });
  if (!auth.ready) {
    throw new Error(auth.error || "ipatool is not logged in — run: ipatool auth login");
  }
  if (auth.email) say(`ipatool: ${auth.email}`);
  report(8, "ipatool auth ok");
  if (explicitIpatoolStorefront(storefront)) say(`storefront ${sf}`);

  const timeoutMs = Math.min(
    90 * 60 * 1000,
    Math.max(15 * 60 * 1000, Number(process.env.FAIRPLAY_IPATOOL_TIMEOUT_MS) || 45 * 60 * 1000)
  );
  const maxAttempts = Math.max(1, Math.min(4, Number(process.env.FAIRPLAY_IPATOOL_RETRIES) || 3));
  let lastErr = null;
  let purchase = true;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    say(
      attempt === 1
        ? `ipatool downloading encrypted IPA${adam ? " · " + adam : ""}…`
        : `ipatool retry ${attempt}/${maxAttempts}${purchase ? "" : " (no --purchase)"}…`
    );
    try {
      await runCmd(ipatool, ipatoolDownloadArgs(enc, { url, vreq, purchase, storefront: sf }), {
        cwd: dir,
        timeoutMs,
        onLine: (line) => {
          // Surface useful progress; skip noisy JSON blobs.
          if (line.length > 160) return;
          const pct = extras && extras.parseDownloadPercent ? extras.parseDownloadPercent(line) : null;
          if (pct != null) {
            report(Math.min(55, 15 + Math.round(pct * 0.4)), line.slice(0, 100));
            say(`download ${pct}%`);
            return;
          }
          if (/^(error|failed|panic)/i.test(line)) say(line.slice(0, 120));
          else if (/%|download|purchas|writing|done|success|app.?id/i.test(line)) {
            say(line.slice(0, 120));
            const stage = extras && extras.mapProgressStage ? extras.mapProgressStage(line) : null;
            if (stage != null) report(stage, line.slice(0, 100));
          }
        },
      });
      lastErr = null;
      break;
    } catch (e) {
      lastErr = e;
      if (purchase && isPurchaseAlreadyOwnedFailure(e)) {
        purchase = false;
        say("already owned — retrying ipatool without --purchase…");
        continue;
      }
      if (attempt < maxAttempts && isTransientIpatoolFailure(e)) {
        const waitMs = 1500 * attempt;
        say(`ipatool transient error — wait ${Math.round(waitMs / 1000)}s…`);
        await sleep(waitMs);
        unlockKeychain();
        continue;
      }
      throw new Error(friendlyIpatoolError(e));
    }
  }
  if (lastErr) throw new Error(friendlyIpatoolError(lastErr));

  const found = newestIpaInDir(dir, enc);
  if (!found) throw new Error("ipatool produced no encrypted IPA");
  if (found !== enc) {
    try {
      fs.renameSync(found, enc);
    } catch {
      fs.copyFileSync(found, enc);
      try {
        fs.rmSync(found, { force: true });
      } catch {
        /* ignore */
      }
    }
  }
  if (!fs.existsSync(enc) || fs.statSync(enc).size < 100) {
    throw new Error("ipatool produced no encrypted IPA");
  }
  const mb = (fs.statSync(enc).size / (1024 * 1024)).toFixed(1);
  say(`encrypted IPA ready · ${mb} MB`);

  if (ipaCache && adam) {
    try {
      ipaCache.putEncrypted(adam, ver, enc);
      say(`cached encrypted IPA (${adam}${ver !== "latest" ? " v" + ver : ""})…`);
    } catch (e) {
      say(`encrypted cache save skipped: ${String((e && e.message) || e).slice(0, 80)}`);
    }
  }
  return enc;
}

function stripAnsi(s) {
  return String(s || "").replace(/\u001b\[[0-9;]*m/g, "");
}

/** User-facing backend name (keep internal ids like unfairplay for env/config). */
function brandBackend(name) {
  const n = String(name || "").toLowerCase();
  if (n === "unfairplay") return "Tetherless";
  if (n === "fairplay-decrypt") return "Tetherless (credential)";
  if (n === "ipadecrypt") return "Tetherless (ipadecrypt)";
  if (n === "ipa-decrypter") return "Tetherless (remote)";
  if (n === "unfaird") return "Tetherless (unfaird)";
  if (n === "phone") return "Tetherless (phone)";
  return name || "Tetherless";
}

/**
 * Try non-phone backends in order. Returns { file, name } or null to fall through to phone.
 * Throws only when a configured backend hard-fails and no further backends remain
 * (caller still may try phone).
 */
async function tryRemoteBackends({ url, dir, say, vreq, skip = [], storefront, onProgress } = {}) {
  const backends = configuredBackends().filter((b) => b !== "phone" && !skip.includes(b));
  if (!backends.length) return null;
  // Stash for ensureEncryptedSource via closure on runUnfairplay / runFairplayDecrypt —
  // pass through env for this job so nested helpers see the storefront.
  if (storefront) {
    process.env.FAIRPLAY_IPATOOL_STOREFRONT = String(storefront).trim().toLowerCase().slice(0, 2);
  }
  // Capture the caller's reporter before rebinding — `say(t)` inside an arrow that
  // closes over the `say` parameter would recurse forever after `say = sayWrapped`
  // ("Maximum call stack size exceeded" on every Mac decrypt).
  const sayOriginal = typeof say === "function" ? say : () => {};
  const sayWrapped = (t) => {
    sayOriginal(t);
    if (typeof onProgress === "function") {
      try {
        const extras = require("./mac-ipatool-extras");
        const stage = extras.mapProgressStage(t);
        if (stage != null) onProgress(stage, t);
      } catch {
        /* ignore */
      }
    }
  };
  say = sayWrapped;

  // fairplay-decrypt needs 16-byte credential.bin.
  // unfairplay needs a model file/dir, or a Mac host with local Tetherless setup.
  const host = hostMode();
  const cred = validateCredentialBin();
  const modelOk = enrollmentModelReady() || unfairplayModelDirReady();
  const unfairOk = unfairplaySecretsReady();
  const wantsDecrypt = backends.includes("fairplay-decrypt");
  const wantsUnfairplay = backends.includes("unfairplay");
  say(`Tetherless host: ${host}`);
  if (wantsDecrypt && !cred.ok) {
    if (!(wantsUnfairplay && unfairOk)) {
      throw new Error(
        `FairPlay credential.bin required for fairplay-decrypt: ${cred.error}. ` +
          `Prefer running the site on a Mac with DECRYPT_BACKENDS=unfairplay, or set FAIRPLAY_CREDENTIAL_BIN. ` +
          `See server/fairplay-backends.md.`
      );
    }
    say(`credential.bin missing — trying Tetherless decrypt…`);
  } else if (cred.ok) {
    say(`Using credential.bin (${cred.bytes} bytes)…`);
  }
  if (host === "mac" && wantsUnfairplay) {
    say(`Tetherless decrypt on this Mac…`);
  } else if (modelOk) {
    say(`Tetherless enrollment model ready…`);
  } else if (wantsUnfairplay && !wantsDecrypt && !unfairOk) {
    throw new Error(
      `Tetherless needs a model (FAIRPLAY_ENROLLMENT_MODEL / UNFAIRPLAY_MODEL_DIR) or FAIRPLAY_HOST=mac with local setup. ` +
        `See server/fairplay-backends.md.`
    );
  } else if (requireCredential() && !cred.ok && !unfairOk) {
    throw new Error(
      `FairPlay secret required: set FAIRPLAY_CREDENTIAL_BIN and/or enrollment model, or run on a Mac (FAIRPLAY_HOST=mac). ` +
        `See server/fairplay-backends.md.`
    );
  }

  const errors = [];
  for (const backend of backends) {
    const label = brandBackend(backend);
    try {
      say(`Trying ${label}…`);
      let result = null;
      if (backend === "fairplay-decrypt") {
        result = await runFairplayDecrypt({ url, dir, say, vreq });
      } else if (backend === "unfairplay") {
        result = await runUnfairplay({ url, dir, say, vreq });
      } else if (backend === "ipadecrypt") {
        result = await runIpadecrypt({ url, dir, say, vreq });
      } else if (backend === "ipa-decrypter") {
        result = await runIpaDecrypter({ url, dir, say, vreq });
      } else if (backend === "unfaird") {
        result = await runUnfaird({ url, dir, say, vreq });
      }
      if (result && result.file && fs.existsSync(result.file)) {
        say(`${label} produced IPA…`);
        result.backend = backend;
        return result;
      }
      errors.push(`${backend}: empty result`);
    } catch (e) {
      const msg = e && e.message ? e.message : String(e);
      errors.push(`${backend}: ${msg}`);
      say(`${label} failed — ${msg.slice(0, 120)}`);
    }
  }
  if (errors.length && !configuredBackends().includes("phone")) {
    throw new Error("All Tetherless decrypt backends failed: " + errors.join(" | "));
  }
  return null;
}

async function runFairplayDecrypt({ url, dir, say, vreq }) {
  const credCheck = validateCredentialBin();
  if (!credCheck.ok) {
    throw new Error(credCheck.error || "credential.bin invalid");
  }
  const cred = credCheck.path;
  const enc = path.join(dir, "encrypted-source.ipa");
  const out = path.join(dir, "fairplay-decrypt-out.ipa");
  try {
    fs.rmSync(out, { force: true });
  } catch {
    /* ignore */
  }

  await ensureEncryptedSource({ url, dir, say, vreq });

  const py = process.env.FAIRPLAY_DECRYPT_PYTHON || "python3";
  const bin = process.env.FAIRPLAY_DECRYPT_BIN || "";
  say(`fairplay-decrypt decrypting with credential.bin…`);
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

async function runUnfairplay({ url, dir, say, vreq }) {
  const bin = which(process.env.UNFAIRPLAY_BIN || "unfairplay");
  if (!bin) throw new Error("Tetherless decrypt binary not found — set UNFAIRPLAY_BIN");

  // --model accepts a file or directory. On Mac, omit it to use the default saved models.
  let modelArg = "";
  if (enrollmentModelReady()) modelArg = enrollmentModelPath();
  else if (unfairplayModelDirReady()) modelArg = unfairplayModelDir();
  else if (hostMode() !== "mac") {
    throw new Error(
      `Tetherless needs FAIRPLAY_ENROLLMENT_MODEL or UNFAIRPLAY_MODEL_DIR (or FAIRPLAY_HOST=mac)`
    );
  }

  const enc = path.join(dir, "encrypted-source.ipa");
  const out = path.join(dir, "unfairplay-out.ipa");
  try {
    fs.rmSync(out, { force: true });
  } catch {
    /* ignore */
  }

  await ensureEncryptedSource({ url, dir, say, vreq });

  const encBytes = fs.existsSync(enc) ? fs.statSync(enc).size : 0;
  const pre = preflightDecrypt({ bytes: encBytes });
  if (!pre.ok) throw new Error(pre.error);

  const args = ["decrypt", "--input", enc, "--output", out, "--force"];
  if (modelArg) {
    say(`Tetherless decrypt (--model ${modelArg})…`);
    args.push("--model", modelArg);
  } else {
    say("Tetherless decrypt (Mac default model dir)…");
  }
  // Bigger IPAs need longer — ~8 min/GB, floor 20m, cap 90m.
  const timeoutMs = Math.min(
    90 * 60 * 1000,
    Math.max(20 * 60 * 1000, Math.round((encBytes / (1024 ** 3)) * 8 * 60 * 1000) || 20 * 60 * 1000)
  );
  say(`decrypt budget ${Math.round(timeoutMs / 60000)}m · free disk ${pre.resources.freeDiskGb.toFixed(1)} GB…`);
  try {
    await runCmd(bin, args, { cwd: dir, timeoutMs });
  } catch (e) {
    throw new Error(friendlyIpatoolError(e));
  }
  if (!fs.existsSync(out) || fs.statSync(out).size < 100) {
    throw new Error("Tetherless decrypt produced no IPA");
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
  ensureEncryptedSource,
  unlockKeychain,
  friendlyIpatoolError,
  friendlyDecryptError,
  ipatoolBin,
  ipatoolAuthStatus,
  isTransientIpatoolFailure,
  hostResources,
  suggestedWorkers,
  preflightDecrypt,
  adamFromStoreUrl,
  validateCredentialBin,
  credentialPath,
  enrollmentModelPath,
  enrollmentModelReady,
  unfairplaySecretsReady,
  hostMode,
  requireCredential,
  DEFAULT_CREDENTIAL_PATH,
  DEFAULT_ENROLLMENT_PATH,
};
