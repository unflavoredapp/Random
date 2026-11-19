// Brand: DELvEK · https://delvek.net
"use strict";
/**
 * DELvEK progress card via `sharp`.
 *
 * Left: Delvek icon + DELVEK · transparent terminal log · centered-lower Tetherless mark
 * Right: app name above icon · Home Screen % ring · version by the divider
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
    // Keep apostrophes as ASCII — sharp SVG sometimes paints &apos; literally.
    .replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]))
    .replace(/'/g, "")
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

/** Tetherless mark — centered in the left panel, lower on the card. */
const CREDIT_ICON = 132;
const CREDIT_ICON_LEFT = 164;
const CREDIT_ICON_TOP = 455;

const BRAND_ICON = 56;
const BRAND_ICON_LEFT = 48;
const BRAND_ICON_TOP = 36;

const TERM_FONT = "Menlo, Monaco, Consolas, monospace";

/** Transparent terminal pane — live backend say() lines (no Mac window chrome). */
function terminalLogSvg({ logLines, W, H, rightLeft }) {
  const lines = (Array.isArray(logLines) ? logLines : [])
    .map((l) => sanitize(String(l || ""), 56))
    .filter(Boolean)
    .slice(-6);
  while (lines.length < 1) lines.push("$ waiting…");

  const panelW = Math.min(500, Math.max(360, rightLeft - 72));
  const panelX = 40;
  const panelY = 108;
  const lineH = 28;
  const padTop = 22;
  const panelH = padTop + lines.length * lineH + 16;
  const rx = 14;

  let body = "";
  for (let i = 0; i < lines.length; i++) {
    const y = panelY + padTop + i * lineH;
    const isLast = i === lines.length - 1;
    const fill = isLast ? "#7CFFB2" : "#8FA3B8";
    const prefix = lines[i].startsWith("$") || lines[i].startsWith(">") ? "" : "> ";
    body += `<text x="${panelX + 18}" y="${y}" fill="${fill}" font-family="${TERM_FONT}" font-size="17" font-weight="${
      isLast ? "700" : "500"
    }">${prefix}${lines[i]}</text>`;
  }

  return Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="termGlass" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#0c121c" stop-opacity="0.62"/>
      <stop offset="100%" stop-color="#070a10" stop-opacity="0.48"/>
    </linearGradient>
  </defs>
  <rect x="${panelX}" y="${panelY}" width="${panelW}" height="${panelH}" rx="${rx}" ry="${rx}" fill="url(#termGlass)" stroke="#ffffff" stroke-opacity="0.14" stroke-width="1.5"/>
  ${body}
</svg>`);
}

function leftPanelSvg({ brand, W, H, creditIconLeft, creditIconTop, creditIconSize }) {
  const ix = creditIconLeft != null ? creditIconLeft : CREDIT_ICON_LEFT;
  const iy = creditIconTop != null ? creditIconTop : CREDIT_ICON_TOP;
  const isz = creditIconSize != null ? creditIconSize : CREDIT_ICON;
  const creditCx = ix + isz / 2;
  const creditTy = iy + isz + 26;
  const brandTextX = BRAND_ICON_LEFT + BRAND_ICON + 16;
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
  <text x="${creditCx}" y="${creditTy}" text-anchor="middle" fill="#b8c0d0" font-family="Arial, Helvetica, sans-serif" font-size="18" font-weight="600">Made by Tetherless.Dev</text>
  <text x="${W - 56}" y="${H - 36}" text-anchor="end" fill="#8a93a6" font-family="Arial, Helvetica, sans-serif" font-size="20">@DELvEKBot</text>
</svg>`);
}

