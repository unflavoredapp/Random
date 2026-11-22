#!/usr/bin/env node
// Brand: FastDecrypt · https://fastdecrypt.bot
"use strict";
/**
 * Discord decrypt bot — FastDecrypt.
 *
 * Env (Mac ~/.tetherless-mac.env only — never commit the token):
 *   DISCORD_BOT_TOKEN=...
 *   DISCORD_BOT_NAME=FastDecrypt   (display hint)
 *
 * Discord Developer Portal:
 *   - Rename app to FastDecrypt
 *   - Bot → Privileged Gateway Intents → enable MESSAGE CONTENT INTENT
 *     (optional: set DISCORD_MESSAGE_CONTENT=1 after enabling — paste-URL decrypt)
 *   - Without that intent the bot still starts; use /decrypt url:…
 *   - Invite with scopes: bot, applications.commands
 *     permissions: Send Messages, Attach Files, Embed Links, Read Message History
 *
 * WebSSH: started by mac-ssh.sh start when DISCORD_BOT_TOKEN is set.
 */
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");
const fairplayBackends = require("./fairplayBackends");
const ipaCache = require("./mac-tg-ipa-cache");
const publicDl = require("./mac-tg-public-dl");
const { renderProgressBanner } = require("./mac-tg-progress-banner");
const userLog = require("./mac-tg-user-log");
const feat = require("./mac-discord-features");
const openIn = require("./mac-open-in");

const TOKEN = String(process.env.DISCORD_BOT_TOKEN || "").trim();
const BOT_NAME = String(process.env.DISCORD_BOT_NAME || "FastDecrypt").trim() || "FastDecrypt";
const SITE = String(process.env.FASTDECRYPT_SITE_URL || "https://fastdecrypt.bot").replace(/\/+$/, "");
const WORK =
  process.env.MAC_DISCORD_WORK_DIR ||
  path.join(os.tmpdir(), "fastdecrypt-discord");
/** Discord bot attachment cap is ~25 MiB without boosts. */
const DISCORD_ATTACH_MAX = Math.max(
  5,
  Number(process.env.DISCORD_UPLOAD_MAX_MB || 24)
) * 1024 * 1024;
const MAX_WORKERS = Math.max(1, Math.min(4, Number(process.env.MAC_DISCORD_WORKERS || 2) || 2));

if (!TOKEN) {
  console.error("Set DISCORD_BOT_TOKEN in ~/.tetherless-mac.env (do not commit it)");
  process.exit(1);
}

fs.mkdirSync(WORK, { recursive: true });

let Discord;
try {
  Discord = require("discord.js");
} catch {
  console.error('Install discord.js: cd ~/tetherless/server && npm install discord.js');
  process.exit(1);
}

const {
  Client,
  GatewayIntentBits,
  Partials,
  EmbedBuilder,
  AttachmentBuilder,
  ActionRowBuilder,
  ButtonBuilder,
  ButtonStyle,
  SlashCommandBuilder,
  StringSelectMenuBuilder,
  StringSelectMenuOptionBuilder,
  REST,
  Routes,
  ActivityType,
} = Discord;

// Message Content is a privileged intent — enabling it in code without flipping
// the Developer Portal switch causes: "Used disallowed intents".
const WANT_MESSAGE_CONTENT =
  String(process.env.DISCORD_MESSAGE_CONTENT || "").trim() === "1";
const intents = [
  GatewayIntentBits.Guilds,
  GatewayIntentBits.GuildMessages,
  GatewayIntentBits.DirectMessages,
];
if (WANT_MESSAGE_CONTENT) intents.push(GatewayIntentBits.MessageContent);

const client = new Client({
  intents,
  partials: [Partials.Channel],
});

let activeWorkers = 0;
const waiters = [];

function queueJob(fn, { priority = false } = {}) {
  return new Promise((resolve, reject) => {
    const job = { fn, resolve, reject };
    if (priority) waiters.unshift(job);
    else waiters.push(job);
    pump();
  });
}

function pump() {
  while (activeWorkers < MAX_WORKERS && waiters.length) {
    const job = waiters.shift();
    activeWorkers++;
    Promise.resolve()
      .then(() => job.fn())
      .then(job.resolve, job.reject)
      .finally(() => {
        activeWorkers--;
        pump();
      });
  }
}

function isStoreUrl(t) {
  return /^https:\/\/(?:apps|itunes)\.apple\.com\//i.test(String(t || "").trim());
}

