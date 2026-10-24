"use strict";
// Premium payments in Litecoin. Non-custodial: the server holds only your extended PUBLIC key (LTC_XPUB), derives a fresh
// receive address for every order, and watches the chain through a block-explorer API. Funds go straight to your wallet.
// There are no private keys, no card data and no third-party processor involved.
//
//   GET  /app/v1/shop                  -> {plans:[{id,name,days,amount(usd cents),currency}], perks, crypto:{coin,enabled,confirmations,quote_minutes}}
//   POST /app/v1/checkout   (auth) {plan}      -> order {order_id,address,amount_ltc,uri,expires_at,...}  (re-uses your open order for the same plan)
//   POST /app/v1/checkout/verify (auth) {order_id?} -> order (re-checks the chain now; no id = your latest open order; 404 if none)
//   GET  /app/v1/purchases  (auth)     -> {purchases:[...]}
//   admin (Basic auth): GET /admin/payments, /admin/payments/data;  POST /admin/payments/grant | /admin/payments/refund (need x-admin: 1)
//
// Env: LTC_XPUB (account-level extended public key, e.g. m/84'/2'/0'), LTC_CONFS (2), LTC_QUOTE_MIN (30), LTC_TOLERANCE_PCT (1),
//      LTC_POLL_SEC (30), LTC_EXPLORER (comma list, default https://litecoinspace.org/api), LTC_PRICE_URLS (comma list of price feeds),
//      LTC_PREMIUM_MAX_OPEN (5), LTC_RATE_CACHE_SEC (60), LTC_VERIFY_MIN_SEC (8)
// Price: the USD price of each plan is fixed here; the LTC amount is quoted at order time from live price feeds.
const { makeDeriver } = require("./ltc-hd");

const PLANS = {
  premium_30: { name: "Premium · 30 days", days: 30, amount: 299, currency: "usd" },
  premium_90: { name: "Premium · 90 days", days: 90, amount: 799, currency: "usd" },
  premium_365: { name: "Premium · 365 days", days: 365, amount: 2499, currency: "usd" },
};

const envNum = (k, d, min = 0) => { const v = Number(process.env[k]); return Number.isFinite(v) && v >= min ? v : d; };
const list = (k, d) => String(process.env[k] || d).split(",").map((s) => s.trim().replace(/\/+$/, "")).filter(Boolean);
const SAT = 100000000;
const ltcStr = (sat) => `${Math.floor(sat / SAT)}.${String(sat % SAT).padStart(8, "0")}`;

