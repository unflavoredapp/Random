"use strict";
// AirShare on-device install (OTA) cert service for the iOS app.  Mounted from site.js.
//
//   GET  /ota/cert.php    X-OTA-Token  -> {cert,key,not_after,sans}   live wildcard pair for *.airshare.lol
//   GET  /ota/status.php  X-OTA-Token  -> {server_time,not_after,days_left,issuer,sans,cert_mtime,last_renew}
//   POST /ota/event.php   X-OTA-Token  {bundle,version,name,mode,stage,device}
//   GET  /ota/event.php   X-OTA-Token  -> {bundle: installedCount}
//
// The app installs over https://ota.airshare.lol (A record -> 127.0.0.1, DNS only), so the cert must cover
// *.airshare.lol.  Point OTA_CERT_DIR at the certbot live dir (default /etc/letsencrypt/live/airshare.lol) holding
// fullchain.pem + privkey.pem; or set OTA_CERT_FILE / OTA_KEY_FILE directly.  Token: OTA_TOKEN (default below).
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");

const DEFAULT_TOKEN = "airshare-ota-2026";

function mount(web, c) {
  const { db, express } = c;
  const TOKEN = process.env.OTA_TOKEN || DEFAULT_TOKEN;
  const dir = process.env.OTA_CERT_DIR || "/etc/letsencrypt/live/airshare.lol";
  const certFile = process.env.OTA_CERT_FILE || path.join(dir, "fullchain.pem");
  const keyFile = process.env.OTA_KEY_FILE || path.join(dir, "privkey.pem");

  db.exec(`CREATE TABLE IF NOT EXISTS ota_events(
    id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER NOT NULL, bundle TEXT, version TEXT, name TEXT,
    mode TEXT, stage TEXT, device TEXT);
    CREATE INDEX IF NOT EXISTS idx_ota_events_bundle ON ota_events(bundle, stage);`);
  const insEvent = db.prepare("INSERT INTO ota_events(ts,bundle,version,name,mode,stage,device) VALUES(?,?,?,?,?,?,?)");
  const counts = db.prepare("SELECT bundle, COUNT(*) n FROM ota_events WHERE stage='installed' AND bundle IS NOT NULL GROUP BY bundle");

  const same = (a, b) => {
    const x = Buffer.from(String(a || "")), y = Buffer.from(String(b || ""));
    return x.length === y.length && crypto.timingSafeEqual(x, y);
  };
  const guard = (req, res, next) => {
    if (!same(req.get("X-OTA-Token"), TOKEN)) return res.status(401).json({ error: "bad token" });
    res.set("Cache-Control", "no-store");
    next();
  };

  function readPair() {
    const cert = fs.readFileSync(certFile, "utf8");
    const key = fs.readFileSync(keyFile, "utf8");
    const x = new crypto.X509Certificate(cert);
    const sans = String(x.subjectAltName || "").split(",").map(s => s.trim().replace(/^DNS:/, "")).filter(Boolean);
    const notAfter = new Date(x.validTo);
    return { cert, key, x, sans, notAfter, mtime: fs.statSync(certFile).mtime };
  }

  web.get("/ota/cert.php", guard, (req, res) => {
    try {
      const p = readPair();
      res.json({ cert: p.cert, key: p.key, not_after: p.notAfter.toISOString(), sans: p.sans });
    } catch (e) {
      console.warn("ota cert:", e.message);
      res.status(503).json({ error: "certificate not available on the server" });
    }
  });

  web.get("/ota/status.php", guard, (req, res) => {
    try {
      const p = readPair();
      res.json({
        server_time: new Date().toISOString(),
        not_after: p.notAfter.toISOString(),
        days_left: Math.floor((p.notAfter - Date.now()) / 86400000),
        issuer: String(p.x.issuer || "").replace(/\n/g, ", "),
        sans: p.sans,
        cert_mtime: p.mtime.toISOString(),
        last_renew: { ok: true, at: p.mtime.toISOString(), source: "certbot" },
      });
    } catch (e) {
      res.json({ server_time: new Date().toISOString(), error: "certificate not available on the server" });
    }
  });

  const small = express.json({ limit: "8kb" });
  web.post("/ota/event.php", guard, small, (req, res) => {
    const b = req.body || {};
    const s = (v, n) => (typeof v === "string" ? v.slice(0, n) : null);
    try { insEvent.run(Date.now(), s(b.bundle, 200), s(b.version, 50), s(b.name, 200), s(b.mode, 20), s(b.stage, 20), s(b.device, 40)); }
    catch (e) { console.warn("ota event:", e.message); }
    res.json({ ok: true });
  });
  web.get("/ota/event.php", guard, (req, res) => {
    const out = {};
    for (const r of counts.all()) out[r.bundle] = r.n;
    res.json(out);
  });
  return { token: TOKEN };
}

module.exports = { mount };
