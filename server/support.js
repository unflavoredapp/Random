"use strict";
// Support tickets. Anyone signed in can write to support; Premium tickets are flagged "priority" and sorted first for staff.
//
//   POST /app/v1/support          (auth) {subject,message}  -> {ok,id}
//   GET  /app/v1/support          (auth)                    -> {ok, premium, tickets:[{id,subject,message,priority,status,reply,replied_at,created_at}]}
//   GET  /admin/support           (Basic auth) staff page;  /admin/support/data  JSON;  POST /admin/support/reply {id,reply,close?}
//
// Mounted from appapi.js. Priority only changes the ORDER staff see tickets in; it makes no promise about response time.
function mount(web, c) {
  const { db, express, base, jsonBody, jsonErr, needAuth, fail, limited, auth, isPremiumUser, priorityOn } = c;
  db.exec(`CREATE TABLE IF NOT EXISTS support_tickets(
      id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, username TEXT, subject TEXT NOT NULL, message TEXT NOT NULL,
      priority INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'open', reply TEXT, replied_at TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS support_user ON support_tickets(user_id);`);
  const clean = (v, n) => String(v == null ? "" : v).replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, " ").trim().slice(0, n);

  web.post("/app/v1/support", base, jsonBody, needAuth, (req, res) => {
    try {
      if (limited("sp|" + req.me.id, 5, 86400000)) return fail(res, 429, "Too many tickets today. Try again tomorrow.");
      const b = req.body || {};
      const subject = clean(b.subject, 80).replace(/\s+/g, " "), message = clean(b.message, 2000);
      if (subject.length < 3) return fail(res, 400, "Add a short subject.");
      if (message.length < 10) return fail(res, 400, "Tell us a bit more about the problem.");
      if (db.prepare("SELECT COUNT(*) c FROM support_tickets WHERE user_id=? AND status='open'").get(req.me.id).c >= 3)
        return fail(res, 409, "You already have 3 open tickets. Wait for a reply first.");
      const now = new Date().toISOString();
      const priority = priorityOn && isPremiumUser(req.me) ? 1 : 0;
      const id = db.prepare("INSERT INTO support_tickets(user_id,username,subject,message,priority,created_at,updated_at) VALUES(?,?,?,?,?,?,?)")
        .run(req.me.id, req.me.username, subject, message, priority, now, now).lastInsertRowid;
      res.json({ ok: true, id: Number(id), priority: !!priority });
    } catch (e) { console.warn("Support ticket failed:", e.message); fail(res, 500, "Something went wrong. Please try again."); }
  }, jsonErr);

  web.get("/app/v1/support", base, needAuth, (req, res) => {
    const rows = db.prepare("SELECT id,subject,message,priority,status,reply,replied_at,created_at FROM support_tickets WHERE user_id=? ORDER BY id DESC LIMIT 30").all(req.me.id);
    res.json({ ok: true, premium: !!(priorityOn && isPremiumUser(req.me)), tickets: rows.map((r) => ({ ...r, priority: !!r.priority })) });
  });

  // ---------- staff (Basic auth, same login as /admin/app) ----------
  if (typeof auth !== "function") return;
  const aj = express.json({ limit: "8kb", type: "application/json" });

  web.get("/admin/support/data", auth, (_req, res) => {
    res.set("Cache-Control", "no-store");
    const rows = db.prepare(`SELECT * FROM support_tickets
      ORDER BY CASE status WHEN 'open' THEN 0 ELSE 1 END, priority DESC, CASE status WHEN 'open' THEN id END ASC, id DESC LIMIT 200`).all();
    const open = rows.filter((r) => r.status === "open");
    res.json({ ok: true, totals: { open: open.length, priority: open.filter((r) => r.priority).length }, tickets: rows });
  });

  web.post("/admin/support/reply", auth, aj, (req, res) => {
    if (req.get("x-admin") !== "1") return res.status(403).json({ ok: false, error: "Bad request." });
    const b = req.body || {};
    const reply = clean(b.reply, 4000), now = new Date().toISOString();
    const t = db.prepare("SELECT id FROM support_tickets WHERE id=?").get(Number(b.id));
    if (!t) return res.status(404).json({ ok: false, error: "No such ticket." });
    if (!reply && !b.close) return res.status(400).json({ ok: false, error: "Write a reply or close the ticket." });
    if (reply) db.prepare("UPDATE support_tickets SET reply=?, replied_at=?, status=?, updated_at=? WHERE id=?").run(reply, now, b.close ? "closed" : "answered", now, t.id);
    else db.prepare("UPDATE support_tickets SET status='closed', updated_at=? WHERE id=?").run(now, t.id);
    res.json({ ok: true });
  });

  web.get("/admin/support", auth, (_req, res) => {
    res.set({ "Cache-Control": "no-store", "Content-Type": "text/html; charset=utf-8" });
    res.send(ADMIN_HTML);
  });
}