/** App name above the right-side icon + version by the divider (lower-left of right panel). */
function rightMetaSvg({ title, version, W, H, rightLeft, iconLeft, iconTop, iconSize }) {
  const name = sanitize(title || "App", 42);
  const verRaw = String(version || "").trim().replace(/^v/i, "");
  const ver = verRaw ? sanitize(`v${verRaw}`, 24) : "";
  // Smaller font so longer App Store names fit above the icon.
  const fontSize = name.length > 28 ? 26 : name.length > 18 ? 30 : 34;
  const nameCx = iconLeft + iconSize / 2;
  const nameY = Math.max(42, iconTop - 22);
  const verX = rightLeft + 28;
  const verY = H - 40;
  return Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg">
  <text x="${nameCx}" y="${nameY}" text-anchor="middle" fill="#ffffff" font-family="Arial, Helvetica, sans-serif" font-size="${fontSize}" font-weight="700">${name}</text>
  ${
    ver
      ? `<text x="${verX}" y="${verY}" fill="#c5cddc" font-family="Arial, Helvetica, sans-serif" font-size="22" font-weight="600">${ver}</text>`
      : ""
  }
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
  version,
  stage,
  logLines,
  pct,
  iconPath,
  dest,
  tag,
  brand,
  done,
} = {}) {
  const sharp = loadSharp();
  if (!sharp) return "";
  const out = path.resolve(dest || "");
  if (!out) return "";

  const W = 1200;
  const H = 630;
  // Slightly smaller icon so the full app name fits above it on the right.
  const S = 440;
  const isDone = !!done;
  const title = String(name || "App").trim() || "App";
  const p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
  const brandLabel = sanitize(brand || "DELVEK", 18).toUpperCase();
  const termLines = Array.isArray(logLines) && logLines.length
    ? logLines
    : [stage || (isDone ? "done" : "starting…")];

  const rightLeft = Math.round(W * 0.46);
  const rightWidth = W - rightLeft;
  const iconLeft = rightLeft + Math.round((rightWidth - S) / 2);
  // Leave room above for the app name.
  const iconTop = Math.round((H - S) / 2) + 18;

  // Centered in the left panel, lower on the card (under the terminal).
  const creditSize = CREDIT_ICON;
  const creditLeft = Math.round((rightLeft - creditSize) / 2);
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
    // Done: clean app icon (Telegram draws its own download UI). In-progress: % ring.
    const withOverlay = isDone
      ? rounded
      : await sharp(rounded)
          .composite([{ input: homescreenOverlaySvg({ pct: p, S }), top: 0, left: 0 }])
          .png()
          .toBuffer();
    layers.push({ input: withOverlay, left: iconLeft, top: iconTop });

    layers.push({
      input: leftPanelSvg({
        brand: brandLabel,
        W,
        H,
        creditIconLeft: creditLeft,
        creditIconTop: creditTop,
        creditIconSize: creditSize,
      }),
      left: 0,
      top: 0,
    });

    layers.push({
      input: terminalLogSvg({
        logLines: termLines,
        W,
        H,
        rightLeft,
      }),
      left: 0,
      top: 0,
    });

    layers.push({
      input: rightMetaSvg({
        title,
        version: version || "",
        W,
        H,
        rightLeft,
        iconLeft,
        iconTop,
        iconSize: S,
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

    // Tetherless mark — centered lower in the left panel.
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

/**
 * IPA document thumbnail (Telegram: JPEG ≤320px, ≤200KB) — clean app icon only.
 * No download-arrow overlay; Telegram already draws its own download control.
 * @returns {Promise<string>} dest path on success, "" on failure
 */
async function renderDownloadThumb({ iconPath, dest, size } = {}) {
  const sharp = loadSharp();
  if (!sharp) return "";
  const out = path.resolve(dest || "");
  if (!out) return "";
  const S = Math.max(160, Math.min(320, Math.round(Number(size) || 320)));

  try {
    fs.mkdirSync(path.dirname(out), { recursive: true });
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
    const mask = Buffer.from(`<?xml version="1.0"?>
<svg width="${S}" height="${S}" xmlns="http://www.w3.org/2000/svg">
  <rect width="${S}" height="${S}" rx="${corner}" ry="${corner}" fill="white"/>
</svg>`);
    await sharp(iconBase)
      .composite([{ input: mask, blend: "dest-in" }])
      .flatten({ background: { r: 20, g: 20, b: 28 } })
      .jpeg({ quality: 82, mozjpeg: true })
      .toFile(out);

    if (!fs.existsSync(out) || fs.statSync(out).size < 400) return "";
    // Telegram thumb hard limit ~200KB — recompress if needed.
    if (fs.statSync(out).size > 190 * 1024) {
      await sharp(out)
        .resize(240, 240, { fit: "cover" })
        .jpeg({ quality: 70, mozjpeg: true })
        .toFile(out);
    }
    return out;
  } catch (e) {
    console.warn("[banner] download thumb failed:", String((e && e.message) || e).slice(0, 160));
    return "";
  }
}

/**
 * Version picker sharp card — versions live on the image (not a text button list).
 * Top center: VERSIONS · app name · icon · numbered builds · page footer.
 * @param {{ title?: string, iconPath?: string, versions?: Array<{n:number,label:string}>, page?: number, pages?: number, total?: number, dest?: string }} opts
 */
async function renderVersionPickerBanner(opts = {}) {
  const sharp = loadSharp();
  if (!sharp) return "";
  const out = path.resolve(opts.dest || "");
  if (!out) return "";

  const W = 1200;
  const H = 630;
  const title = sanitize(opts.title || "App", 36);
  const page = Math.max(1, Number(opts.page) || 1);
  const pages = Math.max(1, Number(opts.pages) || 1);
  const total = Math.max(0, Number(opts.total) || 0);
  const versions = Array.isArray(opts.versions) ? opts.versions : [];
  const iconPath = opts.iconPath || "";

  try {
    fs.mkdirSync(path.dirname(out), { recursive: true });

    const layers = [];

    // Soft icon blur background.
    if (iconPath && fs.existsSync(iconPath)) {
      const blurBuf = await sharp(iconPath)
        .resize(W, H, { fit: "cover" })
        .blur(32)
        .modulate({ brightness: 0.4, saturation: 0.75 })
        .png()
        .toBuffer();
      layers.push({ input: blurBuf, left: 0, top: 0 });
    }

    // Dark scrim so text stays readable.
    const scrim = Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<svg width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0%" stop-color="#080a10" stop-opacity="0.72"/>
      <stop offset="100%" stop-color="#080a10" stop-opacity="0.88"/>
    </linearGradient>
  </defs>
  <rect width="${W}" height="${H}" fill="url(#g)"/>
</svg>`);
    layers.push({ input: await sharp(scrim).png().toBuffer(), left: 0, top: 0 });

    // App icon (left).
    const iconSize = 220;
    const iconLeft = 72;
    const iconTop = 200;
    let iconBuf;
    if (iconPath && fs.existsSync(iconPath)) {
      iconBuf = await roundedPng(sharp, iconPath, iconSize);
    } else {
      iconBuf = await sharp(placeholderIconSvg(iconSize)).png().toBuffer();
    }
    layers.push({ input: iconBuf, left: iconLeft, top: iconTop });

    // Numbered version rows (right of icon).
    const rowLines = versions
      .slice(0, 8)
      .map((v, idx) => {
        const n = Number(v.n != null ? v.n : idx + 1);
        const label = sanitize(String(v.label || "—").replace(/^v/i, ""), 28);
        const star = v.current ? "  *" : "";
        return { n, label: `v${label}${star}` };
      });

    let rowsSvg = "";
    const listLeft = 360;
    const listTop = 175;
    const rowH = 48;
    rowLines.forEach((row, i) => {
      const y = listTop + i * rowH;
      rowsSvg += `
  <circle cx="${listLeft}" cy="${y}" r="18" fill="#1e2a44" stroke="#3d7cff" stroke-width="2"/>
  <text x="${listLeft}" y="${y + 7}" text-anchor="middle" fill="#ffffff" font-family="Arial, Helvetica, sans-serif" font-size="20" font-weight="700">${row.n}</text>
  <text x="${listLeft + 36}" y="${y + 8}" fill="#f2f5fa" font-family="Arial, Helvetica, sans-serif" font-size="28" font-weight="600">${row.label}</text>`;
    });

    const panel = Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<svg width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" xmlns="http://www.w3.org/2000/svg">
  <text x="${W / 2}" y="78" text-anchor="middle" fill="#ffffff" font-family="Arial, Helvetica, sans-serif" font-size="42" font-weight="800" letter-spacing="3">VERSIONS</text>
  <text x="${W / 2}" y="122" text-anchor="middle" fill="#b8c0d0" font-family="Arial, Helvetica, sans-serif" font-size="26" font-weight="600">${title}</text>
  ${rowsSvg}
  <text x="${W / 2}" y="${H - 48}" text-anchor="middle" fill="#9aa3b5" font-family="Arial, Helvetica, sans-serif" font-size="22" font-weight="600">page ${page}/${pages} · ${total} builds · reply with a number</text>
  <text x="${W - 56}" y="${H - 20}" text-anchor="end" fill="#6b7385" font-family="Arial, Helvetica, sans-serif" font-size="18">@DELvEKBot</text>
</svg>`);
    layers.push({ input: await sharp(panel).png().toBuffer(), left: 0, top: 0 });

    // Small Delvek mark top-left.
    const delvekIconPath = resolveDelvekIcon();
    if (delvekIconPath) {
      const delvekRounded = await roundedPng(sharp, delvekIconPath, 48);
      layers.push({ input: delvekRounded, left: 40, top: 36 });
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
    console.warn("[banner] version picker failed:", String((e && e.message) || e).slice(0, 160));
    return "";
  }
}

function whichConvert() {
  return loadSharp() ? "sharp" : "";
}

module.exports = {
  renderProgressBanner,
  renderDownloadThumb,
  renderVersionPickerBanner,
  whichConvert,
  sharpTag,
  loadSharp,
};
