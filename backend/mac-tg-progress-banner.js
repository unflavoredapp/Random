// Brand: DELvEK · https://delvek.net
"use strict";
/**
 * DELvEK progress card via `sharp`.
 *
 * Left: Delvek icon + DELVEK · app name · cruel roast line
 * Mid: bigger Tetherless mark toward the progress circle + Made by Tetherless.Dev
 * Right: app icon with Home Screen circular % ring
 * No hashtag · no delvek.net footer
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
    String(tag || "delvek")
      .toLowerCase()
      .replace(/^#/, "")
      .replace(/[^a-z0-9_]+/g, "")
      .slice(0, 24) || "delvek"
  );
}

/** Bigger Tetherless mark, shifted toward the progress circle. */
const CREDIT_ICON = 160;
const CREDIT_ICON_LEFT = 250;
const CREDIT_ICON_TOP = 300;

const BRAND_ICON = 56;
const BRAND_ICON_LEFT = 48;
const BRAND_ICON_TOP = 36;

function leftPanelSvg({ brand, title, stage, W, H, creditIconLeft, creditIconTop, creditIconSize }) {
  const ix = creditIconLeft != null ? creditIconLeft : CREDIT_ICON_LEFT;
  const iy = creditIconTop != null ? creditIconTop : CREDIT_ICON_TOP;
  const isz = creditIconSize != null ? creditIconSize : CREDIT_ICON;
  const creditCx = ix + isz / 2;
  const creditTy = iy + isz + 30;
  const brandTextX = BRAND_ICON_LEFT + BRAND_ICON + 16;
  // Roast can be longer — wrap roughly via smaller font / wider max
  const stageSafe = sanitize(stage, 48);
  return Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="leftFade" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%" stop-color="#080a10" stop-opacity="0.92"/>
      <stop offset="70%" stop-color="#080a10" stop-opacity="0.55"/>
      <stop offset="100%" stop-color="#080a10" stop-opacity="0"/>
    </linearGradient>
  </defs>
  <rect x="0" y="0" width="${Math.round(W * 0.52)}" height="${H}" fill="url(#leftFade)"/>
  <text x="${brandTextX}" y="74" fill="#9aa3b5" font-family="Arial, Helvetica, sans-serif" font-size="24" font-weight="700" letter-spacing="2">${brand}</text>
  <text x="56" y="150" fill="#ffffff" font-family="Arial, Helvetica, sans-serif" font-size="56" font-weight="700">${title}</text>
  <text x="56" y="214" fill="#ffb4b4" font-family="Arial, Helvetica, sans-serif" font-size="26" font-weight="600">${stageSafe}</text>
  <text x="${creditCx}" y="${creditTy}" text-anchor="middle" fill="#b8c0d0" font-family="Arial, Helvetica, sans-serif" font-size="18" font-weight="600">Made by Tetherless.Dev</text>
  <text x="${W - 56}" y="${H - 36}" text-anchor="end" fill="#8a93a6" font-family="Arial, Helvetica, sans-serif" font-size="20">@DELvEKBot</text>
</svg>`);
}

function resolveAsset(names) {
  const roots = [
    path.join(__dirname, "assets"),
    path.join(__dirname, "..", "docs", "assets"),
    path.join(__dirname, "..", "Assets.xcassets", "AppIcon.appiconset"),
    path.join(__dirname, "..", "Assets.xcassets", "DelvekBadge.imageset"),
  ];
  for (const name of names) {
    for (const root of roots) {
      const p = path.join(root, name);
      if (fs.existsSync(p)) return p;
    }
  }
  return "";
}

function resolveTetherlessIcon() {
  return resolveAsset(["tetherless-icon.png", "icon-1024.png"]);
}

function resolveDelvekIcon() {
  return resolveAsset(["delvek-icon.png", "DelvekBadge@3x.png", "DelvekBadge@2x.png"]);
}

async function roundedPng(sharp, srcPath, size) {
  const corner = Math.round(size * 0.22);
  const base = await sharp(srcPath)
    .resize(size, size, { fit: "cover" })
    .png()
    .toBuffer();
  const mask = Buffer.from(`<?xml version="1.0"?>
<svg width="${size}" height="${size}" xmlns="http://www.w3.org/2000/svg">
  <rect width="${size}" height="${size}" rx="${corner}" ry="${corner}" fill="white"/>
</svg>`);
  return sharp(base)
    .composite([{ input: mask, blend: "dest-in" }])
    .png()
    .toBuffer();
}

/** Polar → cartesian for SVG arc (angles in degrees, 0 = top, clockwise). */
function polar(cx, cy, r, deg) {
  const rad = ((deg - 90) * Math.PI) / 180;
  return {
    x: cx + r * Math.cos(rad),
    y: cy + r * Math.sin(rad),
  };
}

function arcPath(cx, cy, r, pct) {
  const p = Math.max(0, Math.min(100, pct));
  if (p <= 0) return "";
  if (p >= 100) {
    return `M ${cx} ${cy - r} A ${r} ${r} 0 1 1 ${cx} ${cy + r} A ${r} ${r} 0 1 1 ${cx} ${cy - r}`;
  }
  const sweep = (p / 100) * 360;
  const end = polar(cx, cy, r, sweep);
  const large = sweep > 180 ? 1 : 0;
  return `M ${cx} ${cy - r} A ${r} ${r} 0 ${large} 1 ${end.x.toFixed(2)} ${end.y.toFixed(2)}`;
}

function homescreenOverlaySvg({ pct, S }) {
  const p = Math.max(0, Math.min(100, Math.round(pct)));
  const cx = S / 2;
  const cy = S / 2;
  const ringR = Math.round(S * 0.42);
  const stroke = Math.max(10, Math.round(S * 0.055));
  const lensR = Math.round(ringR - stroke * 0.15);
  const track = `M ${cx} ${cy - ringR} A ${ringR} ${ringR} 0 1 1 ${cx} ${cy + ringR} A ${ringR} ${ringR} 0 1 1 ${cx} ${cy - ringR}`;
  const prog = arcPath(cx, cy, ringR, p);
  const fontSize = Math.round(S * 0.2);
  const corner = Math.round(S * 0.223);
  return Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<svg width="${S}" height="${S}" viewBox="0 0 ${S} ${S}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <clipPath id="squircle">
      <rect x="0" y="0" width="${S}" height="${S}" rx="${corner}" ry="${corner}"/>
    </clipPath>
  </defs>
  <rect x="0" y="0" width="${S}" height="${S}" rx="${corner}" ry="${corner}" fill="rgba(0,0,0,0.28)" clip-path="url(#squircle)"/>
  <circle cx="${cx}" cy="${cy}" r="${lensR}" fill="rgba(0,0,0,0.48)"/>
  <path d="${track}" fill="none" stroke="rgba(255,255,255,0.22)" stroke-width="${stroke}" stroke-linecap="round"/>
  ${
    prog
      ? `<path d="${prog}" fill="none" stroke="#ffffff" stroke-width="${stroke}" stroke-linecap="round"/>`
      : ""
  }
  <text x="${cx}" y="${cy + fontSize * 0.36}" text-anchor="middle" fill="#ffffff" font-family="Arial, Helvetica, sans-serif" font-size="${fontSize}" font-weight="700">${p}%</text>
</svg>`);
}