const ADMIN_HTML = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Support</title>
<style>
body{margin:0;background:#101114;color:#e8e8ea;font:14px -apple-system,system-ui,sans-serif;padding:20px;max-width:900px}
h1{font-size:20px;margin:0 0 14px}.tiles{display:flex;gap:10px;margin-bottom:16px}.tile{background:#1a1c21;border-radius:12px;padding:12px 16px;min-width:110px}
.tile b{display:block;font-size:22px}.tile span{color:#9a9aa3;font-size:12px}.t{background:#1a1c21;border-radius:12px;padding:14px;margin-bottom:10px}
.t.pri{box-shadow:inset 3px 0 0 #ffb347}.tag{padding:2px 8px;border-radius:99px;font-size:12px;background:#2a2d34;margin-left:6px}
.pri-tag{background:#4a2a10;color:#ffb347}.open{background:#16351f;color:#6ee08a}.m{color:#9a9aa3;font-size:12px}
pre{white-space:pre-wrap;word-break:break-word;font:inherit;margin:8px 0}.rep{background:#23262d;border-radius:8px;padding:8px 10px;margin:8px 0}
textarea{width:100%;box-sizing:border-box;background:#101114;color:#fff;border:1px solid #2a2d34;border-radius:8px;padding:8px;min-height:70px;font:inherit}
button{background:#2a2d34;color:#fff;border:0;border-radius:8px;padding:6px 12px;cursor:pointer;margin-right:6px}button:hover{background:#3a7bd5}</style>
<h1>Support</h1><div class="tiles" id="t"></div><div id="l"></div><p class="m" id="msg"></p>
<script>
function e(s){var d=document.createElement("div");d.textContent=s==null?"":String(s);return d.innerHTML;}
function load(){fetch("/admin/support/data",{credentials:"same-origin"}).then(function(r){return r.json()}).then(function(d){
 document.getElementById("t").innerHTML="<div class='tile'><b>"+d.totals.open+"</b><span>open</span></div><div class='tile'><b>"+d.totals.priority+"</b><span>premium waiting</span></div>";
 document.getElementById("l").innerHTML=d.tickets.map(function(t){
  return "<div class='t"+(t.priority&&t.status==="open"?" pri":"")+"'><b>"+e(t.subject)+"</b>"+(t.priority?"<span class='tag pri-tag'>PREMIUM</span>":"")+"<span class='tag "+(t.status==="open"?"open":"")+"'>"+e(t.status)+"</span>"+
  "<div class='m'>"+e(t.username)+" (user "+e(t.user_id)+") \\u00b7 "+e((t.created_at||"").replace("T"," ").slice(0,16))+"</div><pre>"+e(t.message)+"</pre>"+
  (t.reply?"<div class='rep'><div class='m'>Your reply</div><pre>"+e(t.reply)+"</pre></div>":"")+
  (t.status==="closed"?"":"<textarea id='r"+t.id+"' placeholder='Reply'></textarea><div style='margin-top:6px'><button data-id='"+t.id+"' data-c='0'>Send reply</button><button data-id='"+t.id+"' data-c='1'>Reply and close</button></div>")+"</div>";
 }).join("")||"<p class='m'>No tickets yet.</p>";});}
document.getElementById("l").addEventListener("click",function(ev){var id=ev.target.getAttribute&&ev.target.getAttribute("data-id");if(!id)return;
 var ta=document.getElementById("r"+id);
 fetch("/admin/support/reply",{method:"POST",credentials:"same-origin",headers:{"content-type":"application/json","x-admin":"1"},body:JSON.stringify({id:Number(id),reply:ta?ta.value:"",close:ev.target.getAttribute("data-c")==="1"})})
 .then(function(r){return r.json()}).then(function(j){document.getElementById("msg").textContent=j.ok?"Saved.":(j.error||"Failed");load();});});
load();
</script>`;

module.exports = { mount };
