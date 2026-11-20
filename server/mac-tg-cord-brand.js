// Brand: Tetherless · https://tetherless.dev
"use strict";
/**
 * Stamp the Mach-O cord watermark onto decrypted IPA app icons (lower-left,
 * ~33% height — same scale as the Alpha/Orbit mockups). Used by DELvEKBot
 * before upload so Telegram thumbs + SpringBoard both show the mark.
 */

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const CORD_HEIGHT_FRAC = 340 / 1024;
const MARGIN_FRAC = 0.028;
const CORD_OPACITY = 0.94;
const MARKER_KEY = "TLCordBranded";

function watermarkPath() {
  const candidates = [
    path.join(__dirname, "assets", "MachOCordWatermark.png"),
    path.join(__dirname, "..", "Assets.xcassets", "MachOCordWatermark.imageset", "MachOCordWatermark.png"),
  ];
  for (const p of candidates) {
    if (fs.existsSync(p) && fs.statSync(p).size > 100) return p;
  }
  return "";
}

/**
 * Brand icons inside an IPA on disk. Idempotent via Info.plist TLCordBranded.
 * Returns { ok, branded, iconPath, error }.
 */
async function brandIpa(ipaPath, { force = false } = {}) {
  const ipa = path.resolve(String(ipaPath || ""));
  if (!ipa || !fs.existsSync(ipa)) {
    return { ok: false, branded: 0, iconPath: "", error: "IPA missing" };
  }
  const wm = watermarkPath();
  if (!wm) {
    return { ok: false, branded: 0, iconPath: "", error: "MachOCordWatermark.png missing" };
  }

  let sharp;
  try {
    sharp = require("sharp");
  } catch (e) {
    return { ok: false, branded: 0, iconPath: "", error: "sharp not installed" };
  }

  const work = fs.mkdtempSync(path.join(os.tmpdir(), "cord-brand-"));
  const extract = path.join(work, "extract");
  fs.mkdirSync(extract, { recursive: true });
  try {
    const unzip = spawnSync("unzip", ["-q", "-o", ipa, "-d", extract], {
      encoding: "utf8",
      maxBuffer: 8 * 1024 * 1024,
      timeout: 120000,
    });
    if (unzip.status !== 0) {
      return {
        ok: false,
        branded: 0,
        iconPath: "",
        error: `unzip failed: ${(unzip.stderr || unzip.error || "").toString().slice(0, 200)}`,
      };
    }

    const payload = path.join(extract, "Payload");
    if (!fs.existsSync(payload)) {
      return { ok: false, branded: 0, iconPath: "", error: "No Payload/" };
    }
    const apps = fs
      .readdirSync(payload)
      .map((n) => path.join(payload, n))
      .filter((p) => p.endsWith(".app") && fs.statSync(p).isDirectory());
    if (!apps.length) {
      return { ok: false, branded: 0, iconPath: "", error: "No Payload/*.app" };
    }

    let total = 0;
    let previewIcon = "";
    for (const app of apps) {
      const r = await brandAppDir(app, wm, sharp, { force });
      total += r.branded;
      if (!previewIcon && r.iconPath) previewIcon = r.iconPath;
    }

    if (total === 0) {
      return { ok: true, branded: 0, iconPath: previewIcon, error: "" };
    }

    // Re-zip Payload → replace IPA atomically.
    const outIpa = path.join(work, "branded.ipa");
    const zip = spawnSync("zip", ["-qr", outIpa, "Payload"], {
      cwd: extract,
      encoding: "utf8",
      maxBuffer: 8 * 1024 * 1024,
      timeout: 180000,
    });
    if (zip.status !== 0 || !fs.existsSync(outIpa)) {
      return {
        ok: false,
        branded: total,
        iconPath: previewIcon,
        error: `zip failed: ${(zip.stderr || zip.error || "").toString().slice(0, 200)}`,
      };
    }
    fs.copyFileSync(outIpa, ipa);
    return { ok: true, branded: total, iconPath: previewIcon, error: "" };
  } catch (e) {
    return { ok: false, branded: 0, iconPath: "", error: String((e && e.message) || e).slice(0, 300) };
  } finally {
    try {
      fs.rmSync(work, { recursive: true, force: true });
    } catch {
      /* ignore */
    }
  }
}

