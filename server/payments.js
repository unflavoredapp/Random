"use strict";
// Stripe payments for AirShare premium days. Mounted from appapi.js.
//
//   GET  /app/v1/shop        -> {ok, plans:[{id,name,days,amount,currency}]}
//   POST /app/v1/checkout    (auth) {plan}  -> {ok, url, session_id}   open url in Safari; Stripe hosts the card form
//   GET  /app/v1/purchases   (auth)         -> {ok, purchases:[...]}
//   POST /stripe/webhook     Stripe-signed  -> grants premium days once per paid checkout session
//   GET  /pay/done           landing page Stripe sends the buyer back to
//
// No npm dependency: it talks to Stripe's REST API with fetch and verifies webhook signatures with crypto.
// Premium days are granted ONLY by the webhook, never by anything the app says, and only once per session.
//
// Env: STRIPE_SECRET_KEY (sk_live_... / sk_test_...), STRIPE_WEBHOOK_SECRET (whsec_...), PUBLIC_BASE_URL (default https://airshare.lol)
const crypto = require("crypto");

// Edit prices and lengths here. The server is the only source of truth for what a plan costs.
const PLANS = {
  premium_30: { name: "Premium · 30 days", days: 30, amount: 299, currency: "usd" },
  premium_90: { name: "Premium · 90 days", days: 90, amount: 799, currency: "usd" },
  premium_365: { name: "Premium · 365 days", days: 365, amount: 2499, currency: "usd" },
};

