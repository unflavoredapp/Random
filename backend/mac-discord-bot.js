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

function queueJob(fn) {
  return new Promise((resolve, reject) => {
    waiters.push({ fn, resolve, reject });
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

async function renderSharpCard({ name, version, iconPath, stage, pct, done }) {
  const dest = path.join(WORK, `sharp-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.jpg`);
  try {
    const out = await renderProgressBanner({
      name: name || "App",
      version: version || "",
      stage: stage || (done ? "done" : "working…"),
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
  const row = new ActionRowBuilder();
  if (downloadUrl) {
    row.addComponents(
      new ButtonBuilder()
        .setStyle(ButtonStyle.Link)
        .setLabel("Download IPA")
        .setURL(downloadUrl)
    );
  }
  row.addComponents(
    new ButtonBuilder().setStyle(ButtonStyle.Link).setLabel("Website").setURL(SITE)
  );
  return [row];
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

function helpEmbed() {
  return new EmbedBuilder()
    .setColor(0xff9a1f)
    .setTitle(BOT_NAME)
    .setDescription(
      [
        `Decrypt App Store IPAs.`,
        ``,
        `• \`/decrypt url:<App Store link>\``,
        `• \`/status\``,
        WANT_MESSAGE_CONTENT ? `• Or paste an App Store link` : "",
        SITE,
      ]
        .filter(Boolean)
        .join("\n")
    );
}

/** Telegram-style result: sharp card image + app name title (no URL dump). */
async function buildDeliveryPayload(result, { storeUrl, name, iconPath, version: verHint }) {
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

  const bannerPath = await renderSharpCard({
    name: appName,
    version,
    iconPath,
    stage: "done",
    pct: 100,
    done: true,
  });

  const files = [];
  const embed = new EmbedBuilder()
    .setColor(0xff9a1f)
    .setTitle(appName);

  const lines = [];
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

  if (st.size <= DISCORD_ATTACH_MAX) {
    files.push(new AttachmentBuilder(file, { name: fileName }));
  } else {
    const staged = publicDl.stageIpa(file, { fileName, bytes: st.size });
    const url = publicDl.downloadUrlFor(staged.token);
    if (!url) {
      throw new Error(
        `IPA is ${mb} MB (over Discord’s ~25 MB attach cap). Run: zsh ~/tetherless/server/mac-ssh.sh api`
      );
    }
    mode = "link";
    downloadUrl = url;
    embed.setFooter({
      text: `Link expires in ~${Math.round(publicDl.TTL_MS / 60000)} min`,
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

async function sayProgress(progressMsg, appName, stage, pct, { iconPath, version } = {}) {
  if (!progressMsg) return;
  const p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
  const bannerPath = await renderSharpCard({
    name: appName,
    version: version || "",
    iconPath: iconPath || "",
    stage,
    pct: p,
    done: false,
  });
  const embed = progressEmbed(appName, stage, p);
  const files = [];
  if (bannerPath) {
    files.push(new AttachmentBuilder(bannerPath, { name: "sharp.jpg" }));
    embed.setImage("attachment://sharp.jpg");
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

async function decryptStoreUrl(link, progressMsg) {
  if (typeof fairplayBackends.unlockKeychain === "function") {
    fairplayBackends.unlockKeychain();
  }
  if (typeof fairplayBackends.preflightDecrypt === "function") {
    const pre = fairplayBackends.preflightDecrypt({});
    if (!pre.ok) throw new Error(pre.error);
  }

  const lookup = lookupStoreApp(link);
  const appName = lookup.name || "App";
  const ver = lookup.version || "";
  const iconPath = lookup.iconPath || "";
  let lastPct = -1;
  let lastAt = 0;
  const pushPct = async (pct, stage) => {
    const p = Math.max(0, Math.min(100, Math.round(Number(pct) || 0)));
    const now = Date.now();
    // Throttle sharp re-renders (Discord rate limits + CPU).
    if (p < 100 && p - lastPct < 8 && now - lastAt < 2500) return;
    lastPct = p;
    lastAt = now;
    await sayProgress(progressMsg, appName, stage, p, { iconPath, version: ver });
  };

  await pushPct(5, "Looking up…");

  const entry = ipaCache.getByStoreUrl(link, "");
  if (entry && entry.diskPath && fs.existsSync(entry.diskPath)) {
    await pushPct(90, "Cache hit…");
    return buildDeliveryPayload(
      {
        file: entry.diskPath,
        meta: { name: entry.name || appName, version: entry.version || ver, bid: entry.bid || lookup.bid },
      },
      {
        storeUrl: link,
        name: entry.name || appName,
        iconPath,
        version: entry.version || ver,
      }
    );
  }

  const dir = fs.mkdtempSync(path.join(WORK, "job-"));
  await pushPct(12, "Fetching IPA…");
  await fairplayBackends.ensureEncryptedSource({
    url: link,
    dir,
    say: (t) => console.log("[discord]", String(t || "").slice(0, 160)),
    onProgress: (pct, msg) => {
      const mapped = Math.max(12, Math.min(55, Math.round(Number(pct) || 12)));
      pushPct(mapped, msg || "Fetching IPA…").catch(() => {});
    },
    vreq: "",
  });
  await pushPct(60, "Decrypting…");
  const result = await fairplayBackends.tryRemoteBackends({
    url: link,
    dir,
    say: (t) => console.log("[discord]", String(t || "").slice(0, 160)),
    onProgress: (pct, msg) => {
      const mapped = Math.max(60, Math.min(92, Math.round(Number(pct) || 60)));
      pushPct(mapped, msg || "Decrypting…").catch(() => {});
    },
    vreq: "",
  });
  await pushPct(96, "Finishing…");
  const meta = (result && result.meta) || {};
  return buildDeliveryPayload(result, {
    storeUrl: link,
    name: meta.name || meta.title || appName,
    iconPath,
    version: meta.version || meta.bundleVersion || ver,
  });
}

async function runDecryptFor(channel, link, notifier) {
  const progressMsg = await notifier({
    embeds: [progressEmbed("Decrypting…", "Starting…", 0)],
  });
  try {
    const payload = await queueJob(async () => decryptStoreUrl(link, progressMsg));
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
    const why = String((e && e.message) || e).slice(0, 400);
    await progressMsg
      .edit({ content: null, embeds: [progressEmbed("Failed", why, 0)], components: [] })
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
      .setName("decrypt")
      .setDescription("Decrypt an App Store IPA")
      .addStringOption((o) =>
        o.setName("url").setDescription("App Store link").setRequired(true)
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
  const st = fairplayBackends.backendStatus();
  console.log(
    `[discord] decrypt=${!!(st.unfairplay && st.unfairplay.ready)} model=${!!(
      st.enrollmentModel && st.enrollmentModel.ready
    )} public=${publicDl.resolvePublicBase() || "unset"} messageContent=${WANT_MESSAGE_CONTENT ? "on" : "off"}`
  );
});

client.on("interactionCreate", async (interaction) => {
  if (!interaction.isChatInputCommand()) return;
  const name = interaction.commandName;
  try {
    if (name === "start") {
      await interaction.reply({ embeds: [helpEmbed()] });
      return;
    }
    if (name === "status") {
      await interaction.reply({ embeds: [statusEmbed()] });
      return;
    }
    if (name === "decrypt") {
      const url = String(interaction.options.getString("url") || "").trim();
      if (!isStoreUrl(url)) {
        await interaction.reply({
          content: "Paste a full App Store link (`https://apps.apple.com/...`).",
          ephemeral: true,
        });
        return;
      }
      await interaction.deferReply();
      const progressMsg = {
        edit: (payload) => interaction.editReply(payload),
      };
      try {
        const payload = await queueJob(async () => decryptStoreUrl(url, progressMsg));
        await interaction.editReply({
          content: null,
          embeds: payload.embeds,
          files: payload.files,
          components: payload.components || [],
        });
      } catch (e) {
        await interaction.editReply({
          content: null,
          embeds: [
            progressEmbed("Failed", String((e && e.message) || e).slice(0, 400)),
          ],
          components: [],
        });
      }
    }
  } catch (e) {
    console.warn("[discord] interaction:", (e && e.message) || e);
    try {
      const msg = String((e && e.message) || e).slice(0, 200);
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
    await message.reply({ embeds: [helpEmbed()] });
    return;
  }
  if (/^\/?status\b/i.test(text)) {
    await message.reply({ embeds: [statusEmbed()] });
    return;
  }

  const m = text.match(/https:\/\/(?:apps|itunes)\.apple\.com\/[^\s>]+/i);
  if (!m) return;
  const link = m[0].replace(/[)>,.]+$/g, "");
  await runDecryptFor(message.channel, link, async (payload) =>
    message.reply(payload)
  );
});

client.login(TOKEN).catch((e) => {
  console.error("[discord] login failed:", (e && e.message) || e);
  process.exit(1);
});
