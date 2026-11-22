// Brand: FastDecrypt · https://fastdecrypt.bot
"use strict";
/**
 * "Open in …" deep links after decrypt (TrollStore, Feather, E-Sign, FlareStore, ShrubSign).
 *
 * Discord: StringSelectMenu dropdown → ephemeral Link to https://fastdecrypt.bot/open/<app>?u=
 * (Link buttons cannot use custom schemes.)
 * Telegram: one “Open in…” link to /open/menu?u= (HTML dropdown) or direct schemes.
 */
const crypto = require("crypto");
const publicDl = require("./mac-tg-public-dl");

const TARGETS = [
  {
    id: "trollstore",
    label: "TrollStore",
    /** @param {string} ipaHttps */
    deep: (ipaHttps) =>
      `apple-magnifier://install?url=${encodeURIComponent(ipaHttps)}`,
  },
  {
    id: "feather",
    label: "Feather",
    deep: (ipaHttps) => `feather://install/${ipaHttps}`,
  },
  {
    id: "esign",
    label: "E-Sign",
    deep: (ipaHttps) => `esign://install?url=${encodeURIComponent(ipaHttps)}`,
  },
  {
    id: "flarestore",
    label: "FlareStore",
    deep: (ipaHttps) => ipaHttps,
    webOnly: true,
  },
  {
    id: "shrubsign",
    label: "ShrubSign",
    deep: (ipaHttps) =>
      `https://shrubsign-web.pages.dev/?ipa=${encodeURIComponent(ipaHttps)}`,
    httpsDirect: true,
  },
];

/** token → { url, expires } for Discord select menus */
const pendingOpen = new Map();
const OPEN_TTL_MS = 2 * 60 * 60 * 1000;

function sanitizeIpaUrl(raw) {
  const u = String(raw || "").trim();
  if (!/^https:\/\/[^\s]+$/i.test(u)) return "";
  if (u.length > 2000) return "";
  return u;
}

function targetById(id) {
  return TARGETS.find((t) => t.id === String(id || "").toLowerCase()) || null;
}

function pruneOpenPending() {
  const now = Date.now();
  for (const [k, v] of pendingOpen) {
    if (!v || v.expires < now) pendingOpen.delete(k);
  }
}

function putOpenPending(ipaHttps) {
  const ipa = sanitizeIpaUrl(ipaHttps);
  if (!ipa) return "";
  pruneOpenPending();
  const token = crypto.randomBytes(6).toString("hex");
  pendingOpen.set(token, { url: ipa, expires: Date.now() + OPEN_TTL_MS });
  return token;
}

function getOpenPending(token) {
  pruneOpenPending();
  const row = pendingOpen.get(String(token || ""));
  return row && row.url ? row.url : "";
}

/** Absolute https://…/open/<target>?u=… (fastdecrypt.bot by default). */
function redirectUrl(targetId, ipaHttps) {
  const base = publicDl.resolvePublicBase();
  const ipa = sanitizeIpaUrl(ipaHttps);
  const t = targetById(targetId);
  if (!base || !ipa || !t) return "";
  if (t.httpsDirect) return t.deep(ipa);
  return `${base}/open/${t.id}?u=${encodeURIComponent(ipa)}`;
}

/** Menu page URL with HTML dropdown of all installers. */
function menuUrl(ipaHttps) {
  const base = publicDl.resolvePublicBase();
  const ipa = sanitizeIpaUrl(ipaHttps);
  if (!base || !ipa) return "";
  return `${base}/open/menu?u=${encodeURIComponent(ipa)}`;
}

/** Direct deep link (Telegram) — custom scheme or https. */
function deepLink(targetId, ipaHttps) {
  const ipa = sanitizeIpaUrl(ipaHttps);
  const t = targetById(targetId);
  if (!ipa || !t) return "";
  return t.deep(ipa);
}

