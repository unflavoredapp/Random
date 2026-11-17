# FairPlay decrypt backends

TetherLess decrypt jobs (`POST /api/decrypt`) can run through one or more backends.
Order is controlled by `DECRYPT_BACKENDS` (comma-separated). The first backend that
produces a clear IPA wins; failures fall through to the next.

```bash
# Example: try Linux offline tools, then unfaird, then the iPhone worker
DECRYPT_BACKENDS=fairplay-decrypt,ipadecrypt,ipa-decrypter,unfaird,phone
```

Default is `phone` (existing Phone Worker).

Status: `GET /api/decrypt/backends` and Admin → Telegram decrypt bot.

---

## 1. `phone` — iPhone Phone Worker

On-device FairPlay via TetherLess (unchanged).

```bash
DECRYPT_WORKER_TOKEN=shared-secret
```

In the app: **Account → Settings → FairPlay Decrypt → Phone Worker** — same token, keep the app open.

---

## 2. `fairplay-decrypt` — [EthanArbuckle/fairplay-decrypt](https://github.com/EthanArbuckle/fairplay-decrypt)

Linux/macOS CLI. Needs a 16-byte `credential.bin` (mint once from a jailbroken device).

```bash
FAIRPLAY_CREDENTIAL_BIN=/var/lib/tetherless/credential.bin
FAIRPLAY_DECRYPT_BIN=/opt/fairplay-decrypt/decrypt.py
FAIRPLAY_DECRYPT_PYTHON=python3
# Optional: download encrypted IPA when job dir has no encrypted-source.ipa
FAIRPLAY_IPATOOL_BIN=ipatool
```

Install the repo on the server, create a venv, pip install requirements, mint credential once.

---

## 3. `ipadecrypt` — [londek/ipadecrypt](https://github.com/londek/ipadecrypt)

All-in-one CLI (download + decrypt).

```bash
IPADECRYPT_BIN=/usr/local/bin/ipadecrypt
```

Bootstrap credentials on the host once (`ipadecrypt` docs). Jobs call:

`ipadecrypt decrypt <store-url> --output <dir>/ipadecrypt-out.ipa --no-on-device`

---

## 4. `ipa-decrypter` — [ac0d3r/ipa-decrypter](https://github.com/ac0d3r/ipa-decrypter)

HTTP server (Docker). Upload credentials in its admin UI; TetherLess queues jobs against it.

```bash
IPA_DECRYPTER_URL=http://127.0.0.1:8787
IPA_DECRYPTER_TOKEN=   # optional Bearer
```

Expects `POST /api/jobs` `{ "url" }` → `{ "id" }`, poll `GET /api/jobs/:id`, download when done.

---

## 5. `unfaird` — jailbroken device daemon

LAN fallback used by ipa-decrypter-style stacks (default port **6347**).

```bash
UNFAIRD_URL=http://192.168.1.20:6347
UNFAIRD_TOKEN=   # optional
```

Health: `GET /health`. Decrypt: `POST /decrypt` with `{ "url", "adamId?" }` — IPA bytes or JSON with `downloadUrl`.

---

## App ↔ server flow

1. App / Telegram / site → `POST /api/decrypt` `{ url }`
2. Server tries backends in `DECRYPT_BACKENDS` order
3. Clear IPA lands in the job dir → same cache / `/api/ipa/file/:up` path as today
4. App downloads clear IPA → Sign → Install

Device-channel Gets (companion FairPlay on this iPhone) are unchanged and do not use these backends.
