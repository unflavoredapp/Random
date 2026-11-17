# FairPlay decrypt backends

TetherLess decrypt jobs (`POST /api/decrypt`) run through backends listed in
`DECRYPT_BACKENDS`. **Default is `fairplay-decrypt` only** — a valid 16-byte
`credential.bin` is required so offline decrypt stays correct.

```bash
# Default (forced credential.bin path)
DECRYPT_BACKENDS=fairplay-decrypt
FAIRPLAY_REQUIRE_CREDENTIAL=1
FAIRPLAY_CREDENTIAL_BIN=/var/lib/tetherless/credential.bin
FAIRPLAY_DECRYPT_BIN=/opt/fairplay-decrypt/decrypt.py
FAIRPLAY_DECRYPT_PYTHON=python3
FAIRPLAY_IPATOOL_BIN=ipatool
```

Optional extras (explicit opt-in):

```bash
DECRYPT_BACKENDS=fairplay-decrypt,ipadecrypt,ipa-decrypter,unfaird,phone
```

Status: `GET /api/decrypt/backends` and Admin → Telegram decrypt bot.

Jobs **refuse to start** when `FAIRPLAY_REQUIRE_CREDENTIAL=1` (default) and
`credential.bin` is missing or not exactly **16 bytes**.

---

## 1. `fairplay-decrypt` (default) — [EthanArbuckle/fairplay-decrypt](https://github.com/EthanArbuckle/fairplay-decrypt)

1. Mint once from a jailbroken device (`credential-retrieval` → `credential.bin`).
2. Put the file on the server and point `FAIRPLAY_CREDENTIAL_BIN` at it.
3. Install the Python decryptor; set `FAIRPLAY_DECRYPT_BIN`.
4. Provide `ipatool` (or drop `encrypted-source.ipa` into the job dir).

```bash
# Validate size
wc -c /var/lib/tetherless/credential.bin   # must print: 16 …
```

---

## 2. `ipadecrypt` — [londek/ipadecrypt](https://github.com/londek/ipadecrypt)

```bash
IPADECRYPT_BIN=/usr/local/bin/ipadecrypt
```

Still subject to `FAIRPLAY_REQUIRE_CREDENTIAL` when that flag is on (keeps the
account credential story consistent). Prefer minting with fairplay-decrypt and
keeping one `credential.bin` as source of truth.

---

## 3. `ipa-decrypter` — [ac0d3r/ipa-decrypter](https://github.com/ac0d3r/ipa-decrypter)

```bash
IPA_DECRYPTER_URL=http://127.0.0.1:8787
IPA_DECRYPTER_TOKEN=
```

Upload the same `credential.bin` in its admin UI for each Apple ID.

---

## 4. `unfaird` — jailbroken LAN daemon

```bash
UNFAIRD_URL=http://192.168.1.20:6347
```

Opt-in fallback only — not the default.

---

## 5. `phone` — iPhone Phone Worker

On-device FairPlay via TetherLess. **Not default.** Add `phone` to
`DECRYPT_BACKENDS` only if you want the iPhone to claim leftover jobs.

```bash
DECRYPT_WORKER_TOKEN=shared-secret
```

App: **Account → Settings → FairPlay Decrypt → Phone Worker**.

---

## App ↔ server flow

1. App / Telegram / site → `POST /api/decrypt` `{ url }`
2. Server verifies `credential.bin` (16 bytes) when required
3. Tries backends in order → clear IPA → `/api/ipa/file/:up`
4. App downloads → Sign → Install

Device-channel Gets (companion FairPlay on this iPhone) are unchanged.
