// Brand: Tetherless · https://tetherless.dev
"use strict";
/**
 * Tetherless progress card for Telegram — URSA-inspired layout, our branding.
 *
 * Left: TETHERLESS · app name · stage + VIP pill · #tag · tetherless.dev
 * Right: blurred icon wash · sharp rounded icon with % overlay · LIVE badge
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
    .replace(/…/g, "...")
    .replace(/[\r\n\t]+/g, " ")
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

function runConvert(args) {
  const r = spawnSync("convert", args, { encoding: "utf8", maxBuffer: 16 * 1024 * 1024 });
  return r.status === 0;
}

/**
 * Build rounded icon with dark glass + big % overlay inside the sharp art.
 */
function buildIconWithPct({ iconPath, pct, fontBold, dest, size }) {
  const S = size || 420;
  const p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
  const tmp = `${dest}.tmp.png`;
  const mask = `${dest}.mask.png`;
  const glass = `${dest}.glass.png`;
  const label = `${dest}.label.png`;

  const cleanupLocal = () => {
    for (const f of [tmp, mask, glass, label]) {
      try {
        fs.rmSync(f, { force: true });
      } catch {
        /* ignore */
      }
    }
  };

  try {
    // Base art (or brand placeholder)
    if (iconPath && fs.existsSync(iconPath)) {
      if (
        !runConvert([
          iconPath,
          "-resize",
          `${S}x${S}^`,
          "-gravity",
          "center",
          "-extent",
          `${S}x${S}`,
          tmp,
        ])
      ) {
        return false;
      }
    } else if (
      !runConvert([
        "-size",
        `${S}x${S}`,
        "gradient:#1a2740-#0a1020",
        "-fill",
        "#6cb6ff",
        "-gravity",
        "center",
        "-pointsize",
        "48",
        ...(fontBold ? ["-font", fontBold] : []),
        "-annotate",
        "+0+0",
        "T",
        tmp,
      ])
    ) {
      return false;
    }

    // Full-card dim + dark pill behind % so it reads on light App Store icons
    runConvert([
      "-size",
      `${S}x${S}`,
      "xc:none",
      "-fill",
      "rgba(0,0,0,0.35)",
      "-draw",
      `rectangle 0,0 ${S},${S}`,
      "-fill",
      "rgba(0,0,0,0.72)",
      "-draw",
      `roundrectangle ${Math.round(S * 0.14)},${Math.round(S * 0.34)} ${Math.round(S * 0.86)},${Math.round(S * 0.72)} 36,36`,
      glass,
    ]);
    runConvert([tmp, glass, "-compose", "Over", "-composite", tmp]);

    // Big % centered inside the sharp icon
    const pt = Math.round(S * 0.26);
    runConvert([
      "-size",
      `${S}x${S}`,
      "xc:none",
      ...(fontBold ? ["-font", fontBold] : []),
      "-fill",
      "#ffffff",
      "-pointsize",
      String(pt),
      "-gravity",
      "center",
      "-annotate",
      "+0+0",
      `${p}%`,
      label,
    ]);
    runConvert([tmp, label, "-compose", "Over", "-composite", tmp]);

    // Progress bar under the %
    const barW = Math.round((S - 100) * (p / 100));
    runConvert([
      tmp,
      "-fill",
      "rgba(255,255,255,0.28)",
      "-draw",
      `roundrectangle 50,${S - 56} ${S - 50},${S - 38} 9,9`,
      "-fill",
      "#5ec8ff",
      "-draw",
      `roundrectangle 50,${S - 56} ${50 + Math.max(10, barW)},${S - 38} 9,9`,
      tmp,
    ]);

    // Round + thin cyan border (URSA “sharp” icon frame)
    runConvert([
      "-size",
      `${S}x${S}`,
      "xc:none",
      "-fill",
      "white",
      "-draw",
      `roundrectangle 0,0 ${S - 1},${S - 1} 72,72`,
      mask,
    ]);
    runConvert([
      tmp,
      mask,
      "-alpha",
      "Off",
      "-compose",
      "CopyOpacity",
      "-composite",
      tmp,
    ]);
    // Border ring
    runConvert([
      "-size",
      `${S}x${S}`,
      "xc:none",
      "-fill",
      "none",
      "-stroke",
      "#5ec8ff",
      "-strokewidth",
      "6",
      "-draw",
      `roundrectangle 3,3 ${S - 4},${S - 4} 70,70`,
      mask,
    ]);
    runConvert([tmp, mask, "-compose", "Over", "-composite", dest]);
    return fs.existsSync(dest);
  } catch {
    return false;
  } finally {
    cleanupLocal();
  }
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
  const title = sanitize(name || "App", 26);
  const progress = sanitize(stage || "Working…", 28);
  const p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
  const hash = `#${sharpTag(tag)}`;
  const brandLabel = sanitize(brand || "TETHERLESS", 18).toUpperCase();
  const font = pickFont(false);
  const fontBold = pickFont(true) || font;
  const tmpDir = path.dirname(out);
  const stamp = `${process.pid}-${Date.now()}`;
  const base = path.join(tmpDir, `tg-banner-${stamp}-base.png`);
  const blurBg = path.join(tmpDir, `tg-banner-${stamp}-blur.png`);
  const iconRound = path.join(tmpDir, `tg-banner-${stamp}-icon.png`);
  const pillVip = path.join(tmpDir, `tg-banner-${stamp}-vip.png`);
  const pillLive = path.join(tmpDir, `tg-banner-${stamp}-live.png`);
  const work = path.join(tmpDir, `tg-banner-${stamp}-work.png`);

  const cleanup = () => {
    for (const f of [base, blurBg, iconRound, pillVip, pillLive, work]) {
      try {
        fs.rmSync(f, { force: true });
      } catch {
        /* ignore */
      }
    }
  };

  try {
    fs.mkdirSync(tmpDir, { recursive: true });

    // Split backdrop: dark left / icon-washed right
    if (!runConvert(["-size", `${W}x${H}`, "xc:#0b0d14", base])) return "";
    if (iconPath && fs.existsSync(iconPath)) {
      runConvert([
        iconPath,
        "-resize",
        `${W}x${H}^`,
        "-gravity",
        "center",
        "-extent",
        `${W}x${H}`,
        "-blur",
        "0x28",
        "-brightness-contrast",
        "-25x-10",
        blurBg,
      ]);
      if (fs.existsSync(blurBg)) {
        // Keep left dark; composite blurred art on the right half
        runConvert([
          "-size",
          `${W}x${H}`,
          "xc:none",
          "-fill",
          "white",
          "-draw",
          `rectangle ${Math.round(W * 0.42)},0 ${W},${H}`,
          path.join(tmpDir, `tg-banner-${stamp}-rmask.png`),
        ]);
        const rmask = path.join(tmpDir, `tg-banner-${stamp}-rmask.png`);
        runConvert([
          blurBg,
          rmask,
          "-alpha",
          "Off",
          "-compose",
          "CopyOpacity",
          "-composite",
          blurBg,
        ]);
        runConvert([base, blurBg, "-compose", "Over", "-composite", work]);
        try {
          fs.rmSync(rmask, { force: true });
        } catch {
          /* ignore */
        }
      }
    }
    if (!fs.existsSync(work)) fs.copyFileSync(base, work);

    // Soft left vignette so text stays readable
    runConvert([
      work,
      "-fill",
      "rgba(8,10,16,0.72)",
      "-draw",
      `rectangle 0,0 ${Math.round(W * 0.55)},${H}`,
      work,
    ]);

    const f = (file) => (file ? ["-font", file] : []);

    // VIP-style pill next to stage (Tetherless accent)
    runConvert([
      "-size",
      "110x44",
      "xc:none",
      "-fill",
      "#f5c542",
      "-draw",
      "roundrectangle 0,0 109,43 22,22",
      ...f(fontBold),
      "-fill",
      "#111111",
      "-pointsize",
      "22",
      "-gravity",
      "center",
      "-annotate",
      "+0+1",
      "LIVE",
      pillVip,
    ]);

    // Status chip top-right over icon (like URSA “NEW MOD”)
    const chip = p >= 100 ? "DONE" : progress.toUpperCase().slice(0, 14) || "LIVE";
    runConvert([
      "-size",
      "240x52",
      "xc:none",
      "-fill",
      "#2f6bff",
      "-draw",
      "roundrectangle 0,0 239,51 26,26",
      ...f(fontBold),
      "-fill",
      "#ffffff",
      "-pointsize",
      "20",
      "-gravity",
      "center",
      "-annotate",
      "+0+1",
      chip,
      pillLive,
    ]);

    // Left copy — no big % here; % lives inside the sharp icon
    runConvert([
      work,
      ...f(fontBold),
      "-fill",
      "#9aa3b5",
      "-pointsize",
      "24",
      "-gravity",
      "Northwest",
      "-annotate",
      "+56+48",
      brandLabel,
      ...f(fontBold),
      "-fill",
      "#ffffff",
      "-pointsize",
      "64",
      "-gravity",
      "Northwest",
      "-annotate",
      "+56+100",
      title,
      ...f(font),
      "-fill",
      "#d7dbe6",
      "-pointsize",
      "30",
      "-gravity",
      "Northwest",
      "-annotate",
      "+56+190",
      progress,
      ...f(font),
      "-fill",
      "#6cb6ff",
      "-pointsize",
      "30",
      "-gravity",
      "Northwest",
      "-annotate",
      "+56+250",
      hash,
      ...f(font),
      "-fill",
      "#8a93a6",
      "-pointsize",
      "22",
      "-gravity",
      "Southwest",
      "-annotate",
      "+56+36",
      "tetherless.dev",
      ...f(font),
      "-fill",
      "#8a93a6",
      "-pointsize",
      "22",
      "-gravity",
      "Southeast",
      "-annotate",
      "+56+36",
      "@tetherless",
      work,
    ]);

    // Stage VIP pill (beside progress text)
    if (fs.existsSync(pillVip)) {
      runConvert([
        work,
        pillVip,
        "-gravity",
        "Northwest",
        "-geometry",
        `+${56 + Math.min(360, progress.length * 16)}+186`,
        "-compose",
        "Over",
        "-composite",
        work,
      ]);
    }

    // Sharp icon with dynamic % overlay
    const iconOk = buildIconWithPct({
      iconPath,
      pct: p,
      fontBold,
      dest: iconRound,
      size: 420,
    });
    if (iconOk && fs.existsSync(iconRound)) {
      runConvert([
        work,
        iconRound,
        "-gravity",
        "East",
        "-geometry",
        "+64+8",
        "-compose",
        "Over",
        "-composite",
        work,
      ]);
    }

    // LIVE / stage chip over icon corner
    if (fs.existsSync(pillLive)) {
      runConvert([
        work,
        pillLive,
        "-gravity",
        "Northeast",
        "-geometry",
        "+88+72",
        "-compose",
        "Over",
        "-composite",
        work,
      ]);
    }

    if (!runConvert([work, "-quality", "90", out])) return "";
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
