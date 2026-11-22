# FairPlay decrypt backends

**Preferred on Debian 13 / Linux VPS:** connect an **iPhone Phone Worker**.  
The VPS only queues jobs; the phone downloads the app, runs FairPlay on-device, and uploads the clear IPA. **No Mac enrollment** and no `credential.bin`.

Status: `GET /api/decrypt/backends` (includes `host`: `mac` | `linux`, plus `phone.ready`)

---

## Preferred — Linux VPS + iPhone Phone Worker

### 1) Install on the VPS (Debian 13)

```bash
sudo bash server/linux-install.sh
# optional: sudo bash server/linux-install.sh --token "$(openssl rand -hex 24)" \
#   --public-base https://fastdecrypt.bot
sudo systemctl enable --now tetherless-api.service
# optional bots:
# sudo systemctl enable --now tetherless-tg-bot.service
# sudo systemctl enable --now tetherless-discord-bot.service
```

Env lives at `/etc/tetherless/linux-host.env` (from `server/linux-host.env.example`):

```bash
FAIRPLAY_HOST=linux
DECRYPT_BACKENDS=phone
DECRYPT_WORKER_TOKEN=…          # same value pasted into the iPhone app
MAC_API_PORT=8787
MAC_PUBLIC_BASE=https://fastdecrypt.bot
```

Put Caddy/nginx in front of `:8787` — see `server/Caddyfile.linux.example`.  
Ops helper: `bash server/linux-ctl.sh status|token|logs api`.

### 2) Connect the iPhone (grabs FairPlay on-device)

1. Sign into **Settings → Media & Purchases / App Store** with the Apple ID that owns the apps.
2. Install / open **TetherLess**.
3. **Account → Settings → FairPlay Decrypt → Decrypt site URL** = your VPS HTTPS origin (same host the API serves). Leave empty only if the app already points at your production host.
4. **Settings → Phone Worker** → paste `DECRYPT_WORKER_TOKEN` → enable → **keep the app open** (or screen on) while jobs run.
5. Optional: use the **FairPlay Keys** capture sheet to confirm Media & Purchases + an App Store install with `SC_Info`. That sheet records readiness only — keys never leave the phone as a file.

Flow:

1. Site / Telegram / Discord / API → `POST /api/decrypt` `{ url }`
2. VPS waits for a Phone Worker claim (`/api/decrypt/worker/claim`)
3. iPhone Store download + on-device FairPlay → upload clear IPA
4. Client downloads → Sign → Install

| Step | Where |
|------|--------|
| Queue / bots / HTTPS | Linux VPS |
| FairPlay decrypt | iPhone (Phone Worker) |
| Mac needed? | **No** |
| Jailbreak? | **No** |

**Never commit** `DECRYPT_WORKER_TOKEN`, enrollment models, or `credential.bin`.

---

## Optional — offline CLI on the VPS (Mac-minted model)

Only if you want decrypt **without** an iPhone online. UnfairPlay enrollment still has to be minted on a Mac once, then copied:

```bash
# On Mac (one-time)
sudo ./unfairplay export-enrollment --output enrollment.snapshot
./unfairplay setup --enrollment enrollment.snapshot --ipa SomeOwnedApp.ipa
# scp fairplay-enrollment.bin → VPS (mode 0600)

# On Linux
export DECRYPT_BACKENDS=phone,unfairplay   # phone remains fallback
export UNFAIRPLAY_BIN=/usr/local/bin/unfairplay
export FAIRPLAY_ENROLLMENT_MODEL=/var/lib/tetherless/fairplay-enrollment.bin
chmod 600 "$FAIRPLAY_ENROLLMENT_MODEL"
```

A stock/sideloaded iPhone **cannot** mint `fairplay-enrollment.bin` or the 16-byte `credential.bin` (those need Mac unfairplay enrollment or a jailbreak SIDB/SINF path).

---

## Optional — Mac host does everything

On an Apple Silicon Mac signed into the Mac App Store:

```bash
export FAIRPLAY_HOST=mac
export DECRYPT_BACKENDS=unfairplay
export UNFAIRPLAY_BIN="$HOME/bin/unfairplay"
sudo ./unfairplay setup --app /Applications/SomeOwnedApp.app
zsh ~/tetherless/server/mac-ssh.sh start   # WebSSH helper (Mac only)
```

See `server/mac-host.env.example`.

---

## Backends

### `phone` (Linux default) — iPhone Phone Worker

Internal id `phone`. Requires `DECRYPT_WORKER_TOKEN`. The iPhone app claims jobs and runs the same Store → FairPlay path as on-device decrypt. User-facing status can say **Tetherless** / Phone Worker.

### `unfairplay` (Mac default) — [DrWhax/unfairplay](https://github.com/DrWhax/unfairplay)

`decrypt --input … --output …` with optional `--model`. On Mac, omitting `--model` uses the default saved model directory after local `setup`. On Linux, a copied model is required.

### `fairplay-decrypt` — [EthanArbuckle/fairplay-decrypt](https://github.com/EthanArbuckle/fairplay-decrypt)

Needs a 16-byte `credential.bin` (jailbreak mint) + encrypted IPA (`ipatool`).

### `ipadecrypt` / `ipa-decrypter`

Optional Linux/Mac CLIs or HTTP wrappers.

### Opt-in

- `unfaird` — jailbroken LAN daemon  

---

## App ↔ server

1. App / site → `POST /api/decrypt` `{ url }`
2. Host tries CLI backends (if configured), else waits for Phone Worker
3. Clear IPA → `/api/ipa/file/:up` (or bot delivery)
4. App downloads → Sign → Install

On-device companion FairPlay inside the iOS app (Decrypt tab) is separate and unchanged.
