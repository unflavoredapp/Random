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
  const website = new ButtonBuilder()
    .setStyle(ButtonStyle.Link)
    .setLabel("Website")
    .setURL(SITE);
  if (!downloadUrl) {
    return [new ActionRowBuilder().addComponents(website)];
  }
  // Download left · Website right (no spacer — Discord rejects blank labels).
  const download = new ButtonBuilder()
    .setStyle(ButtonStyle.Link)
    .setLabel("Download IPA")
    .setURL(downloadUrl);
  return [new ActionRowBuilder().addComponents(download, website)];
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
    stage: DONE_TAGLINE,
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

  const buf = createPctBuffer({
    paint: (p) => sayProgress(progressMsg, appName, p, { iconPath, version: ver }),
    intervalMs: 500,
  });

  try {
    buf.setTarget(3, 10);

    const entry = ipaCache.getByStoreUrl(link, "");
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
      vreq: "",
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
      vreq: "",
    });
    buf.setTarget(92, 97);
    await buf.flush(100);

    const meta = (result && result.meta) || {};
    return buildDeliveryPayload(result, {
      storeUrl: link,
      name: meta.name || meta.title || appName,
      iconPath,
      version: meta.version || meta.bundleVersion || ver,
    });
  } catch (e) {
    buf.stop();
    throw e;
  }
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
          embeds: [progressEmbed("Failed", friendlyError(e), 0)],
          components: [],
        });
      }
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
