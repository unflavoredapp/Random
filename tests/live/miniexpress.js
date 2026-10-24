"use strict";
// Small Express-compatible server (real HTTP, real header/body handling). Used only because the npm registry is unreachable here.
const http = require("http");
function compile(path) {
  const keys = []; const re = new RegExp("^" + path.replace(/:([A-Za-z_]+)/g, (_m, k) => { keys.push(k); return "([^/]+)"; }) + "/?$");
  return { re, keys };
}
function readBody(req) { return new Promise((ok, bad) => { const ch = []; req.on("data", (d) => ch.push(d)); req.on("end", () => ok(Buffer.concat(ch))); req.on("error", bad); }); }
const typeIs = (req, t) => String(req.headers["content-type"] || "").toLowerCase().startsWith(t);
const express = {
  json: (o = {}) => async (req, _res, next) => {
    if (req.body !== undefined) return next();
    if (!typeIs(req, "application/json")) { req.body = {}; return next(); }
    const lim = parseLimit(o.limit, 100 * 1024); const raw = await readBody(req);
    if (raw.length > lim) { const e = new Error("too large"); e.status = 413; return next(e); }
    try { req.body = raw.length ? JSON.parse(raw.toString("utf8")) : {}; next(); } catch (e) { e.status = 400; next(e); }
  },
  raw: (o = {}) => async (req, _res, next) => {
    if (!typeIs(req, o.type || "application/octet-stream")) { req.body = {}; return next(); }
    const raw = await readBody(req); if (raw.length > parseLimit(o.limit, 100 * 1024)) { const e = new Error("too large"); e.status = 413; return next(e); }
    req.body = raw; next();
  },
};
function parseLimit(l, d) { if (typeof l === "number") return l; const m = /^(\d+)(kb|mb)?$/i.exec(String(l || "")); return m ? Number(m[1]) * ({ kb: 1024, mb: 1048576 }[(m[2] || "").toLowerCase()] || 1) : d; }
function createApp() {
  const routes = [], globals = [];
  const add = (method) => (path, ...h) => routes.push({ method, ...compile(path), h: h.flat() });
  const app = { get: add("GET"), post: add("POST"), put: add("PUT"), delete: add("DELETE"), use: (...h) => globals.push(...h.filter((x) => typeof x === "function")) };
  app.handle = async (rq, rs) => {
    const url = new URL(rq.url, "http://x");
    const req = Object.assign(rq, { query: Object.fromEntries(url.searchParams), path: url.pathname, ip: rq.socket.remoteAddress, params: {}, get: (n) => rq.headers[String(n).toLowerCase()] });
    const res = Object.assign(rs, {
      status(c) { rs.statusCode = c; return rs; },
      set(k, v) { if (typeof k === "object") for (const [a, b] of Object.entries(k)) rs.setHeader(a, b); else rs.setHeader(k, v); return rs; },
      json(b) { if (!rs.getHeader("content-type")) rs.setHeader("content-type", "application/json; charset=utf-8"); rs.end(JSON.stringify(b)); return rs; },
      send(b) { if (typeof b === "string" && !rs.getHeader("content-type")) rs.setHeader("content-type", "text/html; charset=utf-8"); rs.end(typeof b === "object" && !Buffer.isBuffer(b) ? JSON.stringify(b) : b); return rs; },
      type(t) { rs.setHeader("content-type", t); return rs; },
    });
    const r = routes.find((x) => x.method === rq.method && x.re.test(url.pathname));
    if (!r) return res.status(404).send("Cannot " + rq.method + " " + url.pathname);
    const m = r.re.exec(url.pathname); r.keys.forEach((k, i) => (req.params[k] = decodeURIComponent(m[i + 1])));
    const chain = [...globals, ...r.h]; let i = 0, err = null;
    const next = async (e) => {
      if (e) err = e;
      while (i < chain.length) {
        const f = chain[i++];
        try {
          if (err) { if (f.length === 4) { const e0 = err; err = null; await f(e0, req, res, next); return; } continue; }
          if (f.length === 4) continue;
          await f(req, res, next); return;
        } catch (ex) { err = ex; }
      }
      if (err && err.status !== 400 && process.env.MINI_DEBUG) console.error("handler error:", err.stack || err);
      if (err && !res.writableEnded) res.status(err.status || 500).json({ ok: false, error: "Server error." });
    };
    await next();
  };
  app.listen = (port, cb) => http.createServer((a, b) => app.handle(a, b).catch((e) => { try { b.statusCode = 500; b.end("x"); } catch {} console.error(e); })).listen(port, "127.0.0.1", cb);
  return app;
}
module.exports = { createApp, express };