function placeholderIconSvg(S) {
  const r = Math.round(S * 0.223);
  return Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<svg width="${S}" height="${S}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0%" stop-color="#3d7cff"/>
      <stop offset="55%" stop-color="#1a3a6e"/>
      <stop offset="100%" stop-color="#0a1628"/>
    </linearGradient>
  </defs>
  <rect width="${S}" height="${S}" rx="${r}" ry="${r}" fill="url(#g)"/>
  <text x="${S / 2}" y="${S / 2 + Math.round(S * 0.08)}" text-anchor="middle" fill="#e8f0ff" font-family="Arial, Helvetica, sans-serif" font-size="${Math.round(S * 0.28)}" font-weight="700">D</text>
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
  const S = 480;
  const title = sanitize(name || "App", 26);
  const progress = sanitize(stage || "You suck at sideloading.", 48);
  const p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
  const brandLabel = sanitize(brand || "DELVEK", 18).toUpperCase();

  const rightLeft = Math.round(W * 0.46);
  const rightWidth = W - rightLeft;
  const iconLeft = rightLeft + Math.round((rightWidth - S) / 2);
  const iconTop = Math.round((H - S) / 2);

  // Tetherless mark sits in the gap toward the circle.
  const creditSize = CREDIT_ICON;
  const creditLeft = CREDIT_ICON_LEFT;
  const creditTop = CREDIT_ICON_TOP;

  try {
    fs.mkdirSync(path.dirname(out), { recursive: true });

    const layers = [];

    if (iconPath && fs.existsSync(iconPath)) {
      const blurBuf = await sharp(iconPath)
        .resize(W, H, { fit: "cover" })
        .blur(28)
        .modulate({ brightness: 0.55, saturation: 0.85 })
        .png()
        .toBuffer();
      const rightMask = Buffer.from(`<?xml version="1.0"?>
<svg width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg">
  <rect x="${rightLeft}" y="0" width="${rightWidth}" height="${H}" fill="white"/>
</svg>`);
      const masked = await sharp(blurBuf)
        .composite([{ input: rightMask, blend: "dest-in" }])
        .png()
        .toBuffer();
      layers.push({ input: masked, left: 0, top: 0 });
    }

    const corner = Math.round(S * 0.223);
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
  <rect width="${S}" height="${S}" rx="${corner}" ry="${corner}" fill="white"/>
</svg>`);
    const rounded = await sharp(iconBase)
      .composite([{ input: iconRoundMask, blend: "dest-in" }])
      .png()
      .toBuffer();
    const withRing = await sharp(rounded)
      .composite([{ input: homescreenOverlaySvg({ pct: p, S }), top: 0, left: 0 }])
      .png()
      .toBuffer();
    layers.push({ input: withRing, left: iconLeft, top: iconTop });

    layers.push({
      input: leftPanelSvg({
        brand: brandLabel,
        title,
        stage: progress,
        W,
        H,
        creditIconLeft: creditLeft,
        creditIconTop: creditTop,
        creditIconSize: creditSize,
      }),
      left: 0,
      top: 0,
    });

    // Delvek mark beside brand label (top-left).
    const delvekIconPath = resolveDelvekIcon();
    if (delvekIconPath) {
      const delvekRounded = await roundedPng(sharp, delvekIconPath, BRAND_ICON);
      layers.push({ input: delvekRounded, left: BRAND_ICON_LEFT, top: BRAND_ICON_TOP });
    }

    // Bigger Tetherless mark toward the circle.
    const creditIconPath = resolveTetherlessIcon();
    if (creditIconPath) {
      const creditRounded = await roundedPng(sharp, creditIconPath, creditSize);
      layers.push({ input: creditRounded, left: creditLeft, top: creditTop });
    }

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
  return loadSharp() ? "sharp" : "";
}

module.exports = {
  renderProgressBanner,
  whichConvert,
  sharpTag,
  loadSharp,
};
