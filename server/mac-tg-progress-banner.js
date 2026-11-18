// Brand: Tetherless · https://tetherless.dev
"use strict";
/**
 * Tetherless progress card — URSA-inspired layout via `sharp` (no ImageMagick).
 *
 * Left: TETHERLESS · app name · stage + LIVE · #tag
 * Right: blurred wash · sharp rounded icon with live % overlay + bar
 */
const fs = require("fs");
const path = require("path");

function loadSharp() {
  try {
    return require("sharp");
  } catch {
    try {
      return require(path.join(__dirname, "node_modules", "sharp"));
    } catch {
      return null;
    }
  }
}

function sanitize(s, max) {
  return String(s || "")
    .replace(/…/g, "...")
    .replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&apos;" }[c]))
    .replace(/[^\x20-\x7E]+/g, "")
    .trim()
    .slice(0, max || 40);
}

function sharpTag(tag) {
  return (
    String(tag || "tetherless")
      .toLowerCase()
      .replace(/^#/, "")
      .replace(/[^a-z0-9_]+/g, "")
      .slice(0, 24) || "tetherless"
  );
}

function escapeXml(s) {
  return String(s || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function leftPanelSvg({ brand, title, stage, hash, W, H }) {
  const pillX = 56 + Math.min(340, stage.length * 15);
  return Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="leftFade" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%" stop-color="#080a10" stop-opacity="0.92"/>
      <stop offset="70%" stop-color="#080a10" stop-opacity="0.55"/>
      <stop offset="100%" stop-color="#080a10" stop-opacity="0"/>
    </linearGradient>
  </defs>
  <rect x="0" y="0" width="${Math.round(W * 0.58)}" height="${H}" fill="url(#leftFade)"/>
  <text x="56" y="72" fill="#9aa3b5" font-family="Arial, Helvetica, sans-serif" font-size="24" font-weight="700" letter-spacing="2">${brand}</text>
  <text x="56" y="150" fill="#ffffff" font-family="Arial, Helvetica, sans-serif" font-size="60" font-weight="700">${title}</text>
  <text x="56" y="214" fill="#d7dbe6" font-family="Arial, Helvetica, sans-serif" font-size="28">${stage}</text>
  <rect x="${pillX}" y="186" rx="22" ry="22" width="100" height="40" fill="#f5c542"/>
  <text x="${pillX + 50}" y="214" text-anchor="middle" fill="#111111" font-family="Arial, Helvetica, sans-serif" font-size="20" font-weight="700">LIVE</text>
  <text x="56" y="268" fill="#6cb6ff" font-family="Arial, Helvetica, sans-serif" font-size="28">${hash}</text>
  <text x="56" y="${H - 36}" fill="#8a93a6" font-family="Arial, Helvetica, sans-serif" font-size="20">tetherless.dev</text>
  <text x="${W - 56}" y="${H - 36}" text-anchor="end" fill="#8a93a6" font-family="Arial, Helvetica, sans-serif" font-size="20">@tetherless</text>
</svg>`);
}

function iconOverlaySvg({ pct, chip, S }) {
  const p = Math.max(0, Math.min(100, pct));
  const barW = Math.round((S - 100) * (p / 100));
  const chipText = escapeXml(String(chip || "LIVE").slice(0, 14).toUpperCase());
  return Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<svg width="${S}" height="${S}" viewBox="0 0 ${S} ${S}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <clipPath id="round">
      <rect x="0" y="0" width="${S}" height="${S}" rx="72" ry="72"/>
    </clipPath>
  </defs>
  <rect x="0" y="0" width="${S}" height="${S}" rx="72" ry="72" fill="rgba(0,0,0,0.32)" clip-path="url(#round)"/>
  <rect x="${Math.round(S * 0.14)}" y="${Math.round(S * 0.34)}" width="${Math.round(S * 0.72)}" height="${Math.round(S * 0.38)}" rx="36" ry="36" fill="rgba(0,0,0,0.72)"/>
  <text x="${S / 2}" y="${S / 2 + 18}" text-anchor="middle" fill="#ffffff" font-family="Arial, Helvetica, sans-serif" font-size="${Math.round(S * 0.24)}" font-weight="700">${p}%</text>
  <rect x="50" y="${S - 56}" width="${S - 100}" height="18" rx="9" ry="9" fill="rgba(255,255,255,0.28)"/>
  <rect x="50" y="${S - 56}" width="${Math.max(10, barW)}" height="18" rx="9" ry="9" fill="#5ec8ff"/>
  <rect x="0" y="0" width="${S}" height="${S}" rx="72" ry="72" fill="none" stroke="#5ec8ff" stroke-width="6"/>
  <rect x="${S - 250}" y="18" rx="26" ry="26" width="232" height="48" fill="#2f6bff"/>
  <text x="${S - 134}" y="50" text-anchor="middle" fill="#ffffff" font-family="Arial, Helvetica, sans-serif" font-size="18" font-weight="700">${chipText}</text>
</svg>`);
}

function placeholderIconSvg(S) {
  return Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<svg width="${S}" height="${S}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#1a2740"/>
      <stop offset="100%" stop-color="#0a1020"/>
    </linearGradient>
  </defs>
  <rect width="${S}" height="${S}" fill="url(#g)"/>
  <text x="${S / 2}" y="${S / 2 + 20}" text-anchor="middle" fill="#6cb6ff" font-family="Arial, Helvetica, sans-serif" font-size="72" font-weight="700">T</text>
</svg>`);
}

/**
 * Render progress banner JPEG with sharp.
 * @returns {Promise<string>} dest path on success, "" on failure
 */
async function renderProgressBanner({
  name,
  stage,
  pct,
  iconPath,
  dest,
  tag,
  brand,
} = {}) {
  const sharp = loadSharp();
  if (!sharp) return "";
  const out = path.resolve(dest || "");
  if (!out) return "";

  const W = 1200;
  const H = 630;
  const S = 420;
  const title = sanitize(name || "App", 26);
  const progress = sanitize(stage || "Working...", 28);
  const p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
  const hash = `#${sharpTag(tag)}`;
  const brandLabel = sanitize(brand || "TETHERLESS", 18).toUpperCase();
  const chip = p >= 100 ? "DONE" : progress.toUpperCase().slice(0, 14) || "LIVE";

  try {
    fs.mkdirSync(path.dirname(out), { recursive: true });

    const layers = [];

    // Right-side blurred wash from app icon
    if (iconPath && fs.existsSync(iconPath)) {
      const blurBuf = await sharp(iconPath)
        .resize(W, H, { fit: "cover" })
        .blur(28)
        .modulate({ brightness: 0.55, saturation: 0.85 })
        .png()
        .toBuffer();
      // Mask to right half via SVG
      const rightMask = Buffer.from(`<?xml version="1.0"?>
<svg width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg">
  <rect x="${Math.round(W * 0.4)}" y="0" width="${Math.round(W * 0.6)}" height="${H}" fill="white"/>
</svg>`);
      const masked = await sharp(blurBuf)
        .composite([{ input: rightMask, blend: "dest-in" }])
        .png()
        .toBuffer();
      layers.push({ input: masked, left: 0, top: 0 });
    }

    // Sharp rounded icon + % overlay
    let iconBase;
    if (iconPath && fs.existsSync(iconPath)) {
      iconBase = await sharp(iconPath)
        .resize(S, S, { fit: "cover" })
        .png()
        .toBuffer();
    } else {
      iconBase = await sharp(placeholderIconSvg(S)).png().toBuffer();
    }
    const iconRoundMask = Buffer.from(`<?xml version="1.0"?>
<svg width="${S}" height="${S}" xmlns="http://www.w3.org/2000/svg">
  <rect width="${S}" height="${S}" rx="72" ry="72" fill="white"/>
</svg>`);
    const rounded = await sharp(iconBase)
      .composite([{ input: iconRoundMask, blend: "dest-in" }])
      .png()
      .toBuffer();
    const withPct = await sharp(rounded)
      .composite([{ input: iconOverlaySvg({ pct: p, chip, S }), top: 0, left: 0 }])
      .png()
      .toBuffer();
    layers.push({ input: withPct, left: W - S - 64, top: Math.round((H - S) / 2) });

    // Left text panel SVG
    layers.push({
      input: leftPanelSvg({
        brand: brandLabel,
        title,
        stage: progress,
        hash,
        W,
        H,
      }),
      left: 0,
      top: 0,
    });

    await sharp({
      create: {
        width: W,
        height: H,
        channels: 3,
        background: { r: 11, g: 13, b: 20 },
      },
    })
      .composite(layers)
      .jpeg({ quality: 90, mozjpeg: true })
      .toFile(out);

    if (!fs.existsSync(out) || fs.statSync(out).size < 800) return "";
    return out;
  } catch (e) {
    console.warn("[banner] sharp render failed:", String((e && e.message) || e).slice(0, 160));
    return "";
  }
}

function whichConvert() {
  // Kept for status/debug — banners now prefer sharp.
  return loadSharp() ? "sharp" : "";
}

module.exports = {
  renderProgressBanner,
  whichConvert,
  sharpTag,
  loadSharp,
};
