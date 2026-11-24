# FairPlay decrypt backends

**Preferred:** a **stock iPhone** signed with a **free/development Apple ID certificate**, running the **Tetherless Decrypt companion** (on-device FairPlay). No Mac enrollment. No jailbreak.

For a Debian 13 / Linux VPS site or bots: queue on the VPS and let an iPhone **Phone Worker** claim jobs (same on-device FairPlay). The VPS never needs `fairplay-enrollment.bin`.

Status: `GET /api/decrypt/backends` (`host`: `mac` | `linux`, plus `phone.ready`)

---

## Stock iPhone — development cert + companion (primary)

FairPlay keys stay on the phone after Media & Purchases / App Store sign-in. Decrypt runs inside the installed **Tetherless Decrypt** companion IPA (signed with your free or paid development certificate), same class of path as fouldecrypt / FairPlayed (`mremap` next to `SC_Info`).

### One-time on the iPhone

1. Sign into **Settings → Media & Purchases / App Store** with the Apple ID that owns the apps.
2. Open **TetherLess** → sign in under **Account** (Store + signing).
3. Ensure a **development / free Apple ID certificate** is linked (Settings / Account signing). On first companion install, **Trust** the cert under **Settings → General → VPN & Device Management**.
4. Leave **“Server decrypt only”** **off** (default) under FairPlay Decrypt — that keeps Get / companion on-device.
5. Use **Get** / Decrypt: Store download → companion install → FairPlay on-device → clear IPA in Library.

Optional readiness: **FairPlay Keys** capture sheet confirms Media & Purchases + an App Store install with `SC_Info`. It does **not** export a credential file — keys never leave the device that way.

---

## Linux VPS + Phone Worker (queue without a Mac)

Use when Telegram / Discord / web should queue App Store links and this iPhone finishes them.

### 1) Install on the VPS (Debian 13)

```bash
sudo bash server/linux-install.sh
sudo systemctl enable --now tetherless-api.service
```

Env: `/etc/tetherless/linux-host.env` (from `server/linux-host.env.example`):

```bash
FAIRPLAY_HOST=linux
DECRYPT_BACKENDS=phone
DECRYPT_WORKER_TOKEN=…          # paste into Phone Worker on the iPhone
MAC_API_PORT=8787
MAC_PUBLIC_BASE=https://fastdecrypt.bot
```

Caddy/nginx → `:8787` — `server/Caddyfile.linux.example`.  
Ops: `bash server/linux-ctl.sh status|token|logs api`.

### 2) Connect the iPhone

1. Same Media & Purchases + development-cert setup as above.
2. **FairPlay Decrypt → Decrypt site URL** = your VPS HTTPS origin.
3. **Settings → Phone Worker** → paste `DECRYPT_WORKER_TOKEN` → enable → keep the app open.
4. Phone Worker downloads the Store IPA and decrypts using **live App Store install licenses when the app is already installed** on this device, then uploads the clear IPA. For the most reliable first decrypt of an app, use **Get → companion** once (development cert), then leave Phone Worker on for the VPS queue.
5. Leave **Server decrypt only** off unless you intentionally want every Get to hit the VPS.

| Step | Where |
|------|--------|
| Queue / bots / HTTPS | Linux VPS |
| FairPlay decrypt | Stock iPhone (dev cert + on-device FairPlay) |
| Mac needed? | **No** |
| Jailbreak? | **No** |

**Never commit** `DECRYPT_WORKER_TOKEN`, enrollment models, or `credential.bin`.

---

## Dopamine + DELvEKBot — Telegram bot only (iPhone 11 · iOS 26.0.1)

For a **Telegram bot** on a Linux VPS whose FairPlay work is done by `Cli/DELvEKBot` on a Dopamine jailbreak phone (not AppAssassin / FastDecryptBot companion).

```
Telegram user → App Store link → VPS bot queue → buddy3 on iPhone → clear IPA → bot reply
```

`buddy3` only accepts **ProductVersion 15.4, 16.2, or 26.0.1** (`sw_vers -productVersion`).

### 1) VPS — bot + phone queue

```bash
sudo bash server/linux-install.sh
```

In `/etc/tetherless/linux-host.env`:

