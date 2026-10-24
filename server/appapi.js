"use strict";
// Native-app API for the AirShare iOS app.  Mounted from site.js (inside the password-account block).
//
//   POST /app/v1/register            {username,password,email?,adid}          -> {ok,token,username,role,adid}
//   POST /app/v1/login               {username,password,adid}                 -> {ok,token,username,role,adid}
//   POST /app/v1/autologin           {adid,device_key}                        -> {ok,token,...profile}   (device_key is issued at sign-in)
//   GET  /app/v1/account             ?token= | Authorization: Bearer          -> profile
//   POST /app/v1/account             {action,token,...}                       -> set_style|set_username|set_email|
//                                                                               change_password|admin_set_mdid|logout
//   GET  /app/v1/status                                                       -> {ok,db,users}
//   GET  /app/v1/roles               ?adid=AS-XXXXXX-XX                       -> {role,staff}
//   GET  /app/v1/quota               ?adid=                                   -> {today,total}
//   POST /app/v1/quota               {adid,action:"consume"}                  -> {today,total}
//   GET  /app/v1/style               ?usernames=a,b,c                         -> {name:{style,role,badges}}
//   GET  /app/v1/certificate-requests (auth)                                  -> {requests:[{id,type,status,note,eta_days,created_at,updated_at}], premium:{active,expires,days_left}}
//   POST /app/v1/certificate-requests (auth) {action:"create",...} | {action:"cancel",id}   -> {ok,id}
//   POST /admin/app/premium          {user_id,days,mode:"add"|"set"|"revoke"}             (Basic auth)  grant / set / remove premium days
//   GET  /admin/app                  (Basic auth, same creds as /analytics)   -> roles + groups + sponsors + certificate requests UI
//   POST /admin/app/groups           {user_id,groups:[...]}                               (Basic auth)  set a user's groups
//   POST /admin/app/sponsor          {user_id,sponsor:"FastDecryptBot"|""}                (Basic auth)  set / clear a user's sponsor
//   POST /app/v1/account  (ADMIN role only):  admin_list_users {q?} | admin_set_groups {username,groups:[...]} | admin_set_sponsor {username,sponsor}
//
// Roles: member (default) | developer | admin.  Bootstrap with env APP_ADMINS / APP_DEVS (usernames or ADIDs,
// comma separated); after that manage them from /admin/app.  ADIDs look like AS-XXXXXX-XX (legacy MS- accepted).
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");
const PERKS = require("./perks");

const ADID_RE = /^(AS|MS)-[A-Z0-9]{6}-[A-Z0-9]{2}$/;
const NAME_RE = /^[A-Za-z0-9_]{3,20}$/;
const EMAIL_RE = /^[^\s@]{1,64}@[^\s@.]+(?:\.[^\s@.]+)+$/;
const RESERVED = new Set(["admin", "administrator", "root", "system", "support", "staff", "moderator", "airshare", "owner"]);
const ROLES = ["member", "developer", "admin"];
// Groups an admin can put a user in. They are shown as badges next to the username in the app and on the site.
const GROUPS = ["admin", "co_admin", "staff", "dev", "verified", "sponsor", "supporter", "og", "top_signer", "founder", "beta"];
const TOKEN_MS = 180 * 86400000;
const csv = (v) => new Set(String(v || "").split(",").map(x => x.trim().toLowerCase()).filter(Boolean));