function mount(web, c) {
  const { db, base, jsonBody, jsonErr, needAuth, fail, limited, setPremium, auth, express } = c;
  const describePerks = typeof c.describePerks === "function" ? c.describePerks : () => [];
  const CONFS = Math.max(1, Math.floor(envNum("LTC_CONFS", 2, 1)));
  const QUOTE_MS = envNum("LTC_QUOTE_MIN", 30, 5) * 60000;
  const TOL = Math.min(5, envNum("LTC_TOLERANCE_PCT", 1));
  const POLL_MS = envNum("LTC_POLL_SEC", 30, 1) * 1000;
  const MAX_OPEN = Math.max(1, Math.floor(envNum("LTC_PREMIUM_MAX_OPEN", 5, 1)));
  const EXPLORERS = list("LTC_EXPLORER", "https://litecoinspace.org/api");
  const PRICE_URLS = list("LTC_PRICE_URLS", "https://api.coinbase.com/v2/prices/LTC-USD/spot,https://api.coingecko.com/api/v3/simple/price?ids=litecoin&vs_currencies=usd");
  const RATE_CACHE_MS = envNum("LTC_RATE_CACHE_SEC", 60) * 1000, VERIFY_GAP_MS = envNum("LTC_VERIFY_MIN_SEC", 8) * 1000;
  const LATE_WATCH_MS = 24 * 3600000, UNDERPAID_AFTER_MS = 2 * 3600000;

  let derive = null;
  if (process.env.LTC_XPUB) {
    try { derive = makeDeriver(process.env.LTC_XPUB, "ltc"); console.log("Litecoin payments on. Address #1 (check it matches your wallet's receive address 1):", derive(1)); }
    catch (e) { console.warn("Litecoin payments off:", e.message); }
  } else console.warn("Litecoin payments off: set LTC_XPUB (extended PUBLIC key) to enable.");
  const enabled = !!derive;

  db.exec(`CREATE TABLE IF NOT EXISTS ltc_orders(
      id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, plan TEXT NOT NULL, days INTEGER NOT NULL, usd_cents INTEGER NOT NULL,
      rate_usd REAL NOT NULL, amount_sat INTEGER NOT NULL, address TEXT UNIQUE, status TEXT NOT NULL,
      received_sat INTEGER NOT NULL DEFAULT 0, confirmations INTEGER NOT NULL DEFAULT 0, txids TEXT,
      created_at TEXT NOT NULL, expires_at TEXT NOT NULL, updated_at TEXT NOT NULL, paid_at TEXT, checked_at INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX IF NOT EXISTS ltc_orders_user ON ltc_orders(user_id);
    CREATE INDEX IF NOT EXISTS ltc_orders_status ON ltc_orders(status);`);
  const now = () => new Date().toISOString();
  const planOf = (id) => (Object.prototype.hasOwnProperty.call(PLANS, id) ? PLANS[id] : null);
  const q = {
    byId: db.prepare("SELECT * FROM ltc_orders WHERE id=?"),
    insert: db.prepare("INSERT INTO ltc_orders(user_id,plan,days,usd_cents,rate_usd,amount_sat,status,created_at,expires_at,updated_at) VALUES(?,?,?,?,?,?,'pending',?,?,?)"),
    setAddr: db.prepare("UPDATE ltc_orders SET address=? WHERE id=?"),
    mine: db.prepare("SELECT * FROM ltc_orders WHERE user_id=? ORDER BY id DESC LIMIT 50"),
    openMine: db.prepare("SELECT * FROM ltc_orders WHERE user_id=? AND status IN ('pending','seen') ORDER BY id DESC"),
    watch: db.prepare("SELECT * FROM ltc_orders WHERE status IN ('pending','seen') OR (status='expired' AND expires_at>?) ORDER BY id"),
    progress: db.prepare("UPDATE ltc_orders SET status=?, received_sat=?, confirmations=?, txids=?, updated_at=?, checked_at=? WHERE id=? AND status IN ('pending','seen','expired','late','underpaid')"),
    touch: db.prepare("UPDATE ltc_orders SET checked_at=? WHERE id=?"),
    // Flip to 'paid' only from these states: .changes === 1 means THIS call won, so the days are granted exactly once.
    claim: db.prepare("UPDATE ltc_orders SET status='paid', received_sat=?, confirmations=?, txids=?, paid_at=?, updated_at=? WHERE id=? AND status IN ('pending','seen')"),
    adminClaim: db.prepare("UPDATE ltc_orders SET status='paid', paid_at=?, updated_at=? WHERE id=? AND status IN ('pending','seen','late','underpaid','expired','user_missing')"),
    setStatus: db.prepare("UPDATE ltc_orders SET status=?, updated_at=? WHERE id=?"),
    refund: db.prepare("UPDATE ltc_orders SET status='refunded', updated_at=? WHERE id=? AND status='paid'"),
    prem: db.prepare("SELECT premium_until FROM local_users WHERE id=?"),
    setPrem: db.prepare("UPDATE local_users SET premium_until=? WHERE id=?"),
  };

  const getOrder = (id) => q.byId.get(id);

  function takeDays(uid, days) {
    const r = q.prem.get(uid);
    const until = r && r.premium_until ? Date.parse(r.premium_until) : NaN;
    if (!Number.isFinite(until)) return;
    const next = until - days * 86400000;
    q.setPrem.run(next > Date.now() ? new Date(next).toISOString() : null, uid);
  }

  // ---------- price ----------
  let rateCache = { at: 0, v: 0 };
  async function getJSON(url) {
    const r = await fetch(url, { signal: AbortSignal.timeout(10000), headers: { accept: "application/json" } });
    if (!r.ok) throw new Error("HTTP " + r.status);
    return r.json();
  }
  const pickRate = (j) => Number((j && j.data && j.data.amount) || (j && j.litecoin && j.litecoin.usd) || (j && j.price) || NaN);
  // Uses the LOWER of the agreeing feeds (more LTC asked, so we never receive less than the USD price). If feeds disagree by
  // more than 5%, one of them is wrong and we refuse to quote rather than guess.
  async function ltcUsd() {
    if (rateCache.v && Date.now() - rateCache.at < RATE_CACHE_MS) return rateCache.v;
    const got = [];
    await Promise.all(PRICE_URLS.map(async (u) => { try { const v = pickRate(await getJSON(u)); if (Number.isFinite(v) && v > 1 && v < 100000) got.push(v); } catch { /* try the others */ } }));
    if (!got.length) throw new Error("no price feed answered");
    if (got.length > 1 && Math.max(...got) / Math.min(...got) > 1.05) throw new Error("price feeds disagree: " + got.join(" vs "));
    rateCache = { at: Date.now(), v: Math.min(...got) };
    return rateCache.v;
  }

  // ---------- chain watching (Esplora-style explorer API) ----------
  async function explorer(path, asText) {
    let last;
    for (const b of EXPLORERS) {
      try {
        const r = await fetch(b + path, { signal: AbortSignal.timeout(10000) });
        if (!r.ok) throw new Error("HTTP " + r.status);
        return asText ? (await r.text()).trim() : await r.json();
      } catch (e) { last = e; }
    }
    throw last || new Error("no explorer configured");
  }
  // What the address has received: [{txid, sat, confs}]
  async function incoming(address) {
    const tip = Number(await explorer("/blocks/tip/height", true));
    const txs = await explorer("/address/" + encodeURIComponent(address) + "/txs");
    if (!Number.isInteger(tip) || !Array.isArray(txs)) throw new Error("unexpected explorer reply");
    const out = [];
    for (const t of txs) {
      if (!t || typeof t.txid !== "string" || !Array.isArray(t.vout)) throw new Error("unexpected explorer reply");
      const sat = t.vout.reduce((s, o) => s + (o && o.scriptpubkey_address === address && Number.isSafeInteger(o.value) ? o.value : 0), 0);
      if (!sat) continue;
      const st = t.status || {};
      out.push({ txid: t.txid, sat, confs: st.confirmed && Number.isInteger(st.block_height) ? Math.max(1, tip - st.block_height + 1) : 0 });
    }
    return out;
  }

  const needSat = (o) => Math.ceil(o.amount_sat * (1 - TOL / 100));

  // Looks at the chain for one order and moves it along. Safe to call concurrently and repeatedly.
  async function evaluate(order) {
    const t = Date.now();
    if (!order.address) return order;
    let txs;
    try { txs = await incoming(order.address); }
    catch (e) { console.warn("Explorer check failed for order", order.id, e.message); return getOrder(order.id); }
    const total = txs.reduce((s, x) => s + x.sat, 0);
    const confirmed = txs.filter((x) => x.confs >= CONFS).reduce((s, x) => s + x.sat, 0);
    const best = txs.reduce((m, x) => Math.max(m, x.confs), 0);
    const ids = JSON.stringify(txs.map((x) => x.txid));
    const expired = t > Date.parse(order.expires_at);
    const cur = getOrder(order.id).status;

    if (confirmed >= needSat(order)) {
      if (cur === "pending" || cur === "seen") {
        if (Number(q.claim.run(confirmed, best, ids, now(), now(), order.id).changes) === 1) {
          const r = setPremium(order.user_id, "add", order.days);
          if (!r) { q.setStatus.run("user_missing", now(), order.id); console.warn("Paid order for unknown user:", order.id); }
          else console.log(`Premium +${order.days}d granted to user ${order.user_id} (LTC order ${order.id}, ${ltcStr(confirmed)} LTC)`);
        }
      } else if (cur === "expired" || cur === "underpaid") q.progress.run("late", total, best, ids, now(), t, order.id); // needs a human decision
    } else if (total > 0) {
      let next = cur;
      if (cur === "pending") next = "seen";
      else if (cur === "expired") next = "late";
      else if (cur === "seen" && t > Date.parse(order.expires_at) + UNDERPAID_AFTER_MS) next = "underpaid";
      q.progress.run(next, total, best, ids, now(), t, order.id);
    } else if (cur === "pending" && expired) {
      q.progress.run("expired", 0, 0, null, now(), t, order.id);
    } else q.touch.run(t, order.id);
    return getOrder(order.id);
  }

  let polling = false;
  async function poll() {
    if (!enabled || polling) return;
    polling = true;
    try { for (const o of q.watch.all(new Date(Date.now() - LATE_WATCH_MS).toISOString())) await evaluate(o); }
    catch (e) { console.warn("LTC poll failed:", e.message); }
    finally { polling = false; }
  }
  if (enabled) { const h = setInterval(poll, POLL_MS); if (h.unref) h.unref(); }

  // ---------- views ----------
  const view = (o) => ({
    order_id: o.id, plan: o.plan, name: (planOf(o.plan) || {}).name || o.plan, days: o.days, status: o.status,
    address: o.address, amount_sat: o.amount_sat, amount_ltc: ltcStr(o.amount_sat), usd_cents: o.usd_cents, rate_usd: o.rate_usd,
    expires_at: o.expires_at, created_at: o.created_at,
    uri: `litecoin:${o.address}?amount=${ltcStr(o.amount_sat)}&label=AirShare`,
    confirmations: o.confirmations, required_confirmations: CONFS, received_ltc: ltcStr(o.received_sat),
  });

  // ---------- app routes ----------
  web.get("/app/v1/shop", base, (_req, res) => {
    res.json({ ok: true, plans: Object.entries(PLANS).map(([id, p]) => ({ id, name: p.name, days: p.days, amount: p.amount, currency: p.currency })), perks: describePerks(),
      crypto: { coin: "LTC", enabled, confirmations: CONFS, quote_minutes: Math.round(QUOTE_MS / 60000) } });
  });

  web.post("/app/v1/checkout", base, jsonBody, needAuth, async (req, res) => {
    try {
      if (!enabled) return fail(res, 503, "Litecoin payments aren't set up yet.");
      if (limited("co|" + req.me.id, 20, 3600000)) return fail(res, 429, "Too many checkout attempts. Try again later.");
      const planId = String((req.body && req.body.plan) || "");
      const plan = planOf(planId);
      if (!plan) return fail(res, 400, "Unknown plan.");
      const open = q.openMine.all(req.me.id);
      const same = open.find((o) => o.plan === planId && o.status === "pending" && Date.parse(o.expires_at) > Date.now() + 60000);
      if (same) return res.json({ ok: true, ...view(same) });          // same plan, still valid: show the same address and amount
      if (open.filter((o) => Date.parse(o.expires_at) > Date.now()).length >= MAX_OPEN) return fail(res, 429, "You have too many unpaid orders. Pay or wait for them to expire.");
      let rate;
      try { rate = await ltcUsd(); } catch (e) { console.warn("Price unavailable:", e.message); return fail(res, 503, "Can't price Litecoin right now. Please try again in a minute."); }
      const sat = Math.ceil((plan.amount * 1e6) / rate - 1e-4); // cents * 1e8 / (rate * 100), without float noise
      const created = new Date(), id = Number(q.insert.run(req.me.id, planId, plan.days, plan.amount, rate, sat, created.toISOString(), new Date(created.getTime() + QUOTE_MS).toISOString(), created.toISOString()).lastInsertRowid);
      q.setAddr.run(derive(id), id);
      res.json({ ok: true, ...view(getOrder(id)) });
    } catch (e) {
      console.warn("Checkout failed:", e.message);
      fail(res, 500, "Couldn't start checkout. Please try again.");
    }
  }, jsonErr);

  // Re-checks the chain for an order right now (the app calls this every few seconds while the pay screen is open).
  web.post("/app/v1/checkout/verify", base, jsonBody, needAuth, async (req, res) => {
    try {
      if (limited("vf|" + req.me.id, 600, 3600000)) return fail(res, 429, "Too many checks. Try again later.");
      const oid = Number(req.body && req.body.order_id);
      const row = Number.isInteger(oid) && oid > 0 ? getOrder(oid) : q.openMine.get(req.me.id);
      if (!row || row.user_id !== req.me.id) return fail(res, 404, "No purchase found to check.");
      let o = row;
      if (["pending", "seen", "expired", "late", "underpaid"].includes(row.status) && enabled && Date.now() - row.checked_at >= VERIFY_GAP_MS) o = await evaluate(row);
      res.json({ ok: true, ...view(o) });
    } catch (e) {
      console.warn("Verify failed:", e.message);
      fail(res, 500, "Couldn't check that purchase right now. Please try again.");
    }
  }, jsonErr);

  web.get("/app/v1/purchases", base, needAuth, (req, res) => {
    res.json({ ok: true, purchases: q.mine.all(req.me.id).map((o) => { const v = view(o); return { session_id: String(o.id), order_id: o.id, name: v.name, amount: o.usd_cents, currency: "usd", amount_ltc: v.amount_ltc, status: o.status, created_at: o.created_at }; }) });
  });

  // ---------- admin (Basic auth) ----------
  if (typeof auth === "function") {
    const aj = express.json({ limit: "8kb", type: "application/json" });
    const FLAGGED = new Set(["late", "underpaid", "user_missing"]);

    web.get("/admin/payments/data", auth, (_req, res) => {
      res.set("Cache-Control", "no-store");
      const rows = db.prepare("SELECT o.*, u.username AS username FROM ltc_orders o LEFT JOIN local_users u ON u.id=o.user_id ORDER BY o.id DESC LIMIT 300").all()
        .map((o) => ({ id: o.id, username: o.username, user_id: o.user_id, plan: o.plan, days: o.days, usd_cents: o.usd_cents, status: o.status, address: o.address,
          amount_ltc: ltcStr(o.amount_sat), received_ltc: ltcStr(o.received_sat), confirmations: o.confirmations, created_at: o.created_at, txids: o.txids ? JSON.parse(o.txids) : [] }));
      const t = { paid_count: 0, paid_usd_cents: 0, open: 0, refunded: 0, flagged: 0 };
      for (const r of db.prepare("SELECT status, COUNT(*) n, COALESCE(SUM(usd_cents),0) a FROM ltc_orders GROUP BY status").all()) {
        if (r.status === "paid") { t.paid_count = r.n; t.paid_usd_cents = r.a; }
        else if (r.status === "pending" || r.status === "seen") t.open += r.n;
        else if (r.status === "refunded") t.refunded = r.n;
        if (FLAGGED.has(r.status)) t.flagged += r.n;
      }
      res.json({ ok: true, enabled, totals: t, rows });
    });

    // Late or short payments are never granted automatically. After looking at the transaction, staff decide.
    web.post("/admin/payments/grant", auth, aj, (req, res) => {
      if (req.get("x-admin") !== "1") return res.status(403).json({ ok: false, error: "Bad request." });
      const row = getOrder(Number((req.body || {}).order_id));
      if (!row) return res.status(404).json({ ok: false, error: "No such order." });
      if (Number(q.adminClaim.run(now(), now(), row.id).changes) !== 1) return res.status(400).json({ ok: false, error: "That order can't be granted from its current status." });
      if (!setPremium(row.user_id, "add", row.days)) { q.setStatus.run("user_missing", now(), row.id); return res.status(404).json({ ok: false, error: "User no longer exists." }); }
      console.log("Admin granted LTC order", row.id);
      res.json({ ok: true });
    });

    // Litecoin can't be pulled back, so a refund is two steps: this removes the days and marks the order; you send the coins back yourself.
    web.post("/admin/payments/refund", auth, aj, (req, res) => {
      if (req.get("x-admin") !== "1") return res.status(403).json({ ok: false, error: "Bad request." });
      const row = getOrder(Number((req.body || {}).order_id));
      if (!row || row.status !== "paid") return res.status(400).json({ ok: false, error: "Only paid orders can be marked refunded." });
      if (Number(q.refund.run(now(), row.id).changes) !== 1) return res.status(400).json({ ok: false, error: "Already refunded." });
      takeDays(row.user_id, row.days);
      res.json({ ok: true, note: `Days removed. Send ${ltcStr(row.received_sat || row.amount_sat)} LTC back to the buyer from your wallet.` });
    });

    web.get("/admin/payments", auth, (_req, res) => {
      res.set({ "Cache-Control": "no-store", "Content-Type": "text/html; charset=utf-8" });
      res.send(ADMIN_HTML);
    });
  }
  return { poll, evaluate };
}