function mount(web, c) {
  const { db, express, base, jsonBody, jsonErr, needAuth, fail, limited, setPremium } = c;
  const SECRET = process.env.STRIPE_SECRET_KEY || "";
  const WEBHOOK_SECRET = process.env.STRIPE_WEBHOOK_SECRET || "";
  const SITE = (process.env.PUBLIC_BASE_URL || "https://airshare.lol").replace(/\/+$/, "");
  if (!SECRET || !WEBHOOK_SECRET) { console.warn("Payments off: set STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET to enable."); return; }
  if (typeof fetch !== "function") { console.warn("Payments off: needs Node 18+ (global fetch)."); return; }

  db.exec(`CREATE TABLE IF NOT EXISTS payments(
      session_id TEXT PRIMARY KEY, user_id INTEGER NOT NULL, plan TEXT NOT NULL, days INTEGER NOT NULL,
      amount INTEGER, currency TEXT, payment_intent TEXT, status TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS payments_user ON payments(user_id);
    CREATE INDEX IF NOT EXISTS payments_pi ON payments(payment_intent);`);
  const now = () => new Date().toISOString();

  // ---------- Stripe REST ----------
  function encode(obj, prefix, out) {
    out = out || [];
    for (const [k, v] of Object.entries(obj)) {
      const key = prefix ? `${prefix}[${k}]` : k;
      if (v && typeof v === "object") encode(v, key, out);
      else if (v !== undefined && v !== null) out.push(encodeURIComponent(key) + "=" + encodeURIComponent(String(v)));
    }
    return out;
  }
  async function stripePost(path, params) {
    const r = await fetch("https://api.stripe.com/v1" + path, {
      method: "POST",
      headers: { Authorization: "Bearer " + SECRET, "Content-Type": "application/x-www-form-urlencoded" },
      body: encode(params).join("&"),
      signal: AbortSignal.timeout(15000),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error((j.error && j.error.message) || "Stripe error " + r.status);
    return j;
  }

  // ---------- queries ----------
  const insertQ = db.prepare("INSERT OR IGNORE INTO payments(session_id,user_id,plan,days,amount,currency,status,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?)");
  const getQ = db.prepare("SELECT * FROM payments WHERE session_id=?");
  // Flip to 'paid' only if it isn't already: .changes === 1 means THIS call won, so the days are granted exactly once.
  const claimQ = db.prepare("UPDATE payments SET status='paid', payment_intent=?, amount=?, currency=?, updated_at=? WHERE session_id=? AND status NOT IN ('paid','refunded')");
  const unclaimQ = db.prepare("UPDATE payments SET status='pending', updated_at=? WHERE session_id=?");
  const setStatusQ = db.prepare("UPDATE payments SET status=?, updated_at=? WHERE session_id=?");
  const refundQ = db.prepare("UPDATE payments SET status='refunded', updated_at=? WHERE payment_intent=?");
  const listQ = db.prepare("SELECT session_id,plan,days,amount,currency,status,created_at FROM payments WHERE user_id=? ORDER BY created_at DESC LIMIT 50");

  // ---------- app routes ----------
  web.get("/app/v1/shop", base, (_req, res) => {
    res.json({ ok: true, plans: Object.entries(PLANS).map(([id, p]) => ({ id, name: p.name, days: p.days, amount: p.amount, currency: p.currency })) });
  });

  web.post("/app/v1/checkout", base, jsonBody, needAuth, async (req, res) => {
    try {
      if (limited("co|" + req.me.id, 10, 3600000)) return fail(res, 429, "Too many checkout attempts. Try again later.");
      const planId = String((req.body && req.body.plan) || "");
      const plan = Object.prototype.hasOwnProperty.call(PLANS, planId) ? PLANS[planId] : null;
      if (!plan) return fail(res, 400, "Unknown plan.");
      const uid = String(req.me.id);
      const meta = { user_id: uid, plan: planId, days: String(plan.days) };
      const params = {
        mode: "payment",
        client_reference_id: uid,
        line_items: { 0: { quantity: 1, price_data: { currency: plan.currency, unit_amount: plan.amount, product_data: { name: "AirShare " + plan.name } } } },
        metadata: meta,
        payment_intent_data: { metadata: meta },
        success_url: SITE + "/pay/done?ok=1",
        cancel_url: SITE + "/pay/done?ok=0",
      };
      const email = String(req.me.email || "");
      if (email && !/@accounts\.invalid$/.test(email)) params.customer_email = email;
      const s = await stripePost("/checkout/sessions", params);
      insertQ.run(s.id, req.me.id, planId, plan.days, plan.amount, plan.currency, "pending", now(), now());
      res.json({ ok: true, url: s.url, session_id: s.id });
    } catch (e) {
      console.warn("Checkout failed:", e.message);
      fail(res, 502, "Couldn't start checkout. Please try again.");
    }
  }, jsonErr);

  web.get("/app/v1/purchases", base, needAuth, (req, res) => {
    res.json({ ok: true, purchases: listQ.all(req.me.id) });
  });

  // ---------- webhook ----------
  function verify(raw, header) {
    let t = null; const sigs = [];
    for (const part of String(header || "").split(",")) {
      const i = part.indexOf("="); if (i < 0) continue;
      const k = part.slice(0, i).trim(), v = part.slice(i + 1).trim();
      if (k === "t") t = v; else if (k === "v1") sigs.push(v);
    }
    if (!t || !sigs.length || !/^\d+$/.test(t)) return false;
    if (Math.abs(Date.now() / 1000 - Number(t)) > 300) return false; // replay window
    const expect = crypto.createHmac("sha256", WEBHOOK_SECRET).update(t + ".").update(raw).digest("hex");
    return sigs.some((s) => s.length === expect.length && crypto.timingSafeEqual(Buffer.from(s), Buffer.from(expect)));
  }

  // Returns true when handled (including "nothing to do"); throws to make Stripe retry.
  function grant(session) {
    if (session.payment_status !== "paid") return true; // async methods: wait for async_payment_succeeded
    const m = session.metadata || {};
    const plan = Object.prototype.hasOwnProperty.call(PLANS, m.plan) ? PLANS[m.plan] : null;
    const uid = Number(m.user_id || session.client_reference_id);
    if (!plan || !Number.isInteger(uid) || uid <= 0) { console.warn("Payment ignored (bad metadata):", session.id); return true; }
    // Never trust metadata for money: the amount Stripe actually charged must match the plan.
    if (session.amount_total !== plan.amount || String(session.currency || "").toLowerCase() !== plan.currency) {
      insertQ.run(session.id, uid, m.plan, plan.days, session.amount_total, session.currency, "mismatch", now(), now());
      setStatusQ.run("mismatch", now(), session.id);
      console.warn("Payment amount mismatch, no days granted:", session.id, session.amount_total, session.currency);
      return true;
    }
    insertQ.run(session.id, uid, m.plan, plan.days, plan.amount, plan.currency, "pending", now(), now());
    const row = getQ.get(session.id);
    if (!row || row.status === "mismatch") return true;
    const claim = claimQ.run(typeof session.payment_intent === "string" ? session.payment_intent : null, session.amount_total, session.currency, now(), session.id);
    if (Number(claim.changes) !== 1) return true; // already granted (Stripe re-sent the event)
    try {
      const result = setPremium(uid, "add", plan.days);
      if (!result) { setStatusQ.run("user_missing", now(), session.id); console.warn("Paid session for unknown user:", session.id, uid); }
      else console.log(`Premium +${plan.days}d granted to user ${uid} (${session.id})`);
    } catch (e) {
      unclaimQ.run(now(), session.id); // let the retry grant it
      throw e;
    }
    return true;
  }

  web.post("/stripe/webhook", express.raw({ type: "application/json", limit: "1mb" }), (req, res) => {
    const raw = req.body;
    if (!Buffer.isBuffer(raw) || !verify(raw, req.get("stripe-signature"))) return res.status(400).send("invalid signature");
    let event;
    try { event = JSON.parse(raw.toString("utf8")); } catch { return res.status(400).send("bad json"); }
    try {
      const obj = event && event.data && event.data.object;
      if (!obj) return res.json({ received: true });
      if (event.type === "checkout.session.completed" || event.type === "checkout.session.async_payment_succeeded") grant(obj);
      else if (event.type === "charge.refunded" && typeof obj.payment_intent === "string") {
        // Marks the record only. Days already granted are left alone; revoke from /admin/app if you want them removed.
        refundQ.run(now(), obj.payment_intent);
        console.log("Charge refunded:", obj.payment_intent);
      }
      res.json({ received: true });
    } catch (e) {
      console.warn("Webhook handling failed:", e.message);
      res.status(500).send("retry");
    }
  });

  // ---------- return page ----------
  web.get("/pay/done", base, (req, res) => {
    const ok = req.query.ok === "1";
    res.set("Content-Type", "text/html; charset=utf-8");
    res.send(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>AirShare</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#111;color:#fff;font:17px -apple-system,system-ui,sans-serif;text-align:center;padding:24px}
h1{font-size:24px;margin:0 0 8px}p{color:#aaa;margin:0}</style>
<div><h1>${ok ? "Payment received" : "Checkout cancelled"}</h1>
<p>${ok ? "Close this window and go back to AirShare. Premium shows up within a few seconds." : "You haven't been charged. Close this window to go back to AirShare."}</p></div>`);
  });
}

module.exports = { mount, PLANS };
