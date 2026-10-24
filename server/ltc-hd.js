"use strict";
// Watch-only address derivation from an extended PUBLIC key (BIP32 public derivation + native segwit bech32 addresses).
// No dependencies and no private keys: the server can make receive addresses but can never spend from them.
const crypto = require("crypto");

const P = 2n ** 256n - 2n ** 32n - 977n;
const N = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
const G = { x: 0x79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798n, y: 0x483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8n };

const mod = (a, m = P) => ((a % m) + m) % m;
function pow(b, e, m = P) { let r = 1n; b = mod(b, m); while (e > 0n) { if (e & 1n) r = (r * b) % m; b = (b * b) % m; e >>= 1n; } return r; }
const inv = (a) => pow(a, P - 2n);

function add(a, b) {
  if (!a) return b; if (!b) return a;
  if (a.x === b.x) { if (mod(a.y + b.y) === 0n) return null; return dbl(a); }
  const l = mod((b.y - a.y) * inv(b.x - a.x)), x = mod(l * l - a.x - b.x);
  return { x, y: mod(l * (a.x - x) - a.y) };
}
function dbl(a) {
  const l = mod(3n * a.x * a.x * inv(2n * a.y)), x = mod(l * l - 2n * a.x);
  return { x, y: mod(l * (a.x - x) - a.y) };
}
function mul(k, pt) { let r = null, q = pt; while (k > 0n) { if (k & 1n) r = add(r, q); q = dbl(q); k >>= 1n; } return r; }

const big = (buf) => BigInt("0x" + (buf.length ? buf.toString("hex") : "0"));
const hex32 = (n) => Buffer.from(n.toString(16).padStart(64, "0"), "hex");
function decodePoint(buf) {
  if (buf.length !== 33 || (buf[0] !== 2 && buf[0] !== 3)) throw new Error("not a compressed public key");
  const x = big(buf.subarray(1));
  if (x >= P) throw new Error("bad public key");
  let y = pow(mod(x * x * x + 7n), (P + 1n) / 4n);
  if (mod(y * y) !== mod(x * x * x + 7n)) throw new Error("bad public key");
  if ((y & 1n) !== BigInt(buf[0] & 1)) y = P - y;
  return { x, y };
}
const encodePoint = (pt) => Buffer.concat([Buffer.from([pt.y & 1n ? 3 : 2]), hex32(pt.x)]);

// ---- base58check ----
const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
function b58decode(s) {
  let n = 0n; for (const ch of s) { const i = B58.indexOf(ch); if (i < 0) throw new Error("bad base58"); n = n * 58n + BigInt(i); }
  let h = n.toString(16); if (h.length % 2) h = "0" + h;
  let out = Buffer.from(h === "00" ? "" : h, "hex");
  let z = 0; while (z < s.length && s[z] === "1") z++;
  return Buffer.concat([Buffer.alloc(z), out]);
}
const sha256 = (b) => crypto.createHash("sha256").update(b).digest();
function b58check(s) {
  const raw = b58decode(s); if (raw.length < 5) throw new Error("too short");
  const body = raw.subarray(0, -4), sum = raw.subarray(-4);
  if (!sha256(sha256(body)).subarray(0, 4).equals(sum)) throw new Error("checksum mismatch (typo in the key?)");
  return body;
}

// ---- bech32 (segwit v0) ----
const CH = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";
function polymod(v) { const g = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]; let c = 1; for (const x of v) { const t = c >>> 25; c = ((c & 0x1ffffff) << 5) ^ x; for (let i = 0; i < 5; i++) if ((t >>> i) & 1) c ^= g[i]; } return c >>> 0; }
const hrpExpand = (h) => [...h].map((c) => c.charCodeAt(0) >> 5).concat([0], [...h].map((c) => c.charCodeAt(0) & 31));
function segwitAddress(hrp, version, program) {
  let acc = 0, bits = 0; const data = [version];
  for (const b of program) { acc = (acc << 8) | b; bits += 8; while (bits >= 5) { bits -= 5; data.push((acc >> bits) & 31); } }
  if (bits) data.push((acc << (5 - bits)) & 31);
  const pm = polymod(hrpExpand(hrp).concat(data, [0, 0, 0, 0, 0, 0])) ^ 1;
  const chk = []; for (let i = 0; i < 6; i++) chk.push((pm >>> (5 * (5 - i))) & 31);
  return hrp + "1" + data.concat(chk).map((x) => CH[x]).join("");
}

const hash160 = (b) => crypto.createHash("ripemd160").update(sha256(b)).digest();

// Parses an extended public key. Version bytes are ignored on purpose (xpub / zpub / Ltub / ...), but a PRIVATE key is refused.
function parseExtendedPublicKey(str) {
  let body;
  try { body = b58check(String(str).trim()); } catch (e) { throw new Error("LTC_XPUB is not a valid extended key: " + e.message); }
  if (body.length !== 78) throw new Error("LTC_XPUB has the wrong length for an extended key");
  const key = body.subarray(45, 78);
  if (key[0] === 0) throw new Error("LTC_XPUB looks like a PRIVATE key. Never put a private key on the server; use the extended PUBLIC key (xpub/zpub/Ltub).");
  decodePoint(key);
  return { chain: Buffer.from(body.subarray(13, 45)), key: Buffer.from(key) };
}

function ckdPub(node, index) {
  if (!Number.isInteger(index) || index < 0 || index >= 0x80000000) throw new Error("bad index");
  const i = Buffer.alloc(4); i.writeUInt32BE(index);
  const I = crypto.createHmac("sha512", node.chain).update(Buffer.concat([node.key, i])).digest();
  const il = big(I.subarray(0, 32)); if (il >= N) throw new Error("invalid child, use the next index");
  const child = add(mul(il, G), decodePoint(node.key)); if (!child) throw new Error("invalid child, use the next index");
  return { chain: Buffer.from(I.subarray(32)), key: encodePoint(child) };
}

// Receive address number `index` (path account/0/index) as a native segwit address.
function makeDeriver(xpub, hrp = "ltc") {
  const receive = ckdPub(parseExtendedPublicKey(xpub), 0);
  return (index) => segwitAddress(hrp, 0, hash160(ckdPub(receive, index).key));
}

module.exports = { makeDeriver, parseExtendedPublicKey, segwitAddress };