const ADMIN_HTML = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Payments</title>
<style>
body{margin:0;background:#101114;color:#e8e8ea;font:14px -apple-system,system-ui,sans-serif;padding:20px}
h1{font-size:20px;margin:0 0 14px}.tiles{display:flex;gap:10px;flex-wrap:wrap;margin-bottom:16px}
.tile{background:#1a1c21;border-radius:12px;padding:12px 16px;min-width:110px}.tile b{display:block;font-size:22px}.tile span{color:#9a9aa3;font-size:12px}
.tile.warn b{color:#ffb347}table{width:100%;border-collapse:collapse;background:#1a1c21;border-radius:12px;overflow:hidden}
th,td{text-align:left;padding:9px 12px;border-bottom:1px solid #26282e;white-space:nowrap}th{color:#9a9aa3;font-weight:600;font-size:12px}
tr.flag td{background:#2a1f12}.tag{padding:2px 8px;border-radius:99px;font-size:12px;background:#2a2d34}
.paid{background:#16351f;color:#6ee08a}.refunded,.expired{background:#2b2b2b;color:#bbb}.seen{background:#1f2b45;color:#8ab4ff}
.late,.underpaid,.user_missing{background:#4a2a10;color:#ffb347}button{background:#2a2d34;color:#fff;border:0;border-radius:8px;padding:5px 10px;cursor:pointer;margin-right:4px}
button:hover{background:#3a7bd5}.m{color:#9a9aa3}.wrap{overflow-x:auto}</style>
<h1>Payments (Litecoin)</h1><div class="tiles" id="t"></div><div class="wrap"><table><thead><tr>
<th>When</th><th>User</th><th>Plan</th><th>Price</th><th>LTC asked</th><th>LTC seen</th><th>Status</th><th>Address</th><th></th></tr></thead><tbody id="b"></tbody></table></div>
<p class="m" id="msg"></p>
<script>
function e(s){var d=document.createElement("div");d.textContent=s==null?"":String(s);return d.innerHTML;}
function usd(c){return "$"+((c||0)/100).toFixed(2);}
function act(url,id,confirmMsg){if(!confirm(confirmMsg))return;
 fetch(url,{method:"POST",credentials:"same-origin",headers:{"content-type":"application/json","x-admin":"1"},body:JSON.stringify({order_id:id})})
 .then(function(r){return r.json()}).then(function(j){document.getElementById("msg").textContent=j.ok?(j.note||"Done."):(j.error||"Failed");load();});}
function load(){fetch("/admin/payments/data",{credentials:"same-origin"}).then(function(r){return r.json()}).then(function(d){
 var t=d.totals;
 document.getElementById("t").innerHTML=
  "<div class='tile'><b>"+usd(t.paid_usd_cents)+"</b><span>"+t.paid_count+" paid</span></div>"+
  "<div class='tile'><b>"+t.open+"</b><span>waiting for payment</span></div>"+
  "<div class='tile'><b>"+t.refunded+"</b><span>refunded</span></div>"+
  "<div class='tile"+(t.flagged?" warn":"")+"'><b>"+t.flagged+"</b><span>need attention</span></div>";
 document.getElementById("b").innerHTML=d.rows.map(function(r){
  var flag=(r.status==="late"||r.status==="underpaid"||r.status==="user_missing");
  var can=["late","underpaid","user_missing","seen","expired","pending"].indexOf(r.status)>=0;
  return "<tr"+(flag?" class='flag'":"")+"><td>"+e((r.created_at||"").replace("T"," ").slice(0,16))+"</td><td>"+e(r.username||("user "+r.user_id))+"</td><td>"+e(r.plan)+" <span class='m'>"+e(r.days)+"d</span></td><td>"+usd(r.usd_cents)+"</td><td>"+e(r.amount_ltc)+"</td><td>"+e(r.received_ltc)+" <span class='m'>"+e(r.confirmations)+" conf</span></td><td><span class='tag "+e(r.status)+"'>"+e(r.status)+"</span></td><td class='m'>"+e(r.address)+"</td><td>"+
   (can?"<button data-g='"+r.id+"'>Grant</button>":"")+(r.status==="paid"?"<button data-r='"+r.id+"'>Mark refunded</button>":"")+"</td></tr>";
 }).join("")||"<tr><td colspan='9' class='m'>No payments yet.</td></tr>";
 });}
document.getElementById("b").addEventListener("click",function(ev){var g=ev.target.getAttribute&&ev.target.getAttribute("data-g"),r=ev.target.getAttribute&&ev.target.getAttribute("data-r");
 if(g)act("/admin/payments/grant",Number(g),"Grant premium for this order? Check the transaction in your wallet or an explorer first.");
 if(r)act("/admin/payments/refund",Number(r),"Remove the premium days and mark this order refunded? You must send the LTC back yourself.");});
load();setInterval(load,15000);
</script>`;

module.exports = { mount, PLANS };
