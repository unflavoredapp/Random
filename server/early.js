"use strict";
// Early looks: posts staff write ahead of time. Premium members (and staff) see a post as soon as it exists; everyone
// else sees it once its public_at time has passed.
//
//   GET  /app/v1/early            (auth) -> {ok, premium, posts:[{id,title,body,public_at,early}], locked}
//        `locked` = how many posts are still early-only and hidden from this account (used for the "Get Premium" nudge)
//   GET  /admin/early             (Basic auth) staff page;  /admin/early/data  JSON
//   POST /admin/early/save   {id?,title,body,public_at}   POST /admin/early/delete {id}
function mount(web, c) {
  const { db, express, base, needAuth, auth, canSeeEarly, earlyOn } = c;
  db.exec(`CREATE TABLE IF NOT EXISTS early_posts(
      id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT NOT NULL, public_at TEXT NOT NULL, created_at TEXT NOT NULL);`);
  const clean = (v, n) => String(v == null ? "" : v).replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, " ").trim().slice(0, n);

  web.get("/app/v1/early", base, needAuth, (req, res) => {
    const nowIso = new Date().toISOString();
    const full = !!(earlyOn && canSeeEarly(req.me));
    const posts = db.prepare("SELECT id,title,body,public_at FROM early_posts WHERE (? OR public_at<=?) ORDER BY public_at DESC, id DESC LIMIT 50").all(full ? 1 : 0, nowIso);
    const locked = full ? 0 : db.prepare("SELECT COUNT(*) c FROM early_posts WHERE public_at>?").get(nowIso).c;
    res.json({ ok: true, premium: full, locked, posts: posts.map((p) => ({ ...p, early: p.public_at > nowIso })) });
  });

  if (typeof auth !== "function") return;
  const aj = express.json({ limit: "16kb", type: "application/json" });

  web.get("/admin/early/data", auth, (_req, res) => {
    res.set("Cache-Control", "no-store");
    res.json({ ok: true, now: new Date().toISOString(), posts: db.prepare("SELECT * FROM early_posts ORDER BY public_at DESC, id DESC LIMIT 100").all() });
  });

  web.post("/admin/early/save", auth, aj, (req, res) => {
    if (req.get("x-admin") !== "1") return res.status(403).json({ ok: false, error: "Bad request." });
    const b = req.body || {};
    const title = clean(b.title, 120), body = clean(b.body, 5000);
    const t = Date.parse(String(b.public_at || ""));
    if (!title || !body) return res.status(400).json({ ok: false, error: "Title and text are required." });
    if (!Number.isFinite(t)) return res.status(400).json({ ok: false, error: "Pick a public date." });
    const publicAt = new Date(t).toISOString();
    if (b.id) {
      const r = db.prepare("UPDATE early_posts SET title=?, body=?, public_at=? WHERE id=?").run(title, body, publicAt, Number(b.id));
      if (!Number(r.changes)) return res.status(404).json({ ok: false, error: "No such post." });
      return res.json({ ok: true, id: Number(b.id) });
    }
    const id = db.prepare("INSERT INTO early_posts(title,body,public_at,created_at) VALUES(?,?,?,?)").run(title, body, publicAt, new Date().toISOString()).lastInsertRowid;
    res.json({ ok: true, id: Number(id) });
  });

  web.post("/admin/early/delete", auth, aj, (req, res) => {
    if (req.get("x-admin") !== "1") return res.status(403).json({ ok: false, error: "Bad request." });
    db.prepare("DELETE FROM early_posts WHERE id=?").run(Number((req.body || {}).id));
    res.json({ ok: true });
  });

  web.get("/admin/early", auth, (_req, res) => {
    res.set({ "Cache-Control": "no-store", "Content-Type": "text/html; charset=utf-8" });
    res.send(ADMIN_HTML);
  });
}