```bash
FAIRPLAY_HOST=linux
DECRYPT_BACKENDS=phone
DECRYPT_WORKER_TOKEN=$(openssl rand -hex 24)   # paste into the phone worker env
TELEGRAM_BOT_TOKEN=…                          # from @BotFather
TELEGRAM_BOT_USERNAME=YourBot
MAC_PUBLIC_BASE=https://your-vps-host
```

```bash
sudo systemctl enable --now tetherless-api.service
# bot is started by the API / linux-ctl — see: bash server/linux-ctl.sh status
```

### 2) iPhone — buddy3 worker (keep this running)

```bash
scp Cli/DELvEKBot server/delvekbot-dopamine-worker.sh mobile@IPHONE_IP:/var/mobile/Documents/
ssh mobile@IPHONE_IP 'chmod +x /var/mobile/Documents/buddy3 /var/mobile/Documents/delvekbot-dopamine-worker.sh'

export DECRYPT_SITE_URL=https://your-vps-host/
export DECRYPT_WORKER_TOKEN=…    # same as linux-host.env
export DELVEKBOT_BIN=/var/mobile/Documents/DELvEKBot
bash /var/mobile/Documents/delvekbot-dopamine-worker.sh
# Script always re-execs with sudo -E (buddy3 needs root on Dopamine).
```

Install each requested app **from the App Store** on this Dopamine phone first (same Apple ID). The worker maps the Store URL → bundle ID, runs `DELvEKBot`, uploads `/var/mobile/Documents/<bid>.ipa`; the Telegram bot sends that IPA back.

| Step | Where |
|------|--------|
| Telegram bot + HTTPS queue | Linux VPS |
| FairPlay decrypt | Dopamine iPhone (`DELvEKBot`) |
| AppAssassin / free cert companion | **Not used** |
| Mac needed? | **No** |

---

## Optional — offline CLI on the VPS (Mac-minted unfairplay model)

Only if you want decrypt **without** an iPhone online. UnfairPlay enrollment still has to be minted on a Mac once:

```bash
# On Mac (one-time) — not required for companion / Phone Worker
sudo ./unfairplay export-enrollment --output enrollment.snapshot
./unfairplay setup --enrollment enrollment.snapshot --ipa SomeOwnedApp.ipa
# scp fairplay-enrollment.bin → VPS (mode 0600)

export DECRYPT_BACKENDS=phone,unfairplay
export UNFAIRPLAY_BIN=/usr/local/bin/unfairplay
export FAIRPLAY_ENROLLMENT_MODEL=/var/lib/tetherless/fairplay-enrollment.bin
```

A stock iPhone **cannot** mint `fairplay-enrollment.bin` (Mac unfairplay) or a jailbreak `credential.bin`. It **can** decrypt via companion / Phone Worker.

---

## Optional — Mac host CLI

```bash
export FAIRPLAY_HOST=mac
export DECRYPT_BACKENDS=unfairplay
sudo ./unfairplay setup --app /Applications/SomeOwnedApp.app
```

See `server/mac-host.env.example`. Prefer Linux + Phone Worker unless you already run on MacDuty.

---

## Backends

### `phone` (Linux default) — iPhone Phone Worker

Requires `DECRYPT_WORKER_TOKEN`. Stock iPhone claims jobs and runs on-device FairPlay (same Apple ID / Media & Purchases as companion).

### `unfairplay` (Mac default) — [DrWhax/unfairplay](https://github.com/DrWhax/unfairplay)

Needs a Mac-minted enrollment model (or live Mac setup). Optional on Linux.

### `fairplay-decrypt` — [EthanArbuckle/fairplay-decrypt](https://github.com/EthanArbuckle/fairplay-decrypt)

16-byte `credential.bin` (jailbreak mint) + encrypted IPA.

### Opt-in

- `ipadecrypt` / `ipa-decrypter` — CLI/HTTP wrappers  
- `unfaird` — jailbroken LAN daemon  

---

## App ↔ server

1. App / site → `POST /api/decrypt` `{ url }` (or companion runs FairPlay locally with no server)
2. Host waits for Phone Worker when `DECRYPT_BACKENDS=phone`
3. Clear IPA → download / bot delivery → Sign → Install

Interactive **Get** uses the development-cert companion on-device unless “Server decrypt only” is enabled.