/** iTunes lookup → app name + icon (same source Telegram sharp cards use). */
function lookupStoreApp(storeUrl) {
  const adam = ipaCache.adamFromStoreUrl(storeUrl);
  const out = { adam, name: "", version: "", iconPath: "", bid: "" };
  if (!adam) return out;
  try {
    const cc = ((/apps\.apple\.com\/([a-z]{2})\//i.exec(storeUrl) || [])[1] || "us").toLowerCase();
    const lookup = spawnSync(
      "curl",
      ["-fsSL", `https://itunes.apple.com/lookup?id=${adam}&country=${cc}`],
      { encoding: "utf8", maxBuffer: 2 * 1024 * 1024 }
    );
    if (lookup.status !== 0) return out;
    const j = JSON.parse(lookup.stdout || "{}");
    const r = j && j.results && j.results[0];
    if (!r) return out;
    out.name = String(r.trackName || r.trackCensoredName || "").trim();
    out.version = String(r.version || "").trim();
    out.bid = String(r.bundleId || "").trim();
    const art = r.artworkUrl512 || r.artworkUrl100;
    if (art) {
      const dest = path.join(WORK, `icon-${adam}.jpg`);
      const artUrl = String(art)
        .replace(/\/\d+x\d+bb(\.[a-z]+)?$/i, "/256x256bb$1")
        .replace("100x100", "256x256");
      const dl = spawnSync("curl", ["-fsSL", "-o", dest, artUrl], { encoding: "utf8" });
      if (dl.status === 0 && fs.existsSync(dest) && fs.statSync(dest).size > 100) {
        out.iconPath = dest;
      }
    }
  } catch {
    /* ignore */
  }
  return out;
}

const DONE_TAGLINE = "Fastest discord\nDecryption Bot";

async function renderSharpCard({ name, version, iconPath, stage, pct, done }) {
  const dest = path.join(WORK, `sharp-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.jpg`);
  try {
    const out = await renderProgressBanner({
      name: name || "App",
      version: version || "",
      stage: stage || (done ? DONE_TAGLINE : "working…"),
      logLines: [],
      pct: done ? 100 : pct || 0,
      iconPath: iconPath || "",
      dest,
      tag: "fastdecrypt",
      brand: BOT_NAME,
      done: !!done,
      hideTerminal: true,
    });
    return out && fs.existsSync(out) ? out : "";
  } catch (e) {
    console.warn("[discord] sharp banner:", (e && e.message) || e);
    return "";
  }
}

function progressEmbed(appName, stage, pct) {
  const p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
  const bits = [];
  if (stage) bits.push(stage);
  bits.push(`**${p}%**`);
  return new EmbedBuilder()
    .setColor(0xff9a1f)
    .setTitle(appName || "Decrypting…")
    .setDescription(bits.join(" · "));
}

function siteButtons(downloadUrl) {
  const rows = [];
  const row1 = new ActionRowBuilder();
  if (downloadUrl) {
    row1.addComponents(
      new ButtonBuilder()
        .setStyle(ButtonStyle.Link)
        .setLabel("Download IPA")
        .setURL(downloadUrl)
    );
  }
  row1.addComponents(
    new ButtonBuilder().setStyle(ButtonStyle.Link).setLabel("Website").setURL(SITE)
  );
  rows.push(row1);

  // Open in … as a dropdown (HTTPS bridge — Discord rejects custom schemes on Link buttons).
  if (downloadUrl) {
    const token = openIn.putOpenPending(downloadUrl);
    if (token) {
      const menu = new StringSelectMenuBuilder()
        .setCustomId(`oin:${token}`)
        .setPlaceholder("Open in…")
        .addOptions(
          openIn.TARGETS.map((t) =>
            new StringSelectMenuOptionBuilder()
              .setLabel(t.label.slice(0, 100))
              .setValue(t.id)
          )
        );
      rows.push(new ActionRowBuilder().addComponents(menu));
    }
  }
  return rows.slice(0, 5);
}

/** User-facing stage only — never raw ipatool / path / INF lines. */
function friendlyStage(pct) {
  const p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
  if (p >= 100) return DONE_TAGLINE;
  if (p >= 93) return "Finishing…";
  if (p >= 56) return "Decrypting…";
  if (p >= 10) return "Fetching IPA…";
  if (p >= 5) return "Looking up…";
  return "Starting…";
}

function friendlyError(err) {
  const raw = String((err && err.message) || err || "").trim();
  if (/BASE_TYPE_REQUIRED|Invalid Form Body|components\[/i.test(raw)) {
    return "Couldn’t send the download buttons — retry /decrypt.";
  }
  if (/login missing|keychain|ipatool auth/i.test(raw)) {
    return "App Store login needed on the Mac — run: zsh ~/tetherless/server/mac-ssh.sh login";
  }
  if (/over Discord|attach cap|mac-ssh\.sh api/i.test(raw)) {
    return "IPA too large for Discord attach — start the Mac API tunnel, then retry.";
  }
  // Strip paths, INF logs, temp dirs.
  let s = raw
    .replace(/\/(?:var|Users|tmp|private)\/[^\s]+/gi, "")
    .replace(/\b\d{1,2}:\d{2}(?:AM|PM)?\s+INF\b[^\n]*/gi, "")
    .replace(/\boutput=\S+/gi, "")
    .replace(/\s{2,}/g, " ")
    .trim();
  if (!s || s.length < 3) return "Decrypt failed — try again.";
  return s.slice(0, 180);
}

function statusEmbed() {
  const st =
    (fairplayBackends.backendStatus && fairplayBackends.backendStatus()) || {};
  const decryptReady = !!(st.unfairplay && st.unfairplay.ready);
  const modelReady = !!(st.enrollmentModel && st.enrollmentModel.ready);
  return new EmbedBuilder()
    .setColor(0xff9a1f)
    .setTitle(BOT_NAME)
    .setDescription(
      [
        decryptReady ? "Decrypt ready" : "Decrypt not ready",
        modelReady ? "Model ready" : "Model not ready",
        `Workers ${activeWorkers}/${MAX_WORKERS}` +
          (waiters.length ? ` · ${waiters.length} queued` : ""),
        SITE,
      ].join("\n")
    );
}

function helpEmbed(userId) {
  const q = feat.quotaStatus(userId);
  return new EmbedBuilder()
    .setColor(0xff9a1f)
    .setTitle(BOT_NAME)
    .setDescription(
      [
        `Decrypt App Store IPAs.`,
        ``,
        `• \`/decrypt url:<link>\` or \`name:Vinted\``,
        `• \`/search query:<app name>\` — pick from results`,
        `• \`/vip\` — status & upgrade`,
        `• \`/status\``,
        WANT_MESSAGE_CONTENT ? `• Or paste a link / type an app name` : "",
        ``,
        feat.quotaLabel(q),
        SITE,
      ]
        .filter(Boolean)
        .join("\n")
    );
}

/** Telegram-style result: sharp card image + app name title (no URL dump). */
async function buildDeliveryPayload(
  result,
  { storeUrl, name, iconPath, version: verHint, cached = false }
) {
  const file = result && result.file;
  if (!file || !fs.existsSync(file)) throw new Error("Decrypt produced no IPA");
  const st = fs.statSync(file);
  const meta = result.meta || {};
  const appName = name || meta.name || meta.title || "App";
  const version = verHint || meta.version || meta.bundleVersion || "";
  const bid = meta.bid || meta.bundleId || "";
  const fileName = `${String(appName).replace(/[^\w.\- +]+/g, "_")}${
    version ? `_v${version}` : ""
  }-[FastDecrypt.Bot].ipa`;
  const mb = (st.size / 1024 / 1024).toFixed(1);

  try {
    const adam = ipaCache.adamFromStoreUrl(storeUrl) || "";
    if (adam) {
      ipaCache.put({
        adam,
        version: version || "",
        bid,
        name: appName,
        storeUrl: storeUrl || "",
        fileName,
        bytes: st.size,
        diskPath: file,
      });
    }
  } catch (e) {
    console.warn("[discord] cache put:", (e && e.message) || e);
  }

  const doneStage = cached ? `instant · cached\n${DONE_TAGLINE}` : DONE_TAGLINE;
  const bannerPath = await renderSharpCard({
    name: appName,
    version,
    iconPath,
    stage: doneStage,
    pct: 100,
    done: true,
  });

  const files = [];
  const embed = new EmbedBuilder()
    .setColor(cached ? 0x2fd16b : 0xff9a1f)
    .setTitle(appName);

  const lines = [];
  if (cached) lines.push("instant · cached");
  if (version) lines.push(`v${version}`);
  lines.push(`${mb} MB`);
  if (bid) lines.push(bid);
  embed.setDescription(lines.join(" · "));

  if (bannerPath) {
    files.push(new AttachmentBuilder(bannerPath, { name: "sharp.jpg" }));
    embed.setImage("attachment://sharp.jpg");
  } else if (iconPath && fs.existsSync(iconPath)) {
    files.push(new AttachmentBuilder(iconPath, { name: "icon.jpg" }));
    embed.setThumbnail("attachment://icon.jpg");
  }

  let mode = "attach";
  let downloadUrl = "";

  // Always stage a public HTTPS URL when possible — Open-in installers need it.
  try {
    const staged = publicDl.stageIpa(file, { fileName, bytes: st.size });
    downloadUrl = publicDl.downloadUrlFor(staged.token) || "";
  } catch (e) {
    console.warn("[discord] stage for open-in:", (e && e.message) || e);
  }

  if (st.size <= DISCORD_ATTACH_MAX) {
    files.push(new AttachmentBuilder(file, { name: fileName }));
  } else {
    if (!downloadUrl) {
      throw new Error(
        `IPA is ${mb} MB (over Discord’s ~25 MB attach cap). Run: zsh ~/tetherless/server/mac-ssh.sh api`
      );
    }
    mode = "link";
  }
  if (downloadUrl) {
    embed.setFooter({
      text: `Link expires in ~${Math.round(publicDl.TTL_MS / 60000)} min · Open in TrollStore / Feather / E-Sign…`,
    });
  }

  return {
    ok: true,
    mode,
    content: null,
    embeds: [embed],
    files,
    components: siteButtons(downloadUrl),
  };
}

async function sayProgress(progressMsg, appName, pct, { iconPath, version } = {}) {
  if (!progressMsg) return;
  const p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
  const stage = friendlyStage(p);
  const bannerPath = await renderSharpCard({
    name: appName,
    version: version || "",
    iconPath: iconPath || "",
    stage,
    pct: p,
    done: false,
  });
  // Embed title = app name only; % lives on the sharp card (no backend text).
  const embed = new EmbedBuilder().setColor(0xff9a1f).setTitle(appName || "Decrypting…");
  const files = [];
  if (bannerPath) {
    files.push(new AttachmentBuilder(bannerPath, { name: "sharp.jpg" }));
    embed.setImage("attachment://sharp.jpg");
  } else {
    embed.setDescription(`**${p}%** · ${stage}`);
  }
  await progressMsg
    .edit({
      content: null,
      embeds: [embed],
      files,
      components: [],
    })
    .catch(() => {});
}

/**
 * Smooth % buffer: display eases +1–2 at a time toward the real target, and
 * slowly creeps ahead while the Mac is still working so the bar never feels stuck.
 * By the time the number reaches a milestone, that work is usually already done.
 */
function createPctBuffer({ paint, intervalMs = 500 }) {
  let target = 0;
  let display = 0;
  let ceiling = 8;
  let timer = null;
  let painting = false;
  let lastPainted = -1;
  let stopped = false;

  const paintSafe = async (p) => {
    if (painting || stopped) return;
    if (p === lastPainted) return;
    painting = true;
    lastPainted = p;
    try {
      await paint(p);
    } catch {
      /* ignore Discord edit races */
    } finally {
      painting = false;
    }
  };

  const tick = () => {
    if (stopped) return;
    // Ease toward known target; if caught up, creep toward ceiling (anticipates next chunk).
    let aim = target;
    if (display >= target && display < ceiling) aim = Math.min(ceiling, display + 1);
    if (display < aim) {
      const gap = aim - display;
      display = Math.min(aim, display + (gap >= 10 ? 2 : 1));
    }
    display = Math.max(0, Math.min(100, display));
    paintSafe(display).catch(() => {});
  };

  const ensureTimer = () => {
    if (stopped || timer) return;
    timer = setInterval(tick, intervalMs);
  };

  return {
    /** Raise the real progress floor and optional phase ceiling (fetch≤55, decrypt≤92…). */
    setTarget(pct, phaseCeil) {
      if (stopped) return;
      const p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
      target = Math.max(target, p);
      if (phaseCeil != null) {
        ceiling = Math.max(ceiling, Math.min(99, Math.round(Number(phaseCeil) || ceiling)));
      }
      // Never let ceiling fall behind target.
      ceiling = Math.max(ceiling, Math.min(99, target));
      ensureTimer();
      tick();
    },
    async flush(to = 100) {
      if (stopped) return;
      target = Math.max(target, to);
      ceiling = Math.max(ceiling, to);
      while (display < to && !stopped) {
        display = Math.min(to, display + 3);
        await paintSafe(display);
        await new Promise((r) => setTimeout(r, 180));
      }
      this.stop();
    },
    stop() {
      stopped = true;
      if (timer) clearInterval(timer);
      timer = null;
    },
    get display() {
      return display;
    },
  };
}

async function decryptStoreUrl(link, progressMsg, { vreq = "" } = {}) {
  if (typeof fairplayBackends.unlockKeychain === "function") {
    fairplayBackends.unlockKeychain();
  }
  if (typeof fairplayBackends.preflightDecrypt === "function") {
    const pre = fairplayBackends.preflightDecrypt({});
    if (!pre.ok) throw new Error(pre.error);
  }

  const lookup = lookupStoreApp(link);
  const appName = lookup.name || "App";
  const verHint = String(vreq || "").trim();
  const ver = verHint || lookup.version || "";
  const iconPath = lookup.iconPath || "";

  const buf = createPctBuffer({
    paint: (p) => sayProgress(progressMsg, appName, p, { iconPath, version: lookup.version || ver }),
    intervalMs: 500,
  });

  try {
    buf.setTarget(3, 10);

    const entry = ipaCache.getByStoreUrl(link, verHint);
    if (entry && entry.diskPath && fs.existsSync(entry.diskPath)) {
      buf.setTarget(70, 95);
      await buf.flush(100);
      return buildDeliveryPayload(
        {
          file: entry.diskPath,
          meta: {
            name: entry.name || appName,
            version: entry.version || ver,
            bid: entry.bid || lookup.bid,
          },
        },
        {
          storeUrl: link,
          name: entry.name || appName,
          iconPath,
          version: entry.version || ver,
          cached: true,
        }
      );
    }

    const dir = fs.mkdtempSync(path.join(WORK, "job-"));
    buf.setTarget(10, 55);
    await fairplayBackends.ensureEncryptedSource({
      url: link,
      dir,
      say: (t) => console.log("[discord]", String(t || "").slice(0, 160)),
      onProgress: (pct) => {
        const mapped = Math.max(12, Math.min(55, Math.round(Number(pct) || 12)));
        buf.setTarget(mapped, 55);
      },
      vreq: verHint,
    });
    buf.setTarget(55, 55);

    buf.setTarget(58, 92);
    const result = await fairplayBackends.tryRemoteBackends({
      url: link,
      dir,
      say: (t) => console.log("[discord]", String(t || "").slice(0, 160)),
      onProgress: (pct) => {
        const mapped = Math.max(60, Math.min(92, Math.round(Number(pct) || 60)));
        buf.setTarget(mapped, 92);
      },
      vreq: verHint,
    });
    buf.setTarget(92, 97);
    await buf.flush(100);

    const meta = (result && result.meta) || {};
    return buildDeliveryPayload(result, {
      storeUrl: link,
      name: meta.name || meta.title || appName,
      iconPath,
      version: meta.version || meta.bundleVersion || ver,
      cached: false,
    });
  } catch (e) {
    buf.stop();
    throw e;
  }
}

function embedTitle(payload) {
  try {
    const e0 = payload && payload.embeds && payload.embeds[0];
    if (!e0) return "ok";
    if (e0.data && e0.data.title) return e0.data.title;
    if (e0.title) return e0.title;
  } catch {
    /* ignore */
  }
  return "ok";
}

/** Run decrypt after quota check; VIP gets priority queue. */
async function runDecryptJob(userId, link, progressMsg, { vreq = "" } = {}) {
  const gate = feat.consumeQuota(userId);
  if (!gate.ok) throw new Error(gate.error);
  const priority = feat.isVip(userId);
  return queueJob(() => decryptStoreUrl(link, progressMsg, { vreq }), { priority });
}

async function offerVersionPicker(interactionOrMsg, link, userId, { reply }) {
  const listed = await feat.listVersionsForUrl(link);
  const vip = feat.isVip(userId);
  const choices = feat.versionChoices(listed, { vip, max: 20 });
  const title = String((listed && listed.title) || "App").slice(0, 80) || "App";

  if (!choices.length) {
    return { mode: "decrypt", link, vreq: "" };
  }
  if (choices.length === 1 && !vip) {
    return { mode: "decrypt", link, vreq: choices[0].vreq || "" };
  }

  const token = feat.putPending({
    type: "version",
    userId: String(userId),
    link,
    items: choices,
  });
  const menu = new StringSelectMenuBuilder()
    .setCustomId(`ver:${token}`)
    .setPlaceholder(vip ? "Pick a version…" : "Latest only (VIP unlocks history)")
    .addOptions(
      choices.slice(0, 25).map(
        (c, i) =>
          new StringSelectMenuOptionBuilder()
            .setLabel(c.label.slice(0, 100))
            .setValue(String(i))
            .setDescription(
              (c.current ? "Current App Store build" : c.ext ? `id ${c.ext}` : "Build").slice(
                0,
                100
              )
            )
      )
    );
  const row = new ActionRowBuilder().addComponents(menu);
  const embed = new EmbedBuilder()
    .setColor(0xff9a1f)
    .setTitle(title)
    .setDescription(
      vip
        ? "Choose a version to decrypt."
        : `Latest only on free tier. Older builds → VIP · ${feat.VIP_URL}`
    );
  await reply({ embeds: [embed], components: [row] });
  return { mode: "picker" };
}

function appPickComponents(token, items) {
  const rows = [];
  let row = new ActionRowBuilder();
  items.slice(0, 8).forEach((it, i) => {
    if (row.components.length >= 5) {
      rows.push(row);
      row = new ActionRowBuilder();
    }
    row.addComponents(
      new ButtonBuilder()
        .setCustomId(`app:${token}:${i}`)
        .setStyle(ButtonStyle.Secondary)
        .setLabel(`${i + 1}. ${it.name}`.slice(0, 80))
    );
  });
  if (row.components.length) rows.push(row);
  return rows;
}

async function offerAppSearch(reply, userId, query) {
  const items = feat.searchAppsByName(query, { limit: 8 });
  if (!items.length) {
    await reply({
      embeds: [
        new EmbedBuilder()
          .setColor(0xff9a1f)
          .setTitle("No apps found")
          .setDescription(`Nothing matched **${query.slice(0, 60)}**. Try another name.`),
      ],
      components: [],
    });
    return;
  }
  const token = feat.putPending({
    type: "app",
    userId: String(userId),
    items,
  });
  const lines = items
    .map((it, i) => {
      const ver = it.version ? ` · v${it.version}` : "";
      return `**${i + 1}.** ${it.name}${ver}`;
    })
    .join("\n");
  await reply({
    embeds: [
      new EmbedBuilder()
        .setColor(0xff9a1f)
        .setTitle(`Search: ${query.slice(0, 40)}`)
        .setDescription(lines),
    ],
    components: appPickComponents(token, items),
  });
}

async function runDecryptFor(channel, link, notifier, { userId, vreq = "" } = {}) {
  const progressMsg = await notifier({
    embeds: [progressEmbed("Decrypting…", "Starting…", 0)],
  });
  try {
    const payload = await runDecryptJob(userId, link, progressMsg, { vreq });
    await progressMsg
      .edit({
        content: null,
        embeds: payload.embeds,
        files: payload.files,
        components: payload.components || [],
      })
      .catch(async () => {
        await channel.send({
          embeds: payload.embeds,
          files: payload.files,
          components: payload.components || [],
        });
      });
  } catch (e) {
    await progressMsg
      .edit({
        content: null,
        embeds: [progressEmbed("Failed", friendlyError(e), 0)],
        components: [],
      })
      .catch(() => {});
  }
}

async function registerCommands(appId) {
  const cmds = [
    new SlashCommandBuilder()
      .setName("start")
      .setDescription("Help / what FastDecrypt does"),
    new SlashCommandBuilder()
      .setName("status")
      .setDescription("Mac decrypt status"),
    new SlashCommandBuilder()
      .setName("vip")
      .setDescription("VIP status and upgrade link"),
    new SlashCommandBuilder()
      .setName("search")
      .setDescription("Search App Store by name")
      .addStringOption((o) =>
        o.setName("query").setDescription("App name e.g. Vinted").setRequired(true)
      ),
    new SlashCommandBuilder()
      .setName("decrypt")
      .setDescription("Decrypt an App Store IPA")
      .addStringOption((o) =>
        o.setName("url").setDescription("App Store link").setRequired(false)
      )
      .addStringOption((o) =>
        o.setName("name").setDescription("App name e.g. Vinted").setRequired(false)
      )
      .addStringOption((o) =>
        o
          .setName("version")
          .setDescription("Version (VIP for older builds)")
          .setRequired(false)
      ),
    new SlashCommandBuilder()
      .setName("users")
      .setDescription("Admin: Discord usage (last 24h)"),
    new SlashCommandBuilder()
      .setName("grantvip")
      .setDescription("Admin: grant timed VIP")
      .addIntegerOption((o) =>
        o
          .setName("days")
          .setDescription("VIP length")
          .setRequired(true)
          .addChoices(
            { name: "7 days", value: 7 },
            { name: "30 days", value: 30 },
            { name: "90 days", value: 90 },
            { name: "180 days", value: 180 },
            { name: "365 days", value: 365 }
          )
      )
      .addUserOption((o) =>
        o.setName("user").setDescription("Discord member").setRequired(false)
      )
      .addStringOption((o) =>
        o
          .setName("user_id")
          .setDescription("Discord user id (if not in this server)")
          .setRequired(false)
      ),
    new SlashCommandBuilder()
      .setName("revokevip")
      .setDescription("Admin: revoke timed VIP")
      .addUserOption((o) =>
        o.setName("user").setDescription("Discord member").setRequired(false)
      )
      .addStringOption((o) =>
        o
          .setName("user_id")
          .setDescription("Discord user id")
          .setRequired(false)
      ),
  ].map((c) => c.toJSON());

  const rest = new REST({ version: "10" }).setToken(TOKEN);
  await rest.put(Routes.applicationCommands(appId), { body: cmds });
  console.log("[discord] slash commands registered");
}

client.once("ready", async () => {
  console.log(
    `[discord] logged in as ${client.user.tag} · brand=${BOT_NAME} · workers=${MAX_WORKERS}`
  );
  try {
    await client.user.setActivity("App Store decrypts", { type: ActivityType.Watching });
  } catch {
    /* ignore */
  }
  try {
    await registerCommands(client.user.id);
  } catch (e) {
    console.warn("[discord] command register failed:", (e && e.message) || e);
  }
  try {
    userLog.pruneOldEvents();
    const n = userLog.listUsers().filter((u) => u.platform === "discord" || String(u.userId || "").startsWith("discord:")).length;
    console.log(`[discord] user usage log: ${userLog.LOG_DIR} (${n} discord users)`);
  } catch {
    /* ignore */
  }
  const st = fairplayBackends.backendStatus();
  console.log(
    `[discord] decrypt=${!!(st.unfairplay && st.unfairplay.ready)} model=${!!(
      st.enrollmentModel && st.enrollmentModel.ready
    )} public=${publicDl.resolvePublicBase() || "unset"} messageContent=${WANT_MESSAGE_CONTENT ? "on" : "off"}`
  );
});

async function startDecryptReply(interaction, link, vreq) {
  const progressMsg = {
    edit: (payload) => interaction.editReply(payload),
  };
  try {
    const payload = await runDecryptJob(interaction.user.id, link, progressMsg, {
      vreq: vreq || "",
    });
    userLog.logDiscord({
      interaction,
      kind: "decrypt_ok",
      detail: String(embedTitle(payload)).slice(0, 80),
    });
    await interaction.editReply({
      content: null,
      embeds: payload.embeds,
      files: payload.files,
      components: payload.components || [],
    });
  } catch (e) {
    userLog.logDiscord({
      interaction,
      kind: "decrypt_fail",
      detail: friendlyError(e).slice(0, 120),
    });
    await interaction.editReply({
      content: null,
      embeds: [progressEmbed("Failed", friendlyError(e), 0)],
      components: [],
    });
  }
}

client.on("interactionCreate", async (interaction) => {
  try {
    // ── App pick buttons ──────────────────────────────────────────
    if (interaction.isButton()) {
      const m = String(interaction.customId || "").match(/^app:([a-f0-9]+):(\d+)$/i);
      if (!m) return;
      const pending = feat.getPending(m[1]);
      if (!pending || pending.type !== "app") {
        await interaction.reply({ content: "That search expired — run /search again.", ephemeral: true });
        return;
      }
      if (String(pending.userId) !== String(interaction.user.id)) {
        await interaction.reply({ content: "That’s someone else’s search.", ephemeral: true });
        return;
      }
      const item = pending.items[Number(m[2])];
      if (!item || !item.url) {
        await interaction.reply({ content: "Invalid pick.", ephemeral: true });
        return;
      }
      feat.takePending(m[1]);
      userLog.logDiscord({
        interaction,
        kind: "app_pick",
        detail: String(item.name || item.url).slice(0, 80),
      });
      await interaction.deferUpdate();
      const pick = await offerVersionPicker(interaction, item.url, interaction.user.id, {
        reply: (p) => interaction.editReply(p),
      });
      if (pick.mode === "decrypt") {
        await interaction.editReply({
          content: null,
          embeds: [progressEmbed(item.name || "Decrypting…", "Starting…", 0)],
          components: [],
        });
        await startDecryptReply(interaction, pick.link, pick.vreq);
      }
      return;
    }

    // ── Selects (Open-in + version) ───────────────────────────────
    if (interaction.isStringSelectMenu()) {
      const oin = String(interaction.customId || "").match(/^oin:([a-f0-9]+)$/i);
      if (oin) {
        const ipa = openIn.getOpenPending(oin[1]);
        if (!ipa) {
          await interaction.reply({
            content: "That Open-in menu expired — decrypt again.",
            ephemeral: true,
          });
          return;
        }
        const id = String(interaction.values[0] || "");
        const t = openIn.targetById(id);
        const url = openIn.redirectUrl(id, ipa) || openIn.deepLink(id, ipa);
        if (!t || !url || !/^https:\/\//i.test(url)) {
          await interaction.reply({
            content: "Couldn’t build that Open-in link.",
            ephemeral: true,
          });
          return;
        }
        await interaction.reply({
          content: `Open **${t.label}** on your iPhone:`,
          ephemeral: true,
          components: [
            new ActionRowBuilder().addComponents(
              new ButtonBuilder()
                .setStyle(ButtonStyle.Link)
                .setLabel(`Open ${t.label}`.slice(0, 80))
                .setURL(url)
            ),
          ],
        });
        return;
      }

      const m = String(interaction.customId || "").match(/^ver:([a-f0-9]+)$/i);
      if (!m) return;
      const pending = feat.takePending(m[1]);
      if (!pending || pending.type !== "version") {
        await interaction.reply({ content: "That version list expired — decrypt again.", ephemeral: true });
        return;
      }
      if (String(pending.userId) !== String(interaction.user.id)) {
        await interaction.reply({ content: "That’s someone else’s picker.", ephemeral: true });
        return;
      }
      const idx = Number(interaction.values[0]);
      const choice = pending.items[idx];
      if (!choice) {
        await interaction.reply({ content: "Invalid version.", ephemeral: true });
        return;
      }
      if (!feat.isVip(interaction.user.id) && !choice.current && idx > 0) {
        await interaction.reply({
          content: `Older versions need VIP · ${feat.VIP_URL}`,
          ephemeral: true,
        });
        return;
      }
      userLog.logDiscord({
        interaction,
        kind: "ver_pick",
        detail: String(choice.label || choice.vreq).slice(0, 80),
      });
      await interaction.deferUpdate();
      await interaction.editReply({
        content: null,
        embeds: [progressEmbed("Decrypting…", "Starting…", 0)],
        components: [],
      });
      await startDecryptReply(interaction, pending.link, choice.vreq || "");
      return;
    }

    if (!interaction.isChatInputCommand()) return;
    const name = interaction.commandName;
    userLog.logDiscord({
      interaction,
      kind: "cmd",
      detail: `/${name}`,
    });

    if (name === "start") {
      await interaction.reply({ embeds: [helpEmbed(interaction.user.id)] });
      return;
    }
    if (name === "status") {
      const q = feat.quotaStatus(interaction.user.id);
      const base = statusEmbed();
      const prev =
        (base.data && base.data.description) ||
        "FastDecrypt status";
      await interaction.reply({
        embeds: [
          base.setDescription(`${prev}\n**Tier:** ${feat.quotaLabel(q)}`),
        ],
      });
      return;
    }
    if (name === "vip") {
      const q = feat.quotaStatus(interaction.user.id);
      const lines = q.vip
        ? [
            "You have **VIP**.",
            q.permanent
              ? "Expires: **lifetime**"
              : `Time left: **${q.left}**` +
                (q.expiresIso ? `\nEnds: <t:${Math.floor(q.expiresAt / 1000)}:f>` : ""),
            "Unlimited decrypts · older versions · priority queue.",
          ]
        : [
            "You’re on the **free** tier.",
            `Decrypts today: **${q.remaining}/${q.limit}**`,
            `Ask an admin for VIP (7 / 30 / 90 / 180 days), or:\n${feat.VIP_URL}`,
          ];
      await interaction.reply({
        embeds: [
          new EmbedBuilder()
            .setColor(0xff9a1f)
            .setTitle("VIP")
            .setDescription(lines.join("\n")),
        ],
        components: [
          new ActionRowBuilder().addComponents(
            new ButtonBuilder()
              .setStyle(ButtonStyle.Link)
              .setLabel(q.vip ? "Website" : "Get VIP")
              .setURL(feat.VIP_URL)
          ),
        ],
      });
      return;
    }
    if (name === "grantvip") {
      if (!feat.isAdmin(interaction.user.id)) {
        await interaction.reply({ content: "Admin only.", ephemeral: true });
        return;
      }
      const days = interaction.options.getInteger("days", true);
      const member = interaction.options.getUser("user");
      const rawId = String(interaction.options.getString("user_id") || "").trim();
      const targetId = member ? member.id : rawId;
      if (!targetId) {
        await interaction.reply({
          content: "Pick a **user** or pass **user_id**.",
          ephemeral: true,
        });
        return;
      }
      const result = feat.grantVip(targetId, days, interaction.user.id);
      if (!result.ok) {
        await interaction.reply({ content: result.error, ephemeral: true });
        return;
      }
      userLog.logDiscord({
        interaction,
        kind: "grantvip",
        detail: `${targetId} ${days}d → ${result.left}`,
      });
      await interaction.reply({
        embeds: [
          new EmbedBuilder()
            .setColor(0xff9a1f)
            .setTitle("VIP granted")
            .setDescription(
              [
                `User: <@${targetId}> (\`${targetId}\`)`,
                `Added: **${days} days**${result.stacked ? " (stacked on existing VIP)" : ""}`,
                `Time left: **${result.left}**`,
                `Ends: <t:${Math.floor(result.expiresAt / 1000)}:f>`,
              ].join("\n")
            ),
        ],
        ephemeral: true,
      });
      return;
    }
    if (name === "revokevip") {
      if (!feat.isAdmin(interaction.user.id)) {
        await interaction.reply({ content: "Admin only.", ephemeral: true });
        return;
      }
      const member = interaction.options.getUser("user");
      const rawId = String(interaction.options.getString("user_id") || "").trim();
      const targetId = member ? member.id : rawId;
      if (!targetId) {
        await interaction.reply({
          content: "Pick a **user** or pass **user_id**.",
          ephemeral: true,
        });
        return;
      }
      const result = feat.revokeVip(targetId);
      if (!result.ok) {
        await interaction.reply({ content: result.error, ephemeral: true });
        return;
      }
      userLog.logDiscord({
        interaction,
        kind: "revokevip",
        detail: targetId,
      });
      await interaction.reply({
        content: `Revoked timed VIP for \`${targetId}\`.`,
        ephemeral: true,
      });
      return;
    }
    if (name === "users") {
      if (!feat.isAdmin(interaction.user.id)) {
        await interaction.reply({ content: "Admin only.", ephemeral: true });
        return;
      }
      const summary = feat.adminUsersSummary({ hours: 24, limit: 15 });
      const lines = summary.top.length
        ? summary.top.map((u, i) => {
            const who = u.username ? `@${u.username}` : u.name || u.id;
            return `**${i + 1}.** ${who} · \`${u.id}\` · ${u.n}`;
          })
        : ["_No Discord decrypts in the last 24h._"];
      await interaction.reply({
        embeds: [
          new EmbedBuilder()
            .setColor(0xff9a1f)
            .setTitle("Discord users · last 24h")
            .setDescription(
              [`Total tracked: **${summary.totalDiscordUsers}**`, "", ...lines].join("\n")
            ),
        ],
        ephemeral: true,
      });
      return;
    }
    if (name === "search") {
      const query = String(interaction.options.getString("query") || "").trim();
      if (query.length < 2) {
        await interaction.reply({ content: "Type at least 2 characters.", ephemeral: true });
        return;
      }
      await interaction.deferReply();
      await offerAppSearch((p) => interaction.editReply(p), interaction.user.id, query);
      return;
    }
    if (name === "decrypt") {
      const url = String(interaction.options.getString("url") || "").trim();
      const appName = String(interaction.options.getString("name") || "").trim();
      const version = String(interaction.options.getString("version") || "").trim();

      if (url && isStoreUrl(url)) {
        userLog.logDiscord({ interaction, kind: "decrypt", detail: url.slice(0, 120) });
        await interaction.deferReply();
        if (version && !feat.isVip(interaction.user.id)) {
          // Free: ignore older version requests → latest
          const pick = await offerVersionPicker(interaction, url, interaction.user.id, {
            reply: (p) => interaction.editReply(p),
          });
          if (pick.mode === "picker") return;
          await interaction.editReply({
            embeds: [progressEmbed("Decrypting…", "Starting…", 0)],
            components: [],
          });
          await startDecryptReply(interaction, pick.link, pick.vreq);
          return;
        }
        if (version) {
          await interaction.editReply({
            embeds: [progressEmbed("Decrypting…", "Starting…", 0)],
            components: [],
          });
          await startDecryptReply(interaction, url, version);
          return;
        }
        const pick = await offerVersionPicker(interaction, url, interaction.user.id, {
          reply: (p) => interaction.editReply(p),
        });
        if (pick.mode === "picker") return;
        await interaction.editReply({
          embeds: [progressEmbed("Decrypting…", "Starting…", 0)],
          components: [],
        });
        await startDecryptReply(interaction, pick.link, pick.vreq);
        return;
      }

      if (appName) {
        userLog.logDiscord({
          interaction,
          kind: "decrypt_name",
          detail: `${appName}${version ? " " + version : ""}`.slice(0, 80),
        });
        await interaction.deferReply();
        const items = feat.searchAppsByName(appName, { limit: 8 });
        if (!items.length) {
          await interaction.editReply({
            embeds: [
              new EmbedBuilder()
                .setColor(0xff9a1f)
                .setTitle("No apps found")
                .setDescription(`Nothing matched **${appName.slice(0, 60)}**.`),
            ],
          });
          return;
        }
        if (items.length === 1 || items[0].name.toLowerCase() === appName.toLowerCase()) {
          const hit = items.find((it) => it.name.toLowerCase() === appName.toLowerCase()) || items[0];
          if (version && feat.isVip(interaction.user.id)) {
            await interaction.editReply({
              embeds: [progressEmbed(hit.name, "Starting…", 0)],
              components: [],
            });
            await startDecryptReply(interaction, hit.url, version);
            return;
          }
          const pick = await offerVersionPicker(interaction, hit.url, interaction.user.id, {
            reply: (p) => interaction.editReply(p),
          });
          if (pick.mode === "picker") return;
          await interaction.editReply({
            embeds: [progressEmbed(hit.name, "Starting…", 0)],
            components: [],
          });
          await startDecryptReply(interaction, pick.link, pick.vreq);
          return;
        }
        await offerAppSearch((p) => interaction.editReply(p), interaction.user.id, appName);
        return;
      }

      await interaction.reply({
        content: "Provide `url:` (App Store link) or `name:` (app name).",
        ephemeral: true,
      });
    }
  } catch (e) {
    console.warn("[discord] interaction:", (e && e.message) || e);
    try {
      const msg = friendlyError(e);
      if (interaction.deferred || interaction.replied) {
        await interaction.followUp({ content: msg, ephemeral: true });
      } else {
        await interaction.reply({ content: msg, ephemeral: true });
      }
    } catch {
      /* ignore */
    }
  }
});

client.on("messageCreate", async (message) => {
  if (!WANT_MESSAGE_CONTENT) return;
  if (!message || message.author.bot) return;
  const text = String(message.content || "").trim();
  if (!text) return;

  if (/^\/?(start|help)\b/i.test(text)) {
    userLog.logDiscord({ message, kind: "cmd", detail: "/start" });
    await message.reply({ embeds: [helpEmbed(message.author.id)] });
    return;
  }
  if (/^\/?status\b/i.test(text)) {
    userLog.logDiscord({ message, kind: "cmd", detail: "/status" });
    await message.reply({ embeds: [statusEmbed()] });
    return;
  }

  const m = text.match(/https:\/\/(?:apps|itunes)\.apple\.com\/[^\s>]+/i);
  if (m) {
    const link = m[0].replace(/[)>,.]+$/g, "");
    userLog.logDiscord({
      message,
      kind: "decrypt",
      detail: link.slice(0, 120),
    });
    const progressMsg = await message.reply({
      embeds: [progressEmbed("Decrypting…", "Starting…", 0)],
    });
    try {
      const listed = await feat.listVersionsForUrl(link);
      const choices = feat.versionChoices(listed, {
        vip: feat.isVip(message.author.id),
        max: 20,
      });
      if (choices.length > 1 && feat.isVip(message.author.id)) {
        const token = feat.putPending({
          type: "version",
          userId: String(message.author.id),
          link,
          items: choices,
        });
        const menu = new StringSelectMenuBuilder()
          .setCustomId(`ver:${token}`)
          .setPlaceholder("Pick a version…")
          .addOptions(
            choices.slice(0, 25).map((c, i) =>
              new StringSelectMenuOptionBuilder()
                .setLabel(c.label.slice(0, 100))
                .setValue(String(i))
            )
          );
        await progressMsg.edit({
          embeds: [
            new EmbedBuilder()
              .setColor(0xff9a1f)
              .setTitle(String((listed && listed.title) || "App").slice(0, 80))
              .setDescription("Choose a version to decrypt."),
          ],
          components: [new ActionRowBuilder().addComponents(menu)],
        });
        return;
      }
      const vreq = (choices[0] && choices[0].vreq) || "";
      const payload = await runDecryptJob(message.author.id, link, progressMsg, { vreq });
      await progressMsg.edit({
        content: null,
        embeds: payload.embeds,
        files: payload.files,
        components: payload.components || [],
      });
    } catch (e) {
      await progressMsg
        .edit({
          content: null,
          embeds: [progressEmbed("Failed", friendlyError(e), 0)],
          components: [],
        })
        .catch(() => {});
    }
    return;
  }

  const parsed = feat.parseAppNameQuery(text);
  if (!parsed) return;
  userLog.logDiscord({
    message,
    kind: "search",
    detail: parsed.name.slice(0, 80),
  });
  const replyMsg = await message.reply({
    embeds: [
      new EmbedBuilder()
        .setColor(0xff9a1f)
        .setTitle("Searching…")
        .setDescription(parsed.name),
    ],
  });
  await offerAppSearch((p) => replyMsg.edit(p), message.author.id, parsed.name);
});

client.login(TOKEN).catch((e) => {
  console.error("[discord] login failed:", (e && e.message) || e);
  process.exit(1);
});
