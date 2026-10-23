"use strict";
// Extra features for the AirShare site: admin page, link checker, hide/pin overrides,
// plus the files that power favorites + offline support (webui.js, sw.js, offline.html).
// Used from site_17.js:  const feat = require("./features").create(d0);  feat.wrap(d0);  feat.mount(web, {...});
const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const read = (f) => { try { return fs.readFileSync(path.join(__dirname, f), "utf8"); } catch { return ""; } };

function create(d0) {
  const { db, keyOf, safeHttps } = d0;

  // ---------- schema ----------
  db.exec("CREATE TABLE IF NOT EXISTS admin_overrides(bundle_id TEXT PRIMARY KEY, hidden INTEGER NOT NULL DEFAULT 0, pinned INTEGER NOT NULL DEFAULT 0, updated_at TEXT)");
  db.exec("CREATE TABLE IF NOT EXISTS link_status(bundle_id TEXT PRIMARY KEY, broken INTEGER NOT NULL DEFAULT 0)");
  for (const col of ["status INTEGER", "fails INTEGER NOT NULL DEFAULT 0", "checked_at TEXT", "error TEXT"]) {
    try { db.exec("ALTER TABLE link_status ADD COLUMN " + col); } catch { /* already there */ }
  }

  // ---------- admin news (shown in the NEWS row, the AltStore feed, and /admin/news) ----------
  db.exec("CREATE TABLE IF NOT EXISTS admin_news(id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, caption TEXT, image_url TEXT, url TEXT, app_id TEXT, tint TEXT, date TEXT NOT NULL, created_at TEXT NOT NULL)");
  for (const col of ["src_id TEXT", "hidden INTEGER NOT NULL DEFAULT 0"]) {
    try { db.exec("ALTER TABLE admin_news ADD COLUMN " + col); } catch { /* already there */ }
  }
  const newsHiddenQ = db.prepare("SELECT 1 FROM admin_news WHERE hidden=1 AND src_id=?");
  let newsVer = 0;
  const newsRows = () => db.prepare("SELECT * FROM admin_news ORDER BY date DESC, id DESC").all();
  const adminNewsItems = () => newsRows().filter(r => !r.hidden).map(r => ({
    identifier: r.src_id || "admin-" + r.id, title: r.title, caption: r.caption || "", imageURL: r.image_url || "",
    url: r.url || "", appID: r.app_id || "", tintColor: r.tint || "", date: r.date,
  }));

  // ---------- hide / pin / staff picks ----------
  try { db.exec("ALTER TABLE admin_overrides ADD COLUMN staff_at TEXT"); } catch { /* already there */ }
  // staff_ver = the version string picked for the app. NULL/"" means "no specific version" (old picks, or
  // apps with a single version) and resolves to the newest version in the catalog.
  try { db.exec("ALTER TABLE admin_overrides ADD COLUMN staff_ver TEXT"); } catch { /* already there */ }
  let hidden = new Set(), pinned = new Set(), staff = [], staffVer = new Map(), ver = 0;
  const load = () => {
    hidden = new Set(); pinned = new Set(); staff = []; staffVer = new Map();
    for (const r of db.prepare("SELECT bundle_id b, hidden h, pinned p, staff_at s, staff_ver v FROM admin_overrides ORDER BY staff_at DESC").all()) {
      if (r.h) hidden.add(r.b);
      if (r.p) pinned.add(r.b);
      if (r.s) { staff.push(r.b); if (r.v) staffVer.set(r.b, String(r.v)); } // newest pick first
    }
    ver++;
  };
  load();
  function setFlag(key, field, on) {
    const f = field === "hidden" ? "hidden" : "pinned", now = new Date().toISOString();
    const up = db.prepare("UPDATE admin_overrides SET " + f + "=?, updated_at=? WHERE bundle_id=?").run(on ? 1 : 0, now, key);
    if (!up.changes) db.prepare("INSERT INTO admin_overrides(bundle_id,hidden,pinned,updated_at) VALUES(?,?,?,?)").run(key, f === "hidden" && on ? 1 : 0, f === "pinned" && on ? 1 : 0, now);
    load();
  }

  // The catalog lists one row per version of an app (same key, different version). Group them:
  // key -> [items], de-duplicated by version string, newest version first.
  const verOf = (it) => String(it && it.version != null ? it.version : "");
  const byVerDesc = (a, b) => verOf(b).localeCompare(verOf(a), "en", { numeric: true });
  function groups() {
    const m = new Map();
    for (const x of d0.getCatalog()) {
      const k = keyOf(x);
      let a = m.get(k);
      if (!a) m.set(k, a = []);
      if (!a.some(y => verOf(y) === verOf(x))) a.push(x);
    }
    for (const a of m.values()) a.sort(byVerDesc);
    return m;
  }

  // on=true  : pick the app; `version` is the specific version ("" = no preference / latest).
  // Re-picking an app that is already a pick only changes its version and keeps its place in the list.
  function setStaff(key, on, version) {
    const now = new Date().toISOString();
    const cur = db.prepare("SELECT staff_at s FROM admin_overrides WHERE bundle_id=?").get(key);
    const at = on ? ((cur && cur.s) || now) : null, v = on && version ? String(version) : null;
    const up = db.prepare("UPDATE admin_overrides SET staff_at=?, staff_ver=?, updated_at=? WHERE bundle_id=?").run(at, v, now, key);
    if (!up.changes && on) db.prepare("INSERT INTO admin_overrides(bundle_id,hidden,pinned,updated_at,staff_at,staff_ver) VALUES(?,?,?,?,?,?)").run(key, 0, 0, now, at, v);
    load();
  }

  // The site works on a view of the catalog with hidden apps removed.
  function wrap(d) {
    let srcCache = null, srcVer = -1, out = null;
    const getCatalog = () => {
      const src = d.getCatalog();
      if (!hidden.size) return src;
      if (src === srcCache && srcVer === ver) return out;
      srcCache = src; srcVer = ver; out = src.filter(x => !hidden.has(keyOf(x)));
      return out;
    };
    return Object.assign({}, d, {
      getCatalog,
      byKey: (k) => { const it = d.byKey(k); return it && !hidden.has(keyOf(it)) ? it : null; },
      search: (q, n) => { const r = d.search(q, n); return hidden.size ? r.filter(x => !hidden.has(keyOf(x))) : r; },
      getNews: () => adminNewsItems().concat(typeof d.getNews === "function" ? (d.getNews() || []) : []),
    });
  }
  const floatPinned = (items) => {
    if (!pinned.size) return items;
    const a = [], b = [];
    for (const it of items) (pinned.has(keyOf(it)) ? a : b).push(it);
    return a.concat(b);
  };

  // ---------- link checker ----------
  const LC = { running: false, done: 0, total: 0, started: 0, finished: 0 };
  const qSel = db.prepare("SELECT broken,fails FROM link_status WHERE bundle_id=?");
  const qUp = db.prepare("UPDATE link_status SET broken=?,status=?,fails=?,checked_at=?,error=? WHERE bundle_id=?");
  const qIns = db.prepare("INSERT INTO link_status(bundle_id,broken,status,fails,checked_at,error) VALUES(?,?,?,?,?,?)");

  async function probe(url) {
    const opts = (method, extra) => ({ method, redirect: "follow", signal: AbortSignal.timeout(10000), headers: Object.assign({ "user-agent": "AirShare-LinkCheck/1.0" }, extra) });
    const drop = async (r) => { try { if (r.body && r.body.cancel) await r.body.cancel(); } catch { /* ignore */ } };
    try {
      let r = await fetch(url, opts("HEAD"));
      if (r.status >= 400) { await drop(r); r = await fetch(url, opts("GET", { range: "bytes=0-0" })); } // some hosts refuse HEAD
      const status = r.status; await drop(r);
      return { ok: status < 400, status, error: status < 400 ? "" : "HTTP " + status };
    } catch (e) {
      return { ok: false, status: 0, error: String((e && e.name === "TimeoutError") ? "timeout" : (e && e.message) || e).slice(0, 120) };
    }
  }
  async function checkOne(item) {
    const key = keyOf(item), url = safeHttps(item.downloadURL);
    if (!url) return;
    const res = await probe(url);
    const prev = qSel.get(key);
    const fails = res.ok ? 0 : ((prev && prev.fails) || 0) + 1;
    const broken = res.ok ? 0 : (fails >= 2 || (prev && prev.broken)) ? 1 : 0; // needs two failed checks in a row
    const args = [broken, res.status, fails, new Date().toISOString(), res.error];
    if (prev) qUp.run(...args, key); else qIns.run(key, ...args);
  }
  async function runCheck() {
    if (LC.running) return false;
    const items = d0.getCatalog().filter(x => safeHttps(x.downloadURL));
    Object.assign(LC, { running: true, done: 0, total: items.length, started: Date.now() });
    let i = 0;
    const worker = async () => {
      while (i < items.length) {
        const it = items[i++];
        try { await checkOne(it); } catch (e) { console.warn("linkcheck:", e.message); }
        LC.done++;
      }
    };
    try { await Promise.all(Array.from({ length: 6 }, worker)); }
    finally { LC.running = false; LC.finished = Date.now(); }
    return true;
  }
  if (process.env.LINKCHECK !== "0") {
    const hrs = Math.max(1, Number(process.env.LINKCHECK_HOURS) || 12);
    setTimeout(() => runCheck().catch(() => {}), 2 * 60 * 1000).unref();
    setInterval(() => runCheck().catch(() => {}), hrs * 3600 * 1000).unref();
  }

  // ---------- routes ----------
  function mount(web, h) {
    const { auth, esc } = h;
    const express = require("express");
    const form = express.urlencoded({ extended: false, limit: "20kb" });
    const csrf = crypto.createHmac("sha256", String(h.secret || "airshare")).update("admin-csrf").digest("hex");
    const okCsrf = (t) => { const a = Buffer.from(String(t || "")), b = Buffer.from(csrf); return a.length === b.length && crypto.timingSafeEqual(a, b); };
    const UI_JS = read("webui.js"), SW_JS = read("sw.js"), OFFLINE = read("offline.html");

    web.get("/sw.js", (_req, res) => {
      if (!SW_JS) return res.status(404).end();
      res.set({ "Content-Type": "application/javascript; charset=utf-8", "Cache-Control": "no-cache", "Service-Worker-Allowed": "/" });
      res.send(SW_JS);
    });
    web.get("/assets/ui.js", (_req, res) => {
      if (!UI_JS) return res.status(404).end();
      res.set({ "Content-Type": "application/javascript; charset=utf-8", "Cache-Control": "public, max-age=300" });
      res.send(UI_JS);
    });
    web.get("/offline", (_req, res) => {
      if (!OFFLINE) return res.status(404).end();
      res.set({
        "Content-Type": "text/html; charset=utf-8", "Cache-Control": "public, max-age=3600",
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'",
      });
      res.send(OFFLINE);
    });

    // Left-hand menu, shared by every admin page. `active` is the path of the current page.
    const MENU = [["/", "Site"], ["/admin", "Admin"], ["/admin/news", "News"], ["/admin/accounts", "Accounts"], ["/admin/telegram", "Telegram"], ["/admin/analytics", "Analytics"]];
    const menu = (active) => `<nav class="side" aria-label="Menu"><ul>${MENU.map(([href, label]) => `<li><a href="${href}"${href === active ? ' aria-current="page"' : ""}>${label}</a></li>`).join("")}</ul></nav>`;

    const ago = (iso) => {
      const t = Date.parse(iso); if (!t) return "never";
      const s = Math.max(0, (Date.now() - t) / 1000);
      return s < 90 ? "just now" : s < 5400 ? Math.round(s / 60) + " min ago" : s < 129600 ? Math.round(s / 3600) + " h ago" : Math.round(s / 86400) + " d ago";
    };
    const CSS = ":root{--acc:#ff3b14}*{box-sizing:border-box}body{margin:0;background:#000;color:#f1f1f1;font:15px/1.5 system-ui,-apple-system,sans-serif;padding:16px 12px 60px}" +
      ".w{max-width:920px;margin:0 auto}h1{margin:6px 0 2px;color:var(--acc);font-size:24px}h2{margin:26px 0 10px;font-size:13px;letter-spacing:1px;color:#9a9a9a}" +
      "a{color:inherit}" +
      ".lay{display:flex;gap:22px;align-items:flex-start}.side{flex:none;width:120px;position:sticky;top:16px;padding-top:6px}.side ul{list-style:none;margin:0;padding:0;display:flex;flex-direction:column;gap:4px}" +
      ".side a{display:block;padding:9px 12px;border-radius:10px;color:#9a9a9a;text-decoration:none}.side a:hover{color:#fff;background:#111}.side a[aria-current]{color:var(--acc);background:rgba(255,59,20,.12);font-weight:600}.main{flex:1 1 0;min-width:0}" +
      "@media(max-width:520px){.lay{gap:12px}.side{width:88px}.side a{padding:8px 9px;font-size:14px}}" +
      "select.ver{height:34px;max-width:150px;padding:0 8px;border:1px solid #333;border-radius:9px;background:#111;color:#ddd;font:inherit;font-size:13px}" +
      ".m{color:#9a9a9a}.box{border:1px solid #292929;border-radius:16px;background:#090909;padding:14px;margin-bottom:12px}" +
      ".grid{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}.st{border:1px solid #292929;border-radius:12px;padding:10px;text-align:center}.st b{display:block;font-size:22px;color:var(--acc)}.st span{font-size:12px;color:#9a9a9a}" +
      "button{font:inherit;cursor:pointer}.btn{height:40px;padding:0 14px;border:1px solid var(--acc);border-radius:11px;background:rgba(255,59,20,.18);color:#fff;font-weight:700}.sm{height:34px;padding:0 11px;border:1px solid #333;border-radius:9px;background:#111;color:#ddd;font-size:13px}" +
      ".sm.on{border-color:var(--acc);color:var(--acc)}.row{display:flex;flex-wrap:wrap;gap:8px 10px;align-items:center;padding:11px 0;border-top:1px solid #1d1d1d}.row:first-child{border-top:0}.row .n{flex:1 1 150px;min-width:0}.row b{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}" +
      ".row code{font-size:11px;color:#9a9a9a;word-break:break-all}.tag{display:inline-block;margin-left:6px;padding:0 7px;border-radius:99px;font-size:11px;border:1px solid #444;color:#bbb}.tag.bad{border-color:#f33;color:#f66}.tag.pin{border-color:var(--acc);color:var(--acc)}" +
      "form.inl{display:flex;gap:6px;margin:0}input[type=search]{flex:1;min-width:0;height:42px;padding:0 12px;border:1px solid #333;border-radius:11px;background:#0b0b0b;color:#fff;font-size:16px}" +
      ".tabs{display:flex;gap:8px;margin:10px 0;flex-wrap:wrap}.tabs a{padding:6px 12px;border:1px solid #333;border-radius:99px;text-decoration:none;font-size:13px}.tabs a.on{border-color:var(--acc);color:var(--acc)}" +
      ".pg{display:flex;justify-content:space-between;margin-top:12px}.flash{padding:10px 14px;border:1px solid var(--acc);border-radius:12px;margin:10px 0;color:var(--acc)}";

    web.get("/admin", auth, (req, res) => {
      const grp = groups(); // one entry per app; repeated catalog rows are its versions
      const stat = new Map(db.prepare("SELECT bundle_id b,broken,status,fails,checked_at,error FROM link_status").all().map(r => [r.b, r]));
      const q = String(req.query.q || "").trim().slice(0, 80).toLowerCase();
      const f = ["all", "broken", "hidden", "pinned", "staff"].includes(req.query.f) ? req.query.f : "all";
      let rows = [...grp].map(([key, vs]) => ({ it: vs[0], key, vs, st: stat.get(key) }));
      const brokenN = rows.filter(r => r.st && r.st.broken).length;
      const checkedN = rows.filter(r => r.st && r.st.checked_at).length;
      const lastCheck = rows.reduce((m, r) => (r.st && r.st.checked_at > m ? r.st.checked_at : m), "");
      if (q) rows = rows.filter(r => (String(r.it.name || "") + " " + r.key + " " + String(r.it.developerName || "")).toLowerCase().includes(q));
      if (f === "broken") rows = rows.filter(r => r.st && r.st.broken);
      if (f === "hidden") rows = rows.filter(r => hidden.has(r.key));
      if (f === "pinned") rows = rows.filter(r => pinned.has(r.key));
      if (f === "staff") rows = rows.filter(r => staff.includes(r.key));
      rows.sort((a, b) => String(a.it.name).localeCompare(String(b.it.name), "en", { sensitivity: "base" }));
      const PER = 40, pages = Math.max(1, Math.ceil(rows.length / PER));
      const page = Math.min(pages, Math.max(1, parseInt(req.query.p, 10) || 1));
      const link = (o) => { const p = Object.assign({ q: req.query.q || "", f, p: 1 }, o); const qs = Object.entries(p).filter(([k, v]) => v && !(k === "p" && v === 1) && !(k === "f" && v === "all")).map(([k, v]) => k + "=" + encodeURIComponent(v)).join("&"); return "/admin" + (qs ? "?" + qs : ""); };
      const back = esc(req.originalUrl.startsWith("/admin") ? req.originalUrl : "/admin");
      const act = (key, a, label, on) => `<button class="sm${on ? " on" : ""}" name="act" value="${a}" type="submit">${label}</button>`;
      const list = rows.slice((page - 1) * PER, page * PER).map(r => {
        const bad = r.st && r.st.broken, isH = hidden.has(r.key), isP = pinned.has(r.key), isS = staff.includes(r.key);
        const why = r.st ? esc((r.st.error || ("HTTP " + r.st.status)) + " \u00b7 " + ago(r.st.checked_at)) : "";
        const multi = r.vs.length > 1, picked = staffVer.get(r.key) || "";
        const cur = r.vs.find(x => verOf(x) === picked) || r.vs[0]; // the version a staff pick resolves to
        const verTag = isS ? "staff pick" + (multi ? " \u00b7 v" + verOf(cur) : "") : "";
        const opts = r.vs.map(x => `<option value="${esc(verOf(x))}"${x === cur ? " selected" : ""}>v${esc(verOf(x) || "?")}${x.versionDate ? " \u00b7 " + esc(String(x.versionDate).slice(0, 10)) : ""}</option>`).join("");
        const picker = multi ? `<select class="ver" name="ver" aria-label="Version for staff pick">${opts}</select>` : "";
        const staffBtns = isS ? (multi ? act(r.key, "staff", "Set version", false) : "") + act(r.key, "unstaff", "\u2605 Picked", true) : act(r.key, "staff", "\u2606 Pick", false);
        return `<div class="row"><div class="n"><b>${esc(r.it.name)}${multi ? `<span class="tag">${r.vs.length} versions</span>` : ""}${bad ? `<span class="tag bad" title="${why}">broken</span>` : ""}${isH ? '<span class="tag">hidden</span>' : ""}${isP ? '<span class="tag pin">pinned</span>' : ""}${isS ? `<span class="tag pin">${esc(verTag)}</span>` : ""}</b><code>${esc(r.key)}</code></div>` +
          `<form class="inl" method="post" action="/admin/act"><input type="hidden" name="csrf" value="${csrf}"><input type="hidden" name="key" value="${esc(r.key)}"><input type="hidden" name="back" value="${back}">` +
          `${picker}${staffBtns}${act(r.key, isP ? "unpin" : "pin", isP ? "Unpin" : "Pin", isP)}${act(r.key, isH ? "unhide" : "hide", isH ? "Unhide" : "Hide", isH)}</form></div>`;
      }).join("") || '<p class="m">Nothing matches.</p>';
      const status = LC.running ? `Checking\u2026 ${LC.done}/${LC.total}` : `Last check: ${ago(lastCheck)}`;
      const flash = req.query.m ? `<div class="flash">${esc(String(req.query.m).slice(0, 80))}</div>` : "";
      res.set({ "Cache-Control": "no-store", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'" });
      res.type("html").send(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><meta name="color-scheme" content="dark">${LC.running ? '<meta http-equiv="refresh" content="5">' : ""}<title>Admin</title><style>${CSS}</style></head><body><div class="w"><div class="lay">${menu("/admin")}<main class="main">
<h1>Admin</h1>${flash}
<h2>LINK CHECKER</h2><div class="box"><div class="grid"><div class="st"><b>${grp.size}</b><span>apps</span></div><div class="st"><b>${brokenN}</b><span>broken</span></div><div class="st"><b>${checkedN}</b><span>checked</span></div></div>
<p class="m">${esc(status)}. Runs automatically every ${Math.max(1, Number(process.env.LINKCHECK_HOURS) || 12)} h; an app is marked broken after two failed checks in a row.</p>
<form method="post" action="/admin/act"><input type="hidden" name="csrf" value="${csrf}"><input type="hidden" name="back" value="/admin"><button class="btn" name="act" value="check" type="submit"${LC.running ? " disabled" : ""}>Check all links now</button></form></div>
<h2>CATALOG (${rows.length})</h2>
<form class="inl" method="get" action="/admin"><input type="search" name="q" value="${esc(req.query.q || "")}" placeholder="Search apps\u2026">${f !== "all" ? `<input type="hidden" name="f" value="${f}">` : ""}<button class="btn" type="submit">Search</button></form>
<div class="tabs">${[["all", "All"], ["broken", "Broken (" + brokenN + ")"], ["hidden", "Hidden (" + hidden.size + ")"], ["pinned", "Pinned (" + pinned.size + ")"], ["staff", "Staff picks (" + staff.length + ")"]].map(([k, l]) => `<a class="${k === f ? "on" : ""}" href="${link({ f: k, p: 1 })}">${l}</a>`).join("")}</div>
<div class="box">${list}</div>
<div class="pg"><span>${page > 1 ? `<a href="${link({ p: page - 1 })}">\u2190 Prev</a>` : ""}</span><span class="m">Page ${page} / ${pages}</span><span>${page < pages ? `<a href="${link({ p: page + 1 })}">Next \u2192</a>` : ""}</span></div>
</main></div></div></body></html>`);
    });

    web.post("/admin/act", auth, form, (req, res) => {
      const b = req.body || {};
      const back = typeof b.back === "string" && /^\/admin(?:[?\/][^\s]*)?$/.test(b.back) && !b.back.includes("//") ? b.back.replace(/([?&])m=[^&]*&?/g, "$1").replace(/[?&]$/, "") : "/admin";
      const done = (m) => res.redirect(303, back + (back.includes("?") ? "&" : "?") + "m=" + encodeURIComponent(m));
      if (!okCsrf(b.csrf)) return res.status(403).send("Bad token. Reload the page and try again.");
      const a = String(b.act || "");
      if (a === "check") { const was = LC.running; runCheck().catch(() => {}); return done(was ? "Link check already running" : "Link check started"); }
      const item = d0.byKey(String(b.key || "").slice(0, 200));
      if (!item) return done("App not found");
      const key = keyOf(item);
      if (a === "hide") setFlag(key, "hidden", true);
      else if (a === "unhide") setFlag(key, "hidden", false);
      else if (a === "pin") setFlag(key, "pinned", true);
      else if (a === "unpin") setFlag(key, "pinned", false);
      else if (a === "staff") {
        // Apps with several versions must name one of them; single-version apps just follow the latest.
        const vs = groups().get(key) || [], want = String(b.ver || "").slice(0, 80);
        const hit = vs.find(x => verOf(x) === want);
        if (vs.length > 1 && !hit) return done("Pick one of the listed versions");
        setStaff(key, true, vs.length > 1 ? verOf(hit) : "");
        return done(item.name + ": staff pick" + (vs.length > 1 ? " v" + verOf(hit) : "") + " saved");
      }
      else if (a === "unstaff") setStaff(key, false);
      else return done("Unknown action");
      return done(item.name + ": " + a + " done");
    });

    // ----- news editor (admin items + every item from the repo / data file, all editable) -----
    const NCSS = CSS + "label{display:block;margin:12px 0 4px;font-size:13px;color:#9a9a9a}input[type=text],input[type=url],input[type=date],textarea{width:100%;padding:10px 12px;border:1px solid #333;border-radius:11px;background:#0b0b0b;color:#fff;font:16px system-ui;outline:0}" +
      "textarea{min-height:84px;resize:vertical}input:focus,textarea:focus{border-color:var(--acc)}.thumb{flex:none;width:52px;height:52px;border-radius:12px;object-fit:cover;background:#111}.two{display:grid;grid-template-columns:1fr 1fr;gap:10px}.hint{font-size:12px;color:#777;margin-top:4px}.acts{display:flex;gap:8px;margin-top:16px}a.sm{display:inline-flex;align-items:center;text-decoration:none}" +
      ".row .n small{display:block;color:#888;font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.btns{display:flex;gap:6px}";
    const dateOnly = (iso) => { const t = Date.parse(iso); return t ? new Date(t).toISOString().slice(0, 10) : ""; };
    const nid = (n) => String((n && (n.identifier || n.title)) || "").trim().slice(0, 80);
    // upstream (repo / data file) items, de-duplicated, as admin_news-shaped rows
    const sourceNews = () => {
      const out = [], seen = new Set();
      for (const n of (typeof h.news === "function" ? h.news() : [])) {
        if (!n || typeof n.title !== "string" || !n.title.trim()) continue;
        const id = nid(n); if (!id || seen.has(id)) continue; seen.add(id);
        out.push({ src_id: id, src: n._src || "repo", title: n.title.trim().slice(0, 80), caption: String(n.caption || ""), image_url: String(n.imageURL || ""), url: String(n.url || ""), app_id: String(n.appID || ""), tint: String(n.tintColor || ""), date: n.date || "" });
      }
      return out;
    };
    const fmtTarget = (r) => (r.app_id ? "app " + r.app_id : r.url || "no link");
    const nrow = (r, btns, tag) => `<div class="row">${r.image_url ? `<img class="thumb" src="${esc(r.image_url)}" alt="" referrerpolicy="no-referrer">` : ""}<div class="n"><b>${esc(r.title)}${tag || ""}</b><code>${esc(dateOnly(r.date) || "no date")} \u00b7 ${esc(fmtTarget(r))}</code>${r.caption ? `<small>${esc(r.caption)}</small>` : ""}</div><div class="btns">${btns}</div></div>`;
    const nform = (act, fields, label, cls) => `<form class="inl" method="post" action="/admin/news/${act}"${cls ? ` onsubmit="return confirm('${cls}')"` : ""}><input type="hidden" name="csrf" value="${csrf}">${fields}<button class="sm" type="submit">${label}</button></form>`;

    web.get("/admin/news", auth, (req, res) => {
      const all = newsRows();
      const mine = all.filter(r => !r.hidden), hid = all.filter(r => r.hidden);
      const taken = new Set(all.filter(r => r.src_id).map(r => r.src_id));
      const srcItems = sourceNews().filter(r => !taken.has(r.src_id));
      const eid = parseInt(req.query.edit, 10), from = String(req.query.from || "").slice(0, 80);
      let v = (eid && db.prepare("SELECT * FROM admin_news WHERE id=?").get(eid)) || {};
      if (!v.id && from) v = sourceNews().find(x => x.src_id === from) || {};
      const srcId = v.id ? v.src_id || "" : v.src_id || "";
      const flash = req.query.m ? `<div class="flash">${esc(String(req.query.m).slice(0, 120))}</div>` : "";
      const target = v.app_id ? "App: " + v.app_id : v.url ? v.url : "no link";
      const editing = !!(v.id || v.src_id);
      const yours = mine.map(r => nrow(r,
        `<a class="sm" href="/admin/news?edit=${r.id}">Edit</a>` + nform("delete", `<input type="hidden" name="id" value="${r.id}">`, r.src_id ? "Revert" : "Delete", r.src_id ? "Revert to the original repo item?" : "Delete this news item?"),
        r.src_id ? ' <span class="tag pin">edited copy</span>' : "")).join("") || '<p class="m">Nothing yet. Add your first item below.</p>';
      const fromSrc = srcItems.map(r => nrow(r,
        `<a class="sm" href="/admin/news?from=${encodeURIComponent(r.src_id)}">Edit</a>` + nform("hide", `<input type="hidden" name="src" value="${esc(r.src_id)}">`, "Hide", "Hide this item from the site and feed?"),
        ` <span class="tag">${esc(r.src)}</span>`)).join("") || '<p class="m">No repo or file news found.</p>';
      const hidden = hid.map(r => nrow(r, nform("delete", `<input type="hidden" name="id" value="${r.id}">`, "Restore"), ' <span class="tag bad">hidden</span>')).join("");
      res.set({ "Cache-Control": "no-store", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; img-src https: data:; form-action 'self'; base-uri 'none'; frame-ancestors 'none'; script-src 'unsafe-inline'" });
      res.type("html").send(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><meta name="color-scheme" content="dark"><title>News \u00b7 Admin</title><style>${NCSS}</style></head><body><div class="w"><div class="lay">${menu("/admin/news")}<main class="main">
<h1>News</h1>${flash}
<h2>${editing ? "EDIT ITEM" : "ADD ITEM"}</h2><form class="box" method="post" action="/admin/news/save"><input type="hidden" name="csrf" value="${csrf}"><input type="hidden" name="id" value="${v.id || ""}"><input type="hidden" name="src" value="${esc(srcId)}">
${!v.id && srcId ? `<p class="hint" style="margin:0 0 6px">Editing a ${esc(v.src || "repo")} item. Saving makes an edited copy that replaces the original on the site and feed.</p>` : ""}
<label for="t">Title (required, 80 max)</label><input id="t" type="text" name="title" maxlength="80" required value="${esc(v.title || "")}">
<label for="c">Caption (220 max)</label><textarea id="c" name="caption" maxlength="220">${esc(v.caption || "")}</textarea>
<label for="i">Image URL (https)</label><input id="i" type="url" name="image_url" placeholder="https://\u2026/banner.png" value="${esc(v.image_url || "")}">
<div class="two"><div><label for="a">Link to an app (bundle ID)</label><input id="a" type="text" name="app" placeholder="com.example.app" value="${esc(v.app_id || "")}" autocapitalize="off" autocorrect="off"></div>
<div><label for="u">\u2026or external link (https)</label><input id="u" type="url" name="url" placeholder="https://\u2026" value="${esc(v.url || "")}"></div></div>
<p class="hint">If both are filled in, the app link wins. Current: ${esc(target)}.</p>
<div class="two"><div><label for="k">Accent color</label><input id="k" type="text" name="tint" placeholder="#ff3b14" maxlength="7" autocapitalize="off" value="${esc(v.tint || "")}"></div>
<div><label for="d">Date</label><input id="d" type="date" name="date" value="${esc(dateOnly(v.date))}"></div></div>
<div class="acts"><button class="btn" type="submit">${editing ? "Save changes" : "Publish"}</button>${editing ? '<a class="sm" style="height:40px;padding:0 14px" href="/admin/news">Cancel</a>' : ""}</div></form>
<h2>YOUR ITEMS (${mine.length})</h2><div class="box">${yours}</div>
<h2>FROM REPO / FILE (${srcItems.length})</h2><div class="box">${fromSrc}</div>
${hid.length ? `<h2>HIDDEN (${hid.length})</h2><div class="box">${hidden}</div>` : ""}
<p class="m">Changes reach the site's NEWS row and the AltStore/SideStore feed within a few seconds. Editing a repo item saves a copy here; Revert brings the original back.</p>
</main></div></div></body></html>`);
    });

    web.post("/admin/news/save", auth, form, (req, res) => {
      const b = req.body || {};
      const src = String(b.src || "").trim().slice(0, 80);
      let id = parseInt(b.id, 10) || 0;
      const done = (m, i) => res.redirect(303, "/admin/news?" + (i ? "edit=" + i + "&" : "") + "m=" + encodeURIComponent(m));
      const back = (m) => (id ? done(m, id) : src ? res.redirect(303, "/admin/news?from=" + encodeURIComponent(src) + "&m=" + encodeURIComponent(m)) : done(m, 0));
      if (!okCsrf(b.csrf)) return res.status(403).send("Bad token. Reload the page and try again.");
      const title = String(b.title || "").trim().slice(0, 80);
      if (!title) return back("Title is required");
      const caption = String(b.caption || "").trim().slice(0, 220);
      const imgIn = String(b.image_url || "").trim(), image = imgIn ? safeHttps(imgIn) : "";
      if (imgIn && !image) return back("Image must be an https:// URL");
      let appId = "", url = "";
      const appIn = String(b.app || "").trim().slice(0, 200), urlIn = String(b.url || "").trim();
      if (appIn) { const it = d0.byKey(appIn); if (!it) return back("No app with ID \u201c" + appIn.slice(0, 40) + "\u201d"); appId = keyOf(it); }
      else if (urlIn) { url = safeHttps(urlIn); if (!url) return back("Link must be an https:// URL"); }
      const tintIn = String(b.tint || "").trim();
      const tint = /^#?[0-9a-f]{6}$/i.test(tintIn) ? "#" + tintIn.replace("#", "") : "";
      if (tintIn && !tint) return back("Color must look like #ff3b14");
      if (!id && src) { const ex = db.prepare("SELECT id FROM admin_news WHERE src_id=?").get(src); if (ex) id = ex.id; }
      const old = id ? db.prepare("SELECT date FROM admin_news WHERE id=?").get(id) : null;
      const t = Date.parse(b.date);
      const date = t ? new Date(t).toISOString() : (old && old.date) || new Date().toISOString();
      const now = new Date().toISOString();
      if (id && old) { db.prepare("UPDATE admin_news SET title=?,caption=?,image_url=?,url=?,app_id=?,tint=?,date=?,hidden=0 WHERE id=?").run(title, caption, image, url, appId, tint, date, id); newsVer++; return done("Saved \u201c" + title + "\u201d", id); }
      db.prepare("INSERT INTO admin_news(title,caption,image_url,url,app_id,tint,date,created_at,src_id,hidden) VALUES(?,?,?,?,?,?,?,?,?,0)").run(title, caption, image, url, appId, tint, date, now, src || null);
      newsVer++;
      return done((src ? "Saved edited copy of \u201c" : "Published \u201c") + title + "\u201d", 0);
    });

    web.post("/admin/news/hide", auth, form, (req, res) => {
      const b = req.body || {};
      if (!okCsrf(b.csrf)) return res.status(403).send("Bad token. Reload the page and try again.");
      const src = String(b.src || "").trim().slice(0, 80), it = sourceNews().find(x => x.src_id === src);
      if (!it) return res.redirect(303, "/admin/news?m=" + encodeURIComponent("Item not found"));
      db.prepare("INSERT INTO admin_news(title,caption,image_url,url,app_id,tint,date,created_at,src_id,hidden) VALUES(?,?,?,?,?,?,?,?,?,1)")
        .run(it.title, it.caption, it.image_url, it.url, it.app_id, it.tint, Date.parse(it.date) ? new Date(it.date).toISOString() : new Date().toISOString(), new Date().toISOString(), src);
      newsVer++;
      return res.redirect(303, "/admin/news?m=" + encodeURIComponent("Hidden \u201c" + it.title + "\u201d"));
    });

    web.post("/admin/news/delete", auth, form, (req, res) => {
      const b = req.body || {};
      if (!okCsrf(b.csrf)) return res.status(403).send("Bad token. Reload the page and try again.");
      const row = db.prepare("SELECT src_id,hidden FROM admin_news WHERE id=?").get(parseInt(b.id, 10) || 0);
      db.prepare("DELETE FROM admin_news WHERE id=?").run(parseInt(b.id, 10) || 0);
      newsVer++;
      return res.redirect(303, "/admin/news?m=" + encodeURIComponent(row && row.hidden ? "Restored" : row && row.src_id ? "Reverted to original" : "Deleted"));
    });

    // ---------- Telegram account for the Decrypt popup (lock icon) ----------
    if (h.tg) {
      const T = h.tg;
      const tjson = express.json({ limit: "20kb", type: "application/json" });
      const tj = (res, code, error) => res.status(code).json({ ok: false, error });
      const tguard = (req, res, next) => {
        res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });
        if (!req.is("application/json")) return tj(res, 400, "Bad request.");
        if (!okCsrf((req.body || {}).csrf)) return tj(res, 403, "Bad token. Reload the page and try again.");
        next();
      };
      const TCSS = CSS + "label{display:block;margin:12px 0 4px;font-size:13px;color:#9a9a9a}input[type=text],input[type=password],input[type=tel]{width:100%;height:44px;padding:0 12px;border:1px solid #333;border-radius:11px;background:#0b0b0b;color:#fff;font:16px system-ui;outline:0}input:focus{border-color:var(--acc)}.acts{display:flex;gap:8px;flex-wrap:wrap;margin-top:14px}.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:8px;background:#f33}.dot.ok{background:#2fd16b}.mm{color:#9a9a9a;font-size:12px}.sm.danger{border-color:#7a2318;color:#f66}code.k{background:#111;border:1px solid #292929;border-radius:8px;padding:2px 7px}";
      web.get("/admin/telegram", auth, async (req, res) => {
        const s = await T.status();
        const state = !s.lib ? "The <code class=\"k\">telegram</code> package isn't installed. Run <code class=\"k\">cd /opt/airshare-telegram &amp;&amp; npm i telegram &amp;&amp; pm2 restart airshare</code>."
          : s.authed ? `Connected as <b>${esc(s.who.name || "account")}</b>${s.who.username ? " (@" + esc(s.who.username) + ")" : ""}. Requests go to <b>@${esc(s.bot)}</b>.`
          : s.hasKeys ? "Not logged in. Add your phone below." + (s.error ? " (" + esc(s.error) + ")" : "") : "Add your API id and hash first.";
        res.set({ "Cache-Control": "no-store", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'; script-src 'unsafe-inline'" });
        res.type("html").send(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><meta name="color-scheme" content="dark"><title>Telegram \u00b7 Admin</title><style>${TCSS}</style></head><body><div class="w"><div class="lay">${menu("/admin/telegram")}<main class="main">
<h1>Telegram</h1><div class="flash" id="fl" hidden></div>
<div class="box"><span class="dot${s.authed ? " ok" : ""}"></span>${state}
<p class="mm">Decrypt build ${esc(s.build || "old")} \u00b7 max file ${esc(s.maxGb || 1.5)} GB</p>
<p class="mm">The lock icon on the site sends App Store links from this account to @${esc(s.bot)} and returns the IPA to the visitor. Use a dedicated account if you can.</p></div>
<h2>1 \u00b7 API KEYS</h2><div class="box"><p class="mm" style="margin-top:0">From my.telegram.org &rarr; API development tools.</p>
<label for="ai">api_id</label><input id="ai" type="text" inputmode="numeric" autocomplete="off" value="${esc(s.apiId)}" placeholder="12345678">
<label for="ah">api_hash</label><input id="ah" type="password" autocomplete="off" placeholder="${s.hasKeys ? "saved (enter to replace)" : "32 hex characters"}">
<div class="acts"><button class="btn" type="button" id="k">Save keys</button></div></div>
<h2>2 \u00b7 LOG IN</h2><div class="box">
<label for="ph">Phone (with country code)</label><input id="ph" type="tel" autocomplete="off" placeholder="+15551234567">
<div class="acts"><button class="btn" type="button" id="sc">Send code</button></div>
<div id="cb" hidden><label for="cd">Code from Telegram</label><input id="cd" type="text" inputmode="numeric" autocomplete="off" placeholder="12345">
<div class="acts"><button class="btn" type="button" id="si">Sign in</button></div></div>
<div id="pb" hidden><label for="pw">2-step verification password</label><input id="pw" type="password" autocomplete="off">
<div class="acts"><button class="btn" type="button" id="sp">Sign in</button></div></div></div>
<details class="box"><summary style="cursor:pointer;color:var(--acc);font-weight:600">Or paste a session string</summary><label for="ss">gramjs StringSession</label><input id="ss" type="password" autocomplete="off"><div class="acts"><button class="btn" type="button" id="us">Use session</button></div></details>
${s.authed ? '<div class="acts"><button class="sm danger" type="button" id="lo">Log out of Telegram</button></div>' : ""}
</main></div></div>
<script>
(function(){
var T=${JSON.stringify(csrf)};
function $(i){return document.getElementById(i);}
function flash(t,bad){var f=$('fl');f.textContent=t;f.hidden=false;f.style.borderColor=bad?'#f33':'';f.style.color=bad?'#f66':'';window.scrollTo(0,0);}
function post(u,o){o.csrf=T;return fetch(u,{method:'POST',credentials:'same-origin',headers:{'content-type':'application/json'},body:JSON.stringify(o)}).then(function(r){return r.json();});}
function ok(m){sessionStorage.setItem('adm:m',m);location.reload();}
var m=sessionStorage.getItem('adm:m');if(m){sessionStorage.removeItem('adm:m');flash(m);}
function run(b,p,f){b.disabled=true;p.then(function(j){b.disabled=false;f(j);}).catch(function(){b.disabled=false;flash('Network error.',true);});}
$('k').onclick=function(){run(this,post('/admin/telegram/keys',{api_id:$('ai').value,api_hash:$('ah').value}),function(j){j.ok?ok('Keys saved.'):flash(j.error,true);});};
$('sc').onclick=function(){run(this,post('/admin/telegram/code',{phone:$('ph').value}),function(j){if(j.ok){$('cb').hidden=false;flash(j.viaApp?'Code sent. Check your Telegram app.':'Code sent by SMS.');}else flash(j.error,true);});};
$('si').onclick=function(){run(this,post('/admin/telegram/signin',{code:$('cd').value}),function(j){if(j.ok)ok('Logged in.');else if(j.need2fa){$('pb').hidden=false;flash('This account has 2-step verification. Enter the password.');}else flash(j.error,true);});};
$('sp').onclick=function(){run(this,post('/admin/telegram/signin',{password:$('pw').value}),function(j){j.ok?ok('Logged in.'):flash(j.error||'Failed.',true);});};
$('us').onclick=function(){run(this,post('/admin/telegram/session',{session:$('ss').value}),function(j){j.ok?ok('Session saved.'):flash(j.error,true);});};
if($('lo'))$('lo').onclick=function(){if(!confirm('Log out of Telegram? Decrypt stops working until you log in again.'))return;run(this,post('/admin/telegram/logout',{}),function(j){ok('Logged out.');});};
})();
</script></body></html>`);
      });
      web.post("/admin/telegram/keys", auth, tjson, tguard, async (req, res) => {
        const b = req.body || {};
        const err = await T.setKeys(b.api_id, b.api_hash);
        return err ? tj(res, 400, err) : res.json({ ok: true });
      });
      web.post("/admin/telegram/code", auth, tjson, tguard, async (req, res) => { const r = await T.sendCode((req.body || {}).phone); return r.error ? tj(res, 400, r.error) : res.json(r); });
      web.post("/admin/telegram/signin", auth, tjson, tguard, async (req, res) => { const b = req.body || {}; const r = await T.signIn(b.code, b.password); return r.error ? tj(res, 400, r.error) : res.json(r.need2fa ? { ok: false, need2fa: true } : { ok: true }); });
      web.post("/admin/telegram/session", auth, tjson, tguard, async (req, res) => { const err = await T.useSession((req.body || {}).session); return err ? tj(res, 400, err) : res.json({ ok: true }); });
      web.post("/admin/telegram/logout", auth, tjson, tguard, async (req, res) => { await T.logout(); return res.json({ ok: true }); });
    }

    // ---------- analytics, inside the admin layout ----------
    if (h.analytics) {
      const ANCSS = CSS + ".an h1{margin:6px 0 2px}.stats{display:grid;grid-template-columns:repeat(2,1fr);gap:10px;margin:12px 0}.stats .box{margin:0}.stats strong{display:block;font-size:26px;color:var(--acc)}.stats h2,.box h2{margin:0 0 6px}" +
        ".chips{display:flex;gap:8px;flex-wrap:wrap;margin:10px 0;align-items:center}.ch{padding:6px 12px;border:1px solid #333;border-radius:99px;text-decoration:none;font-size:13px;color:#ccc}.ch.on{border-color:var(--acc);color:var(--acc)}" +
        ".tablewrap{overflow-x:auto;-webkit-overflow-scrolling:touch}table{width:100%;border-collapse:collapse;font-size:13px}th,td{padding:7px 8px;text-align:left;border-top:1px solid #1d1d1d;white-space:nowrap}th{color:#9a9a9a;font-weight:600;border-top:0}td.nm{white-space:normal}.pager{display:flex;gap:12px;align-items:center;justify-content:center;margin-top:10px}a.btn{display:inline-flex;align-items:center;text-decoration:none}";
      const anPage = (kind, active, title) => (req, res) => {
        let body = "";
        try { body = h.analytics[kind](req, "/admin/analytics"); } catch (e) { console.warn("Analytics:", e.message); body = '<p class="m">Analytics failed to load.</p>'; }
        body = body.replace(/<i class="fa-solid fa-chevron-left"><\/i>/g, "\u2039").replace(/<i class="fa-solid fa-chevron-right"><\/i>/g, "\u203a");
        res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' https: data:; base-uri 'none'; frame-ancestors 'none'" });
        res.type("html").send(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><meta name="color-scheme" content="dark"><title>${title} \u00b7 Admin</title><style>${ANCSS}</style></head><body><div class="w"><div class="lay">${menu("/admin/analytics")}<main class="main">${body}</main></div></div></body></html>`);
      };
      web.get("/admin/analytics", auth, anPage("apps", "/admin/analytics", "Analytics"));
      web.get("/admin/analytics/server", auth, anPage("server", "/admin/analytics", "Server analytics"));
    }

    // ---------- accounts (admin creates logins and attaches certificates; the user can sign with them but never export them) ----------
    if (h.accounts) {
      const A = h.accounts;
      const ajson = express.json({ limit: "10mb", type: "application/json" });
      const jf = (res, code, error) => res.status(code).json({ ok: false, error });
      const guardA = (req, res, next) => {
        res.set({ "Cache-Control": "no-store", "X-Robots-Tag": "noindex, nofollow" });
        if (!req.is("application/json")) return jf(res, 400, "Bad request.");
        if (!okCsrf((req.body || {}).csrf)) return jf(res, 403, "Bad token. Reload the page and try again.");
        next();
      };
      const jerr = (err, _req, res, next) => (err ? jf(res, 413, "Files too large (p12 up to 5 MB, profile up to 2 MB).") : next());
      const ACSS = CSS + "label{display:block;margin:12px 0 4px;font-size:13px;color:#9a9a9a}input[type=text],input[type=password],input[type=email]{width:100%;height:44px;padding:0 12px;border:1px solid #333;border-radius:11px;background:#0b0b0b;color:#fff;font:16px system-ui;outline:0}input:focus{border-color:var(--acc)}" +
        ".two{display:grid;grid-template-columns:1fr 1fr;gap:10px}.acts{display:flex;gap:8px;flex-wrap:wrap;margin-top:14px}.cert{display:flex;align-items:center;gap:10px;padding:8px 0;border-top:1px solid #1d1d1d}.cert .n{flex:1;min-width:0}.cert b{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}" +
        ".fbtn{position:relative;display:flex;align-items:center;height:44px;padding:0 12px;border:1px dashed #444;border-radius:11px;color:#9a9a9a;overflow:hidden;font-size:14px}.fbtn.has{border-style:solid;border-color:var(--acc);color:#fff}.fbtn input{position:absolute;inset:0;opacity:0;width:100%;height:100%;cursor:pointer}.fbtn span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}" +
        "details.add{margin-top:10px}details.add summary{cursor:pointer;color:var(--acc);font-weight:600}.warnbox{padding:8px 12px;border:1px solid #6b4310;border-radius:12px;color:#ffb860;font-size:13px;margin:10px 0}.mm{color:#9a9a9a;font-size:12px}" +
        "details.acc{padding:0;overflow:hidden}details.acc>summary{display:flex;align-items:center;gap:12px;padding:13px 14px;cursor:pointer;list-style:none}details.acc>summary::-webkit-details-marker{display:none}details.acc[open]>summary{border-bottom:1px solid #1d1d1d}" +
        ".av{flex:none;width:40px;height:40px;border-radius:50%;background:rgba(255,59,20,.16);border:1px solid var(--acc);color:var(--acc);display:flex;align-items:center;justify-content:center;font-weight:700}.who{flex:1;min-width:0}.who b{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.who small{display:block;color:#888;font-size:12px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}" +
        ".chips2{display:flex;flex-direction:column;gap:4px;align-items:flex-end}.chip{padding:1px 9px;border:1px solid #444;border-radius:99px;font-size:11px;color:#bbb;white-space:nowrap}.chip.ok{border-color:#2f8f4a;color:#5fd17f}.chip.bad{border-color:#f33;color:#f66}.chip.off{border-color:#6b4310;color:#ffb860}" +
        ".det{padding:4px 14px 14px}.det h3{margin:16px 0 4px;font-size:12px;letter-spacing:1px;color:#9a9a9a;font-weight:600;text-transform:uppercase}.kv{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:12px}.kv div{border:1px solid #1d1d1d;border-radius:10px;padding:8px 10px}.kv span{display:block;font-size:11px;color:#888}.kv b{font-size:14px}" +
        ".rec{list-style:none;margin:0;padding:0}.rec li{display:flex;justify-content:space-between;gap:10px;padding:5px 0;border-top:1px solid #1d1d1d;font-size:12px;color:#888}.rec li:first-child{border-top:0}.rec code{color:#ccc;word-break:break-all}" +
        ".cert code{display:block;font-size:11px;color:#9a9a9a}.tag.ok{border-color:#2f8f4a;color:#5fd17f}.tag.warn{border-color:#c98a1a;color:#ffb860}.sm.danger{border-color:#7a2318;color:#f66}" +
        ".sum{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin:6px 0}.sum div{border:1px solid #292929;border-radius:12px;padding:9px 6px;text-align:center}.sum b{display:block;font-size:20px;color:var(--acc)}.sum span{font-size:11px;color:#9a9a9a}input[type=search].fq{width:100%;height:44px;margin:10px 0 4px}" +
        "select.role{width:100%;height:44px;padding:0 10px;border:1px solid #333;border-radius:11px;background:#0b0b0b;color:#fff;font:16px system-ui}.gchips{display:flex;flex-wrap:wrap;gap:7px;margin-top:8px}.gc{cursor:pointer;padding:6px 12px;border:1px solid #444;border-radius:99px;background:transparent;color:#bbb;font:600 13px system-ui}.gc.on{border-color:var(--acc);color:#fff;background:rgba(255,154,31,.18)}.chip.rl{border-color:var(--acc);color:var(--acc)}";
      const day = (iso) => { const t = Date.parse(iso); return t ? new Date(t).toISOString().slice(0, 10) : ""; };

      web.get("/admin/accounts", auth, (req, res) => {
        const users = A.list();
        const dleft = (iso) => { const t = Date.parse(iso); return t ? Math.ceil((t - Date.now()) / 864e5) : null; };
        const ago2 = (iso) => (Date.parse(iso) ? ago(iso) : "never");
        const cards = users.map(u => {
          const noMail = /@accounts\.invalid$/.test(u.email);
          const bad = u.certs.filter(c => { const n = dleft(c.expires); return n !== null && n < 0; }).length;
          const certs = u.certs.map(c => {
            const n = dleft(c.expires);
            const st = n === null ? "" : n < 0 ? ' <span class="tag bad">expired</span>' : n <= 30 ? ` <span class="tag warn">${n}d left</span>` : ` <span class="tag ok">${n}d left</span>`;
            return `<div class="cert"><div class="n"><b>${esc(c.name)}${c.locked ? ' <span class="tag pin">locked</span>' : ""}${st}</b><code>${esc(c.team || "no team")}</code><code>expires ${esc(day(c.expires) || "unknown")} \u00b7 attached ${esc(day(c.created_at) || "?")} \u00b7 id ${c.id}</code></div><button class="sm" type="button" data-act="delcert" data-uid="${u.id}" data-cert="${c.id}">Remove</button></div>`;
          }).join("") || '<p class="m" style="margin:8px 0">No certificates attached. This user can\'t sign until you attach one.</p>';
          const recent = (u.recent || []).map(r => `<li><code>${esc(r.b || "unknown app")}</code><span>${esc(ago2(r.ts))}</span></li>`).join("");
          return `<details class="box acc" data-u="${u.id}" data-q="${esc((u.username + " " + (noMail ? "" : u.email)).toLowerCase())}"><summary><span class="av">${esc(u.username.slice(0, 1).toUpperCase())}</span><span class="who"><b>${esc(u.username)}</b><small>${esc(noMail ? "no email" : u.email)}</small></span><span class="chips2">${u.role && u.role !== "member" ? `<span class="chip rl">${esc(u.role)}</span>` : ""}<span class="chip ${u.certs.length ? (bad ? "bad" : "ok") : "off"}">${u.certs.length} cert${u.certs.length === 1 ? "" : "s"}</span><span class="chip">${u.signs} signed</span></span></summary>
<div class="det"><div class="kv"><div><span>User ID</span><b>u${u.id}</b></div><div><span>Created</span><b>${esc(day(u.created_at) || "?")}</b></div><div><span>Last login</span><b>${esc(ago2(u.last_login))}</b></div><div><span>Last signed</span><b>${esc(u.last_sign ? ago2(u.last_sign) : "never")}</b></div><div><span>Signs (7 days)</span><b>${u.signs7}</b></div><div><span>Signs (all)</span><b>${u.signs}</b></div></div>
<h3>Role, groups &amp; sponsor</h3>
<label>Role (changes what this user can access)</label><select class="role">${(A.roleCatalog || []).map(r => `<option value="${esc(r)}"${r === u.role ? " selected" : ""}>${esc(r)}</option>`).join("")}</select>
<label>Groups (badges shown in the app)</label><div class="gchips">${(A.groupCatalog || []).map(g => `<button type="button" class="gc${(u.groups || []).includes(g) ? " on" : ""}" data-g="${esc(g)}">${esc(g.replace(/_/g, " "))}</button>`).join("")}</div>
<label>Sponsor label (like FastDecryptBot)</label><input type="text" class="spn" maxlength="40" value="${esc(u.sponsor || "")}" placeholder="Sponsor name (empty = none)" autocomplete="off">
<div class="acts"><button class="btn" type="button" data-act="saveroles" data-uid="${u.id}">Save role, groups &amp; sponsor</button></div>
<h3>Premium</h3>
<p class="m" style="margin:4px 0 8px">${u.premium && u.premium.active ? `Active \u00b7 ${u.premium.days_left} day${u.premium.days_left === 1 ? "" : "s"} left (until ${esc(day(u.premium.expires))})` : "Not active"}</p>
<div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center"><input type="number" class="pdays" min="0" max="3650" placeholder="Days" style="width:110px"><button class="sm" type="button" data-act="premadd" data-uid="${u.id}">Add days</button><button class="sm" type="button" data-act="premset" data-uid="${u.id}">Set to</button><button class="sm danger" type="button" data-act="premrev" data-uid="${u.id}">Remove</button></div>
<div class="acts" style="margin-top:8px">${[7, 30, 90, 365].map(n => `<button class="sm" type="button" data-act="premquick" data-n="${n}" data-uid="${u.id}">+${n}d</button>`).join("")}</div>
${recent ? `<h3>Recent signs</h3><ul class="rec">${recent}</ul>` : ""}
<h3>Certificates (${u.certs.length}/10)</h3>${certs}
<details class="add"><summary>Attach certificate</summary>
<input type="text" class="cname" placeholder="Name shown to the user (optional)" maxlength="60" autocomplete="off">
<div class="two" style="margin-top:8px"><label class="fbtn"><span>Choose .p12</span><input type="file" class="fp12"></label><label class="fbtn"><span>Choose .mobileprovision</span><input type="file" class="fprov"></label></div>
<input type="password" class="cpw" placeholder="p12 password" autocomplete="off" style="margin-top:8px">
<div class="acts"><button class="btn" type="button" data-act="addcert" data-uid="${u.id}">Attach</button></div></details>
<details class="add"><summary>Reset password</summary><input type="password" class="npw" placeholder="New password (8+ characters)" autocomplete="off"><div class="acts"><button class="btn" type="button" data-act="setpw" data-uid="${u.id}">Set password</button></div></details>
<div class="acts"><button class="sm danger" type="button" data-act="deluser" data-uid="${u.id}">Delete account</button></div></div></details>`;
        }).join("") || '<p class="m">No accounts yet. Create the first one above.</p>';
        const tot = users.reduce((o, u) => { o.c += u.certs.length; o.s += u.signs7; if (!u.certs.length) o.n++; return o; }, { c: 0, s: 0, n: 0 });
        res.set({ "Cache-Control": "no-store", "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; img-src https: data:; connect-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'; script-src 'unsafe-inline'" });
        res.type("html").send(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><meta name="color-scheme" content="dark"><title>Accounts \u00b7 Admin</title><style>${ACSS}</style></head><body><div class="w"><div class="lay">${menu("/admin/accounts")}<main class="main">
<h1>Accounts</h1><div class="flash" id="fl" hidden></div>
<h2>CREATE ACCOUNT</h2><div class="box">
<div class="two"><div><label for="nu">Username</label><input id="nu" type="text" maxlength="20" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="3-20 letters, numbers, _"></div><div><label for="ne">Email (optional)</label><input id="ne" type="email" maxlength="120" autocomplete="off" autocapitalize="off" placeholder="blank is fine"></div></div>
<label for="np">Password</label><div style="display:flex;gap:8px"><input id="np" type="text" maxlength="128" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="8+ characters"><button class="sm" type="button" id="gen" style="height:44px">Generate</button></div>
<div class="acts"><button class="btn" type="button" id="mk">Create account</button></div>
<p class="mm">Attached certificates are used by the signer on the server. Users can sign with them but can't download, view or remove them.</p></div>
<h2>ACCOUNTS (${users.length})</h2><div class="sum"><div><b>${users.length}</b><span>Accounts</span></div><div><b>${tot.c}</b><span>Certificates</span></div><div><b>${tot.n}</b><span>No cert</span></div><div><b>${tot.s}</b><span>Signs 7d</span></div></div><input type="search" class="fq" id="fq" placeholder="Search accounts" autocomplete="off" autocapitalize="off"><div id="list">${cards}</div>
</main></div></div>
<script>
(function(){
var T=${JSON.stringify(csrf)};
function $(i){return document.getElementById(i);}
function qa(s,r){return Array.prototype.slice.call((r||document).querySelectorAll(s));}
function flash(t,bad){var f=$('fl');f.textContent=t;f.hidden=false;f.style.borderColor=bad?'#f33':'';f.style.color=bad?'#f66':'';window.scrollTo(0,0);}
function post(u,o){o.csrf=T;return fetch(u,{method:'POST',credentials:'same-origin',headers:{'content-type':'application/json'},body:JSON.stringify(o)}).then(function(r){return r.json();});}
function b64(file){return new Promise(function(ok,no){var r=new FileReader();r.onload=function(){var u=new Uint8Array(r.result),a='',i;for(i=0;i<u.length;i+=32768)a+=String.fromCharCode.apply(null,u.subarray(i,i+32768));ok(btoa(a));};r.onerror=no;r.readAsArrayBuffer(file);});}
function done(j,msg,uid){if(j.ok){sessionStorage.setItem('adm:m',msg);if(uid)sessionStorage.setItem('adm:o',uid);location.reload();}else flash(j.error||'Failed.',true);}
$('fq').addEventListener('input',function(){var q=this.value.trim().toLowerCase();qa('#list details.acc').forEach(function(d){d.hidden=!!q&&d.getAttribute('data-q').indexOf(q)<0;});});
var o=sessionStorage.getItem('adm:o');if(o){sessionStorage.removeItem('adm:o');var oc=document.querySelector('details.acc[data-u="'+o+'"]');if(oc)oc.open=true;}
var m=sessionStorage.getItem('adm:m');if(m){sessionStorage.removeItem('adm:m');flash(m);}
$('gen').addEventListener('click',function(){var a=new Uint8Array(12);crypto.getRandomValues(a);var c='abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789',s='';for(var i=0;i<a.length;i++)s+=c[a[i]%c.length];$('np').value=s;});
$('mk').addEventListener('click',function(){var u=$('nu').value.trim(),p=$('np').value;
 post('/admin/accounts/create',{username:u,email:$('ne').value,password:p}).then(function(j){done(j,'Created '+u+' \\u2014 password: '+p);}).catch(function(){flash('Network error.',true);});});
qa('.fbtn input').forEach(function(x){x.addEventListener('change',function(){var g=x.files&&x.files[0];x.parentNode.querySelector('span').textContent=g?g.name:(x.className==='fp12'?'Choose .p12':'Choose .mobileprovision');x.parentNode.className=g?'fbtn has':'fbtn';});});
$('list').addEventListener('click',function(e){var g=e.target.closest('.gc');if(g){g.classList.toggle('on');return;}var b=e.target.closest('[data-act]');if(!b)return;var act=b.getAttribute('data-act'),uid=Number(b.getAttribute('data-uid')),box=b.closest('.box');
 if(act==='saveroles'){var gs=[].map.call(box.querySelectorAll('.gc.on'),function(x){return x.getAttribute('data-g');});post('/admin/accounts/roles',{id:uid,role:box.querySelector('.role').value,groups:gs,sponsor:box.querySelector('.spn').value}).then(function(j){done(j,'Saved. The app picks it up on next refresh.',uid);});}
 else if(act==='premadd'||act==='premset'||act==='premrev'||act==='premquick'){var n=act==='premquick'?Number(b.getAttribute('data-n')):Number(box.querySelector('.pdays').value)||0;
  if((act==='premadd'||act==='premset')&&act!=='premset'&&n<=0){flash('Enter a number of days.',true);return;}
  post('/admin/accounts/premium',{id:uid,mode:act==='premrev'?'revoke':act==='premset'?'set':'add',days:n}).then(function(j){done(j,j.ok&&j.premium&&j.premium.active?'Premium: '+j.premium.days_left+' days left.':'Premium removed.',uid);});}
 else if(act==='deluser'){if(!confirm('Delete this account and its certificates?'))return;post('/admin/accounts/delete',{id:uid}).then(function(j){done(j,'Account deleted.');});}
 else if(act==='delcert'){if(!confirm('Remove this certificate?'))return;post('/admin/accounts/cert/delete',{id:uid,cert:Number(b.getAttribute('data-cert'))}).then(function(j){done(j,'Certificate removed.',uid);});}
 else if(act==='setpw'){var pw=box.querySelector('.npw').value;post('/admin/accounts/password',{id:uid,password:pw}).then(function(j){done(j,'Password updated.',uid);});}
 else if(act==='addcert'){var p=box.querySelector('.fp12').files[0],v=box.querySelector('.fprov').files[0];
  if(!p||!v){flash('Choose both files.',true);return;}
  if(p.size>5e6||v.size>2e6){flash('Files too large.',true);return;}
  b.disabled=true;Promise.all([b64(p),b64(v)]).then(function(a){return post('/admin/accounts/cert/add',{id:uid,name:box.querySelector('.cname').value,p12:a[0],prov:a[1],password:box.querySelector('.cpw').value});})
  .then(function(j){b.disabled=false;done(j,'Certificate attached.',uid);}).catch(function(){b.disabled=false;flash('Network error.',true);});}
});
})();
</script></body></html>`);
      });

      web.post("/admin/accounts/create", auth, ajson, guardA, async (req, res) => {
        try { const b = req.body || {}; const r = await A.create(b.username, b.email, b.password); return r.error ? jf(res, 400, r.error) : res.json({ ok: true, id: r.id }); }
        catch (e) { console.warn("Account create failed:", e.message); return jf(res, 500, "Something went wrong."); }
      }, jerr);
      web.post("/admin/accounts/roles", auth, ajson, guardA, (req, res) => {
        const b = req.body || {}; const id = Number(b.id);
        if (!Number.isInteger(id) || !A.setRole || !A.setGroups || !A.setSponsor) return jf(res, 404, "Account not found.");
        if (!A.setRole(id, b.role)) return jf(res, 400, "Unknown role or account.");
        if (A.setGroups(id, b.groups) === null) return jf(res, 404, "Account not found.");
        A.setSponsor(id, b.sponsor);
        return res.json({ ok: true });
      }, jerr);
      web.post("/admin/accounts/premium", auth, ajson, guardA, (req, res) => {
        const b = req.body || {}, mode = String(b.mode || "add");
        if (!A.setPremium || !["add", "set", "revoke"].includes(mode)) return jf(res, 400, "Bad request.");
        const p = A.setPremium(Number(b.id), mode, b.days);
        return p ? res.json({ ok: true, premium: p }) : jf(res, 404, "Account not found.");
      }, jerr);
      web.post("/admin/accounts/delete", auth, ajson, guardA, (req, res) => {
        const id = Number((req.body || {}).id);
        return Number.isInteger(id) && A.remove(id) ? res.json({ ok: true }) : jf(res, 404, "Account not found.");
      }, jerr);
      web.post("/admin/accounts/password", auth, ajson, guardA, async (req, res) => {
        try { const b = req.body || {}; const err = await A.setPassword(Number(b.id), b.password); return err ? jf(res, 400, err) : res.json({ ok: true }); }
        catch (e) { return jf(res, 500, "Something went wrong."); }
      }, jerr);
      web.post("/admin/accounts/cert/add", auth, ajson, guardA, (req, res) => {
        try { const b = req.body || {}; const err = A.addCert(Number(b.id), b); return err ? jf(res, 400, err) : res.json({ ok: true }); }
        catch (e) { console.warn("Attach cert failed:", e.message); return jf(res, 500, "Something went wrong."); }
      }, jerr);
      web.post("/admin/accounts/cert/delete", auth, ajson, guardA, (req, res) => {
        const b = req.body || {}; const id = Number(b.id), cert = Number(b.cert);
        if (!Number.isInteger(id) || !Number.isInteger(cert)) return jf(res, 400, "Bad request.");
        A.delCert(id, cert); return res.json({ ok: true });
      }, jerr);
    }
  }

  // Staff picks, newest pick first, hidden apps left out.
  const staffKeys = () => staff.filter(k => !hidden.has(k));
  // The catalog item a pick points at: the chosen version, or the newest one when no version was stored
  // (older picks, single-version apps) or the chosen version has since left the catalog.
  const staffItem = (key) => {
    const vs = groups().get(key);
    return vs ? (vs.find(x => verOf(x) === staffVer.get(key)) || vs[0]) : null;
  };
  return {
    wrap, floatPinned, mount, runCheck, newsVer: () => newsVer, newsHidden: (id) => !!newsHiddenQ.get(String(id)),
    staffPicks: staffKeys,                                                    // [key, ...]  (unchanged)
    staffVersion: (key) => staffVer.get(key) || "",                           // chosen version string, "" = none
    staffEntries: () => staffKeys().map(k => ({ key: k, version: staffVer.get(k) || "" })),
    staffItem,                                                                // key -> the chosen version's catalog item
    staffItems: () => staffKeys().map(staffItem).filter(Boolean),             // the picks, resolved to items
  };
}

module.exports = { create };
