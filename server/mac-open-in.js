// Brand: FastDecrypt · https://fastdecrypt.bot
"use strict";
/**
 * "Open in …" deep links after decrypt (TrollStore, Feather, E-Sign, FlareStore, ShrubSign).
 *
 * Discord Link buttons only allow https:// — so Discord uses /open/<target>?u= on the
 * Mac public API, which redirects into the app’s custom scheme.
 * Telegram inline buttons can use custom schemes directly.
 */
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
    // Feather docs: feather://install/<url> (keep https:// unescaped in path)
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
    // No reliable public scheme — open helper that falls back to IPA download for Import.
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

function sanitizeIpaUrl(raw) {
  const u = String(raw || "").trim();
  if (!/^https:\/\/[^\s]+$/i.test(u)) return "";
  if (u.length > 2000) return "";
  return u;
}

function targetById(id) {
  return TARGETS.find((t) => t.id === String(id || "").toLowerCase()) || null;
}

/** Absolute https://…/open/<target>?u=… for Discord Link buttons. */
function redirectUrl(targetId, ipaHttps) {
  const base = publicDl.resolvePublicBase();
  const ipa = sanitizeIpaUrl(ipaHttps);
  const t = targetById(targetId);
  if (!base || !ipa || !t) return "";
  if (t.httpsDirect) return t.deep(ipa);
  return `${base}/open/${t.id}?u=${encodeURIComponent(ipa)}`;
}

/** Direct deep link (Telegram) — custom scheme or https. */
function deepLink(targetId, ipaHttps) {
  const ipa = sanitizeIpaUrl(ipaHttps);
  const t = targetById(targetId);
  if (!ipa || !t) return "";
  return t.deep(ipa);
}

/**
 * HTML bridge page: try custom scheme, show fallbacks.
 * @returns {string} html
 */
function bridgeHtml({ targetId, ipaHttps }) {
  const t = targetById(targetId) || { id: "app", label: "Installer", deep: (u) => u };
  const ipa = sanitizeIpaUrl(ipaHttps);
  const deep = ipa ? t.deep(ipa) : "";
  const label = t.label || "Installer";
  const esc = (s) =>
    String(s || "")
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/"/g, "&quot;");
  const tryDeep = deep && deep !== ipa;
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Open in ${esc(label)} · FastDecrypt</title>
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
  <h1>Open in ${esc(label)}</h1>
  <p>FastDecrypt · decrypted IPA handoff</p>
  ${
    tryDeep
      ? `<a class="btn primary" id="open" href="${esc(deep)}">Open ${esc(label)}</a>`
      : ""
  }
  ${ipa ? `<a class="btn ghost" href="${esc(ipa)}">Download IPA</a>` : ""}
  <p class="note">${
    t.id === "flarestore"
      ? "FlareStore: Download the IPA, then Import it in the FlareStore app."
      : tryDeep
        ? `If ${esc(label)} didn’t open, install it first, then tap Open again.`
        : "Download the IPA, then import it in your installer app."
  }</p>
  ${
    tryDeep
      ? `<script>
  (function(){
    var deep=${JSON.stringify(deep)};
    try { window.location.href = deep; } catch (e) {}
    setTimeout(function(){
      var a=document.getElementById('open');
      if(a) a.focus();
    }, 400);
  })();
</script>`
      : ""
  }
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
  deepLink,
  bridgeHtml,
  openInButtons,
};