function escHtml(s) {
  return String(s || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/"/g, "&quot;");
}

/**
 * HTML bridge page: try custom scheme, show fallbacks.
 */
function bridgeHtml({ targetId, ipaHttps }) {
  const t = targetById(targetId) || { id: "app", label: "Installer", deep: (u) => u };
  const ipa = sanitizeIpaUrl(ipaHttps);
  const deep = ipa ? t.deep(ipa) : "";
  const label = t.label || "Installer";
  const tryDeep = deep && deep !== ipa;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Open in ${escHtml(label)} · FastDecrypt</title>
<style>
  body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;background:#0b0d14;color:#e8eef8;margin:0;padding:28px 20px;line-height:1.45}
  h1{font-size:1.35rem;margin:0 0 8px}
  p{color:#9aa3b5;margin:0 0 18px}
  a.btn{display:block;text-align:center;padding:14px 16px;border-radius:12px;margin:10px 0;text-decoration:none;font-weight:700}
  .primary{background:#ff9a1f;color:#111}
  .ghost{background:#1a2030;color:#e8eef8;border:1px solid #2a3348}
  .note{font-size:.85rem;margin-top:22px}
</style>
</head>
<body>
  <h1>Open in ${escHtml(label)}</h1>
  <p>FastDecrypt · fastdecrypt.bot</p>
  ${tryDeep ? `<a class="btn primary" id="open" href="${escHtml(deep)}">Open ${escHtml(label)}</a>` : ""}
  ${ipa ? `<a class="btn ghost" href="${escHtml(ipa)}">Download IPA</a>` : ""}
  <p class="note">${
    t.id === "flarestore"
      ? "FlareStore: Download the IPA, then Import it in the FlareStore app."
      : tryDeep
        ? `If ${escHtml(label)} didn’t open, install it first, then tap Open again.`
        : "Download the IPA, then import it in your installer app."
  }</p>
  ${
    tryDeep
      ? `<script>
  (function(){
    var deep=${JSON.stringify(deep)};
    try { window.location.href = deep; } catch (e) {}
  })();
</script>`
      : ""
  }
</body>
</html>`;
}

/** HTML dropdown chooser for all installers (Telegram / Safari). */
function menuHtml(ipaHttps) {
  const ipa = sanitizeIpaUrl(ipaHttps);
  const options = TARGETS.map(
    (t) => `<option value="${escHtml(t.id)}">${escHtml(t.label)}</option>`
  ).join("");
  const bridges = {};
  for (const t of TARGETS) {
    bridges[t.id] = redirectUrl(t.id, ipa) || deepLink(t.id, ipa) || ipa;
  }
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Open in… · FastDecrypt</title>
<style>
  body{font-family:-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;background:#0b0d14;color:#e8eef8;margin:0;padding:28px 20px}
  h1{font-size:1.35rem;margin:0 0 8px}
  p{color:#9aa3b5}
  select{width:100%;font-size:1.05rem;padding:14px;border-radius:12px;border:1px solid #2a3348;background:#1a2030;color:#e8eef8;margin:16px 0}
  a.btn,button.btn{display:block;width:100%;box-sizing:border-box;text-align:center;padding:14px 16px;border-radius:12px;margin:10px 0;text-decoration:none;font-weight:700;border:0;font-size:1rem}
  .primary{background:#ff9a1f;color:#111}
  .ghost{background:#1a2030;color:#e8eef8;border:1px solid #2a3348}
</style>
</head>
<body>
  <h1>Open in…</h1>
  <p>Pick an installer, then open it on this iPhone.</p>
  <select id="app">${options}</select>
  <button class="btn primary" type="button" id="go">Continue</button>
  ${ipa ? `<a class="btn ghost" href="${escHtml(ipa)}">Download IPA</a>` : ""}
  <script>
  var bridges=${JSON.stringify(bridges)};
  document.getElementById('go').onclick=function(){
    var id=document.getElementById('app').value;
    var u=bridges[id];
    if(u) location.href=u;
  };
  </script>
</body>
</html>`;
}

/** Discord/Telegram button specs for a given IPA https URL. */
function openInButtons(ipaHttps, { httpsRedirect = true } = {}) {
  const ipa = sanitizeIpaUrl(ipaHttps);
  if (!ipa) return [];
  return TARGETS.map((t) => {
    const url = httpsRedirect ? redirectUrl(t.id, ipa) || deepLink(t.id, ipa) : deepLink(t.id, ipa);
    return { id: t.id, label: t.label, url };
  }).filter((b) => b.url);
}

module.exports = {
  TARGETS,
  targetById,
  sanitizeIpaUrl,
  redirectUrl,
  menuUrl,
  deepLink,
  bridgeHtml,
  menuHtml,
  openInButtons,
  putOpenPending,
  getOpenPending,
};
