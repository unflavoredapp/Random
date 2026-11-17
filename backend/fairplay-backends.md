# FairPlay decrypt backends (Linux-only)

TetherLess site decrypt targets a **Debian/Linux host**. No jailbreak, no
TrollStore, and no iPhone Phone Worker are required for the default path.

```bash
# Default — Linux offline decrypt
DECRYPT_BACKENDS=fairplay-decrypt,unfairplay
FAIRPLAY_REQUIRE_CREDENTIAL=1
FAIRPLAY_CREDENTIAL_BIN=/var/lib/tetherless/credential.bin
FAIRPLAY_ENROLLMENT_MODEL=/var/lib/tetherless/fairplay-enrollment.bin
FAIRPLAY_DECRYPT_BIN=/opt/fairplay-decrypt/decrypt.py
FAIRPLAY_DECRYPT_PYTHON=python3
FAIRPLAY_IPATOOL_BIN=ipatool
UNFAIRPLAY_BIN=/usr/local/bin/unfairplay
```

Status: `GET /api/decrypt/backends`

---

## Important: decrypt vs mint

| Step | Where | Jailbreak? |
|------|--------|------------|
| **Decrypt every job** | Linux (this server) | **No** |
| **Get `credential.bin` / enrollment model once** | Enrolled **Mac** via [UnfairPlay](https://github.com/DrWhax/unfairplay) | **No** (Mac App Store enrollment) |

Jailbreak/`unfaird` / Phone Worker exist only as **opt-in** leftovers — leave them out of `DECRYPT_BACKENDS`.

### One-time Mac → Linux (no JB)

On an Apple Silicon Mac signed into the Mac App Store (same enrollment as your IPAs):

```bash
# Option A — export snapshot, finish setup on Linux
sudo ./unfairplay export-enrollment --output enrollment.snapshot
chmod 600 enrollment.snapshot
# copy snapshot privately to Linux, then:
./unfairplay setup --enrollment enrollment.snapshot --ipa SomeOwnedApp.ipa
# copies a reusable enrollment model into the UnfairPlay model dir

# Option B — setup on the Mac, copy only the model file to Linux
sudo ./unfairplay setup --app /Applications/SomeApp.app
```

On Linux, point the server at the model (and/or a 16-byte credential for fairplay-decrypt):

```bash
# Enrollment model for unfairplay decrypt --model …
export FAIRPLAY_ENROLLMENT_MODEL=/var/lib/tetherless/fairplay-enrollment.bin
chmod 600 "$FAIRPLAY_ENROLLMENT_MODEL"

# Optional companion secret for EthanArbuckle fairplay-decrypt
export FAIRPLAY_CREDENTIAL_BIN=/var/lib/tetherless/credential.bin
chmod 600 "$FAIRPLAY_CREDENTIAL_BIN"
wc -c "$FAIRPLAY_CREDENTIAL_BIN"   # must be 16 when used
```

Model-only Linux queue:

```bash
DECRYPT_BACKENDS=unfairplay
FAIRPLAY_ENROLLMENT_MODEL=/var/lib/tetherless/fairplay-enrollment.bin
```

After that, **all decrypt jobs run on Linux**.

---

## Backends

### 1. `fairplay-decrypt` (default) — [EthanArbuckle/fairplay-decrypt](https://github.com/EthanArbuckle/fairplay-decrypt)

Pure Python on Linux. Needs the 16-byte `credential.bin` + encrypted IPA (`ipatool`).

### 2. `unfairplay` (default fallback) — [DrWhax/unfairplay](https://github.com/DrWhax/unfairplay)

Linux amd64/arm64 binary. Uses `decrypt --input … --output … --model <enrollment>`.  
(`--credential` is only for UnfairPlay’s `convert-ipa-macos`, not decrypt.)

### 3. `ipadecrypt` — [londek/ipadecrypt](https://github.com/londek/ipadecrypt)

Optional all-in-one Linux CLI.

### 4. `ipa-decrypter` — [ac0d3r/ipa-decrypter](https://github.com/ac0d3r/ipa-decrypter)

Optional Docker/HTTP wrapper; upload the same `credential.bin` in its admin UI.

### Opt-in only (skip for Linux-only)

- `phone` — TetherLess Phone Worker  
- `unfaird` — jailbroken LAN daemon  

---

## App ↔ server

1. App / site → `POST /api/decrypt` `{ url }`
2. Server uses `credential.bin` and/or enrollment model on Linux
3. Linux backends decrypt → `/api/ipa/file/:up`
4. App downloads → Sign → Install

On-device companion FairPlay inside the iOS app is separate and unchanged.
