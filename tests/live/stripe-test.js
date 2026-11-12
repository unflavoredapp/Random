"use strict";
// Card payments (server/stripe.js) against a fake Stripe API: intent, verify, webhook signature, exactly-once grant, refund.
//   node --experimental-sqlite tests/live/stripe-test.js
const path = require("path"), crypto = require("crypto"), assert = require("assert");
const SRV = path.join(__dirname, "..", "..", "server");
Object.assign(process.env, { STRIPE_SECRET_KEY: "sk_test_x", STRIPE_PUBLISHABLE_KEY: "pk_test_x", STRIPE_WEBHOOK_SECRET: "whsec_test" });
const { DatabaseSync } = require("node:sqlite");
const db = new DatabaseSync(":memory:");
db.exec("CREATE TABLE local_users(id INTEGER PRIMARY KEY, username TEXT, premium_until TEXT)");
db.prepare("INSERT INTO local_users(id,username) VALUES(1,'a'),(2,'b')").run();

// fake Stripe
const pis = {}; let n = 0;
globalThis.fetch = async (url, o = {}) => {
  const u = new URL(url), body = o.body ? Object.fromEntries(new URLSearchParams(o.body)) : {};
  const ok = (j) => ({ ok: true, status: 200, json: async () => j });
  if (o.method === "POST" && u.pathname === "/v1/payment_intents") {
    const id = "pi_" + (++n); pis[id] = { id, client_secret: id + "_secret", amount: Number(body.amount), amount_received: 0, currency: body.currency, status: "requires_payment_method" }; return ok(pis[id]);
  }
  const m = /^\/v1\/payment_intents\/(.+)$/.exec(u.pathname);
  if (m && pis[m[1]]) return ok(pis[m[1]]);
  return { ok: false, status: 404, json: async () => ({ error: { message: "nope" } }) };
};

const { createApp, express } = require("./miniexpress");
const web = createApp();
const setPremium = (id, mode, days) => { const r = db.prepare("SELECT premium_until FROM local_users WHERE id=?").get(id); if (!r) return null;
  const cur = Date.parse(r.premium_until || ""), from = Number.isFinite(cur) && cur > Date.now() ? cur : Date.now();
  db.prepare("UPDATE local_users SET premium_until=? WHERE id=?").run(new Date(from + days * 86400000).toISOString(), id); return {}; };
const jsonBody = express.json({ limit: "16kb", type: "application/json" });
const needAuth = (req, res, next) => { const t = String(req.get("authorization") || "").replace("Bearer u", ""); if (!/^\d+$/.test(t)) return res.status(401).json({ ok: false }); req.me = { id: Number(t) }; next(); };
const fail = (res, c, m) => res.status(c).json({ ok: false, error: m });
require(SRV + "/stripe.js").mount(web, { db, express, base: (_q, _r, nx) => nx(), jsonBody, jsonErr: (e, _q, res, _n) => res.status(400).json({ ok: false }), needAuth, fail, limited: () => false, setPremium });
(async () => {
  const server = await new Promise((r) => { const s = web.listen(0, () => r(s)); });
  const BASE = "http://127.0.0.1:" + server.address().port;
  const realFetch = require("http");
  const call = (method, p, { token, body, headers = {} } = {}) => new Promise((resolve) => {
    const data = body === undefined ? null : (typeof body === "string" ? body : JSON.stringify(body));
    const req = realFetch.request(BASE + p, { method, headers: { ...(token ? { authorization: "Bearer u" + token } : {}), ...(data ? { "content-type": "application/json", "content-length": Buffer.byteLength(data) } : {}), ...headers } }, (res) => {
      let b = ""; res.on("data", (c) => (b += c)); res.on("end", () => resolve({ s: res.statusCode, j: (() => { try { return JSON.parse(b); } catch { return {}; } })() }));
    }); if (data) req.write(data); req.end();
  });
  const sign = (raw, t = Math.floor(Date.now() / 1000), sec = "whsec_test") => `t=${t},v1=` + crypto.createHmac("sha256", sec).update(`${t}.${raw}`).digest("hex");
  const hook = (ev, hdr) => { const raw = JSON.stringify(ev); return call("POST", "/app/v1/stripe/webhook", { body: raw, headers: { "stripe-signature": hdr || sign(raw) } }); };
  const prem = (id) => db.prepare("SELECT premium_until FROM local_users WHERE id=?").get(id).premium_until;

  assert.strictEqual((await call("POST", "/app/v1/stripe/intent", { body: { plan: "premium_30" } })).s, 401);
  assert.strictEqual((await call("POST", "/app/v1/stripe/intent", { token: 1, body: { plan: "nope" } })).s, 400);
  const i = await call("POST", "/app/v1/stripe/intent", { token: 1, body: { plan: "premium_30" } });
  assert.strictEqual(i.s, 200); assert.ok(i.j.client_secret && i.j.publishable_key === "pk_test_x" && i.j.amount === 299);
  const pi = Object.values(pis)[0];

  // someone else can't verify my order; unpaid verify changes nothing
  assert.strictEqual((await call("POST", "/app/v1/stripe/verify", { token: 2, body: { order_id: i.j.order_id } })).s, 404);
  assert.strictEqual((await call("POST", "/app/v1/stripe/verify", { token: 1, body: { order_id: i.j.order_id } })).j.status, "pending");
  assert.strictEqual(prem(1), null);

  // webhook: bad signature, stale timestamp, wrong secret all rejected, nothing granted
  const ev = { type: "payment_intent.succeeded", data: { object: { id: pi.id, amount_received: 299, currency: "usd" } } };
  assert.strictEqual((await hook(ev, "t=1,v1=00")).s, 400);
  assert.strictEqual((await hook(ev, sign(JSON.stringify(ev), 1000))).s, 400);
  assert.strictEqual((await hook(ev, sign(JSON.stringify(ev), undefined, "whsec_other"))).s, 400);
  assert.strictEqual(prem(1), null);
  // short payment amount isn't granted
  assert.strictEqual((await hook({ ...ev, data: { object: { ...ev.data.object, amount_received: 100 } } })).s, 200);
  assert.strictEqual(prem(1), null);

  // real success: webhook and verify race, days added exactly once
  pi.status = "succeeded"; pi.amount_received = 299;
  const [a, b] = await Promise.all([hook(ev), call("POST", "/app/v1/stripe/verify", { token: 1, body: { order_id: i.j.order_id } })]);
  assert.strictEqual(a.s, 200); assert.strictEqual(b.j.status, "paid");
  await hook(ev); await call("POST", "/app/v1/stripe/verify", { token: 1, body: { order_id: i.j.order_id } });
  const days = Math.round((Date.parse(prem(1)) - Date.now()) / 86400000);
  assert.strictEqual(days, 30, "granted exactly once, got " + days);

  // refund removes the days once
  const rf = { type: "charge.refunded", data: { object: { payment_intent: pi.id, refunded: true } } };
  await hook(rf); await hook(rf);
  assert.strictEqual(prem(1), null);
  console.log("stripe tests passed");
  server.close(); process.exit(0);
})().catch((e) => { console.error(e); process.exit(1); });
