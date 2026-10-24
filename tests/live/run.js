"use strict";
// Real-HTTP test: boots appapi/payments/support/early behind a small Express-compatible server a fake Litecoin explorer and fake price feeds.
// Run:  node --experimental-sqlite tests/live/run.js   (Node 22+).  With real Express installed, swap miniexpress for it.
const fs = require("fs"), os = require("os"), path = require("path"), crypto = require("crypto"), http = require("http"), assert = require("assert");
const SRV = path.join(__dirname, "..", "..", "server");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "airshare-live-"));

// ---- fake Litecoin explorer (Esplora-style) and two fake price feeds ----
const chain = { tip: 1000, txs: {}, broken: false, down: false, n: 0 };
const pay = (addr, sat, confs, extra = {}) => { const tx = { txid: "tx" + (++chain.n).toString(16).padStart(8, "0"), confs, outs: [{ a: addr, v: sat }, { a: "ltc1qsomeoneelse", v: 5 }], ...extra };
  (chain.txs[extra.listedUnder || addr] = chain.txs[extra.listedUnder || addr] || []).push(tx); return tx; };
const explorer = http.createServer((req, res) => {
  const send = (c, b, t) => { res.statusCode = c; res.setHeader("content-type", t || "application/json"); res.end(typeof b === "string" ? b : JSON.stringify(b)); };
  if (chain.down) return send(503, { error: "down" });
  if (req.url === "/api/blocks/tip/height") return send(200, String(chain.tip), "text/plain");
  const m = /^\/api\/address\/([^/]+)\/txs$/.exec(req.url);
  if (!m) return send(404, {});
  if (chain.broken) return send(200, { not: "an array" });
  const list = (chain.txs[decodeURIComponent(m[1])] || []).map((t) => ({ txid: t.txid, vout: t.outs.map((o) => ({ scriptpubkey_address: o.a, value: o.v })),
    status: t.confs > 0 ? { confirmed: true, block_height: chain.tip - t.confs + 1 } : { confirmed: false } }));
  send(200, list);
});
const feeds = { a: { body: { data: { amount: "80.00" } }, code: 200 }, b: { body: { litecoin: { usd: 81 } }, code: 200 } };
const feed = (k) => http.createServer((_q, res) => { res.statusCode = feeds[k].code; res.setHeader("content-type", "application/json"); res.end(JSON.stringify(feeds[k].body)); });
const feedA = feed("a"), feedB = feed("b");
const listen = (srv) => new Promise((r) => srv.listen(0, "127.0.0.1", () => r(srv.address().port)));

