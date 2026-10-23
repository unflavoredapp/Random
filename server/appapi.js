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

const ADID_RE = /^(AS|MS)-[A-Z0-9]{6}-[A-Z0-9]{2}$/;
const NAME_RE = /^[A-Za-z0-9_]{3,20}$/;
const EMAIL_RE = /^[^\s@]{1,64}@[^\s@.]+(?:\.[^\s@.]+)+$/;
const RESERVED = new Set(["admin", "administrator", "root", "system", "support", "staff", "moderator", "airshare", "owner"]);
const ROLES = ["member", "developer", "admin"];
// Groups an admin can put a user in. They are shown as badges next to the username in the app and on the site.
const GROUPS = ["admin", "co_admin", "staff", "dev", "verified", "sponsor", "supporter", "og", "top_signer", "founder"];
const TOKEN_MS = 180 * 86400000;
const csv = (v) => new Set(String(v || "").split(",").map(x => x.trim().toLowerCase()).filter(Boolean));

function mount(web, c) {
  const { db, express, hashPw, checkPw, limited, key, auth, esc } = c;
  const APP_ADMINS = csv(process.env.APP_ADMINS), APP_DEVS = csv(process.env.APP_DEVS);

  // ---------- schema ----------
  for (const col of ["adid TEXT", "role TEXT NOT NULL DEFAULT 'member'", "style TEXT", "badges TEXT", "tv INTEGER NOT NULL DEFAULT 0", "sponsor TEXT", "premium_until TEXT"]) {
    try { db.exec("ALTER TABLE local_users ADD COLUMN " + col); } catch { /* already there */ }
  }
  try { db.exec("CREATE UNIQUE INDEX IF NOT EXISTS idx_local_users_adid ON local_users(adid) WHERE adid IS NOT NULL"); } catch (e) { console.warn("adid index:", e.message); }
  db.exec(`CREATE TABLE IF NOT EXISTS app_signs(adid TEXT NOT NULL, day TEXT NOT NULL, n INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(adid, day));
    CREATE TABLE IF NOT EXISTS cert_requests(
      id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER, username TEXT, adid TEXT, type TEXT, reason TEXT, udid TEXT, benefit TEXT,
      status TEXT NOT NULL DEFAULT 'pending', note TEXT, created_at TEXT NOT NULL, updated_at TEXT);
    CREATE INDEX IF NOT EXISTS cert_requests_user ON cert_requests(user_id);
    CREATE TABLE IF NOT EXISTS app_devices(adid TEXT PRIMARY KEY, user_id INTEGER NOT NULL, key_hash TEXT NOT NULL, created_at TEXT NOT NULL, last_used TEXT);
    CREATE INDEX IF NOT EXISTS app_devices_user ON app_devices(user_id);`);
  for (const col of ["device_name TEXT", "eta_days INTEGER", "reviewed_by TEXT"]) {
    try { db.exec("ALTER TABLE cert_requests ADD COLUMN " + col); } catch { /* already there */ }
  }

  const byId = db.prepare("SELECT id,username,email,pass_hash,adid,role,style,badges,tv,sponsor,premium_until,created_at FROM local_users WHERE id=?");
  const byName = db.prepare("SELECT id,username,email,pass_hash,adid,role,style,badges,tv,sponsor,premium_until,created_at FROM local_users WHERE username=? OR email=?");
  const byAdid = db.prepare("SELECT id,username,adid,role,badges FROM local_users WHERE adid=?");
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
    return u && (u.tv || 0) === Number(p[2]) ? u : null;
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
    return Array.from(new Set(b));
  }
  function styleOf(u) { try { const s = JSON.parse(u.style || "{}"); return s && typeof s === "object" ? s : {}; } catch { return {}; } }
  // Premium is a number of days on the account: it counts down from the moment it is granted, and more days stack on top.
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
  const setGroupsQ = db.prepare("UPDATE local_users SET badges=? WHERE id=?");
  const setSponsorQ = db.prepare("UPDATE local_users SET sponsor=? WHERE id=?");
  const storedBadges = (u) => { try { const b = JSON.parse(u.badges || "[]"); return Array.isArray(b) ? b.filter(x => typeof x === "string") : []; } catch { return []; } };
  // Hand the account tools to site.js -> features.js (the /admin Accounts page): same data the iOS app reads.
  if (c.acct) Object.assign(c.acct, {
    groupCatalog: GROUPS, roleCatalog: ROLES,
    extra: (id) => { const u = byId.get(Number(id)); return u ? { role: roleOf(u), groups: storedBadges(u), sponsor: String(u.sponsor || ""), premium: premiumOf(u) } : {}; },
    setPremium: (id, mode, days) => setPremium(id, String(mode), days),
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
      return { tier: "member", limit: DEC.member };
    }
    if (/^\d+$/.test(String(uid || ""))) return { tier: "member", limit: DEC.member }; // Telegram-login website account
    return { tier: "guest", limit: DEC.guest };
  }
  const qN = db.prepare("SELECT n FROM dec_quota WHERE k=? AND day=?");
  const qUp = db.prepare("INSERT INTO dec_quota(k,day,n) VALUES(?,?,1) ON CONFLICT(k,day) DO UPDATE SET n=n+1");
  const qDown = db.prepare("UPDATE dec_quota SET n=n-1 WHERE k=? AND day=? AND n>0");
  const nOf = (k) => { const r = k ? qN.get(k, day()) : null; return r ? r.n : 0; };
  const nextReset = () => { const d = new Date(); d.setUTCHours(24, 0, 0, 0); return d.toISOString(); };
  function decStatus(uid, ip) {
    const t = decTier(uid), used = nOf(uid || null);
    const ipUsed = t.tier === "guest" ? nOf("ip|" + (ip || "")) : 0;
    if (t.limit == null) return { ok: true, tier: t.tier, limit: null, used, left: null, unlimited: true, resets_at: nextReset() };
    const left = Math.max(0, Math.min(t.limit - used, t.tier === "guest" ? DEC.ipGuest - ipUsed : t.limit));
    return { ok: true, tier: t.tier, limit: t.limit, used, left, unlimited: false, resets_at: nextReset() };
  }
  function decConsume(uid, ip) { // counts one decrypt; { ok:false } when today's allowance is spent
    const st = decStatus(uid, ip);
    if (!st.unlimited && st.left <= 0) return { ...st, ok: false };
    if (uid) qUp.run(uid, day());
    if (st.tier === "guest" && ip) qUp.run("ip|" + ip, day());
    return decStatus(uid, ip);
  }
  function decRefund(uid, ip) { // a decrypt that failed doesn't cost anything
    if (uid) qDown.run(uid, day());
    if (decTier(uid).tier === "guest" && ip) qDown.run("ip|" + ip, day());
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
      const hash = await hashPw(password), now = new Date().toISOString();
      let id;
      try { id = db.prepare("INSERT INTO local_users(username,email,pass_hash,created_at,last_login) VALUES(?,?,?,?,?)").run(username, email, hash, now, now).lastInsertRowid; }
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
      db.prepare("UPDATE local_users SET last_login=? WHERE id=?").run(new Date().toISOString(), row.id);
      const reqAdid = String(b.adid || b.mdid || "").toUpperCase();
      bindAdid(row, reqAdid);
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
      if (!u || u.adid !== adid) return fail(res, 401, "This device isn't recognized. Sign in once.");
      const now = new Date().toISOString();
      db.prepare("UPDATE app_devices SET last_used=? WHERE adid=?").run(now, adid);
      db.prepare("UPDATE local_users SET last_login=? WHERE id=?").run(now, u.id);
      return res.json({ ...profile(u), token: mint(u) });
    } catch (e) { console.warn("App autologin failed:", e.message); return fail(res, 500, "Something went wrong. Please try again."); }
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
    const out = {}, q = db.prepare("SELECT id,username,adid,role,style,badges FROM local_users WHERE username=?");
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

  // ---------- admin (Basic auth, same credentials as /analytics) ----------
  const aj = express.json({ limit: "8kb", type: "application/json" });
  web.get("/admin/app/data", auth, (_req, res) => {
    res.set("Cache-Control", "no-store");
    const users = db.prepare("SELECT id,username,email,adid,role,badges,sponsor,premium_until,created_at,last_login FROM local_users ORDER BY id DESC LIMIT 500").all()
      .map(u => ({ id: u.id, username: u.username, adid: u.adid, created_at: u.created_at, last_login: u.last_login,
        email: /@accounts\.invalid$/.test(u.email) ? "" : u.email, role: roleOf(u), groups: storedBadges(u), sponsor: String(u.sponsor || ""), premium: premiumOf(u) }));
    const sender = db.prepare("SELECT id,username,adid,role,badges,premium_until,created_at FROM local_users WHERE id=?");
    const requests = db.prepare("SELECT * FROM cert_requests ORDER BY (status='pending') DESC, id DESC LIMIT 200").all().map(r => {
      const u = r.user_id ? sender.get(r.user_id) : null;
      return { ...r, sender: u ? { id: u.id, username: u.username, adid: u.adid || "", role: roleOf(u), groups: storedBadges(u), premium: premiumOf(u), joined: u.created_at } : null };
    });
    res.json({ users, groups: GROUPS, requests });
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
  web.post("/admin/app/premium", auth, aj, (req, res) => {
    const b = req.body || {}, mode = String(b.mode || "add");
    if (!["add", "set", "revoke"].includes(mode)) return fail(res, 400, "Bad request.");
    const p = setPremium(Number(b.user_id), mode, b.days);
    return p ? res.json({ ok: true, premium: p }) : fail(res, 404, "Not found.");
  });
  web.get("/admin/app", auth, (_req, res) => {
    res.set({ "Cache-Control": "no-store", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'" });
    res.type("html").send(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><meta name="color-scheme" content="dark"><title>App admin</title>
<style>body{margin:0;background:#0b0b0b;color:#eee;font:15px/1.4 -apple-system,system-ui,sans-serif;padding:16px}h1{font-size:20px}h2{font-size:13px;letter-spacing:1px;color:#9a9a9a;margin:22px 0 8px}
.row{border:1px solid #292929;border-radius:12px;padding:10px 12px;margin:8px 0;background:#121212}.row b{color:#ff3b14}.m{color:#888;font-size:12px;word-break:break-all}
select,button{background:#1b1b1b;color:#eee;border:1px solid #333;border-radius:9px;padding:7px 10px;font-size:14px;margin:6px 6px 0 0}button.ok{border-color:#2f8f4a}button.no{border-color:#7a2318}
.tag{font-size:11px;border:1px solid #444;border-radius:99px;padding:1px 8px;color:#bbb}input{background:#1b1b1b;color:#eee;border:1px solid #333;border-radius:9px;padding:8px 10px;font-size:14px;margin:6px 6px 0 0}.chip{border-radius:99px;padding:5px 11px;font-size:13px}.chip.on{border-color:#ff9a1f;color:#ff9a1f}</style></head><body>
<h1>App admin</h1><h2>CERTIFICATE REQUESTS</h2><div id="rq">Loading…</div>
<h2>ACCOUNTS, GROUPS &amp; SPONSORS</h2><input id="q" placeholder="Search username, ADID or sponsor" oninput="draw()" style="width:100%;box-sizing:border-box"><div id="us"></div>
<script>
var D={users:[],groups:[],requests:[]};
var TITLE={admin:'ADMIN',co_admin:'CO-ADMIN',staff:'STAFF',dev:'DEV',verified:'VERIFIED',sponsor:'SPONSOR',supporter:'SUPPORTER',og:'OG',top_signer:'TOP SIGNER',founder:'FOUNDER'};
function e(s){return String(s==null?'':s).replace(/[&<>"']/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]});}
function post(u,o){return fetch(u,{method:'POST',credentials:'same-origin',headers:{'content-type':'application/json'},body:JSON.stringify(o)}).then(function(r){return r.json()});}
function ck(j){if(!j.ok)alert(j.error||'Failed');return j;}
function pm(p){return p&&p.active?'PREMIUM · '+p.days_left+'d left':'no premium';}
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
 draw();});}
function draw(){var q=(document.getElementById('q').value||'').toLowerCase();
 document.getElementById('us').innerHTML=D.users.filter(function(u){return !q||(u.username+' '+(u.adid||'')+' '+(u.sponsor||'')).toLowerCase().indexOf(q)>=0}).map(function(u){
  var chips=D.groups.map(function(g){var on=u.groups.indexOf(g)>=0;return '<button class="chip'+(on?' on':'')+'" onclick="tg('+u.id+',\\''+g+'\\')">'+(on?'✓ ':'')+e(TITLE[g]||g)+'</button>'}).join('');
  return '<div class="row"><b>'+e(u.username)+'</b> <span class="m">u'+u.id+' · '+e(u.adid||'no ADID')+'</span><br>'
  +'<select onchange="rl('+u.id+',this.value)">'+['member','developer','admin'].map(function(r){return '<option'+(r===u.role?' selected':'')+'>'+r+'</option>'}).join('')+'</select>'
  +'<div class="m" style="margin-top:8px">PREMIUM · '+e(pm(u.premium))+(u.premium&&u.premium.active?' (until '+e(u.premium.expires.slice(0,10))+')':'')+'</div><input id="pd'+u.id+'" type="number" min="0" max="3650" placeholder="Days" style="width:90px"><button class="ok" onclick="prc('+u.id+')">Add days</button><button onclick="prs('+u.id+')">Set to</button><button class="no" onclick="pr('+u.id+',\\'revoke\\',0)">Remove</button>'
  +'<div class="m" style="margin-top:8px">GROUPS</div>'+chips
  +'<div class="m" style="margin-top:8px">SPONSOR</div><input id="sp'+u.id+'" maxlength="40" placeholder="e.g. FastDecryptBot" value="'+e(u.sponsor)+'"><button class="ok" onclick="sp('+u.id+')">Save</button><button onclick="spc('+u.id+')">Clear</button></div>'}).join('')||'<p class="m">No accounts.</p>';}
function find(id){for(var i=0;i<D.users.length;i++)if(D.users[i].id===id)return D.users[i];}
function tg(id,g){var u=find(id),a=u.groups.slice(),i=a.indexOf(g);if(i>=0)a.splice(i,1);else a.push(g);post('/admin/app/groups',{user_id:id,groups:a}).then(ck).then(function(j){if(j.ok){u.groups=j.groups;draw();}});}
function sp(id){post('/admin/app/sponsor',{user_id:id,sponsor:document.getElementById('sp'+id).value}).then(ck).then(function(j){if(j.ok){find(id).sponsor=j.sponsor;draw();}});}
function spc(id){post('/admin/app/sponsor',{user_id:id,sponsor:''}).then(ck).then(function(j){if(j.ok){find(id).sponsor='';draw();}});}
function st(id,s){var n=document.getElementById('nt'+id).value||'';if(s==='denied'&&!n)n=prompt('Note for the user (optional)')||'';post('/admin/app/request',{id:id,status:s,note:n,eta_days:document.getElementById('eta'+id).value}).then(load);}
function rl(id,r){post('/admin/app/role',{id:id,role:r}).then(function(j){if(!j.ok)alert(j.error);});}
load();
</script></body></html>`);
  });

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