function mount(web, c) {
  const { db, express, hashPw, checkPw, limited, key, auth, esc } = c;
  const APP_ADMINS = csv(process.env.APP_ADMINS), APP_DEVS = csv(process.env.APP_DEVS);

  // ---------- schema ----------
  for (const col of ["adid TEXT", "role TEXT NOT NULL DEFAULT 'member'", "style TEXT", "badges TEXT", "tv INTEGER NOT NULL DEFAULT 0", "sponsor TEXT", "premium_until TEXT", "banned INTEGER NOT NULL DEFAULT 0", "banned_reason TEXT", "banned_until TEXT", "banned_at TEXT", "dec_carry INTEGER NOT NULL DEFAULT 0", "dec_carry_day TEXT"]) {
    try { db.exec("ALTER TABLE local_users ADD COLUMN " + col); } catch { /* already there */ }
  }
  try { db.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_local_users_adid ON local_users(adid) WHERE adid IS NOT NULL"); } catch (e) { console.warn("adid index:", e.message); }
  db.exec(`CREATE TABLE IF NOT EXISTS app_signs(adid TEXT NOT NULL, day TEXT NOT NULL, n INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(adid, day));
    CREATE TABLE IF NOT EXISTS cert_requests(
      id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER, username TEXT, adid TEXT, type TEXT, reason TEXT, udid TEXT, benefit TEXT,
      status TEXT NOT NULL DEFAULT 'pending', note TEXT, created_at TEXT NOT NULL, updated_at TEXT);
    CREATE INDEX IF NOT EXISTS cert_requests_user ON cert_requests(user_id);
    CREATE TABLE IF NOT EXISTS app_devices(adid TEXT PRIMARY KEY, user_id INTEGER NOT NULL, key_hash TEXT NOT NULL, created_at TEXT NOT NULL, last_used TEXT);
    CREATE INDEX IF NOT EXISTS app_devices_user ON app_devices(user_id);
    CREATE TABLE IF NOT EXISTS banned_adids(adid TEXT PRIMARY KEY, reason TEXT, banned_at TEXT NOT NULL, banned_until TEXT);
    CREATE TABLE IF NOT EXISTS login_events(id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, adid TEXT, ip_hash TEXT, kind TEXT, at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS login_events_user ON login_events(user_id, at);
    CREATE INDEX IF NOT EXISTS login_events_adid ON login_events(adid);
    CREATE INDEX IF NOT EXISTS login_events_ip ON login_events(ip_hash);
    CREATE TABLE IF NOT EXISTS dec_cooldown(k TEXT PRIMARY KEY, app_id TEXT NOT NULL, until INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS ban_appeals(
      id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, banned_at TEXT, message TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending', admin_note TEXT, created_at TEXT NOT NULL, reviewed_at TEXT, reviewed_by TEXT);
    CREATE INDEX IF NOT EXISTS ban_appeals_user ON ban_appeals(user_id, created_at);
    CREATE INDEX IF NOT EXISTS ban_appeals_status ON ban_appeals(status, created_at);`);
  for (const col of ["device_name TEXT", "eta_days INTEGER", "reviewed_by TEXT"]) {
    try { db.exec("ALTER TABLE cert_requests ADD COLUMN " + col); } catch { /* already there */ }
  }

  const byId = db.prepare("SELECT id,username,email,pass_hash,adid,role,style,badges,tv,sponsor,premium_until,banned,banned_reason,banned_until,banned_at,dec_carry,dec_carry_day,created_at FROM local_users WHERE id=?");
  const byName = db.prepare("SELECT id,username,email,pass_hash,adid,role,style,badges,tv,sponsor,premium_until,banned,banned_reason,banned_until,banned_at,created_at FROM local_users WHERE username=? OR email=?");
  const byAdid = db.prepare("SELECT id,username,adid,role,badges,banned,banned_reason,banned_until,banned_at FROM local_users WHERE adid=?");
  const setAdid = db.prepare("UPDATE local_users SET adid=? WHERE id=?");

  // ---------- helpers ----------
  const sig = (s) => crypto.createHmac("sha256", key).update("app-token|" + s).digest("base64url");
  const eq = (a, b) => { const x = Buffer.from(String(a)), y = Buffer.from(String(b)); return x.length === y.length && crypto.timingSafeEqual(x, y); };
  const mint = (u) => { const exp = Date.now() + TOKEN_MS, body = `v1.${u.id}.${u.tv || 0}.${exp}`; return `${body}.${sig(body)}`; };
  function userFromToken(t) {
    const p = String(t || "").split(".");
    if (p.length !== 5 || p[0] !== "v1") return null;
    const body = p.slice(0, 4).join(".");
    if (!eq(p[4], sig(body)) || Number(p[3]) < Date.now()) return null;
    const u = byId.get(Number(p[1]));
    return u && !isBanned(u) && (u.tv || 0) === Number(p[2]) ? u : null;
  }
  const tokenOf = (req) => {
    const h = String(req.get("authorization") || "");
    return h.startsWith("Bearer ") ? h.slice(7).trim() : String((req.body && req.body.token) || req.query.token || "");
  };
  function roleOf(u) {
    if (!u) return "member";
    const name = String(u.username || "").toLowerCase(), adid = String(u.adid || "").toLowerCase();
    if (APP_ADMINS.has(name) || (adid && APP_ADMINS.has(adid))) return "admin";
    if (u.role === "admin") return "admin";
    if (APP_DEVS.has(name) || (adid && APP_DEVS.has(adid))) return u.role === "member" ? "developer" : u.role;
    return ROLES.includes(u.role) ? u.role : "member";
  }
  function badgesOf(u) {
    let b = []; try { b = JSON.parse(u.badges || "[]"); } catch { /* ignore */ }
    b = Array.isArray(b) ? b.filter(x => typeof x === "string") : [];
    const r = roleOf(u);
    if (r === "admin" && !b.includes("founder")) b.unshift("founder");
    if (r === "developer" && !b.includes("dev")) b.unshift("dev");
    if (PERKS.badge && premiumOf(u).active && !b.includes("premium")) b.push("premium");
    return Array.from(new Set(b));
  }
  function styleOf(u) { try { const s = JSON.parse(u.style || "{}"); return s && typeof s === "object" ? s : {}; } catch { return {}; } }
  // Premium is a number of days on the account: it counts down from the moment it is granted, and more days stack on top.
  // A ban with banned_until in the past has lapsed; isBanned() is the single source of truth everywhere.
  const clearBanQ = db.prepare("UPDATE local_users SET banned=0, banned_reason=NULL, banned_until=NULL, banned_at=NULL WHERE id=?");
  function isBanned(u) {
    if (!u || !u.banned) return false;
    if (u.banned_until) {
      const t = Date.parse(u.banned_until);
      if (Number.isFinite(t) && t <= Date.now()) { clearBanQ.run(u.id); return false; }
    }
    return true;
  }
  // One appeal per ban "window" (banned_at): a fresh ban always gets a fresh banned_at, so a user who was
  // banned, appealed, got unbanned and was later banned again can appeal again — but can't spam the same ban.
  const appealForQ = db.prepare("SELECT id,message,status,admin_note,created_at,reviewed_at FROM ban_appeals WHERE user_id=? AND banned_at IS ? ORDER BY id DESC LIMIT 1");
  const latestAppealQ = db.prepare("SELECT id,message,status,admin_note,created_at,reviewed_at FROM ban_appeals WHERE user_id=? ORDER BY id DESC LIMIT 1");
  function appealFor(userId, bannedAt) { return appealForQ.get(Number(userId), bannedAt || null); }
  const appealJSON = (ap) => ap ? { id: ap.id, submitted: true, status: ap.status, message: ap.message, admin_note: String(ap.admin_note || ""), at: ap.created_at } : { submitted: false };
  // For admin display, the appeal (and the admin's note on it) stays visible after an unban — that history is
  // exactly what an appeal inbox is for. appealFor() (ban-window-scoped) is still what gates a new submission.
  function banInfo(u) {
    const banned = isBanned(u);
    const appeal = appealJSON(banned ? appealFor(u.id, u.banned_at || null) : latestAppealQ.get(u.id));
    if (!banned) return { banned: false, reason: "", until: null, appeal };
    return { banned: true, reason: String(u.banned_reason || ""), until: u.banned_until || null, appeal };
  }
  function banMessage(u) {
    let m = "This account has been banned.";
    if (u.banned_reason) m += " Reason: " + u.banned_reason;
    if (u.banned_until) m += " It lifts " + new Date(u.banned_until).toLocaleString("en-US", { timeZone: "UTC" }) + " UTC.";
    return m;
  }
  // Verifies the same credentials login/autologin would accept, without minting a session — used so a banned
  // user (who has no working token) can still prove it's their own account before an appeal is recorded.
  async function submitAppeal({ username, password, adid, deviceKey, message }) {
    const msg = String(message || "").trim().replace(/[\u0000-\u001f]/g, " ").slice(0, 1000);
    if (msg.length < 10) return { ok: false, code: 400, error: "Tell us a bit more — at least 10 characters." };
    let u = null;
    const ident = String(username || "").trim();
    const pw = typeof password === "string" ? password.slice(0, 128) : "";
    const a = String(adid || "").trim().toUpperCase();
    const dk = typeof deviceKey === "string" ? deviceKey : "";
    if (ident && pw) {
      const row = byName.get(ident, ident);
      if (row && (await checkPw(pw, row.pass_hash))) u = byId.get(row.id);
    } else if (ADID_RE.test(a) && dk.length >= 20) {
      const dev = db.prepare("SELECT user_id,key_hash FROM app_devices WHERE adid=?").get(a);
      if (dev && eq(dev.key_hash, sha(dk))) u = byId.get(dev.user_id);
    }
    if (!u) return { ok: false, code: 401, error: "Couldn't verify that account." };
    if (!isBanned(u)) return { ok: false, code: 400, error: "This account isn't banned." };
    if (appealFor(u.id, u.banned_at || null)) return { ok: false, code: 409, error: "An appeal has already been submitted for this ban." };
    db.prepare("INSERT INTO ban_appeals(user_id,banned_at,message,status,created_at) VALUES(?,?,?,?,?)")
      .run(u.id, u.banned_at || null, msg, "pending", new Date().toISOString());
    return { ok: true, appeal: { submitted: true, status: "pending" } };
  }
  function listAppeals(status) {
    const rows = status
      ? db.prepare("SELECT a.*, u.username, u.banned, u.banned_reason, u.banned_until FROM ban_appeals a JOIN local_users u ON u.id=a.user_id WHERE a.status=? ORDER BY a.id DESC LIMIT 300").all(String(status))
      : db.prepare("SELECT a.*, u.username, u.banned, u.banned_reason, u.banned_until FROM ban_appeals a JOIN local_users u ON u.id=a.user_id ORDER BY (a.status='pending') DESC, a.id DESC LIMIT 300").all();
    return rows.map(r => ({
      id: r.id, user_id: r.user_id, username: r.username, message: r.message, status: r.status, admin_note: r.admin_note || "",
      created_at: r.created_at, reviewed_at: r.reviewed_at, reviewed_by: r.reviewed_by || "",
      currently_banned: !!r.banned, ban_reason: r.banned_reason || "", ban_until: r.banned_until || null,
    }));
  }
  function reviewAppeal(id, note, unban) {
    const a = db.prepare("SELECT * FROM ban_appeals WHERE id=?").get(Number(id));
    if (!a) return null;
    db.prepare("UPDATE ban_appeals SET status='reviewed', admin_note=?, reviewed_at=?, reviewed_by=? WHERE id=?")
      .run(String(note || "").replace(/[\u0000-\u001f<>]/g, " ").trim().slice(0, 500) || null, new Date().toISOString(), "admin", a.id);
    if (unban) setBanned(a.user_id, false);
    return { ok: true };
  }
  function premiumOf(u) {
    const t = u && u.premium_until ? Date.parse(u.premium_until) : NaN;
    if (!Number.isFinite(t) || t <= Date.now()) return { active: false, expires: null, days_left: 0 };
    return { active: true, expires: new Date(t).toISOString(), days_left: Math.ceil((t - Date.now()) / 86400000) };
  }
  const setPremiumQ = db.prepare("UPDATE local_users SET premium_until=? WHERE id=?");
  function setPremium(id, mode, days) { // mode: add | set | revoke  -> returns the new premium state, or null if no such user
    const u = byId.get(Number(id));
    if (!u) return null;
    const n = Math.min(3650, Math.max(0, Math.floor(Number(days) || 0)));
    if (mode === "revoke" || (mode === "set" && n === 0)) setPremiumQ.run(null, u.id);
    else if (n > 0) {
      const cur = Date.parse(u.premium_until || ""), from = mode === "add" && Number.isFinite(cur) && cur > Date.now() ? cur : Date.now();
      setPremiumQ.run(new Date(from + n * 86400000).toISOString(), u.id);
    }
    return premiumOf(byId.get(u.id));
  }
  const profile = (u) => ({
    ok: true, username: u.username, email: /@accounts\.invalid$/.test(u.email || "") ? "" : (u.email || ""),
    role: roleOf(u), adid: u.adid || "", mdid: u.adid || "", style: styleOf(u), badges: badgesOf(u),
    groups: badgesOf(u), sponsor: String(u.sponsor || ""), premium: premiumOf(u), decrypt: decStatus("u" + u.id, ""),
  });
  const cleanGroups = (g) => Array.from(new Set((Array.isArray(g) ? g : []).map(x => String(x).toLowerCase().trim()).filter(x => GROUPS.includes(x))));
  const cleanSponsor = (v) => String(v == null ? "" : v).replace(/[\u0000-\u001f<>]/g, "").trim().slice(0, 40);
  // Ban: sign-in, saved device logins, existing sessions and beta downloads all stop at once.
  // days: null/0 = permanent, otherwise auto-lifts after that many days (temporary ban).
  function setBanned(id, flag, reason, days) {
    id = Number(id);
    const u = byId.get(id);
    if (!u) return null;
    if (flag) {
      const until = Number(days) > 0 ? new Date(Date.now() + Math.min(3650, Math.floor(Number(days))) * 86400000).toISOString() : null;
      db.prepare("UPDATE local_users SET banned=1, banned_reason=?, banned_until=?, banned_at=?, tv=COALESCE(tv,0)+1 WHERE id=?")
        .run(String(reason || "").replace(/[\u0000-\u001f<>]/g, " ").trim().slice(0, 200) || null, until, new Date().toISOString(), id);
      db.prepare("DELETE FROM app_devices WHERE user_id=?").run(id);
    } else {
      clearBanQ.run(id);
    }
    return banInfo(byId.get(id));
  }
  // Device-level ban: blocks an ADID outright, even for a brand-new account that has never touched it before.
  const banAdidQ = db.prepare("INSERT INTO banned_adids(adid,reason,banned_at,banned_until) VALUES(?,?,?,?) ON CONFLICT(adid) DO UPDATE SET reason=excluded.reason, banned_at=excluded.banned_at, banned_until=excluded.banned_until");
  const unbanAdidQ = db.prepare("DELETE FROM banned_adids WHERE adid=?");
  const adidBanQ = db.prepare("SELECT * FROM banned_adids WHERE adid=?");
  function adidBanInfo(adid) {
    if (!ADID_RE.test(adid || "")) return null;
    const r = adidBanQ.get(adid);
    if (!r) return null;
    if (r.banned_until && Date.parse(r.banned_until) <= Date.now()) { unbanAdidQ.run(adid); return null; }
    return r;
  }
  function setAdidBanned(adid, flag, reason, days) {
    adid = String(adid || "").trim().toUpperCase();
    if (!ADID_RE.test(adid)) return null;
    if (!flag) { unbanAdidQ.run(adid); return { adid, banned: false }; }
    const until = Number(days) > 0 ? new Date(Date.now() + Math.min(3650, Math.floor(Number(days))) * 86400000).toISOString() : null;
    banAdidQ.run(adid, String(reason || "").replace(/[\u0000-\u001f<>]/g, " ").trim().slice(0, 200) || null, new Date().toISOString(), until);
    const r = adidBanQ.get(adid);
    return { adid, banned: true, reason: r.reason || "", until: r.banned_until || null };
  }
  // Correlation: every other account / login seen on the same ADID or the same (hashed) IP — surfaces ban evasion.
  const ipHashOf = (ip) => crypto.createHash("sha256").update("login-ip|" + key + "|" + String(ip || "")).digest("hex").slice(0, 24);
  const logLogin = (userId, adid, ip, kind) => { try { db.prepare("INSERT INTO login_events(user_id,adid,ip_hash,kind,at) VALUES(?,?,?,?,?)").run(userId, adid || null, ipHashOf(ip), kind, new Date().toISOString()); } catch {} };
  function correlate(userId) {
    userId = Number(userId);
    const mine = db.prepare("SELECT DISTINCT adid FROM login_events WHERE user_id=? AND adid IS NOT NULL").all(userId).map(r => r.adid)
      .concat(db.prepare("SELECT adid FROM local_users WHERE id=? AND adid IS NOT NULL").all(userId).map(r => r.adid));
    const myIps = db.prepare("SELECT DISTINCT ip_hash FROM login_events WHERE user_id=?").all(userId).map(r => r.ip_hash);
    const others = new Map();
    const add = (row, via) => { if (row.id === userId) return; const e = others.get(row.id) || { id: row.id, username: row.username, banned: !!row.banned, via: new Set() }; e.via.add(via); others.set(row.id, e); };
    for (const adid of new Set(mine)) {
      if (!adid) continue;
      for (const row of db.prepare("SELECT DISTINCT u.id,u.username,u.banned FROM login_events e JOIN local_users u ON u.id=e.user_id WHERE e.adid=?").all(adid)) add(row, "adid:" + adid);
      const owner = byAdid.get(adid);
      if (owner) add(owner, "adid:" + adid);
    }
    for (const h of new Set(myIps)) {
      if (!h) continue;
      for (const row of db.prepare("SELECT DISTINCT u.id,u.username,u.banned FROM login_events e JOIN local_users u ON u.id=e.user_id WHERE e.ip_hash=?").all(h)) add(row, "ip");
    }
    return Array.from(others.values()).map(e => ({ id: e.id, username: e.username, banned: e.banned, via: Array.from(e.via) }));
  }
  const setGroupsQ = db.prepare("UPDATE local_users SET badges=? WHERE id=?");
  const setSponsorQ = db.prepare("UPDATE local_users SET sponsor=? WHERE id=?");
  const storedBadges = (u) => { try { const b = JSON.parse(u.badges || "[]"); return Array.isArray(b) ? b.filter(x => typeof x === "string") : []; } catch { return []; } };
  // Hand the account tools to site.js -> features.js (the /admin Accounts page): same data the iOS app reads.
  if (c.acct) Object.assign(c.acct, {
    groupCatalog: GROUPS, roleCatalog: ROLES,
    extra: (id) => { const u = byId.get(Number(id)); return u ? { role: roleOf(u), groups: storedBadges(u), sponsor: String(u.sponsor || ""), premium: premiumOf(u), ban: banInfo(u) } : {}; },
    isBanned: (id) => isBanned(byId.get(Number(id))),
    banMessage: (id) => { const u = byId.get(Number(id)); return u ? banMessage(u) : ""; },
    banInfo: (id) => { const u = byId.get(Number(id)); return u ? banInfo(u) : { banned: false, reason: "", until: null }; },
    setBanned: (id, flag, reason, days) => setBanned(id, !!flag, reason, days),
    submitAppeal: (args) => submitAppeal(args),
    reviewAppeal: (id, note, unban) => reviewAppeal(id, note, !!unban),
    setAdidBanned: (adid, flag, reason, days) => setAdidBanned(adid, !!flag, reason, days),
    bannedAdids: () => db.prepare("SELECT * FROM banned_adids ORDER BY banned_at DESC LIMIT 200").all(),
    correlate: (id) => correlate(id),
    setPremium: (id, mode, days) => setPremium(id, String(mode), days),
    isPremium: (uid) => premiumUid(uid),
    perks: PERKS,
    setGroups: (id, groups) => { if (!byId.get(Number(id))) return null; const g = cleanGroups(groups); setGroupsQ.run(JSON.stringify(g), Number(id)); return g; },
    setSponsor: (id, sponsor) => { if (!byId.get(Number(id))) return null; const v = cleanSponsor(sponsor); setSponsorQ.run(v, Number(id)); return v; },
    setRole: (id, role) => { if (!ROLES.includes(String(role)) || !byId.get(Number(id))) return false; db.prepare("UPDATE local_users SET role=? WHERE id=?").run(String(role), Number(id)); return true; },
  });
  const fail = (res, code, error) => res.status(code).json({ ok: false, error });
  const day = () => new Date().toISOString().slice(0, 10);

  // Device key: issued at sign-in, kept in the device Keychain. ADID + device key = automatic sign-in on that device.
  // (An ADID alone is shown on screen and shared with staff, so it is never enough to get a session by itself.)
  const sha = (x) => crypto.createHash("sha256").update(String(x)).digest("hex");
  function issueDevice(u) {
    if (!u || !u.adid || !ADID_RE.test(u.adid)) return "";
    const k = crypto.randomBytes(32).toString("base64url"), now = new Date().toISOString();
    db.prepare("INSERT OR REPLACE INTO app_devices(adid,user_id,key_hash,created_at,last_used) VALUES(?,?,?,?,?)").run(u.adid, u.id, sha(k), now, now);
    return k;
  }

  function bindAdid(u, adid) { // an ADID is only attached when free (or already ours): knowing one never steals it from another account
    if (!ADID_RE.test(adid || "")) return u.adid || "";
    if (u.adid) return u.adid;
    const owner = byAdid.get(adid);
    if (owner && owner.id !== u.id) return "";
    setAdid.run(adid, u.id);
    return adid;
  }

  // ---------- daily decrypt limits (website + app share one counter per account / guest) ----------
  // guest 3 · signed-in 10 · developer 25 · staff and admin unlimited.  Days are UTC, like the sign counter.
  db.exec("CREATE TABLE IF NOT EXISTS dec_quota(k TEXT NOT NULL, day TEXT NOT NULL, n INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(k,day))");
  const envN = (name, d) => { const v = Number(process.env[name]); return Number.isFinite(v) && v >= 0 ? Math.floor(v) : d; };
  const DEC = { guest: envN("DEC_LIMIT_GUEST", 3), member: envN("DEC_LIMIT_MEMBER", 10), developer: envN("DEC_LIMIT_DEV", 25), ipGuest: envN("DEC_LIMIT_GUEST_IP", 9) };
  const UNLIMITED_GROUPS = ["admin", "co_admin", "staff", "founder"];
  function decTier(uid) { // -> { tier, limit }   limit null = unlimited
    const m = /^u(\d+)$/.exec(String(uid || ""));
    const u = m ? byId.get(Number(m[1])) : null;
    if (u) {
      const role = roleOf(u), g = badgesOf(u);
      if (role === "admin" || g.some(x => UNLIMITED_GROUPS.includes(x))) return { tier: "staff", limit: null };
      if (role === "developer" || g.includes("dev")) return { tier: "developer", limit: DEC.developer };
      if (premiumOf(u).active) return { tier: "member", limit: Math.max(DEC.member, PERKS.decryptLimit) };
      return { tier: "member", limit: DEC.member };
    }
    if (/^\d+$/.test(String(uid || ""))) return { tier: "member", limit: DEC.member }; // Telegram-login website account
    return { tier: "guest", limit: DEC.guest };
  }
  const qN = db.prepare("SELECT n FROM dec_quota WHERE k=? AND day=?");
  const qUp = db.prepare("INSERT INTO dec_quota(k,day,n) VALUES(?,?,1) ON CONFLICT(k,day) DO UPDATE SET n=n+1");
  const qDown = db.prepare("UPDATE dec_quota SET n=n-1 WHERE k=? AND day=? AND n>0");
  const nOf = (k, d) => { const r = k ? qN.get(k, d || day()) : null; return r ? r.n : 0; };
  const nextReset = () => { const d = new Date(); d.setUTCHours(24, 0, 0, 0); return d.toISOString(); };
  const yesterday = () => { const d = new Date(); d.setUTCDate(d.getUTCDate() - 1); return d.toISOString().slice(0, 10); };

  // Premium rollover: a small amount of yesterday's unused daily quota carries into today, for premium members only.
  // Computed once per day per account and stashed on the row, so repeated status checks agree on the same number.
  const DEC_CARRY_MAX = envN("DEC_CARRY_MAX", PERKS.carryMax);
  const setCarryQ = db.prepare("UPDATE local_users SET dec_carry=?, dec_carry_day=? WHERE id=?");
  function carryFor(uid, tier) {
    const m = /^u(\d+)$/.exec(String(uid || ""));
    const u = m ? byId.get(Number(m[1])) : null;
    if (!u || tier.limit == null || !premiumOf(u).active) return 0;
    const today = day();
    if (u.dec_carry_day === today) return u.dec_carry || 0;
    const carry = Math.max(0, Math.min(DEC_CARRY_MAX, tier.limit - nOf(uid, yesterday())));
    setCarryQ.run(carry, today, u.id);
    return carry;
  }

  // Per-app cooldown: once an app is decrypted, the same actor can't immediately re-trigger it again (separate from
  // the daily quota — this is about not hammering one app's pipeline, not about running out of allowance).
  const DEC_APP_COOLDOWN_MS = envN("DEC_APP_COOLDOWN_MIN", 5) * 60000;
  const coolQ = db.prepare("SELECT until FROM dec_cooldown WHERE k=?");
  const coolSetQ = db.prepare("INSERT INTO dec_cooldown(k,app_id,until) VALUES(?,?,?) ON CONFLICT(k) DO UPDATE SET app_id=excluded.app_id, until=excluded.until");
  const coolClearQ = db.prepare("DELETE FROM dec_cooldown WHERE k=?");
  const premiumUid = (uid) => { const m = /^u(\d+)$/.exec(String(uid || "")); const u = m ? byId.get(Number(m[1])) : null; return !!(u && premiumOf(u).active); };
  const cooldownMsFor = (uid) => (premiumUid(uid) ? Math.min(DEC_APP_COOLDOWN_MS, PERKS.cooldownMin * 60000) : DEC_APP_COOLDOWN_MS);
  function appCooldownLeft(uid, appId) {
    if (!appId || DEC_APP_COOLDOWN_MS <= 0) return 0;
    const r = coolQ.get(uid + "|" + appId);
    return r && r.until > Date.now() ? r.until - Date.now() : 0;
  }
  setInterval(() => { try { db.prepare("DELETE FROM dec_cooldown WHERE until<?").run(Date.now()); } catch {} }, 3600000).unref();

  function decStatus(uid, ip, appId) {
    const t = decTier(uid), used = nOf(uid || null);
    const ipUsed = t.tier === "guest" ? nOf("ip|" + (ip || "")) : 0;
    const cooldownMs = appCooldownLeft(uid, appId);
    if (t.limit == null) return { ok: true, tier: t.tier, limit: null, used, left: null, unlimited: true, resets_at: nextReset(), cooldown_s: Math.ceil(cooldownMs / 1000) };
    const carry = carryFor(uid, t), effLimit = t.limit + carry;
    const left = Math.max(0, Math.min(effLimit - used, t.tier === "guest" ? DEC.ipGuest - ipUsed : effLimit));
    return { ok: true, tier: t.tier, limit: effLimit, base_limit: t.limit, carry, used, left, unlimited: false, resets_at: nextReset(), cooldown_s: Math.ceil(cooldownMs / 1000) };
  }
  function decConsume(uid, ip, appId) { // counts one decrypt; { ok:false } when the quota's spent or the app's on cooldown
    const cooldownMs = appCooldownLeft(uid, appId);
    if (cooldownMs > 0) return { ok: false, cooldown: true, cooldown_s: Math.ceil(cooldownMs / 1000), error: `This app was just decrypted. Try again in ${Math.ceil(cooldownMs / 60000)}m.` };
    const st = decStatus(uid, ip, appId);
    if (!st.unlimited && st.left <= 0) return { ...st, ok: false };
    if (uid) qUp.run(uid, day());
    if (st.tier === "guest" && ip) qUp.run("ip|" + ip, day());
    if (appId) coolSetQ.run(uid + "|" + appId, appId, Date.now() + cooldownMsFor(uid));
    return decStatus(uid, ip, appId);
  }
  function decRefund(uid, ip, appId) { // a decrypt that failed doesn't cost anything, and doesn't start the cooldown either
    if (uid) qDown.run(uid, day());
    if (decTier(uid).tier === "guest" && ip) qDown.run("ip|" + ip, day());
    if (appId) coolClearQ.run(uid + "|" + appId);
  }
  if (c.acct) c.acct.decrypt = { status: decStatus, consume: decConsume, refund: decRefund };

  // ---------- middleware ----------
  const jsonBody = express.json({ limit: "16kb", type: "application/json" });
  const base = (req, res, next) => { res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" }); next(); };
  const jsonErr = (err, _req, res, next) => (err ? fail(res, 400, "Bad request.") : next());
  const needAuth = (req, res, next) => {
    const u = userFromToken(tokenOf(req));
    if (!u) return fail(res, 401, "Invalid session. Sign in again.");
    req.me = u; next();
  };

  web.get("/app/v1/status", base, (_req, res) => {
    let users = 0; try { users = db.prepare("SELECT COUNT(*) c FROM local_users").get().c; } catch { /* ignore */ }
    res.json({ ok: true, db: true, users, time: new Date().toISOString() });
  });

  // ---------- register / login ----------
  web.post("/app/v1/register", base, jsonBody, async (req, res) => {
    try {
      if (limited("ar|" + req.ip, 10, 3600000)) return fail(res, 429, "Too many sign-ups from this network. Try again later.");
      const b = req.body || {};
      const username = String(b.username || "").trim(), password = typeof b.password === "string" ? b.password : "";
      let email = String(b.email || "").trim().toLowerCase();
      if (!NAME_RE.test(username)) return fail(res, 400, "Username must be 3-20 letters, numbers or underscores.");
      if (RESERVED.has(username.toLowerCase())) return fail(res, 400, "That username isn't available.");
      if (email && (email.length > 120 || !EMAIL_RE.test(email))) return fail(res, 400, "Enter a valid email address.");
      if (!email) email = `${username.toLowerCase()}@accounts.invalid`;
      if (password.length < 8 || password.length > 128) return fail(res, 400, "Password must be 8-128 characters.");
      const regAdid = String(b.adid || b.mdid || "").trim().toUpperCase();
      const adidBanR = regAdid ? adidBanInfo(regAdid) : null;
      if (adidBanR) return fail(res, 403, "This device can't create an account." + (adidBanR.reason ? " Reason: " + adidBanR.reason : ""));
      const hash = await hashPw(password), now = new Date().toISOString();
      let id;
      try { id = db.prepare("INSERT INTO local_users(username,email,pass_hash,created_at,last_login) VALUES(?,?,?,?,?)").run(username, email, hash, now, now).lastInsertRowid; if (regAdid) logLogin(id, regAdid, req.ip, "register"); }
      catch (e) { if (/UNIQUE/i.test(String(e.message))) return fail(res, 409, "That username or email is already in use."); throw e; }
      const u = byId.get(Number(id));
      const reqAdid = String(b.adid || b.mdid || "").toUpperCase();
      bindAdid(u, reqAdid);
      const fresh = byId.get(u.id);
      return res.json({ ...profile(fresh), token: mint(fresh), device_key: fresh.adid === reqAdid ? issueDevice(fresh) : "" });
    } catch (e) { console.warn("App register failed:", e.message); return fail(res, 500, "Something went wrong. Please try again."); }
  }, jsonErr);

  web.post("/app/v1/login", base, jsonBody, async (req, res) => {
    try {
      const b = req.body || {};
      const ident = String(b.username || b.id || "").trim().slice(0, 120), password = typeof b.password === "string" ? b.password.slice(0, 128) : "";
      if (!ident || !password) return fail(res, 400, "Enter your username and password.");
      if (limited("al|" + req.ip, 20, 900000) || limited("alu|" + ident.toLowerCase(), 8, 900000)) return fail(res, 429, "Too many attempts. Try again in a few minutes.");
      const row = byName.get(ident, ident);
      const ok = await checkPw(password, row ? row.pass_hash : null);
      if (!row || !ok) return fail(res, 401, "Incorrect username or password.");
      if (isBanned(row)) return res.status(403).json({ ok: false, error: banMessage(row), banned: true, ban: banInfo(row) });
      const reqAdid = String(b.adid || b.mdid || "").toUpperCase();
      const adidBan0 = reqAdid ? adidBanInfo(reqAdid) : null;
      if (adidBan0) return fail(res, 403, "This device can't sign in." + (adidBan0.reason ? " Reason: " + adidBan0.reason : ""));
      db.prepare("UPDATE local_users SET last_login=? WHERE id=?").run(new Date().toISOString(), row.id);
      bindAdid(row, reqAdid);
      logLogin(row.id, reqAdid, req.ip, "login");
      const fresh = byId.get(row.id);
      return res.json({ ...profile(fresh), token: mint(fresh), device_key: fresh.adid === reqAdid ? issueDevice(fresh) : "" });
    } catch (e) { console.warn("App login failed:", e.message); return fail(res, 500, "Something went wrong. Please try again."); }
  }, jsonErr);

  web.post("/app/v1/autologin", base, jsonBody, (req, res) => {
    try {
      const b = req.body || {}, adid = String(b.adid || b.mdid || "").trim().toUpperCase(), key = String(b.device_key || "");
      if (!ADID_RE.test(adid) || key.length < 20 || key.length > 100) return fail(res, 400, "Bad request.");
      if (limited("ad|" + req.ip, 60, 900000) || limited("adu|" + adid, 20, 900000)) return fail(res, 429, "Too many attempts. Try again in a few minutes.");
      const row = db.prepare("SELECT user_id,key_hash FROM app_devices WHERE adid=?").get(adid);
      if (!row || !eq(row.key_hash, sha(key))) return fail(res, 401, "This device isn't recognized. Sign in once.");
      const u = byId.get(row.user_id);
      if (u && isBanned(u)) return res.status(403).json({ ok: false, error: banMessage(u), banned: true, ban: banInfo(u) });
      if (!u || u.adid !== adid) return fail(res, 401, "This device isn't recognized. Sign in once.");
      const adb = adidBanInfo(adid);
      if (adb) return fail(res, 403, "This device can't sign in." + (adb.reason ? " Reason: " + adb.reason : ""));
      const now = new Date().toISOString();
      db.prepare("UPDATE app_devices SET last_used=? WHERE adid=?").run(now, adid);
      db.prepare("UPDATE local_users SET last_login=? WHERE id=?").run(now, u.id);
      logLogin(u.id, adid, req.ip, "autologin");
      return res.json({ ...profile(u), token: mint(u) });
    } catch (e) { console.warn("App autologin failed:", e.message); return fail(res, 500, "Something went wrong. Please try again."); }
  }, jsonErr);

  // One appeal message per ban. No session needed (a banned account has none) — re-proves identity with the
  // same username/password login would accept, or the device's adid + device_key (autologin's credentials).
  web.post("/app/v1/appeal", base, jsonBody, async (req, res) => {
    try {
      if (limited("ap|" + req.ip, 8, 3600000)) return fail(res, 429, "Too many attempts. Try again later.");
      const b = req.body || {};
      const r = await submitAppeal({ username: b.username, password: b.password, adid: b.adid || b.mdid, deviceKey: b.device_key, message: b.message });
      return r.ok ? res.json(r) : fail(res, r.code || 400, r.error);
    } catch (e) { console.warn("App appeal failed:", e.message); return fail(res, 500, "Something went wrong. Please try again."); }
  }, jsonErr);

  // ---------- account ----------
  web.get("/app/v1/account", base, needAuth, (req, res) => res.json(profile(req.me)));

  web.post("/app/v1/account", base, jsonBody, needAuth, async (req, res) => {
    try {
      const b = req.body || {}, u = req.me;
      if (limited("aa|" + u.id, 60, 600000)) return fail(res, 429, "Too many requests. Slow down.");
      switch (String(b.action || "")) {
        case "logout": {
          db.prepare("UPDATE local_users SET tv=tv+1 WHERE id=?").run(u.id);
          const la = String(b.adid || "").toUpperCase();
          if (ADID_RE.test(la)) db.prepare("DELETE FROM app_devices WHERE adid=? AND user_id=?").run(la, u.id);
          else db.prepare("DELETE FROM app_devices WHERE user_id=?").run(u.id);
          return res.json({ ok: true });
        }
        case "device_key": { // already-signed-in device pairs itself for automatic sign-in (needs a valid session)
          const a = String(b.adid || "").toUpperCase();
          if (!ADID_RE.test(a) || u.adid !== a) return fail(res, 400, "This device's ADID isn't linked to your account.");
          return res.json({ ok: true, device_key: issueDevice(u) });
        }
        case "set_style": {
          const col = String(b.color || ""), gif = String(b.gif || "").slice(0, 300);
          const st = {
            color: /^#[0-9a-fA-F]{6}$/.test(col) ? col.toUpperCase() : "",
            rainbow: b.rainbow === true || b.rainbow === 1,
            gif: /^https:\/\//.test(gif) ? gif : "",
            font: String(b.font || "").replace(/[^A-Za-z0-9\-_ ]/g, "").slice(0, 40),
            size: Math.min(4, Math.max(1, parseInt(b.size, 10) || 2)),
          };
          if (PERKS.fancyStyles && !premiumOf(u).active && roleOf(u) === "member" && !storedBadges(u).length) {
            const cur = styleOf(u); // styles a user already had stay editable; only NEW rainbow / GIF needs Premium
            if ((st.rainbow && !cur.rainbow) || (st.gif && st.gif !== cur.gif)) return fail(res, 403, "Rainbow and GIF styles are a Premium perk.");
          }
          db.prepare("UPDATE local_users SET style=? WHERE id=?").run(JSON.stringify(st), u.id);
          return res.json({ ok: true, style: st });
        }
        case "set_username": {
          const n = String(b.username || "").trim();
          if (!NAME_RE.test(n)) return fail(res, 400, "Username must be 3-20 letters, numbers or underscores.");
          if (RESERVED.has(n.toLowerCase()) && n.toLowerCase() !== u.username.toLowerCase()) return fail(res, 400, "That username isn't available.");
          try { db.prepare("UPDATE local_users SET username=? WHERE id=?").run(n, u.id); }
          catch (e) { if (/UNIQUE/i.test(String(e.message))) return fail(res, 409, "That username is taken."); throw e; }
          return res.json({ ok: true, username: n });
        }
        case "set_email": {
          const e = String(b.email || "").trim().toLowerCase();
          const val = e || `${u.username.toLowerCase()}@accounts.invalid`;
          if (e && (e.length > 120 || !EMAIL_RE.test(e))) return fail(res, 400, "Enter a valid email address.");
          try { db.prepare("UPDATE local_users SET email=? WHERE id=?").run(val, u.id); }
          catch (er) { if (/UNIQUE/i.test(String(er.message))) return fail(res, 409, "That email is already in use."); throw er; }
          return res.json({ ok: true });
        }
        case "change_password": {
          const cur = typeof b.current_password === "string" ? b.current_password.slice(0, 128) : "", nw = typeof b.new_password === "string" ? b.new_password : "";
          if (!(await checkPw(cur, u.pass_hash))) return fail(res, 401, "Current password is wrong.");
          if (nw.length < 8 || nw.length > 128) return fail(res, 400, "Password must be 8-128 characters.");
          db.prepare("UPDATE local_users SET pass_hash=?, tv=tv+1 WHERE id=?").run(await hashPw(nw), u.id);
          db.prepare("DELETE FROM app_devices WHERE user_id=?").run(u.id);
          const fresh = byId.get(u.id);
          return res.json({ ok: true, token: mint(fresh) });
        }
        case "admin_set_mdid": {
          if (roleOf(u) !== "admin") return fail(res, 403, "Admins only.");
          const v = String(b.mdid || b.adid || "").trim().toUpperCase();
          if (!ADID_RE.test(v)) return fail(res, 400, "ADID must look like AS-XXXXXX-XX.");
          const owner = byAdid.get(v);
          if (owner && owner.id !== u.id) return fail(res, 409, "ADID already belongs to another account");
          setAdid.run(v, u.id);
          return res.json({ ok: true, mdid: v, adid: v });
        }
        case "admin_list_users": {
          if (roleOf(u) !== "admin") return fail(res, 403, "Admins only.");
          const q = "%" + String(b.q || "").trim().replace(/[%_]/g, "").slice(0, 40) + "%";
          const rows = db.prepare("SELECT id,username,adid,role,badges,sponsor FROM local_users WHERE username LIKE ? ORDER BY id DESC LIMIT 60").all(q);
          return res.json({ ok: true, groups: GROUPS, users: rows.map(r => ({ username: r.username, adid: r.adid || "", role: roleOf(r), groups: storedBadges(r), sponsor: String(r.sponsor || "") })) });
        }
        case "admin_set_groups": {
          if (roleOf(u) !== "admin") return fail(res, 403, "Admins only.");
          const t = db.prepare("SELECT id,username,badges FROM local_users WHERE username=? COLLATE NOCASE").get(String(b.username || "").trim());
          if (!t) return fail(res, 404, "No user with that name.");
          const g = cleanGroups(b.groups);
          setGroupsQ.run(JSON.stringify(g), t.id);
          return res.json({ ok: true, username: t.username, groups: g });
        }
        case "admin_set_sponsor": {
          if (roleOf(u) !== "admin") return fail(res, 403, "Admins only.");
          const t = db.prepare("SELECT id,username FROM local_users WHERE username=? COLLATE NOCASE").get(String(b.username || "").trim());
          if (!t) return fail(res, 404, "No user with that name.");
          const sp = cleanSponsor(b.sponsor);
          setSponsorQ.run(sp, t.id);
          return res.json({ ok: true, username: t.username, sponsor: sp });
        }
        default: return fail(res, 400, "Unknown action.");
      }
    } catch (e) { console.warn("App account failed:", e.message); return fail(res, 500, "Something went wrong. Please try again."); }
  }, jsonErr);

  // ---------- role gate (by device ADID) ----------
  web.get("/app/v1/roles", base, (req, res) => {
    if (limited("rg|" + req.ip, 240, 600000)) return fail(res, 429, "Too many requests.");
    const adid = String(req.query.adid || req.query.mdid || "").trim().toUpperCase();
    if (!ADID_RE.test(adid)) return fail(res, 400, "Bad ADID.");
    const u = byAdid.get(adid) || (APP_ADMINS.has(adid.toLowerCase()) ? { role: "admin", adid } : APP_DEVS.has(adid.toLowerCase()) ? { role: "developer", adid } : null);
    const role = roleOf(u);
    return res.json({ ok: true, role, staff: role !== "member" });
  });

  // ---------- sign counter ----------
  const qGet = db.prepare("SELECT COALESCE(SUM(n),0) t, COALESCE(SUM(CASE WHEN day=? THEN n END),0) d FROM app_signs WHERE adid=?");
  const qInc = db.prepare("INSERT INTO app_signs(adid,day,n) VALUES(?,?,1) ON CONFLICT(adid,day) DO UPDATE SET n=n+1");
  const counts = (adid) => { const r = qGet.get(day(), adid); return { ok: true, today: r.d, total: r.t }; };
  web.get("/app/v1/quota", base, (req, res) => {
    const adid = String(req.query.adid || req.query.mdid || "").trim().toUpperCase();
    return ADID_RE.test(adid) ? res.json(counts(adid)) : fail(res, 400, "Bad ADID.");
  });
  web.post("/app/v1/quota", base, jsonBody, (req, res) => {
    const b = req.body || {}, adid = String(b.adid || b.mdid || "").trim().toUpperCase();
    if (!ADID_RE.test(adid)) return fail(res, 400, "Bad ADID.");
    if (b.action === "consume") {
      if (limited("qs|" + adid, 120, 3600000) || limited("qi|" + req.ip, 600, 3600000)) return res.json(counts(adid));
      qInc.run(adid, day());
    }
    return res.json(counts(adid));
  }, jsonErr);

  // ---------- public style lookup ----------
  web.get("/app/v1/style", base, (req, res) => {
    if (limited("st|" + req.ip, 300, 600000)) return fail(res, 429, "Too many requests.");
    const names = String(req.query.usernames || "").split(",").map(s => s.trim()).filter(s => /^[A-Za-z0-9_.]{3,32}$/.test(s)).slice(0, 50);
    const out = {}, q = db.prepare("SELECT id,username,adid,role,style,badges,premium_until FROM local_users WHERE username=?");
    for (const n of names) { const u = q.get(n); if (u) out[n.toLowerCase()] = { style: styleOf(u), role: roleOf(u), badges: badgesOf(u), sponsor: String(u.sponsor || "") }; }
    return res.json(out);
  });

  // ---------- certificate requests ----------
  // Every request belongs to a signed-in account, so staff see who sent it and the sender sees the answer.
  const TYPES = new Set(["Development", "Testing", "Personal use", "Other"]);
  const reqView = (r) => ({ id: r.id, type: r.type, status: r.status, note: r.note || "", eta_days: r.eta_days == null ? null : r.eta_days,
    udid: r.udid, created_at: r.created_at, updated_at: r.updated_at || null });
  const listMine = db.prepare("SELECT id,type,udid,status,note,eta_days,created_at,updated_at FROM cert_requests WHERE user_id=? ORDER BY id DESC LIMIT 50");
  web.get("/app/v1/certificate-requests", base, needAuth, (req, res) =>
    res.json({ ok: true, requests: listMine.all(req.me.id).map(reqView), premium: premiumOf(req.me) }));
  web.post("/app/v1/certificate-requests", base, jsonBody, needAuth, (req, res) => {
    try {
      const b = req.body || {}, u = req.me, action = String(b.action || "create");
      if (action === "cancel") {
        const r = db.prepare("UPDATE cert_requests SET status='cancelled', updated_at=? WHERE id=? AND user_id=? AND status='pending'")
          .run(new Date().toISOString(), Number(b.id), u.id);
        return r.changes ? res.json({ ok: true }) : fail(res, 404, "No open request to cancel.");
      }
      if (action !== "create") return fail(res, 400, "Unknown action.");
      if (limited("cr|" + u.id, 5, 86400000)) return fail(res, 429, "Too many requests today. Try again tomorrow.");
      const udid = String(b.udid || "").trim().toUpperCase().slice(0, 64);
      if (!/^[A-F0-9-]{20,64}$/.test(udid)) return fail(res, 400, "Enter a valid UDID.");
      const type = TYPES.has(b.certificate_type) ? b.certificate_type : "Other";
      const reason = String(b.reason || "").trim().slice(0, 2000), benefit = String(b.benefit || "").trim().slice(0, 2000);
      if (!reason || !benefit) return fail(res, 400, "Reason and benefit are required.");
      const device = String(b.device_name || "").replace(/[\u0000-\u001f<>]/g, "").trim().slice(0, 60);
      const sent = String(b.mdid || b.adid || "").toUpperCase();
      const adid = u.adid || (ADID_RE.test(sent) ? sent : "");
      if (db.prepare("SELECT COUNT(*) c FROM cert_requests WHERE (user_id=? OR udid=?) AND status='pending'").get(u.id, udid).c)
        return fail(res, 409, "You already have a request waiting for review.");
      const id = db.prepare("INSERT INTO cert_requests(user_id,username,adid,type,reason,udid,benefit,device_name,created_at) VALUES(?,?,?,?,?,?,?,?,?)")
        .run(u.id, u.username, adid, type, reason, udid, benefit, device, new Date().toISOString()).lastInsertRowid;
      return res.json({ ok: true, id: Number(id) });
    } catch (e) { console.warn("Cert request failed:", e.message); return fail(res, 500, "Something went wrong. Please try again."); }
  }, jsonErr);


  // ---------- closed beta builds ----------
  // Builds live on disk outside any public folder. A build is only listed for, and only downloadable by, an ADID that
  // belongs to an account in the "beta" group (or staff). A build can also carry its own ADID allow-list.
  const BETA_DIR = process.env.BETA_DIR || path.join(__dirname, "..", "data", "beta-builds");
  try { fs.mkdirSync(BETA_DIR, { recursive: true }); } catch (e) { console.warn("Beta dir:", e.message); }
  const BETA_IPA_MAX = (Number(process.env.NEWS_IPA_MAX_GB) || 4) * 1e9;
  db.exec(`CREATE TABLE IF NOT EXISTS beta_builds(
    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, bundle_id TEXT NOT NULL, version TEXT NOT NULL, subtitle TEXT, description TEXT,
    icon_url TEXT, tint TEXT, ipa_file TEXT, ipa_size INTEGER NOT NULL DEFAULT 0, adids TEXT, created_at TEXT NOT NULL, hidden INTEGER NOT NULL DEFAULT 0)`);
  const BETA_FILE_RE = /^[a-f0-9]{24}\.ipa$/;
  const BETA_GROUPS = ["beta", "admin", "co_admin", "staff", "founder"];
  const betaSig = (id, adid) => crypto.createHmac("sha256", String(key)).update("beta|" + id + "|" + adid).digest("hex").slice(0, 32);
  function betaUser(adid) { // the account that owns this ADID, if it may use beta builds
    if (!ADID_RE.test(adid || "")) return null;
    const u = byAdid.get(adid);
    if (!u || u.banned) return null;
    return roleOf(u) === "admin" || badgesOf(u).some(g => BETA_GROUPS.includes(g)) ? u : null;
  }
  const betaAdids = (r) => { try { const a = JSON.parse(r.adids || "[]"); return Array.isArray(a) ? a.map(x => String(x).toUpperCase()) : []; } catch { return []; } };
  const betaOpen = (r, adid) => { const l = betaAdids(r); return !l.length || l.includes(adid); };
  function betaApps(adid, baseUrl) { // AltStore-format entries for this ADID ([] when it isn't allowed)
    adid = String(adid || "").trim().toUpperCase();
    if (!betaUser(adid)) return [];
    return db.prepare("SELECT * FROM beta_builds WHERE hidden=0 AND ipa_file<>'' ORDER BY id DESC").all().filter(r => betaOpen(r, adid)).map(r => {
      const url = `${baseUrl}/app/v1/beta/dl/${r.id}/${adid}/${betaSig(r.id, adid)}`;
      const date = new Date(r.created_at).toISOString();
      return {
        name: r.name, bundleIdentifier: r.bundle_id, developerName: "AirShare Beta", subtitle: r.subtitle || "Closed beta",
        localizedDescription: r.description || "", iconURL: r.icon_url || undefined, tintColor: r.tint || undefined, beta: true,
        version: r.version, versionDate: date, size: r.ipa_size || undefined, downloadURL: url, screenshotURLs: [],
        versions: [{ version: r.version, date, size: r.ipa_size || undefined, downloadURL: url, localizedDescription: r.description || undefined }],
      };
    });
  }
  if (c.acct) c.acct.beta = { appsFor: betaApps };
  const siteBase = (req) => (process.env.SITE_URL || process.env.BASE_URL || (req.protocol + "://" + req.get("host"))).replace(/\/$/, "");
  const BETA_BAD = "Invalid ADID. This build is only available to closed-beta testers.";

  web.get("/app/v1/beta", (req, res) => { // the iOS app also gets these inside /air.json?adid=
    res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });
    return res.json({ ok: true, apps: betaApps(req.query.adid || req.query.mdid, siteBase(req)) });
  });
  // A beta build of the app polls this. "revoked" (banned, or taken out of the beta group) tells it to remove itself;
  // "unknown" (no account owns this ADID) and any network failure never do anything.
  web.get("/app/v1/beta/status", (req, res) => {
    res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });
    const adid = String(req.query.adid || req.query.mdid || "").trim().toUpperCase();
    if (!ADID_RE.test(adid) || limited("betast|" + adid, 120, 3600000)) return res.json({ ok: true, status: "unknown" });
    const u = byAdid.get(adid);
    if (!u) return res.json({ ok: true, status: "unknown" });
    if (isBanned(u)) { const bi = banInfo(u); return res.json({ ok: true, status: "revoked", reason: "banned", ban_reason: bi.reason, ban_until: bi.until }); }
    return res.json({ ok: true, status: betaUser(adid) ? "ok" : "revoked", reason: betaUser(adid) ? "" : "removed" });
  });
  web.get("/app/v1/beta/dl/:id/:adid/:sig", (req, res) => {
    res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });
    const adid = String(req.params.adid || "").toUpperCase(), id = parseInt(req.params.id, 10) || 0;
    if (limited("betadl|" + req.ip, 600, 900000)) return fail(res, 429, "Too many requests. Try again in a few minutes.");
    const sig = Buffer.from(String(req.params.sig || "")), want = Buffer.from(betaSig(id, adid));
    const r = db.prepare("SELECT * FROM beta_builds WHERE id=? AND hidden=0").get(id);
    // Same answer for every failure, so nothing leaks about which builds exist.
    if (!r || !r.ipa_file || sig.length !== want.length || !crypto.timingSafeEqual(sig, want) || !betaUser(adid) || !betaOpen(r, adid)) return fail(res, 403, BETA_BAD);
    const file = path.join(BETA_DIR, r.ipa_file);
    if (!BETA_FILE_RE.test(r.ipa_file) || !fs.existsSync(file)) return fail(res, 404, "Build file is missing.");
    const nm = String(r.name).replace(/[^A-Za-z0-9._ -]+/g, "_").trim().slice(0, 60) || "app";
    return res.sendFile(file, { headers: { "Content-Type": "application/octet-stream", "Content-Disposition": `attachment; filename="${nm}-${String(r.version).replace(/[^0-9A-Za-z._-]/g, "")}.ipa"`, "X-Content-Type-Options": "nosniff" }, dotfiles: "deny", cacheControl: false });
  });

  // ---------- admin (Basic auth, same credentials as /analytics) ----------
  const aj = express.json({ limit: "8kb", type: "application/json" });
  web.get("/admin/app/data", auth, (_req, res) => {
    res.set("Cache-Control", "no-store");
    const users = db.prepare("SELECT id,username,email,adid,role,badges,sponsor,premium_until,banned,banned_reason,banned_until,created_at,last_login FROM local_users ORDER BY id DESC LIMIT 500").all()
      .map(u => ({ id: u.id, username: u.username, adid: u.adid, created_at: u.created_at, last_login: u.last_login,
        email: /@accounts\.invalid$/.test(u.email) ? "" : u.email, role: roleOf(u), groups: storedBadges(u), sponsor: String(u.sponsor || ""), premium: premiumOf(u), ban: banInfo(u) }));
    const sender = db.prepare("SELECT id,username,adid,role,badges,premium_until,created_at FROM local_users WHERE id=?");
    const requests = db.prepare(PERKS.priorityReview
      ? "SELECT * FROM cert_requests ORDER BY (status='pending') DESC, (status='pending' AND COALESCE((SELECT premium_until FROM local_users WHERE id=cert_requests.user_id),'') > ?) DESC, id DESC LIMIT 200"
      : "SELECT * FROM cert_requests ORDER BY (status='pending') DESC, id DESC LIMIT ?").all(PERKS.priorityReview ? new Date().toISOString() : 200).map(r => {
      const u = r.user_id ? sender.get(r.user_id) : null;
      return { ...r, sender: u ? { id: u.id, username: u.username, adid: u.adid || "", role: roleOf(u), groups: storedBadges(u), premium: premiumOf(u), joined: u.created_at } : null };
    });
    res.json({ users, groups: GROUPS, requests, bannedAdids: db.prepare("SELECT * FROM banned_adids ORDER BY banned_at DESC LIMIT 200").all(), appeals: listAppeals() });
  });
  web.get("/admin/app/correlate/:id", auth, (req, res) => {
    res.set("Cache-Control", "no-store");
    const id = Number(req.params.id);
    if (!Number.isInteger(id) || !byId.get(id)) return fail(res, 404, "Not found.");
    return res.json({ ok: true, others: correlate(id) });
  });
  web.post("/admin/app/ban-device", auth, aj, (req, res) => {
    const b = req.body || {};
    const r = setAdidBanned(b.adid, !!b.banned, b.reason, b.days);
    return r === null ? fail(res, 400, "Bad ADID.") : res.json({ ok: true, ban: r });
  });
  web.post("/admin/app/groups", auth, aj, (req, res) => {
    const b = req.body || {}, id = Number(b.user_id);
    if (!Number.isInteger(id) || !byId.get(id)) return fail(res, 404, "Not found.");
    const g = cleanGroups(b.groups);
    setGroupsQ.run(JSON.stringify(g), id);
    return res.json({ ok: true, groups: g });
  });
  web.post("/admin/app/sponsor", auth, aj, (req, res) => {
    const b = req.body || {}, id = Number(b.user_id);
    if (!Number.isInteger(id) || !byId.get(id)) return fail(res, 404, "Not found.");
    const sp = cleanSponsor(b.sponsor);
    setSponsorQ.run(sp, id);
    return res.json({ ok: true, sponsor: sp });
  });
  web.post("/admin/app/role", auth, aj, (req, res) => {
    const b = req.body || {}, id = Number(b.id), role = String(b.role || "");
    if (!Number.isInteger(id) || !ROLES.includes(role)) return fail(res, 400, "Bad request.");
    return db.prepare("UPDATE local_users SET role=? WHERE id=?").run(role, id).changes ? res.json({ ok: true }) : fail(res, 404, "Not found.");
  });
  web.post("/admin/app/request", auth, aj, (req, res) => {
    const b = req.body || {}, id = Number(b.id), st = String(b.status || "");
    if (!Number.isInteger(id) || !["pending", "approved", "denied", "done"].includes(st)) return fail(res, 400, "Bad request.");
    const eta = b.eta_days === "" || b.eta_days == null ? null : Math.min(365, Math.max(0, Math.floor(Number(b.eta_days)) || 0)) || null;
    const r = db.prepare("UPDATE cert_requests SET status=?, note=?, eta_days=?, reviewed_by=?, updated_at=? WHERE id=?")
      .run(st, String(b.note || "").replace(/[\u0000-\u001f<>]/g, " ").slice(0, 500), eta, "admin", new Date().toISOString(), id);
    return r.changes ? res.json({ ok: true }) : fail(res, 404, "Not found.");
  });
  web.post("/admin/app/ban", auth, aj, (req, res) => {
    const b = req.body || {};
    const r = setBanned(b.user_id, !!b.banned, b.reason, b.days);
    return r === null ? fail(res, 404, "Not found.") : res.json({ ok: true, ban: r });
  });
  web.post("/admin/app/appeal-review", auth, aj, (req, res) => {
    const b = req.body || {}, r = reviewAppeal(b.id, b.note, !!b.unban);
    return r === null ? fail(res, 404, "Not found.") : res.json({ ok: true, appeals: listAppeals() });
  });
  web.post("/admin/app/premium", auth, aj, (req, res) => {
    const b = req.body || {}, mode = String(b.mode || "add");
    if (!["add", "set", "revoke"].includes(mode)) return fail(res, 400, "Bad request.");
    const p = setPremium(Number(b.user_id), mode, b.days);
    return p ? res.json({ ok: true, premium: p }) : fail(res, 404, "Not found.");
  });

  // Beta builds: list / upload the IPA / save / delete.
  web.get("/admin/app/beta", auth, (_req, res) => {
    res.set("Cache-Control", "no-store");
    res.json({ ok: true, builds: db.prepare("SELECT * FROM beta_builds ORDER BY id DESC").all().map(r => ({ ...r, adids: betaAdids(r), has_file: !!r.ipa_file })) });
  });
  web.put("/admin/app/beta/upload", auth, (req, res) => {
    res.set("Cache-Control", "no-store");
    const bad = (code, error) => res.status(code).json({ ok: false, error });
    if (req.get("x-admin") !== "1") return bad(403, "Bad request.");
    if (Number(req.get("content-length") || 0) > BETA_IPA_MAX) return bad(413, "File too large.");
    const tmp = path.join(BETA_DIR, ".up-" + crypto.randomBytes(8).toString("hex"));
    const out = fs.createWriteStream(tmp);
    let got = 0, dead = false;
    const drop = (code, msg) => { if (dead) return; dead = true; req.unpipe(out); out.destroy(); fs.rm(tmp, { force: true }, () => {}); if (!res.headersSent) bad(code, msg); req.resume(); };
    req.on("data", (ch) => { got += ch.length; if (got > BETA_IPA_MAX) drop(413, "File too large."); });
    req.on("aborted", () => drop(499, "Upload cancelled."));
    out.on("error", () => drop(500, "Could not save the file."));
    out.on("finish", () => {
      if (dead) return;
      try {
        const fd = fs.openSync(tmp, "r"), h4 = Buffer.alloc(4); fs.readSync(fd, h4, 0, 4, 0); fs.closeSync(fd);
        if (!got || !(h4[0] === 0x50 && h4[1] === 0x4b && h4[2] === 3 && h4[3] === 4)) { fs.rmSync(tmp, { force: true }); return bad(400, "That isn't an IPA file."); }
        const name = crypto.randomBytes(12).toString("hex") + ".ipa";
        fs.renameSync(tmp, path.join(BETA_DIR, name));
        return res.json({ ok: true, name, size: got });
      } catch { fs.rmSync(tmp, { force: true }); return bad(500, "Could not save the file."); }
    });
    req.pipe(out);
  });
  const betaPrune = () => {
    try {
      const keep = new Set(db.prepare("SELECT ipa_file f FROM beta_builds").all().map(r => r.f));
      for (const n of fs.readdirSync(BETA_DIR)) { const f = path.join(BETA_DIR, n); if (!keep.has(n) && Date.now() - fs.statSync(f).mtimeMs > 3600000) fs.rmSync(f, { force: true }); }
    } catch { /* best effort */ }
  };
  web.post("/admin/app/beta/save", auth, aj, (req, res) => {
    const b = req.body || {}, id = Number(b.id) || 0;
    const txt = (v, n) => String(v == null ? "" : v).replace(/[\u0000-\u001f<>]/g, " ").trim().slice(0, n);
    const name = txt(b.name, 60), bundle = txt(b.bundle_id, 120), version = String(b.version || "").replace(/[^0-9A-Za-z._-]/g, "").slice(0, 30);
    if (!name || !/^[A-Za-z0-9.-]{3,120}$/.test(bundle) || !version) return fail(res, 400, "Name, bundle ID and version are required.");
    const adids = Array.from(new Set((Array.isArray(b.adids) ? b.adids : String(b.adids || "").split(/[\s,]+/)).map(x => String(x).trim().toUpperCase()).filter(Boolean)));
    if (adids.some(a => !ADID_RE.test(a))) return fail(res, 400, "Every ADID must look like AS-XXXXXX-XX.");
    const icon = /^https:\/\/[^\s"'<>]{4,400}$/.test(String(b.icon_url || "")) ? String(b.icon_url) : "";
    const tint = /^#?[0-9a-f]{6}$/i.test(String(b.tint || "")) ? String(b.tint).replace("#", "") : "";
    const old = id ? db.prepare("SELECT ipa_file,ipa_size FROM beta_builds WHERE id=?").get(id) : null;
    if (id && !old) return fail(res, 404, "Not found.");
    let file = old ? old.ipa_file : "", size = old ? old.ipa_size : 0;
    if (b.ipa_file) {
      if (!BETA_FILE_RE.test(String(b.ipa_file)) || !fs.existsSync(path.join(BETA_DIR, b.ipa_file))) return fail(res, 400, "Upload the IPA again.");
      file = b.ipa_file; size = fs.statSync(path.join(BETA_DIR, file)).size;
    }
    const vals = [name, bundle, version, txt(b.subtitle, 80), txt(b.description, 1500), icon, tint, file, size, JSON.stringify(adids), b.hidden ? 1 : 0];
    if (id) db.prepare("UPDATE beta_builds SET name=?,bundle_id=?,version=?,subtitle=?,description=?,icon_url=?,tint=?,ipa_file=?,ipa_size=?,adids=?,hidden=? WHERE id=?").run(...vals, id);
    else db.prepare("INSERT INTO beta_builds(name,bundle_id,version,subtitle,description,icon_url,tint,ipa_file,ipa_size,adids,hidden,created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)").run(...vals, new Date().toISOString());
    betaPrune();
    return res.json({ ok: true });
  });
  web.post("/admin/app/beta/delete", auth, aj, (req, res) => {
    const r = db.prepare("DELETE FROM beta_builds WHERE id=?").run(Number((req.body || {}).id) || 0);
    betaPrune();
    return r.changes ? res.json({ ok: true }) : fail(res, 404, "Not found.");
  });
  web.get("/admin/app", auth, (_req, res) => {
    res.set({ "Cache-Control": "no-store", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'" });
    res.type("html").send(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><meta name="color-scheme" content="dark"><title>App admin</title>
<style>body{margin:0;background:#0b0b0b;color:#eee;font:15px/1.4 -apple-system,system-ui,sans-serif;padding:16px}h1{font-size:20px}h2{font-size:13px;letter-spacing:1px;color:#9a9a9a;margin:22px 0 8px}
.row{border:1px solid #292929;border-radius:12px;padding:10px 12px;margin:8px 0;background:#121212}.row b{color:#ff3b14}.m{color:#888;font-size:12px;word-break:break-all}
select,button{background:#1b1b1b;color:#eee;border:1px solid #333;border-radius:9px;padding:7px 10px;font-size:14px;margin:6px 6px 0 0}button.ok{border-color:#2f8f4a}button.no{border-color:#7a2318}
.tag{font-size:11px;border:1px solid #444;border-radius:99px;padding:1px 8px;color:#bbb}.tag.ban{border-color:#7a2318;color:#ff6b57}input{background:#1b1b1b;color:#eee;border:1px solid #333;border-radius:9px;padding:8px 10px;font-size:14px;margin:6px 6px 0 0}.chip{border-radius:99px;padding:5px 11px;font-size:13px}.chip.on{border-color:#ff9a1f;color:#ff9a1f}</style></head><body>
<h1>App admin</h1><h2>BETA BUILDS (only ADIDs in the beta group can list or download)</h2><div id="bb"></div>
<div class="row"><b id="bft">Add a build</b><input id="bn" placeholder="Name" style="width:46%"><input id="bi" placeholder="Bundle ID" style="width:46%"><input id="bv" placeholder="Version" style="width:30%"><input id="bs" placeholder="Subtitle" style="width:62%"><input id="bc" placeholder="Icon URL (https, optional)" style="width:100%;box-sizing:border-box"><textarea id="bd" placeholder="Description / what to test" style="width:100%;box-sizing:border-box;min-height:70px;background:#1b1b1b;color:#eee;border:1px solid #333;border-radius:9px;padding:8px;margin-top:6px"></textarea><textarea id="ba" placeholder="Only these ADIDs (one per line, AS-XXXXXX-XX). Leave empty for every beta member." style="width:100%;box-sizing:border-box;min-height:56px;background:#1b1b1b;color:#eee;border:1px solid #333;border-radius:9px;padding:8px;margin-top:6px"></textarea><div class="m" style="margin-top:6px">IPA: <input id="bf" type="file" accept=".ipa" style="margin:0"></div><div class="m" id="bm"></div><button class="ok" onclick="bsave()">Save build</button><button onclick="breset()">Clear</button></div>
<h2>CERTIFICATE REQUESTS</h2><div id="rq">Loading…</div>
<h2>ACCOUNTS, GROUPS &amp; SPONSORS</h2><input id="q" placeholder="Search username, ADID or sponsor" oninput="draw()" style="width:100%;box-sizing:border-box"><div id="us"></div>
<h2>BAN APPEALS</h2><div id="ap_list"></div>
<h2>BANNED DEVICES (ADID banned outright, even on a new account)</h2><div id="bd_list"></div>
<div class="row"><input id="bdadid" placeholder="AS-XXXXXX-XX" style="width:170px" autocapitalize="off"><input id="bdreason" placeholder="Reason (optional)" style="width:46%"><input id="bddays" type="number" min="0" max="3650" placeholder="Days (blank = forever)" style="width:170px"><button class="no" onclick="bdban()">Ban device</button></div>
<h2>CORRELATION</h2><div class="row"><input id="corid" type="number" placeholder="User ID (u#)" style="width:150px"><button onclick="corload()">Show other accounts on the same device / network</button><div id="cor" class="m" style="margin-top:8px"></div></div>
<script>
var D={users:[],groups:[],requests:[]};
var TITLE={admin:'ADMIN',co_admin:'CO-ADMIN',staff:'STAFF',dev:'DEV',verified:'VERIFIED',sponsor:'SPONSOR',supporter:'SUPPORTER',og:'OG',top_signer:'TOP SIGNER',founder:'FOUNDER',beta:'BETA'};
function e(s){return String(s==null?'':s).replace(/[&<>"']/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]});}
function post(u,o){return fetch(u,{method:'POST',credentials:'same-origin',headers:{'content-type':'application/json'},body:JSON.stringify(o)}).then(function(r){return r.json()});}
function ck(j){if(!j.ok)alert(j.error||'Failed');return j;}
function pm(p){return p&&p.active?'PREMIUM · '+p.days_left+'d left':'no premium';}
function bm(b){if(!b||!b.banned)return'';return 'BANNED'+(b.reason?' — '+b.reason:'')+(b.until?' (until '+b.until.slice(0,10)+')':' (permanent)');}
function rqRow(r){var u=r.sender,who=u?'<b>'+e(u.username)+'</b> <span class="tag">'+e(u.role)+'</span> <span class="m">u'+u.id+' · joined '+e((u.joined||'').slice(0,10))+' · '+e(pm(u.premium))+'</span>':'<b>guest</b> <span class="m">(sent without an account)</span>';
 var btn=['approved','denied','done','pending'].map(function(x){return '<button class="'+(x==='approved'?'ok':x==='denied'?'no':'')+'" data-s="'+x+'" onclick="st('+r.id+',this.dataset.s)">'+x+'</button>'}).join('');
 var prem=u?'<div class="m" style="margin-top:8px">PREMIUM FOR '+e(u.username).toUpperCase()+'</div>'+[7,30,90,365].map(function(n){return '<button onclick="pr('+u.id+',\\'add\\','+n+')">+'+n+'d</button>'}).join('')+'<button class="no" onclick="pr('+u.id+',\\'revoke\\',0)">Remove</button>':'';
 return '<div class="row"><b>'+e(r.type)+'</b> <span class="tag">'+e(r.status)+'</span> <span class="m">#'+r.id+' · '+e(r.created_at)+'</span><div style="margin-top:4px">'+who+'</div>'
  +'<div class="m">Device '+e(r.device_name||'unknown')+' · UDID '+e(r.udid)+' · ADID '+e(r.adid||'none')+'</div><p>'+e(r.reason)+'</p><div class="m">'+e(r.benefit)+'</div>'
  +'<input id="eta'+r.id+'" type="number" min="1" max="365" placeholder="Days to wait" value="'+e(r.eta_days||'')+'" style="width:120px"><input id="nt'+r.id+'" maxlength="500" placeholder="Note shown to the user" value="'+e(r.note||'')+'" style="width:60%">'
  +'<div>'+btn+'</div>'+prem+'</div>';}
function pr(id,mode,n){post('/admin/app/premium',{user_id:id,mode:mode,days:n}).then(ck).then(function(j){if(j.ok)load();});}
function prc(id){var n=parseInt(document.getElementById('pd'+id).value,10)||0;pr(id,'add',n);}
function prs(id){var n=parseInt(document.getElementById('pd'+id).value,10)||0;pr(id,'set',n);}
function load(){fetch('/admin/app/data',{credentials:'same-origin'}).then(function(r){return r.json()}).then(function(d){D=d;
 document.getElementById('rq').innerHTML=d.requests.map(rqRow).join('')||'<p class="m">No requests.</p>';
 window.AP=d.appeals||[];apdraw();
 draw();});}
function apRow(a){return '<div class="row"><b>'+e(a.username)+'</b> <span class="m">u'+a.user_id+' · '+e((a.created_at||'').slice(0,16).replace('T',' '))+'</span> '
 +(a.status==='pending'?'<span class="tag" style="border-color:#ff9a1f;color:#ff9a1f">PENDING</span>':'<span class="tag">reviewed</span>')
 +(a.currently_banned?' <span class="tag ban">'+e(bm({banned:true,reason:a.ban_reason,until:a.ban_until}))+'</span>':' <span class="m">no longer banned</span>')
 +'<p>'+e(a.message)+'</p>'+(a.admin_note?'<div class="m">Admin note: '+e(a.admin_note)+'</div>':'')
 +(a.status==='pending'?('<input id="apn'+a.id+'" placeholder="Note (optional)" style="width:60%"><button class="ok" onclick="apreview('+a.id+',false)">Mark reviewed</button>'
   +(a.currently_banned?'<button class="no" onclick="apreview('+a.id+',true)">Unban &amp; mark reviewed</button>':''))
   :'<div class="m">Reviewed '+e((a.reviewed_at||'').slice(0,16).replace('T',' '))+'</div>')
 +'</div>';}
function apreview(id,unban){var n=document.getElementById('apn'+id);post('/admin/app/appeal-review',{id:id,note:n?n.value:'',unban:unban}).then(ck).then(function(j){if(j.ok){window.AP=j.appeals;apdraw();load();}});}
function apdraw(){var list=window.AP||[];document.getElementById('ap_list').innerHTML=list.map(apRow).join('')||'<p class="m">No appeals.</p>';}
function draw(){var q=(document.getElementById('q').value||'').toLowerCase();
 document.getElementById('us').innerHTML=D.users.filter(function(u){return !q||(u.username+' '+(u.adid||'')+' '+(u.sponsor||'')).toLowerCase().indexOf(q)>=0}).map(function(u){
  var chips=D.groups.map(function(g){var on=u.groups.indexOf(g)>=0;return '<button class="chip'+(on?' on':'')+'" onclick="tg('+u.id+',\\''+g+'\\')">'+(on?'✓ ':'')+e(TITLE[g]||g)+'</button>'}).join('');
  return '<div class="row"><b>'+e(u.username)+'</b> <span class="m">u'+u.id+' · '+e(u.adid||'no ADID')+'</span><br>'
  +'<select onchange="rl('+u.id+',this.value)">'+['member','developer','admin'].map(function(r){return '<option'+(r===u.role?' selected':'')+'>'+r+'</option>'}).join('')+'</select>'
  +'<div class="m" style="margin-top:8px">PREMIUM · '+e(pm(u.premium))+(u.premium&&u.premium.active?' (until '+e(u.premium.expires.slice(0,10))+')':'')+'</div><input id="pd'+u.id+'" type="number" min="0" max="3650" placeholder="Days" style="width:90px"><button class="ok" onclick="prc('+u.id+')">Add days</button><button onclick="prs('+u.id+')">Set to</button><button class="no" onclick="pr('+u.id+',\\'revoke\\',0)">Remove</button>'
  +'<div class="m" style="margin-top:8px">GROUPS</div>'+chips
  +'<div class="m" style="margin-top:8px">SPONSOR</div><input id="sp'+u.id+'" maxlength="40" placeholder="e.g. FastDecryptBot" value="'+e(u.sponsor)+'"><button class="ok" onclick="sp('+u.id+')">Save</button><button onclick="spc('+u.id+')">Clear</button>'
  +'<div class="m" style="margin-top:8px">'+(u.ban&&u.ban.banned?'<span class="tag ban">'+e(bm(u.ban))+'</span> <button class="ok" onclick="unban('+u.id+')">Unban</button>':'BAN')+'</div>'
  +(u.ban&&u.ban.banned?'':'<input id="brs'+u.id+'" placeholder="Reason (optional)" style="width:46%"><input id="bdy'+u.id+'" type="number" min="0" max="3650" placeholder="Days (blank = forever)" style="width:170px"><button class="no" onclick="ban('+u.id+')">Ban account</button>')
  +'</div>'}).join('')||'<p class="m">No accounts.</p>';}
function find(id){for(var i=0;i<D.users.length;i++)if(D.users[i].id===id)return D.users[i];}
function tg(id,g){var u=find(id),a=u.groups.slice(),i=a.indexOf(g);if(i>=0)a.splice(i,1);else a.push(g);post('/admin/app/groups',{user_id:id,groups:a}).then(ck).then(function(j){if(j.ok){u.groups=j.groups;draw();}});}
function sp(id){post('/admin/app/sponsor',{user_id:id,sponsor:document.getElementById('sp'+id).value}).then(ck).then(function(j){if(j.ok){find(id).sponsor=j.sponsor;draw();}});}
function spc(id){post('/admin/app/sponsor',{user_id:id,sponsor:''}).then(ck).then(function(j){if(j.ok){find(id).sponsor='';draw();}});}
function st(id,s){var n=document.getElementById('nt'+id).value||'';if(s==='denied'&&!n)n=prompt('Note for the user (optional)')||'';post('/admin/app/request',{id:id,status:s,note:n,eta_days:document.getElementById('eta'+id).value}).then(load);}
function rl(id,r){post('/admin/app/role',{id:id,role:r}).then(function(j){if(!j.ok)alert(j.error);});}
function ban(id){var rs=document.getElementById('brs'+id),dy=document.getElementById('bdy'+id);post('/admin/app/ban',{user_id:id,banned:true,reason:rs?rs.value:'',days:dy?dy.value:''}).then(ck).then(function(j){if(j.ok){find(id).ban=j.ban;draw();}});}
function unban(id){post('/admin/app/ban',{user_id:id,banned:false}).then(ck).then(function(j){if(j.ok){find(id).ban=j.ban;draw();}});}
function bdload(){fetch('/admin/app/data',{credentials:'same-origin'}).then(function(r){return r.json()}).then(function(d){var list=d.bannedAdids||[];document.getElementById('bd_list').innerHTML=list.map(function(r){return '<div class="row"><b>'+e(r.adid)+'</b>'+(r.reason?' <span class="m">'+e(r.reason)+'</span>':'')+(r.banned_until?' <span class="tag">until '+e(r.banned_until.slice(0,10))+'</span>':' <span class="tag ban">permanent</span>')+' <button class="ok" onclick="bdunban(\\'' + r.adid + '\\')">Unban</button></div>';}).join('')||'<p class="m">No banned devices.</p>';});}
function bdban(){var a=(document.getElementById('bdadid').value||'').trim().toUpperCase();if(!a)return;post('/admin/app/ban-device',{adid:a,banned:true,reason:document.getElementById('bdreason').value,days:document.getElementById('bddays').value}).then(ck).then(function(j){if(j.ok){document.getElementById('bdadid').value='';document.getElementById('bdreason').value='';document.getElementById('bddays').value='';bdload();}});}
function bdunban(a){post('/admin/app/ban-device',{adid:a,banned:false}).then(ck).then(bdload);}
function corload(){var id=parseInt(document.getElementById('corid').value,10);if(!id)return;fetch('/admin/app/correlate/'+id,{credentials:'same-origin'}).then(function(r){return r.json();}).then(function(j){var el=document.getElementById('cor');if(!j.ok){el.textContent=j.error||'Failed';return;}if(!j.others.length){el.textContent='No other accounts found on the same device or network.';return;}el.innerHTML=j.others.map(function(o){return '<div>u'+o.id+' <b>'+e(o.username)+'</b>'+(o.banned?' <span class="tag ban">BANNED</span>':'')+' <span class="m">via '+o.via.map(e).join(', ')+'</span></div>';}).join('');});}

var BE=null;
function bload(){fetch("/admin/app/beta",{credentials:"same-origin"}).then(function(r){return r.json()}).then(function(j){var h="";(j.builds||[]).forEach(function(b){h+="<div class='row'><b>"+e(b.name)+"</b> <span class='tag'>"+e(b.version)+"</span> "+(b.hidden?"<span class='tag'>hidden</span> ":"")+"<span class='m'>"+e(b.bundle_id)+" · "+(b.has_file?(b.ipa_size/1e6).toFixed(1)+" MB":"no IPA")+" · "+(b.adids.length?b.adids.length+" ADID(s)":"all beta members")+"</span><br><button onclick='bedit("+b.id+")'>Edit</button><button class='no' onclick='bdel("+b.id+")'>Delete</button></div>";});document.getElementById("bb").innerHTML=h||"<div class='m'>No beta builds yet.</div>";window.BL=j.builds||[];});}
function breset(){BE=null;["bn","bi","bv","bs","bc","bd","ba"].forEach(function(i){document.getElementById(i).value="";});document.getElementById("bf").value="";document.getElementById("bft").textContent="Add a build";document.getElementById("bm").textContent="";}
function bedit(id){var b=window.BL.filter(function(x){return x.id===id})[0];if(!b)return;BE=id;document.getElementById("bn").value=b.name;document.getElementById("bi").value=b.bundle_id;document.getElementById("bv").value=b.version;document.getElementById("bs").value=b.subtitle||"";document.getElementById("bc").value=b.icon_url||"";document.getElementById("bd").value=b.description||"";document.getElementById("ba").value=b.adids.join("\\n");document.getElementById("bft").textContent="Edit "+b.name+" (choose an IPA only to replace it)";window.scrollTo(0,0);}
function bdel(id){if(confirm("Delete this beta build?"))post("/admin/app/beta/delete",{id:id}).then(ck).then(bload);}
function bsave(){var f=document.getElementById("bf").files[0],m=document.getElementById("bm");
 function go(name){post("/admin/app/beta/save",{id:BE,name:document.getElementById("bn").value,bundle_id:document.getElementById("bi").value,version:document.getElementById("bv").value,subtitle:document.getElementById("bs").value,icon_url:document.getElementById("bc").value,description:document.getElementById("bd").value,adids:document.getElementById("ba").value,ipa_file:name||""}).then(ck).then(function(j){if(j.ok){breset();bload();m.textContent="Saved.";}});}
 if(!f){go("");return;}
 var x=new XMLHttpRequest();x.open("PUT","/admin/app/beta/upload");x.setRequestHeader("x-admin","1");x.setRequestHeader("content-type","application/octet-stream");
 x.upload.onprogress=function(ev){if(ev.lengthComputable)m.textContent="Uploading "+Math.round(ev.loaded/ev.total*100)+"%";};
 x.onload=function(){var j;try{j=JSON.parse(x.responseText)}catch(er){m.textContent="Upload failed";return;}if(j.ok){m.textContent="Saving...";go(j.name);}else m.textContent=j.error||"Upload failed";};
 x.onerror=function(){m.textContent="Network error";};x.send(f);}
bload();
load();
bdload();
</script></body></html>`);
  });

  // Litecoin payments for premium days (see payments.js and ltc-hd.js). Stays off unless LTC_XPUB (an extended PUBLIC key) is set.
  try { require("./payments").mount(web, { db, express, base, jsonBody, jsonErr, needAuth, fail, limited, setPremium, auth,
    describePerks: () => PERKS.describe({ memberLimit: DEC.member, cooldownMin: Math.round(DEC_APP_COOLDOWN_MS / 60000) }) }); }
  catch (e) { console.warn("Payments disabled:", e.message); }
  // Priority support tickets and "early look" posts (Premium sees early posts first).
  const canSeeEarly = (u) => premiumOf(u).active || roleOf(u) !== "member" || storedBadges(u).some(g => ["admin", "co_admin", "staff", "founder", "dev"].includes(g));
  try { require("./support").mount(web, { db, express, base, jsonBody, jsonErr, needAuth, fail, limited, auth, isPremiumUser: (u) => premiumOf(u).active, priorityOn: PERKS.prioritySupport }); }
  catch (e) { console.warn("Support disabled:", e.message); }
  try { require("./early").mount(web, { db, express, base, needAuth, auth, canSeeEarly, earlyOn: PERKS.earlyLooks }); }
  catch (e) { console.warn("Early looks disabled:", e.message); }

  // Used by site.js actorId(): lets the iOS app reuse the website's decrypt / search / download routes.
  // Bearer token -> the account ("u<id>", same owner as the website session); otherwise the device ADID header -> a guest actor.
  return function identify(req) {
    const h = String(req.get("authorization") || "");
    if (h.startsWith("Bearer ")) { const u = userFromToken(h.slice(7).trim()); if (u) return "u" + u.id; }
    const adid = String(req.get("x-as-adid") || "").trim().toUpperCase();
    return ADID_RE.test(adid) ? "d" + adid : null;
  };
}

module.exports = { mount };
