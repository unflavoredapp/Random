// Brand: Tetherless · https://tetherless.dev
"use strict";
/**
 * URSA-style progress banner for the Telegram live card.
 * Left: brand · app name · #tag · stage · big %
 * Right: app icon + LIVE pill
 *
 * Uses ImageMagick (`convert`). Works on MacDuty + Linux hosts.
 */
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

function whichConvert() {
  const r = spawnSync("which", ["convert"], { encoding: "utf8" });
  if (r.status === 0 && String(r.stdout || "").trim()) return String(r.stdout).trim();
  return "";
}

function pickFont(bold) {
  const candidates = bold
    ? [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/Library/Fonts/Arial Bold.ttf",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
      ]
    : [
        "/System/Library/Fonts/Supplemental/Arial.ttf",
        "/Library/Fonts/Arial.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
      ];
  for (const f of candidates) {
    if (fs.existsSync(f)) return f;
  }
  return "";
}

function sanitize(s, max) {
  return String(s || "")
    .replace(/[\r\n\t]+/g, " ")
    .replace(/[^\x20-\x7E\u00A0-\uFFFF]/g, "")
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

function runConvert(args) {
  const r = spawnSync("convert", args, { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  return r.status === 0;
}

/**
 * Render progress banner JPEG.
 * @returns {string} dest path on success, "" on failure
 */
function renderProgressBanner({
  name,
  stage,
  pct,
  iconPath,
  dest,
  tag,
  brand,
} = {}) {
  if (!whichConvert()) return "";
  const out = path.resolve(dest || "");
  if (!out) return "";

  const W = 1200;
  const H = 630;
  const title = sanitize(name || "App", 28);
  const progress = sanitize(stage || "Working…", 36);
  const p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
  const hash = `#${sharpTag(tag)}`;
  const brandLabel = sanitize(brand || "TETHERLESS", 18).toUpperCase();
  const font = pickFont(false);
  const fontBold = pickFont(true) || font;
  const tmpDir = path.dirname(out);
  const stamp = `${process.pid}-${Date.now()}`;
  const base = path.join(tmpDir, `tg-banner-${stamp}-base.png`);
  const glow = path.join(tmpDir, `tg-banner-${stamp}-glow.png`);
  const iconRound = path.join(tmpDir, `tg-banner-${stamp}-icon.png`);
  const pill = path.join(tmpDir, `tg-banner-${stamp}-pill.png`);
  const work = path.join(tmpDir, `tg-banner-${stamp}-work.png`);

  const cleanup = () => {
    for (const f of [base, glow, iconRound, pill, work]) {
      try {
        fs.rmSync(f, { force: true });
      } catch {
        /* ignore */
      }
    }
  };

  try {
    fs.mkdirSync(tmpDir, { recursive: true });

    if (!runConvert(["-size", `${W}x${H}`, "xc:#0c0c10", base])) return "";

    // Soft blue glow on the right (behind icon)
    runConvert([
      "-size",
      `${W}x${H}`,
      "radial-gradient:#3b7cff66-#00000000",
      glow,
    ]);
    runConvert([
      base,
      glow,
      "-gravity",
      "East",
      "-compose",
      "Screen",
      "-composite",
      work,
    ]);
    if (!fs.existsSync(work)) fs.copyFileSync(base, work);

    const f = (file) => (file ? ["-font", file] : []);

    // Text stack (URSA-like): brand → name → #tag → stage → %
    runConvert([
      work,
      ...f(fontBold),
      "-fill",
      "#b8b8c4",
      "-pointsize",
      "26",
      "-gravity",
      "Northwest",
      "-annotate",
      "+64+52",
      brandLabel,
      ...f(fontBold),
      "-fill",
      "#ffffff",
      "-pointsize",
      "70",
      "-gravity",
      "Northwest",
      "-annotate",
      "+64+110",
      title,
      ...f(font),
      "-fill",
      "#6cb6ff",
      "-pointsize",
      "32",
      "-gravity",
      "Northwest",
      "-annotate",
      "+64+210",
      hash,
      ...f(font),
      "-fill",
      "#ececf2",
      "-pointsize",
      "34",
      "-gravity",
      "Northwest",
      "-annotate",
      "+64+275",
      progress,
      ...f(fontBold),
      "-fill",
      "#ffffff",
      "-pointsize",
      "92",
      "-gravity",
      "Northwest",
      "-annotate",
      "+64+340",
      `${p}%`,
      ...f(font),
      "-fill",
      "#8a8a96",
      "-pointsize",
      "22",
      "-gravity",
      "Southwest",
      "-annotate",
      "+64+36",
      "tetherless.dev",
      work,
    ]);

    // Rounded app icon
    if (iconPath && fs.existsSync(iconPath)) {
      const ok = runConvert([
        iconPath,
        "-resize",
        "400x400^",
        "-gravity",
        "center",
        "-extent",
        "400x400",
        "(",
        "+clone",
        "-alpha",
        "transparent",
        "-fill",
        "white",
        "-draw",
        "roundrectangle 0,0 399,399 68,68",
        ")",
        "-alpha",
        "off",
        "-compose",
        "CopyOpacity",
        "-composite",
        iconRound,
      ]);
      if (ok && fs.existsSync(iconRound)) {
        runConvert([
          work,
          iconRound,
          "-gravity",
          "East",
          "-geometry",
          "+64+20",
          "-compose",
          "Over",
          "-composite",
          work,
        ]);
      }
    }

    // VIP-style LIVE / DONE pill (top-right)
    const pillText = p >= 100 ? "DONE" : "LIVE";
    runConvert([
      "-size",
      "200x56",
      "xc:none",
      "-fill",
      "#f5c542",
      "-draw",
      "roundrectangle 0,0 199,55 28,28",
      ...f(fontBold),
      "-fill",
      "#111111",
      "-pointsize",
      "26",
      "-gravity",
      "center",
      "-annotate",
      "+0+1",
      pillText,
      pill,
    ]);
    if (fs.existsSync(pill)) {
      runConvert([
        work,
        pill,
        "-gravity",
        "Northeast",
        "-geometry",
        "+56+48",
        "-compose",
        "Over",
        "-composite",
        work,
      ]);
    }

    if (!runConvert([work, "-quality", "88", out])) return "";
    if (!fs.existsSync(out) || fs.statSync(out).size < 800) return "";
    return out;
  } catch {
    return "";
  } finally {
    cleanup();
  }
}

module.exports = {
  renderProgressBanner,
  whichConvert,
  sharpTag,
};
