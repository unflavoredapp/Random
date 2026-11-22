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
const fairplayBackends = require("./fairplayBackends");
const ipaCache = require("./mac-tg-ipa-cache");
const publicDl = require("./mac-tg-public-dl");

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

function statusEmbed() {
  const st =
    (fairplayBackends.backendStatus && fairplayBackends.backendStatus()) || {};
  const decryptReady = !!(st.unfairplay && st.unfairplay.ready);
  const modelReady = !!(st.enrollmentModel && st.enrollmentModel.ready);
  const pub = publicDl.resolvePublicBase() || "";
  return new EmbedBuilder()
    .setColor(0xff9a1f)
    .setTitle(`${BOT_NAME} status`)
    .setDescription(
      [
        `**Decrypt:** ${decryptReady ? "ready" : "not ready"}`,
        `**Model:** ${modelReady ? "ready" : "not ready"}`,
        `**Workers:** ${activeWorkers}/${MAX_WORKERS}` +
          (waiters.length ? ` · ${waiters.length} queued` : ""),
        `**Cache:** ${ipaCache.list().length} clear · ${ipaCache.listEncrypted().length} encrypted`,
        pub
          ? `**Big IPA:** HTTPS \`${pub}/d/…\``
          : `**Big IPA:** run \`mac-ssh.sh api\` for download links (>25 MB)`,
        `**Site:** ${SITE}`,
      ].join("\n")
    );
}

function helpEmbed() {
  return new EmbedBuilder()
    .setColor(0xff9a1f)
    .setTitle(`${BOT_NAME}`)
    .setDescription(
      [
        `Decrypt App Store IPAs on the Mac host.`,
        ``,
        `• \`/decrypt url:<App Store link>\``,
        `• \`/status\` — Mac decrypt readiness`,
        WANT_MESSAGE_CONTENT
          ? `• Or paste an App Store link in chat`
          : `• Paste-URL needs Message Content Intent + DISCORD_MESSAGE_CONTENT=1`,
        ``,
        `Files over ~25 MB are sent as an HTTPS download link.`,
        SITE,
      ].join("\n")
    );
}

async function deliverIpa(channel, result, { storeUrl, name }) {
  const file = result && result.file;
  if (!file || !fs.existsSync(file)) throw new Error("Decrypt produced no IPA");
  const st = fs.statSync(file);
  const meta = result.meta || {};
  const appName = name || meta.name || meta.title || "App";
  const version = meta.version || meta.bundleVersion || "";
  const fileName = `${String(appName).replace(/[^\w.\- +]+/g, "_")}${
    version ? `_v${version}` : ""
  }-[FastDecrypt.Bot].ipa`;
  const mb = (st.size / 1024 / 1024).toFixed(1);

  // Cache disk for later Discord re-sends / Telegram if both run.
  try {
    const adam = ipaCache.adamFromStoreUrl(storeUrl) || "";
    if (adam) {
      ipaCache.put({
        adam,
        version: version || "",
        bid: meta.bid || meta.bundleId || "",
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

  if (st.size <= DISCORD_ATTACH_MAX) {
    const attach = new AttachmentBuilder(file, { name: fileName });
    const embed = new EmbedBuilder()
      .setColor(0x2fd16b)
      .setTitle(`${appName}${version ? ` · v${version}` : ""}`)
      .setDescription(`Decrypted · ${mb} MB\n${storeUrl || ""}`.trim());
    await channel.send({ embeds: [embed], files: [attach] });
    return { ok: true, mode: "attach" };
  }

  const staged = publicDl.stageIpa(file, { fileName, bytes: st.size });
  const url = publicDl.downloadUrlFor(staged.token);
  if (!url) {
    throw new Error(
      `IPA is ${mb} MB (over Discord’s ~25 MB attach cap). Run: zsh ~/tetherless/server/mac-ssh.sh api`
    );
  }
  const embed = new EmbedBuilder()
    .setColor(0xff9a1f)
    .setTitle(`${appName}${version ? ` · v${version}` : ""}`)
    .setDescription(
      [
        `Decrypted · **${mb} MB** (too large for Discord attach)`,
        `[Download IPA](${url})`,
        `\`${url}\``,
        `_Link expires in ~${Math.round(publicDl.TTL_MS / 60000)} minutes._`,
      ].join("\n")
    );
  await channel.send({ embeds: [embed] });
  return { ok: true, mode: "link", url };
}

async function decryptStoreUrl(channel, link, progressMsg) {
  if (typeof fairplayBackends.unlockKeychain === "function") {
    fairplayBackends.unlockKeychain();
  }
  if (typeof fairplayBackends.preflightDecrypt === "function") {
    const pre = fairplayBackends.preflightDecrypt({});
    if (!pre.ok) throw new Error(pre.error);
  }

  // Cache hit
  const entry = ipaCache.getByStoreUrl(link, "");
  if (entry && entry.diskPath && fs.existsSync(entry.diskPath)) {
    if (progressMsg) {
      await progressMsg.edit({ content: `Cache hit — sending **${entry.name || "App"}**…` }).catch(() => {});
    }
    return deliverIpa(
      channel,
      { file: entry.diskPath, meta: { name: entry.name, version: entry.version, bid: entry.bid } },
      { storeUrl: link, name: entry.name }
    );
  }

  const dir = fs.mkdtempSync(path.join(WORK, "job-"));
  try {
    if (progressMsg) {
      await progressMsg.edit({ content: "Fetching App Store IPA…" }).catch(() => {});
    }
    await fairplayBackends.ensureEncryptedSource({
      url: link,
      dir,
      say: (t) => console.log("[discord]", String(t || "").slice(0, 160)),
      vreq: "",
    });
    if (progressMsg) {
      await progressMsg.edit({ content: "Decrypting (FairPlay)…" }).catch(() => {});
    }
    const result = await fairplayBackends.tryRemoteBackends({
      url: link,
      dir,
      say: (t) => console.log("[discord]", String(t || "").slice(0, 160)),
      vreq: "",
    });
    if (progressMsg) {
      await progressMsg.edit({ content: "Uploading / linking…" }).catch(() => {});
    }
    return await deliverIpa(channel, result, { storeUrl: link });
  } finally {
    // keep decrypted file if cached via put(diskPath); temp dir may still hold intermediates
    try {
      /* leave dir for debugging; OS tmp cleans eventually */
    } catch {
      /* ignore */
    }
  }
}

async function runDecryptFor(channel, link, notifier) {
  const progressMsg = await notifier(`Decrypting…\n${link}`);
  try {
    await queueJob(async () => decryptStoreUrl(channel, link, progressMsg));
    await progressMsg.edit({ content: "Done." }).catch(() => {});
  } catch (e) {
    const why = String((e && e.message) || e).slice(0, 400);
    await progressMsg.edit({ content: `Failed: ${why}` }).catch(() => {});
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
        await queueJob(async () =>
          decryptStoreUrl(interaction.channel, url, progressMsg)
        );
        await interaction.editReply({ content: "Done." });
      } catch (e) {
        await interaction.editReply({
          content: `Failed: ${String((e && e.message) || e).slice(0, 400)}`,
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
  await runDecryptFor(message.channel, link, async (content) =>
    message.reply({ content })
  );
});

client.login(TOKEN).catch((e) => {
  console.error("[discord] login failed:", (e && e.message) || e);
  process.exit(1);
});