(async () => {
  const [pe, pa, pb] = [await listen(explorer), await listen(feedA), await listen(feedB)];
  const XPUB = "zpub6rFR7y4Q2AijBEqTUquhVz398htDFrtymD9xYYfG1m4wAcvPhXNfE3EfH1r1ADqtfSdVCToUG868RvUUkgDKf31mGDtKsAYz2oz2AGutZYs";
  const derive = require(path.join(SRV, "ltc-hd.js")).makeDeriver(XPUB, "ltc");
  Object.assign(process.env, {
    LTC_XPUB: XPUB, LTC_EXPLORER: `http://127.0.0.1:1/api,http://127.0.0.1:${pe}/api`, // first one is dead on purpose: tests the fallback
    LTC_PRICE_URLS: `http://127.0.0.1:${pa}/,http://127.0.0.1:${pb}/`, LTC_RATE_CACHE_SEC: "0", LTC_VERIFY_MIN_SEC: "0", LTC_POLL_SEC: "1", LTC_CONFS: "2",
    APP_ADMINS: "rootadmin",
  });
  const { DatabaseSync } = require("node:sqlite");
  const db = new DatabaseSync(path.join(tmp, "live.db"));
  db.exec("CREATE TABLE local_users(id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE, email TEXT UNIQUE, pass_hash TEXT, created_at TEXT, last_login TEXT)");

  // real password hashing, real Basic auth, real rate limiter
  const hashPw = async (p) => { const salt = crypto.randomBytes(16); return salt.toString("hex") + ":" + crypto.scryptSync(p, salt, 32).toString("hex"); };
  const checkPw = async (p, h) => { if (!h) return false; const [s, k] = h.split(":"); return crypto.timingSafeEqual(Buffer.from(k, "hex"), crypto.scryptSync(p, Buffer.from(s, "hex"), 32)); };
  const hits = new Map();
  const limited = (k, max, win) => { if (k.startsWith("ar|")) return false; /* sign-up limiter relaxed so the test can create many users */ const n = Date.now(), a = (hits.get(k) || []).filter((t) => n - t < win); a.push(n); hits.set(k, a); return a.length > max; };
  const ADMIN_USER = "staff", ADMIN_PASS = "s3cret-pass";
  const auth = (req, res, next) => {
    const h = String(req.get("authorization") || "");
    if (h.startsWith("Basic ")) {
      const [u, ...rest] = Buffer.from(h.slice(6), "base64").toString().split(":"); const p = rest.join(":");
      const ok = (a, b) => { const x = Buffer.from(a), y = Buffer.from(b); return x.length === y.length && crypto.timingSafeEqual(x, y); };
      if (ok(u, ADMIN_USER) && ok(p, ADMIN_PASS)) return next();
    }
    res.set("WWW-Authenticate", 'Basic realm="admin"').status(401).send("Auth required");
  };

  const { createApp, express } = require("./miniexpress");
  const web = createApp();
  const acct = {};
  require(SRV + "/appapi.js").mount(web, { db, express, hashPw, checkPw, limited, key: "test-signing-key", auth, esc: (x) => String(x), acct });
  await new Promise((r) => web.listen(0, r));
  // listen() returned the server only through callback; recover port via a second handle
  const server = await new Promise((r) => { const s = web.listen(0, () => r(s)); });
  const BASE = "http://127.0.0.1:" + server.address().port;

  // ---------------- helpers ----------------
  const basic = (u = ADMIN_USER, p = ADMIN_PASS) => "Basic " + Buffer.from(u + ":" + p).toString("base64");
  const api = async (method, p, { token, headers = {}, body, raw } = {}) => {
    const h = { ...headers }; if (token) h.authorization = "Bearer " + token;
    let payload = raw; if (body !== undefined) { h["content-type"] = "application/json"; payload = JSON.stringify(body); }
    const r = await fetch(BASE + p, { method, headers: h, body: payload, redirect: "manual" });
    const t = await r.text(); let j = null; try { j = JSON.parse(t); } catch {}
    return { code: r.status, json: j, text: t, headers: r.headers };
  };
  let pass = 0; const ok = (cond, msg) => { assert(cond, "FAILED: " + msg); pass++; console.log("  ok  " + msg); };
  const eq = (a, b, msg) => { assert.deepStrictEqual(a, b, "FAILED: " + msg + " (got " + JSON.stringify(a) + ", want " + JSON.stringify(b) + ")"); pass++; console.log("  ok  " + msg); };
  const section = (s) => console.log("\n== " + s);
  const register = async (name) => { const r = await api("POST", "/app/v1/register", { body: { username: name, password: "password-" + name, email: name + "@example.com" } }); assert.equal(r.code, 200, "register " + name + ": " + r.text); return { id: db.prepare("SELECT id FROM local_users WHERE username=?").get(name).id, token: r.json.token, name }; };
  const profile = async (u) => (await api("GET", "/app/v1/account", { token: u.token })).json;
  const adminPremium = (u, mode, days) => api("POST", "/admin/app/premium", { headers: { authorization: basic() }, body: { user_id: u.id, mode, days } });
  const daysLeft = (u) => { const r = db.prepare("SELECT premium_until FROM local_users WHERE id=?").get(u.id).premium_until; return r ? Math.round((Date.parse(r) - Date.now()) / 86400000) : 0; };
  const adminH = { authorization: basic(), "x-admin": "1" };

  const free = await register("freebie"), prem = await register("premmy"), other = await register("bystander"), boss = await register("rootadmin");

  // ============ 1. Premium access changes ============
  section("1. Premium grant / revoke / expiry change what the server allows");
  let p = await profile(free);
  eq([p.premium.active, p.decrypt.limit, p.decrypt.base_limit], [false, 10, 10], "free account: premium off, 10 decrypts a day");
  eq((await api("GET", "/app/v1/style?usernames=freebie")).json.freebie.badges.includes("premium"), false, "free account: no premium badge");

  let r = await api("POST", "/app/v1/account", { token: free.token, body: { action: "set_style", rainbow: true } });
  eq(r.code, 403, "free account cannot turn on a rainbow style");
  r = await api("POST", "/app/v1/account", { token: free.token, body: { action: "set_style", gif: "https://example.com/a.gif" } });
  eq(r.code, 403, "free account cannot set a GIF style");
  r = await api("POST", "/app/v1/account", { token: free.token, body: { action: "set_style", color: "#ff8800", size: 3 } });
  eq(r.code, 200, "free account can still set a plain colour");

  r = await adminPremium(prem, "add", 30);
  eq([r.code, r.json.premium.active], [200, true], "admin grants 30 days");
  p = await profile(prem);
  eq([p.premium.active, p.premium.days_left, p.decrypt.base_limit], [true, 30, 15], "premium account: active, 30 days left, 15 decrypts a day");
  ok((await api("GET", "/app/v1/style?usernames=premmy")).json.premmy.badges.includes("premium"), "premium badge appears in public style lookup");
  r = await api("POST", "/app/v1/account", { token: prem.token, body: { action: "set_style", rainbow: true } });
  eq(r.code, 200, "premium account can set rainbow");

  // premium style stays if premium lapses (grandfathered), but cannot be CHANGED to a new fancy style
  r = await adminPremium(prem, "revoke");
  p = await profile(prem);
  eq([p.premium.active, p.decrypt.base_limit], [false, 10], "revoke: back to free limit immediately");
  eq((await api("GET", "/app/v1/style?usernames=premmy")).json.premmy.badges.includes("premium"), false, "revoke: badge gone");
  r = await api("POST", "/app/v1/account", { token: prem.token, body: { action: "set_style", rainbow: true, color: "#112233" } });
  eq(r.code, 200, "lapsed premium keeps the rainbow style they already had (grandfathered)");
  r = await api("POST", "/app/v1/account", { token: prem.token, body: { action: "set_style", gif: "https://example.com/new.gif" } });
  eq(r.code, 403, "lapsed premium cannot add a NEW gif");

  await adminPremium(prem, "add", 10); await adminPremium(prem, "add", 5);
  eq(daysLeft(prem), 15, "days stack when added");
  await adminPremium(prem, "set", 3);
  eq(daysLeft(prem), 3, "set replaces the balance");
  db.prepare("UPDATE local_users SET premium_until=? WHERE id=?").run(new Date(Date.now() - 1000).toISOString(), prem.id);
  p = await profile(prem);
  eq([p.premium.active, p.decrypt.base_limit], [false, 10], "natural expiry: perks switch off with no job needed");

  // support priority + early visibility follow premium
  await adminPremium(prem, "add", 30);
  r = await api("POST", "/app/v1/support", { token: free.token, body: { subject: "Free ticket", message: "Something is not working for me" } });
  eq(r.json.priority, false, "free ticket is not flagged");
  r = await api("POST", "/app/v1/support", { token: prem.token, body: { subject: "Premium ticket", message: "Something is not working for me either" } });
  eq(r.json.priority, true, "premium ticket is flagged priority");
  r = await api("GET", "/admin/support/data", { headers: { authorization: basic() } });
  eq([r.code, r.json.tickets[0].subject], [200, "Premium ticket"], "admin list shows the premium ticket first");
  const past = new Date(Date.now() - 86400000).toISOString(), future = new Date(Date.now() + 7 * 86400000).toISOString();
  await api("POST", "/admin/early/save", { headers: adminH, body: { title: "Out now", body: "public text", public_at: past } });
  await api("POST", "/admin/early/save", { headers: adminH, body: { title: "Secret feature", body: "SECRET-BODY-TEXT", public_at: future } });
  r = await api("GET", "/app/v1/early", { token: free.token });
  eq([r.json.premium, r.json.posts.length, r.json.locked], [false, 1, 1], "free user: only the public post, 1 locked");
  ok(!r.text.includes("SECRET-BODY-TEXT") && !r.text.includes("Secret feature"), "free user's response contains no early title or text");
  r = await api("GET", "/app/v1/early", { token: prem.token });
  eq([r.json.premium, r.json.posts.length, r.json.locked], [true, 2, 0], "premium user: sees early post");
  await adminPremium(prem, "revoke");
  r = await api("GET", "/app/v1/early", { token: prem.token });
  ok(!r.text.includes("SECRET-BODY-TEXT"), "after revoke the early text is withheld again");

  // ============ 2. Litecoin payments through real HTTP ============
  section("2. Litecoin orders, watching the chain, granting");
  const buyer = await register("buyer");
  const order = async (u, plan) => api("POST", "/app/v1/checkout", { token: u.token, body: { plan } });
  const verify = async (u, id) => api("POST", "/app/v1/checkout/verify", { token: u.token, body: id ? { order_id: id } : {} });
  const row = (id) => db.prepare("SELECT * FROM ltc_orders WHERE id=?").get(id);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  r = await api("GET", "/app/v1/shop");
  eq([r.code, r.json.plans.map((x) => x.id), r.json.crypto.enabled, r.json.crypto.coin, r.json.crypto.confirmations], [200, ["premium_30", "premium_90", "premium_365"], true, "LTC", 2], "shop is public, lists plans and says LTC with 2 confirmations");
  ok(r.json.perks.some((x) => /Priority support: your tickets are flagged and shown to our team first/.test(x.text)), "priority-support wording is the corrected one");
  ok(!/stripe/i.test(r.text), "shop mentions no Stripe");
  eq((await api("POST", "/app/v1/checkout", { body: { plan: "premium_30" } })).code, 401, "checkout without a session is 401");
  eq((await order(buyer, "premium_999")).code, 400, "unknown plan is 400");
  eq((await order(buyer, "__proto__")).code, 400, "prototype-key plan is 400");

  r = await api("POST", "/app/v1/checkout", { token: buyer.token, body: { plan: "premium_30", amount: 1, amount_sat: 1, rate: 1000000 } });
  const o1 = r.json;
  eq([r.code, o1.status, o1.address], [200, "pending", derive(o1.order_id)], "order created; address is derived from the xpub for this order id");
  ok(/^ltc1q[02-9ac-hj-np-z]{38}$/.test(o1.address), "address is a native segwit ltc1q address");
  eq([o1.amount_sat, o1.amount_ltc], [3737500, "0.03737500"], "amount = $2.99 at the LOWER feed price ($80), ignoring client-sent numbers");
  eq(o1.uri, `litecoin:${o1.address}?amount=0.03737500&label=AirShare`, "payment URI is right");
  const mins = (Date.parse(o1.expires_at) - Date.now()) / 60000; ok(mins > 28 && mins <= 30.1, "quote valid for about 30 minutes");
  r = await order(buyer, "premium_30");
  eq([r.json.order_id, r.json.address], [o1.order_id, o1.address], "same plan again re-uses the open order (same address and amount)");
  r = await order(buyer, "premium_90");
  ok(r.json.order_id !== o1.order_id && r.json.address !== o1.address, "a different plan gets its own address");
  eq(row(r.json.order_id).status, "pending", "second order pending");

  // price feeds
  feeds.b.body = { litecoin: { usd: 120 } };
  r = await order(other, "premium_30"); eq(r.code, 503, "feeds that disagree by more than 5% -> refuse to quote (503)");
  feeds.b.code = 500; r = await order(other, "premium_30"); eq([r.code, r.json.amount_ltc], [200, "0.03737500"], "one feed down -> quotes from the other");
  const otherOrder = r.json;
  feeds.a.code = 500; r = await order(other, "premium_365"); eq(r.code, 503, "both feeds down -> 503, no guess");
  feeds.a.code = 200; feeds.b.code = 200; feeds.b.body = { litecoin: { usd: 81 } };

  eq((await api("POST", "/app/v1/checkout/verify", { body: {} })).code, 401, "verify needs a session");
  eq((await verify(other, o1.order_id)).code, 404, "another user cannot verify my order");
  eq((await api("GET", "/app/v1/purchases", { token: other.token })).json.purchases.some((p) => p.order_id === o1.order_id), false, "other user's history doesn't include my order");
  r = await verify(buyer, o1.order_id); eq([r.json.status, daysLeft(buyer)], ["pending", 0], "nothing paid yet: pending, no premium");

  // payment arrives: mempool -> 1 conf -> 2 confs
  const t1 = pay(o1.address, o1.amount_sat, 0);
  r = await verify(buyer, o1.order_id); eq([r.json.status, r.json.confirmations, daysLeft(buyer)], ["seen", 0, 0], "seen in the mempool: 'seen', no premium yet");
  t1.confs = 1; r = await verify(buyer, o1.order_id); eq([r.json.status, daysLeft(buyer)], ["seen", 0], "1 of 2 confirmations: still not granted");
  t1.confs = 2; r = await verify(buyer, o1.order_id); eq([r.json.status, daysLeft(buyer)], ["paid", 30], "2 confirmations: paid, 30 days granted");
  eq([(await profile(buyer)).premium.active, (await profile(buyer)).decrypt.base_limit], [true, 15], "profile is premium with the 15/day limit");
  for (let i = 0; i < 3; i++) await verify(buyer, o1.order_id);
  await verify(buyer);
  eq(daysLeft(buyer), 30, "repeated verifies never grant twice");
  await sleep(2300);
  eq(daysLeft(buyer), 30, "the background poller doesn't grant again either");
  r = await verify(buyer); eq([r.code, r.json.plan, r.json.status], [200, "premium_90", "pending"], "verify with no id finds the user's latest OPEN order (the unpaid 90-day one), not the paid one");
  eq((await verify(await register("noorders"))).code, 404, "a user with no open order gets 404 (the app treats that as 'nothing to restore')");

  // the poller grants on its own
  const auto = await register("autopay"); const ao = (await order(auto, "premium_30")).json;
  pay(ao.address, ao.amount_sat, 3);
  await sleep(2600);
  eq([row(ao.order_id).status, daysLeft(auto)], ["paid", 30], "background poller finds a confirmed payment with no app involvement");

  // amounts
  const amt = await register("amounts"); const under = (await order(amt, "premium_90")).json;
  const ta = pay(under.address, Math.floor(under.amount_sat / 2), 5);
  r = await verify(amt, under.order_id); eq([r.json.status, daysLeft(amt)], ["seen", 0], "half the amount: 'seen', not granted");
  pay(under.address, under.amount_sat - Math.floor(under.amount_sat / 2), 5);
  r = await verify(amt, under.order_id); eq([r.json.status, daysLeft(amt)], ["paid", 90], "second payment completes it (amounts add up)");
  const tol = await register("tolerant"); const to = (await order(tol, "premium_30")).json;
  pay(to.address, Math.ceil(to.amount_sat * 0.995), 2); r = await verify(tol, to.order_id); eq(r.json.status, "paid", "within 1% short (exchange fees) is accepted");
  const sho = await register("short"); const so = (await order(sho, "premium_30")).json;
  pay(so.address, Math.floor(so.amount_sat * 0.97), 9); r = await verify(sho, so.order_id); eq([r.json.status, daysLeft(sho)], ["seen", 0], "3% short is not accepted automatically");
  const ov = await register("overpay"); const oo = (await order(ov, "premium_30")).json;
  pay(oo.address, oo.amount_sat * 3, 2); r = await verify(ov, oo.order_id);
  eq([r.json.status, daysLeft(ov), r.json.received_ltc], ["paid", 30, "0.11212500"], "overpayment grants the plan once and records what arrived");
  // things that must not count
  const fk = await register("faker"); const fo = (await order(fk, "premium_30")).json;
  pay("ltc1qsomeoneelse", fo.amount_sat, 6, { listedUnder: fo.address }); // explorer lists a tx under our address, but it pays another address
  r = await verify(fk, fo.order_id); eq([r.json.status, daysLeft(fk)], ["pending", 0], "a transaction that doesn't pay this order's address is ignored");
  pay(o1.address, 999999999, 9); // someone pays an OLD paid order's address: nothing for other orders
  r = await verify(fk, fo.order_id); eq(daysLeft(fk), 0, "paying another order's address doesn't credit this one");
  chain.broken = true; pay(fo.address, fo.amount_sat, 9);
  r = await verify(fk, fo.order_id); eq([r.code, r.json.status, daysLeft(fk)], [200, "pending", 0], "malformed explorer reply: no change, no grant, no crash");
  chain.broken = false; chain.down = true;
  r = await verify(fk, fo.order_id); eq([r.code, r.json.status, daysLeft(fk)], [200, "pending", 0], "explorer down: state unchanged, still 200");
  chain.down = false; r = await verify(fk, fo.order_id); eq([r.json.status, daysLeft(fk)], ["paid", 30], "explorer back: the payment is picked up");

  // expiry, late payments, admin decision
  const ex = await register("expirer"); const eo = (await order(ex, "premium_30")).json;
  db.prepare("UPDATE ltc_orders SET expires_at=? WHERE id=?").run(new Date(Date.now() - 60000).toISOString(), eo.order_id);
  r = await verify(ex, eo.order_id); eq(r.json.status, "expired", "unpaid quote past its time -> expired");
  pay(eo.address, eo.amount_sat, 4); r = await verify(ex, eo.order_id);
  eq([r.json.status, daysLeft(ex)], ["late", 0], "payment after expiry is NOT granted automatically (price may have moved) -> 'late'");
  r = await api("GET", "/admin/payments/data", { headers: { authorization: basic() } });
  ok(r.json.totals.flagged >= 1 && r.json.rows.some((x) => x.status === "late"), "admin sees it flagged");
  eq((await api("POST", "/admin/payments/grant", { headers: { authorization: basic() }, body: { order_id: eo.order_id } })).code, 403, "grant without x-admin is 403");
  r = await api("POST", "/admin/payments/grant", { headers: adminH, body: { order_id: eo.order_id } });
  eq([r.code, daysLeft(ex), row(eo.order_id).status], [200, 30, "paid"], "admin grants the late order after checking it");
  eq((await api("POST", "/admin/payments/grant", { headers: adminH, body: { order_id: eo.order_id } })).code, 400, "cannot grant the same order twice");
  eq((await api("POST", "/admin/payments/grant", { headers: adminH, body: { order_id: 99999 } })).code, 404, "grant of unknown order is 404");
  const un = await register("underpaid2"); const uo = (await order(un, "premium_30")).json;
  pay(uo.address, Math.floor(uo.amount_sat / 3), 1); await verify(un, uo.order_id);
  db.prepare("UPDATE ltc_orders SET expires_at=? WHERE id=?").run(new Date(Date.now() - 3 * 3600000).toISOString(), uo.order_id);
  r = await verify(un, uo.order_id); eq([r.json.status, daysLeft(un)], ["underpaid", 0], "short payment still short 2h after expiry -> 'underpaid' for review");

  // refund (manual for crypto)
  eq((await api("POST", "/admin/payments/refund", { headers: { authorization: basic() }, body: { order_id: o1.order_id } })).code, 403, "refund without x-admin is 403");
  eq((await api("POST", "/admin/payments/refund", { headers: adminH, body: { order_id: otherOrder.order_id } })).code, 400, "an unpaid order can't be marked refunded");
  r = await api("POST", "/admin/payments/refund", { headers: adminH, body: { order_id: o1.order_id } });
  eq([r.code, daysLeft(buyer), (await profile(buyer)).premium.active], [200, 0, false], "mark refunded takes the days back");
  ok(/Send 0\.037375\d* LTC back/.test(r.json.note), "response reminds staff to send the coins back");
  eq((await api("POST", "/admin/payments/refund", { headers: adminH, body: { order_id: o1.order_id } })).code, 400, "cannot refund twice");
  r = await api("GET", "/app/v1/purchases", { token: buyer.token });
  ok(r.json.purchases.some((x) => x.order_id === o1.order_id && x.status === "refunded"), "buyer history shows it refunded");
  ok(!r.text.includes("txid") && !r.text.includes("tx0000"), "history doesn't expose transaction ids");

  // key safety
  const hd = require(path.join(SRV, "ltc-hd.js"));
  const throws = (f, re, msg) => { let m = ""; try { f(); } catch (e) { m = e.message; } ok(re.test(m), msg + " (" + m + ")"); };
  throws(() => hd.makeDeriver("xprv9s21ZrQH143K3QTDL4LXw2F7HEK3wJUD2nW2nRk4stbPy6cq3jPPqjiChkVvvNKmPGJxWUtg6LnF5kejMRNNU3TGtRBeJgk33yuGBxrMPHi"), /PRIVATE/, "a private extended key is refused outright");
  throws(() => hd.makeDeriver(XPUB.slice(0, -1) + "x"), /checksum/, "a mistyped key is caught by its checksum");
  eq(hd.makeDeriver(XPUB, "bc")(0), "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu", "derivation matches the official BIP84 test vector (address 0)");
  eq(hd.makeDeriver(XPUB, "bc")(1), "bc1qnjg0jd8228aq7egyzacy8cys3knf9xvrerkf9g", "derivation matches the official BIP84 test vector (address 1)");

  // ============ 3. Admin authorization ============
  section("3. Admin authorization matrix");
  const adminGets = ["/admin/app", "/admin/app/data", "/admin/payments", "/admin/payments/data", "/admin/support", "/admin/support/data", "/admin/early", "/admin/early/data", "/admin/app/beta"];
  const adminPosts = [["/admin/payments/refund", { order_id: 1 }], ["/admin/payments/grant", { order_id: 1 }], ["/admin/support/reply", { id: 1, reply: "x" }], ["/admin/early/save", { title: "t", body: "b", public_at: future }], ["/admin/early/delete", { id: 1 }],
    ["/admin/app/premium", { user_id: free.id, mode: "add", days: 999 }], ["/admin/app/role", { id: free.id, role: "admin" }], ["/admin/app/ban", { user_id: other.id, banned: true }], ["/admin/app/sponsor", { user_id: free.id, sponsor: "x" }]];
  const noCreds = [["no credentials", {}], ["wrong password", { authorization: basic(ADMIN_USER, "nope") }], ["wrong user", { authorization: basic("root", ADMIN_PASS) }], ["member Bearer token only", { authorization: "Bearer " + free.token }], ["admin-role Bearer token only", { authorization: "Bearer " + boss.token }], ["malformed Basic", { authorization: "Basic !!!" }]];
  for (const [label, h] of noCreds) {
    for (const g of adminGets) { const x = await api("GET", g, { headers: h }); assert.equal(x.code, 401, `${label} GET ${g} -> ${x.code}`); }
    for (const [pth, b] of adminPosts) { const x = await api("POST", pth, { headers: { ...h, "x-admin": "1" }, body: b }); assert.equal(x.code, 401, `${label} POST ${pth} -> ${x.code}`); }
    pass++; console.log(`  ok  ${label}: all ${adminGets.length} GET and ${adminPosts.length} POST admin routes -> 401 (even with x-admin: 1)`);
  }
  eq(db.prepare("SELECT role FROM local_users WHERE id=?").get(free.id).role, "member", "attempted role escalation did not change anything");
  eq(daysLeft(free), 0, "attempted premium grant without credentials did nothing");
  eq(db.prepare("SELECT banned FROM local_users WHERE id=?").get(other.id).banned, 0, "attempted ban without credentials did nothing");
  for (const g of adminGets) { const x = await api("GET", g, { headers: { authorization: basic() } }); assert.equal(x.code, 200, `valid creds GET ${g} -> ${x.code}`); }
  pass++; console.log("  ok  valid Basic credentials: all admin pages and data routes -> 200");
  for (const [pth, b] of [["/admin/payments/refund", { order_id: 1 }], ["/admin/payments/grant", { order_id: 1 }], ["/admin/support/reply", { id: 1, reply: "hello" }], ["/admin/early/save", { title: "t", body: "b", public_at: future }], ["/admin/early/delete", { id: 1 }]]) {
    const x = await api("POST", pth, { headers: { authorization: basic() }, body: b }); assert.equal(x.code, 403, `valid Basic, no x-admin, POST ${pth} -> ${x.code}`);
    const y = await api("POST", pth, { headers: { authorization: basic(), "x-admin": "0" }, body: b }); assert.equal(y.code, 403, `x-admin: 0 POST ${pth} -> ${y.code}`);
  }
  pass++; console.log("  ok  valid Basic without x-admin: 1 -> 403 on refund, grant, support reply, early save and delete");
  eq(db.prepare("SELECT COUNT(*) c FROM early_posts").get().c, 2, "403'd early save/delete changed nothing");
  eq((await api("GET", "/admin/payments/data", { headers: { authorization: basic() } })).headers.get("cache-control"), "no-store", "admin data is no-store");

  section("3b. Account-level admin actions (Bearer, role-gated)");
  const adm = (token, action, extra = {}) => api("POST", "/app/v1/account", { token, body: { action, ...extra } });
  eq((await adm(free.token, "admin_list_users")).code, 403, "member cannot list users");
  eq((await adm(free.token, "admin_set_groups", { username: "freebie", groups: ["founder"] })).code, 403, "member cannot give themselves a group");
  eq((await adm(free.token, "admin_set_sponsor", { username: "freebie", sponsor: "x" })).code, 403, "member cannot set a sponsor");
  eq((await adm(free.token, "admin_set_mdid", { adid: "AS-ABCDEF-12" })).code, 403, "member cannot set an ADID by admin action");
  eq((await adm(boss.token, "admin_list_users")).code, 200, "APP_ADMINS account can list users");
  eq((await adm(boss.token, "admin_set_groups", { username: "freebie", groups: [] })).code, 200, "APP_ADMINS account can set groups");
  eq((await adm("garbage.token", "admin_list_users")).code, 401, "garbage token is 401");
  const parts = free.token.split("."); parts[1] = String(boss.id);
  eq((await adm(parts.join("."), "admin_list_users")).code, 401, "token with swapped user id fails its signature");
  eq((await api("GET", "/app/v1/account")).code, 401, "no token is 401");
  eq((await api("GET", "/app/v1/early")).code, 401, "early looks need a session");
  eq((await api("GET", "/app/v1/support")).code, 401, "support needs a session");
  eq((await api("POST", "/app/v1/support", { body: { subject: "abc", message: "0123456789" } })).code, 401, "support create needs a session");

  // banned users lose access immediately
  await api("POST", "/admin/app/ban", { headers: { authorization: basic() }, body: { user_id: other.id, banned: true, reason: "test" } });
  eq((await api("GET", "/app/v1/purchases", { token: other.token })).code, 401, "banned user's token stops working at once");

  console.log(`\nALL ${pass} CHECKS PASSED`);
  process.exit(0);
})().catch((e) => { console.error("\n" + (e.stack || e)); process.exit(1); });
