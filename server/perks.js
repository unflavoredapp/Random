"use strict";
// One place that says what Premium gives. appapi.js and site.js read these numbers, and describe() builds the
// perk list the iOS shop sheet shows, so the sheet can only ever promise what the server really does.
// Every number can be overridden with an env var. Setting a perk equal to the free value turns it off (it drops off the list).
const envN = (name, d) => { const v = Number(process.env[name]); return Number.isFinite(v) && v >= 0 ? Math.floor(v) : d; };
const on = (name, d) => (process.env[name] === undefined ? d : process.env[name] !== "0");

const PERKS = {
  decryptLimit: envN("DEC_LIMIT_PREMIUM", 15),          // decrypts per day (free accounts: DEC_LIMIT_MEMBER, default 10)
  carryMax: envN("DEC_CARRY_PREMIUM", 5),               // unused decrypts from yesterday that carry into today
  cooldownMin: envN("DEC_APP_COOLDOWN_PREMIUM_MIN", 1), // wait before decrypting the same app again (free: DEC_APP_COOLDOWN_MIN, default 5)
  decryptBusyCap: envN("DEC_BUSY_PREMIUM", 12),         // premium can still start a decrypt when this many are running (free: 8)
  signBusyCap: envN("SIGN_BUSY_PREMIUM", 5),            // same for the signer (free: 3)
  decryptFileMin: envN("DEC_FILE_PREMIUM_MIN", 180),    // minutes a decrypted IPA stays ready to sign/download (free: 45)
  signLinkMin: envN("SIGN_LINK_PREMIUM_MIN", 120),      // minutes a signed-app install link stays valid (free: 30)
  fancyStyles: on("PREMIUM_FANCY_STYLES", true),        // rainbow + GIF username styles
  badge: on("PREMIUM_BADGE", true),                     // "premium" badge next to the username
  priorityReview: on("PREMIUM_PRIORITY_REVIEW", true),  // certificate requests sorted first in /admin/app
  certSlots: envN("CERT_SLOTS_PREMIUM", 25),            // saved certificates per account (free: 10)
  historyKeep: envN("DEC_HISTORY_PREMIUM", 60),         // decrypt history entries kept (free: 30, shows 12)
  historyDays: envN("DEC_HISTORY_PREMIUM_DAYS", 180),   // how long history is kept (free: 30 days)
  cacheKeepDays: envN("DEC_CACHE_PREMIUM_DAYS", 14),    // decrypted apps you ran stay re-downloadable this long (free: 1 day)
  prioritySupport: on("PREMIUM_PRIORITY_SUPPORT", true),// support tickets flagged and listed first for staff (no reply-time promise)
  earlyLooks: on("PREMIUM_EARLY_LOOKS", true),          // early posts visible to premium before they go public
};

// What free accounts get, used only to decide which perks are real upgrades and to word them.
const FREE = { decryptBusyCap: 8, signBusyCap: 3, decryptFileMin: 45, signLinkMin: 30, certSlots: 10, historyKeep: 30, historyDays: 30, cacheKeepDays: 1 };

const fmtMin = (m) => (m >= 60 && m % 60 === 0 ? `${m / 60} hour${m === 60 ? "" : "s"}` : `${m} min`);

// base: { memberLimit, cooldownMin } from the running server config
function describe(base) {
  const out = [];
  const add = (icon, text) => out.push({ icon, text });
  if (PERKS.decryptLimit > base.memberLimit) add("lock.open.fill", `${PERKS.decryptLimit} decrypts a day (${base.memberLimit} on free accounts)`);
  if (PERKS.carryMax > 0) add("arrow.triangle.2.circlepath", `Unused decrypts carry over, up to ${PERKS.carryMax}`);
  if (PERKS.cooldownMin < base.cooldownMin) add("timer", `${PERKS.cooldownMin} min wait before re-decrypting the same app (${base.cooldownMin} min free)`);
  if (PERKS.decryptBusyCap > FREE.decryptBusyCap || PERKS.signBusyCap > FREE.signBusyCap) add("bolt.fill", "Priority when decrypt and signing are busy");
  if (PERKS.decryptFileMin > FREE.decryptFileMin) add("clock.fill", `Decrypted files stay ready for ${fmtMin(PERKS.decryptFileMin)} (${fmtMin(FREE.decryptFileMin)} free)`);
  if (PERKS.signLinkMin > FREE.signLinkMin) add("link", `Install links last ${fmtMin(PERKS.signLinkMin)} (${fmtMin(FREE.signLinkMin)} free)`);
  if (PERKS.fancyStyles) add("paintpalette.fill", "Rainbow and animated (GIF) username styles");
  if (PERKS.badge) add("checkmark.seal.fill", "Premium badge next to your name");
  if (PERKS.priorityReview) add("tray.full.fill", "Your certificate requests are listed first for our team");
  if (PERKS.certSlots > FREE.certSlots) add("key.fill", `Save up to ${PERKS.certSlots} certificates (${FREE.certSlots} free)`);
  if (PERKS.historyKeep > FREE.historyKeep || PERKS.historyDays > FREE.historyDays) {
    const months = PERKS.historyDays >= 60 ? `${Math.round(PERKS.historyDays / 30)} months` : `${PERKS.historyDays} days`;
    add("clock.arrow.circlepath", `Decrypt history: last ${PERKS.historyKeep} apps, kept ${months} (${FREE.historyDays} days free)`);
  }
  if (PERKS.cacheKeepDays > FREE.cacheKeepDays) add("arrow.down.circle.fill", `Re-download apps you decrypted for ${PERKS.cacheKeepDays} days (${FREE.cacheKeepDays} day free)`);
  if (PERKS.prioritySupport) add("lifepreserver.fill", "Priority support: your tickets are flagged and shown to our team first");
  if (PERKS.earlyLooks) add("sparkles", "Early looks at new features before everyone else");
  return out;
}

module.exports = Object.assign(PERKS, { describe, FREE });