const ADMIN_HTML = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Early looks</title>
<style>
body{margin:0;background:#101114;color:#e8e8ea;font:14px -apple-system,system-ui,sans-serif;padding:20px;max-width:760px}
h1{font-size:20px;margin:0 0 14px}.box,.t{background:#1a1c21;border-radius:12px;padding:14px;margin-bottom:12px}
input,textarea{width:100%;box-sizing:border-box;background:#101114;color:#fff;border:1px solid #2a2d34;border-radius:8px;padding:8px;font:inherit;margin:4px 0 8px}
textarea{min-height:110px}button{background:#2a2d34;color:#fff;border:0;border-radius:8px;padding:6px 12px;cursor:pointer;margin-right:6px}button:hover{background:#3a7bd5}
.tag{padding:2px 8px;border-radius:99px;font-size:12px;background:#2a2d34;margin-left:6px}.early{background:#4a2a10;color:#ffb347}.live{background:#16351f;color:#6ee08a}
.m{color:#9a9aa3;font-size:12px}pre{white-space:pre-wrap;word-break:break-word;font:inherit;margin:8px 0}</style>
<h1>Early looks</h1>
<div class="box"><b id="ft">New post</b><input id="ti" maxlength="120" placeholder="Title"><textarea id="bo" placeholder="What's coming"></textarea>
<div class="m">Premium members see it right away. Everyone else sees it from:</div><input id="pa" type="datetime-local">
<button id="sv">Save</button><button id="cl">Clear</button><span class="m" id="msg"></span></div>
<div id="l"></div>
<script>
var P=[];
function e(s){var d=document.createElement("div");d.textContent=s==null?"":String(s);return d.innerHTML;}
function localVal(iso){var d=new Date(iso);d.setMinutes(d.getMinutes()-d.getTimezoneOffset());return d.toISOString().slice(0,16);}
function reset(){document.getElementById("ft").textContent="New post";document.getElementById("ti").value="";document.getElementById("bo").value="";
 document.getElementById("pa").value=localVal(new Date(Date.now()+7*86400000).toISOString());window.EID=null;}
function load(){fetch("/admin/early/data",{credentials:"same-origin"}).then(function(r){return r.json()}).then(function(d){P=d.posts;
 document.getElementById("l").innerHTML=P.map(function(p,i){var early=p.public_at>d.now;
  return "<div class='t'><b>"+e(p.title)+"</b><span class='tag "+(early?"early":"live")+"'>"+(early?"Early \\u00b7 public "+e(p.public_at.slice(0,16).replace("T"," "))+" UTC":"Public")+"</span><pre>"+e(p.body)+"</pre>"+
  "<button data-e='"+i+"'>Edit</button><button data-d='"+p.id+"'>Delete</button></div>";}).join("")||"<p class='m'>No posts yet.</p>";});}
document.getElementById("l").addEventListener("click",function(ev){var g=ev.target.getAttribute&&ev.target;if(!g||!g.getAttribute)return;
 var ei=g.getAttribute("data-e"),di=g.getAttribute("data-d");
 if(ei!==null){var p=P[Number(ei)];window.EID=p.id;document.getElementById("ft").textContent="Editing post "+p.id;document.getElementById("ti").value=p.title;document.getElementById("bo").value=p.body;document.getElementById("pa").value=localVal(p.public_at);window.scrollTo(0,0);}
 if(di!==null&&confirm("Delete this post?"))fetch("/admin/early/delete",{method:"POST",credentials:"same-origin",headers:{"content-type":"application/json","x-admin":"1"},body:JSON.stringify({id:Number(di)})}).then(load);});
document.getElementById("cl").onclick=reset;
document.getElementById("sv").onclick=function(){var v=document.getElementById("pa").value;
 fetch("/admin/early/save",{method:"POST",credentials:"same-origin",headers:{"content-type":"application/json","x-admin":"1"},body:JSON.stringify({id:window.EID||undefined,title:document.getElementById("ti").value,body:document.getElementById("bo").value,public_at:v?new Date(v).toISOString():""})})
 .then(function(r){return r.json()}).then(function(j){document.getElementById("msg").textContent=j.ok?"Saved.":(j.error||"Failed");if(j.ok){reset();load();}});};
reset();load();
</script>`;

module.exports = { mount };
