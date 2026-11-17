# FairPlay decrypt backends

**Best path if you rent a Mac:** run the whole TetherLess site decrypt queue **on that Mac**. Enroll once with UnfairPlay, then every job decrypts there — no mint → Linux hop.

No jailbreak / TrollStore / Phone Worker required.

Status: `GET /api/decrypt/backends` (includes `host`: `mac` | `linux`)

---

## Preferred — Mac server does everything

On an Apple Silicon Mac (rented or local), signed into the **Mac App Store** with the same Apple ID / enrollment as your IPAs:

```bash
# 1) Install UnfairPlay + ipatool, put them on PATH
# 2) One-time enrollment (either form)
sudo ./unfairplay setup --app /Applications/SomeOwnedApp.app
# or: export-enrollment on this Mac, then setup --enrollment … --ipa App.ipa

# 3) Point env at the enrollment model (MacDuty example paths)
export FAIRPLAY_HOST=mac
export DECRYPT_BACKENDS=unfairplay
export UNFAIRPLAY_BIN="$HOME/bin/unfairplay"
export FAIRPLAY_ENROLLMENT_MODEL="$HOME/unfairplay/models/fairplay-enrollment.bin"
export UNFAIRPLAY_MODEL_DIR="$HOME/unfairplay/models"
export FAIRPLAY_IPATOOL_BIN=ipatool
# FAIRPLAY_REQUIRE_CREDENTIAL defaults off on Mac

# 4) Run the TetherLess Node site on THIS Mac (same process as production)
# Then in the iOS app: Account → Settings → FairPlay Decrypt → Decrypt site URL
# set to https://YOUR-MAC-HOST/  (HTTPS required for App Transport; or keep tetherless.dev
# and copy FAIRPLAY_ENROLLMENT_MODEL to the Linux production host instead)
```

**App setting:** FairPlay Decrypt → **Decrypt site URL** writes UserDefaults `as_site_base`. Leave empty for `tetherless.dev`.

**Never commit** `fairplay-enrollment.bin` / `enrollment.snapshot` — private enrollment secrets.

Optional: also set `FAIRPLAY_CREDENTIAL_BIN` + `fairplay-decrypt` if you want that backend as a fallback on the same Mac.

---

## Alternate — Linux decrypt (copy secrets once)

If the Node server stays on Debian/Linux, mint on a Mac once and copy:

```bash
# On Mac
sudo ./unfairplay export-enrollment --output enrollment.snapshot
# then on Mac or Linux:
./unfairplay setup --enrollment enrollment.snapshot --ipa SomeOwnedApp.ipa
# copy the resulting model file to the Linux host

# On Linux
export FAIRPLAY_HOST=linux
export DECRYPT_BACKENDS=fairplay-decrypt,unfairplay
export FAIRPLAY_ENROLLMENT_MODEL=/var/lib/tetherless/fairplay-enrollment.bin
export FAIRPLAY_CREDENTIAL_BIN=/var/lib/tetherless/credential.bin   # if using fairplay-decrypt
export FAIRPLAY_REQUIRE_CREDENTIAL=1
export UNFAIRPLAY_BIN=/usr/local/bin/unfairplay
export FAIRPLAY_DECRYPT_BIN=/opt/fairplay-decrypt/decrypt.py
export FAIRPLAY_IPATOOL_BIN=ipatool
chmod 600 "$FAIRPLAY_ENROLLMENT_MODEL" "$FAIRPLAY_CREDENTIAL_BIN"
```

| Step | Mac-host mode | Linux-host mode |
|------|----------------|-----------------|
| Enroll / setup | Same Mac | Mac once → copy model |
| Decrypt jobs | Same Mac | Linux |
| Jailbreak? | No | No |

---

## Backends

### `unfairplay` (Mac default) — [DrWhax/unfairplay](https://github.com/DrWhax/unfairplay)

`decrypt --input … --output …` with optional `--model`. On Mac, omitting `--model` uses UnfairPlay’s default saved model directory after local `setup`.

### `fairplay-decrypt` — [EthanArbuckle/fairplay-decrypt](https://github.com/EthanArbuckle/fairplay-decrypt)

Needs a 16-byte `credential.bin` + encrypted IPA (`ipatool`).

### `ipadecrypt` / `ipa-decrypter`

Optional Linux/Mac CLIs or HTTP wrappers.

### Opt-in only

- `phone` — TetherLess Phone Worker  
- `unfaird` — jailbroken LAN daemon  

---

## App ↔ server

1. App / site → `POST /api/decrypt` `{ url }`
2. Host runs UnfairPlay / fairplay-decrypt
3. Clear IPA → `/api/ipa/file/:up`
4. App downloads → Sign → Install

On-device companion FairPlay inside the iOS app is separate and unchanged.