async function brandAppDir(appDir, wmPath, sharp, { force }) {
  const infoURL = path.join(appDir, "Info.plist");
  let already = false;
  if (fs.existsSync(infoURL)) {
    const raw = fs.readFileSync(infoURL);
    if (!force && raw.includes(Buffer.from(MARKER_KEY))) {
      // Still refresh preview icon path if present.
      const existing = ["AppIcon60x60@3x.png", "AppIcon.png", "iTunesArtwork@2x"].find((n) =>
        fs.existsSync(path.join(appDir, n))
      );
      return {
        branded: 0,
        iconPath: existing ? path.join(appDir, existing) : "",
      };
    }
    already = raw.includes(Buffer.from(MARKER_KEY));
  }

  const source = await loadBestIconBuffer(appDir, sharp);
  if (!source) return { branded: 0, iconPath: "" };

  const wmMeta = await sharp(wmPath).ensureAlpha().metadata();
  const wmW = wmMeta.width || 1;
  const wmH = wmMeta.height || 1;

  async function compositeAt(side) {
    const cordH = Math.max(8, Math.round(side * CORD_HEIGHT_FRAC));
    const cordW = Math.max(8, Math.round((cordH * wmW) / wmH));
    const margin = Math.max(2, Math.round(side * MARGIN_FRAC));
    const left = margin;
    const top = side - cordH - margin;

    const base = await sharp(source)
      .resize(side, side, { fit: "cover", position: "centre" })
      .ensureAlpha()
      .png()
      .toBuffer();

    // Resize cord and scale alpha toward CORD_OPACITY.
    const cord = await sharp(wmPath)
      .resize(cordW, cordH, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
      .ensureAlpha()
      .linear([1, 1, 1, CORD_OPACITY], [0, 0, 0, 0])
      .png()
      .toBuffer();

    return sharp(base)
      .composite([{ input: cord, left, top, blend: "over" }])
      .png()
      .toBuffer();
  }

  let branded = 0;
  // Overwrite existing icon-ish PNGs at native size.
  for (const name of fs.readdirSync(appDir)) {
    if (!/\.png$/i.test(name)) continue;
    if (!looksLikeIcon(name)) continue;
    const fp = path.join(appDir, name);
    try {
      const meta = await sharp(fp).metadata();
      const side = Math.max(meta.width || 0, meta.height || 0) || 1024;
      const buf = await compositeAt(side);
      fs.writeFileSync(fp, buf);
      branded += 1;
    } catch {
      /* skip broken png */
    }
  }

  const flats = [
    ["AppIcon.png", 1024],
    ["AppIcon60x60@2x.png", 120],
    ["AppIcon60x60@3x.png", 180],
    ["AppIcon76x76@2x~ipad.png", 152],
    ["iTunesArtwork@2x", 1024],
    ["iTunesArtwork", 512],
  ];
  let preview = "";
  for (const [name, side] of flats) {
    try {
      const buf = await compositeAt(side);
      const fp = path.join(appDir, name);
      fs.writeFileSync(fp, buf);
      branded += 1;
      if (!preview) preview = fp;
    } catch {
      /* skip */
    }
  }

  pointInfoPlistAtFlatIcons(infoURL);
  return { branded: already ? branded : branded, iconPath: preview };
}

function looksLikeIcon(name) {
  const lower = name.toLowerCase();
  return (
    lower.includes("appicon") ||
    lower.startsWith("icon") ||
    lower.includes("itunesartwork") ||
    lower.includes("60x60") ||
    lower.includes("76x76") ||
    lower.includes("83.5x83.5")
  );
}

async function loadBestIconBuffer(appDir, sharp) {
  const names = fs.readdirSync(appDir);
  const prefer = [
    "AppIcon60x60@3x.png",
    "AppIcon60x60@2x.png",
    "AppIcon76x76@2x~ipad.png",
    "AppIcon.png",
    "iTunesArtwork@2x",
    "iTunesArtwork",
  ];
  for (const n of prefer) {
    const fp = path.join(appDir, n);
    if (fs.existsSync(fp)) {
      try {
        return await sharp(fp).ensureAlpha().png().toBuffer();
      } catch {
        /* try next */
      }
    }
  }
  const iconish = names
    .filter((n) => /\.png$/i.test(n) && looksLikeIcon(n))
    .map((n) => path.join(appDir, n))
    .sort((a, b) => fs.statSync(b).size - fs.statSync(a).size);
  for (const fp of iconish) {
    try {
      return await sharp(fp).ensureAlpha().png().toBuffer();
    } catch {
      /* try next */
    }
  }
  return null;
}

function pointInfoPlistAtFlatIcons(infoURL) {
  if (!fs.existsSync(infoURL)) return;
  // Prefer plutil on macOS; fall back to a light XML rewrite.
  const tmpJson = infoURL + ".cord.json";
  const toJson = spawnSync("plutil", ["-convert", "json", "-o", tmpJson, infoURL], {
    encoding: "utf8",
  });
  if (toJson.status === 0 && fs.existsSync(tmpJson)) {
    try {
      const dict = JSON.parse(fs.readFileSync(tmpJson, "utf8"));
      dict.CFBundleIconFile = "AppIcon";
      dict.CFBundleIcons = {
        CFBundlePrimaryIcon: {
          CFBundleIconFiles: ["AppIcon60x60"],
        },
      };
      // Critical: do NOT set CFBundleIconName — that forces Assets.car and hides flat PNGs.
      if (dict.CFBundleIcons && dict.CFBundleIcons.CFBundlePrimaryIcon) {
        delete dict.CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName;
      }
      dict[MARKER_KEY] = true;
      fs.writeFileSync(tmpJson, JSON.stringify(dict));
      spawnSync("plutil", ["-convert", "binary1", "-o", infoURL, tmpJson], { encoding: "utf8" });
    } catch {
      /* fall through */
    }
    try {
      fs.unlinkSync(tmpJson);
    } catch {
      /* ignore */
    }
    return;
  }

  // XML plist fallback (no plutil): strip IconName + inject marker + flat files.
  try {
    let xml = fs.readFileSync(infoURL, "utf8");
    if (!xml.includes("<?xml")) return;
    xml = xml.replace(
      /<key>CFBundleIconName<\/key>\s*<string>[^<]*<\/string>/g,
      ""
    );
    if (!xml.includes(MARKER_KEY)) {
      xml = xml.replace(
        "</dict>\n</plist>",
        `  <key>${MARKER_KEY}</key>\n  <true/>\n</dict>\n</plist>`
      );
    }
    if (!xml.includes("CFBundleIconFiles")) {
      xml = xml.replace(
        "</dict>\n</plist>",
        `  <key>CFBundleIconFile</key>\n  <string>AppIcon</string>\n  <key>CFBundleIcons</key>\n  <dict>\n    <key>CFBundlePrimaryIcon</key>\n    <dict>\n      <key>CFBundleIconFiles</key>\n      <array>\n        <string>AppIcon60x60</string>\n      </array>\n    </dict>\n  </dict>\n</dict>\n</plist>`
      );
    }
    fs.writeFileSync(infoURL, xml);
  } catch {
    /* ignore */
  }
}

/** Brand a loose icon image file (Telegram thumb / cache .icon.png). */
async function brandIconFile(iconPath, destPath) {
  const src = path.resolve(String(iconPath || ""));
  const dest = path.resolve(String(destPath || iconPath || ""));
  const wm = watermarkPath();
  if (!src || !dest || !wm || !fs.existsSync(src) || !fs.existsSync(wm)) return "";
  let sharp;
  try {
    sharp = require("sharp");
  } catch {
    return "";
  }
  try {
    const meta = await sharp(src).metadata();
    const side = Math.max(meta.width || 0, meta.height || 0, 180);
    const cordH = Math.max(8, Math.round(side * CORD_HEIGHT_FRAC));
    const wmMeta = await sharp(wm).metadata();
    const cordW = Math.max(8, Math.round((cordH * (wmMeta.width || 1)) / (wmMeta.height || 1)));
    const margin = Math.max(2, Math.round(side * MARGIN_FRAC));
    const cord = await sharp(wm)
      .resize(cordW, cordH, { fit: "contain", background: { r: 0, g: 0, b: 0, alpha: 0 } })
      .ensureAlpha()
      .png()
      .toBuffer();
    const base = await sharp(src)
      .resize(side, side, { fit: "cover", position: "centre" })
      .ensureAlpha()
      .png()
      .toBuffer();
    await sharp(base)
      .composite([{ input: cord, left: margin, top: side - cordH - margin, blend: "over" }])
      .png()
      .toFile(dest);
    return dest;
  } catch {
    return "";
  }
}

module.exports = {
  brandIpa,
  brandIconFile,
  watermarkPath,
  MARKER_KEY,
};
