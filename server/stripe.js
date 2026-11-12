"use strict";
// Premium by card with Stripe PaymentSheet (the app shows Stripe's native sheet: card, Apple Pay, Link).
// No stripe npm package: the server talks to Stripe's REST API with fetch and checks webhook signatures itself.
//
//   POST /app/v1/stripe/intent   (auth) {plan}      -> {order_id, client_secret, publishable_key, amount, currency, name, days}
//   POST /app/v1/stripe/verify   (auth) {order_id}  -> {status}   (asks Stripe directly, so the app doesn't wait for the webhook)
//   POST /app/v1/stripe/webhook  (Stripe-Signature) -> grants the days when payment_intent.succeeded arrives
//
// Env: STRIPE_SECRET_KEY (sk_live_… / sk_test_…), STRIPE_PUBLISHABLE_KEY (pk_…), STRIPE_WEBHOOK_SECRET (whsec_…)
// In the Stripe dashboard add a webhook endpoint https://decrypt.team/app/v1/stripe/webhook for:
//   payment_intent.succeeded, payment_intent.payment_failed, charge.refunded
// Days are granted exactly once: an order flips pending → paid with a single UPDATE and only that winner adds the days.
const crypto = require("crypto");
const { PLANS } = require("./payments");

function mount(web, c) {
  const { db, base, jsonBody, jsonErr, needAuth, fail, limited, setPremium, express } = c;
  const SECRET = process.env.STRIPE_SECRET_KEY || "";
  const PUB = process.env.STRIPE_PUBLISHABLE_KEY || "";
  const WHSEC = process.env.STRIPE_WEBHOOK_SECRET || "";
  const enabled = /^sk_(live|test)_/.test(SECRET) && /^pk_(live|test)_/.test(PUB);
  if (!enabled) console.warn("Card payments off: set STRIPE_SECRET_KEY and STRIPE_PUBLISHABLE_KEY to enable.");
  else if (!WHSEC) console.warn("Card payments: STRIPE_WEBHOOK_SECRET is not set, so only the app's verify call can grant days.");

  db.exec(`CREATE TABLE IF NOT EXISTS stripe_orders(
      id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER NOT NULL, plan TEXT NOT NULL, days INTEGER NOT NULL, usd_cents INTEGER NOT NULL,
      pi_id TEXT UNIQUE, status TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, paid_at TEXT);
    CREATE INDEX IF NOT EXISTS stripe_orders_user ON stripe_orders(user_id);`);
  const now = () => new Date().toISOString();
  const q = {
    byId: db.prepare("SELECT * FROM stripe_orders WHERE id=?"),
    byPi: db.prepare("SELECT * FROM stripe_orders WHERE pi_id=?"),
    insert: db.prepare("INSERT INTO stripe_orders(user_id,plan,days,usd_cents,status,created_at,updated_at) VALUES(?,?,?,?,'creating',?,?)"),
    setPi: db.prepare("UPDATE stripe_orders SET pi_id=?, status='pending', updated_at=? WHERE id=?"),
    // Only one caller can win this UPDATE, so the days are added once even if the webhook and verify race.
    claim: db.prepare("UPDATE stripe_orders SET status='paid', paid_at=?, updated_at=? WHERE id=? AND status IN ('pending','creating','failed')"),
    setStatus: db.prepare("UPDATE stripe_orders SET status=?, updated_at=? WHERE id=? AND status<>'paid'"),
    refund: db.prepare("UPDATE stripe_orders SET status='refunded', updated_at=? WHERE id=? AND status='paid'"),
    mine: db.prepare("SELECT * FROM stripe_orders WHERE user_id=? AND status NOT IN ('creating') ORDER BY id DESC LIMIT 50"),
    prem: db.prepare("SELECT premium_until FROM local_users WHERE id=?"),
    setPrem: db.prepare("UPDATE local_users SET premium_until=? WHERE id=?"),
  };

  function takeDays(uid, days) {
    const r = q.prem.get(uid);
    const until = r && r.premium_until ? Date.parse(r.premium_until) : NaN;
    if (!Number.isFinite(until)) return;
    const next = until - days * 86400000;
    q.setPrem.run(next > Date.now() ? new Date(next).toISOString() : null, uid);
  }

  async function stripe(method, path, form) {
    const r = await fetch("https://api.stripe.com/v1" + path, {
      method, signal: AbortSignal.timeout(15000),
      headers: { Authorization: "Bearer " + SECRET, "Content-Type": "application/x-www-form-urlencoded",
        ...(form && form._idem ? { "Idempotency-Key": form._idem } : {}) },
      body: form ? new URLSearchParams(Object.entries(form).filter(([k]) => k !== "_idem")).toString() : undefined,
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error((j.error && j.error.message) || "Stripe HTTP " + r.status);
    return j;
  }

  function grant(order, how) {
    if (Number(q.claim.run(now(), now(), order.id).changes) !== 1) return false;
    const r = setPremium(order.user_id, "add", order.days);
    if (!r) { q.setStatus.run("user_missing", now(), order.id); console.warn("Card payment for unknown user, order", order.id); return false; }
    console.log(`Premium +${order.days}d granted to user ${order.user_id} (card order ${order.id}, ${how})`);
    return true;
  }

  const view = (o) => ({ order_id: o.id, status: o.status, plan: o.plan, days: o.days, amount: o.usd_cents, currency: "usd", created_at: o.created_at, paid_at: o.paid_at || null });

  // ---------- app routes ----------
  web.post("/app/v1/stripe/intent", base, jsonBody, needAuth, async (req, res) => {
    try {
      if (!enabled) return fail(res, 503, "Card payments aren't set up yet.");
      if (limited("si|" + req.me.id, 20, 3600000)) return fail(res, 429, "Too many checkout attempts. Try again later.");
      const planId = String((req.body && req.body.plan) || "");
      const plan = Object.prototype.hasOwnProperty.call(PLANS, planId) ? PLANS[planId] : null;
      if (!plan) return fail(res, 400, "Unknown plan.");
      const id = Number(q.insert.run(req.me.id, planId, plan.days, plan.amount, now(), now()).lastInsertRowid);
      const pi = await stripe("POST", "/payment_intents", {
        amount: String(plan.amount), currency: plan.currency, "automatic_payment_methods[enabled]": "true",
        "metadata[order_id]": String(id), "metadata[user_id]": String(req.me.id), "metadata[plan]": planId, "metadata[days]": String(plan.days),
        description: "Decrypt.Team " + plan.name, _idem: "dt-order-" + id,
      });
      q.setPi.run(pi.id, now(), id);
      res.json({ ok: true, order_id: id, client_secret: pi.client_secret, publishable_key: PUB, amount: plan.amount, currency: plan.currency, name: plan.name, days: plan.days });
    } catch (e) {
      console.warn("Stripe intent failed:", e.message);
      fail(res, 500, "Couldn't start the card payment. Please try again.");
    }
  }, jsonErr);

  web.post("/app/v1/stripe/verify", base, jsonBody, needAuth, async (req, res) => {
    try {
      if (limited("sv|" + req.me.id, 300, 3600000)) return fail(res, 429, "Too many checks. Try again later.");
      const row = q.byId.get(Number(req.body && req.body.order_id));
      if (!row || row.user_id !== req.me.id) return fail(res, 404, "No purchase found to check.");
      let o = row;
      if (enabled && row.pi_id && ["pending", "failed"].includes(row.status)) {
        const pi = await stripe("GET", "/payment_intents/" + encodeURIComponent(row.pi_id));
        // Trust Stripe's own record, never the app: amount and currency must match the plan price.
        if (pi.status === "succeeded" && pi.amount_received >= row.usd_cents && pi.currency === "usd") grant(row, "verify");
        else if (pi.status === "canceled") q.setStatus.run("canceled", now(), row.id);
        o = q.byId.get(row.id);
      }
      res.json({ ok: true, ...view(o) });
    } catch (e) {
      console.warn("Stripe verify failed:", e.message);
      fail(res, 500, "Couldn't check that payment right now. Please try again.");
    }
  }, jsonErr);

  // ---------- webhook (raw body, signature checked) ----------
  function signatureOk(raw, header) {
    if (!WHSEC || !header) return false;
    const parts = Object.fromEntries(String(header).split(",").map((p) => p.split("=")).filter((p) => p.length === 2));
    const t = Number(parts.t);
    if (!Number.isFinite(t) || Math.abs(Date.now() / 1000 - t) > 300) return false;
    const want = crypto.createHmac("sha256", WHSEC).update(`${t}.${raw}`).digest("hex");
    return String(header).split(",").filter((p) => p.startsWith("v1=")).some((p) => {
      const got = p.slice(3);
      return got.length === want.length && crypto.timingSafeEqual(Buffer.from(got), Buffer.from(want));
    });
  }

  web.post("/app/v1/stripe/webhook", base, express.raw({ type: "application/json", limit: "256kb" }), (req, res) => {
    const raw = Buffer.isBuffer(req.body) ? req.body.toString("utf8") : "";
    if (!signatureOk(raw, req.get("stripe-signature"))) return res.status(400).json({ ok: false, error: "Bad signature." });
    let ev;
    try { ev = JSON.parse(raw); } catch { return res.status(400).json({ ok: false, error: "Bad JSON." }); }
    try {
      const obj = ev.data && ev.data.object ? ev.data.object : {};
      if (ev.type === "payment_intent.succeeded") {
        const o = q.byPi.get(obj.id);
        if (o && obj.amount_received >= o.usd_cents && obj.currency === "usd") grant(o, "webhook");
        else if (o) console.warn("Card payment amount mismatch, not granted: order", o.id);
      } else if (ev.type === "payment_intent.payment_failed") {
        const o = q.byPi.get(obj.id);
        if (o) q.setStatus.run("failed", now(), o.id);
      } else if (ev.type === "charge.refunded") {
        const o = obj.payment_intent ? q.byPi.get(obj.payment_intent) : null;
        if (o && obj.refunded && Number(q.refund.run(now(), o.id).changes) === 1) { takeDays(o.user_id, o.days); console.log("Card order refunded, days removed:", o.id); }
      }
      res.json({ ok: true });
    } catch (e) {
      console.warn("Stripe webhook handling failed:", e.message);
      res.status(500).json({ ok: false });   // Stripe retries
    }
  });

  return {
    enabled, publishableKey: PUB,
    purchases: (uid) => q.mine.all(uid).map((o) => ({ session_id: "card-" + o.id, order_id: o.id, name: (PLANS[o.plan] || {}).name || o.plan, amount: o.usd_cents, currency: "usd", method: "card", status: o.status, created_at: o.created_at })),
  };
}

module.exports = { mount };
