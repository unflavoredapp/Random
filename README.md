<p align="center">
  <img src="docs/assets/tetherless-icon.png" width="148" alt="TetherLess app icon" />
</p>

<h1 align="center">TetherLess</h1>

<p align="center">
  <strong>On-device sideloading — pair, sign, install. No computer required.</strong><br />
  <a href="https://tetherless.dev">tetherless.dev</a>
  · Bundle ID <code>dev.tetherless.app</code>
  · v3.7
</p>

---

## Look & feel

TetherLess ships a glassmorphism shell over the existing signing and install stack:

- **Purple → teal** full-bleed gradient background
- **Glass cards** and capsule controls with soft material blur
- **Floating tab bar** — Pair · Files · Library · Decrypt · Settings
- Gradient **app icon** (no-cable mark) matching the UI palette

Backends (TrustCore signing, OTA, native install) are unchanged under the new chrome.

## Features

- **Sign & install any IPA** — using your free Apple ID, or your own certificate.
- **Get a clean copy of apps you own** — decrypt on this iPhone with your App Store keys (not a Telegram bot). That Apple ID must have signed in to this iPhone’s App Store at least once so iOS has its decryption keys; afterward you can switch the active App Store account back.
- **Multiple App Store accounts** — sign several Apple IDs in for downloads and switch between them right in the Decrypt tab.
- **Tweak injection** — add `.deb` or `.dylib` tweaks while you sign.
- **Keep apps alive** — resign in one tap, Refresh All at once, or automate it with a Shortcut so your apps (and TetherLess itself) never expire — even while your iPhone is locked.
- **Built-in Files** — manage IPAs, tweaks, and downloads without leaving the app.
- **Custom certificate mode** — bring your own paid certificate to install over the air, with no pairing or VPN.
- **Manage your Apple ID** — view your signing certificates, App IDs, and devices, and revoke a certificate to free a slot — right in the app, no Apple Developer portal needed.

| Area | What you get |
| --- | --- |
| **Pair** | On-device pairing + local VPN for native installs |
| **Files** | Drop / open archives, extract, inspect, push |
| **Library** | Source repos, staff picks, updates, device-installed apps |
| **Decrypt** | On-device decrypt (this iPhone’s App Store keys) + multi-account Store Access |

**Decrypt tip:** Decrypt runs on this device — not via Telegram. The Apple ID used in TetherLess must have been signed in to this iPhone’s App Store at least once (App Store app, or Settings → your name → Media & Purchases). iOS stores that account’s decryption keys on first sign-in; without it, decrypt fails after download even though TetherLess is set up correctly.
| **Settings** | Install method (OTA vs Native), Store Access, certs, account |
| **Sign & install** | TrustCore signing, OTA via `*.tetherless.dev`, or native idevice install |
| **Analysis** | Local Analysis Center — disassembler, CFG, pseudocode, reversible patch proposals |
| **Identity** | ADID (`AS-XXXXXX-XX`) minted on first launch, stored in Keychain |

### Install paths

1. **OTA (default)** — `itms-services` over the tetherless.dev loopback HTTPS host  
2. **Native** — built-in local VPN + device pairing (Settings › Install Method)

### On-device OTA (`tetherless.dev`)

1. DNS: `*.tetherless.dev` → `127.0.0.1` (apex hosts `pack.json` on the VPS)
2. Generate & deploy the pack — see [`server/ota/tetherless-ota.md`](server/ota/tetherless-ota.md)
3. App pulls the pack on launch; enable **Full Trust** for the pack CA once

Native install details: [`NATIVE_INSTALL.md`](NATIVE_INSTALL.md)

## ADID identity

New installations mint a cryptographically random `AS-XXXXXX-XX` ADID on first use. The ID is stored in Keychain and is not derived from hardware or display fingerprints.

Administrators can reassign the ADID of their authenticated admin account from Settings → Account. The app calls `account.php` with `action=admin_set_mdid`; the server must atomically update the account ADID and its ADID-based role mapping before returning the canonical ADID. TetherLess only changes its local Keychain value after that server response.

See [`MDID_IDENTITY.md`](MDID_IDENTITY.md) for the API contract.

## Local Analysis Center

The analysis stack is local-first — no remote analysis service. The same annotated `UCFunction` feeds the Disassembler Browser, CFG Viewer, Pseudocode Viewer, and Analysis Center.

Analysis Center exposes:

- Overview / local analysis statistics
- String annotations
- Resolved symbols / classes / methods
- Function / call inspection
- Basic-block graph edges
- Call / branch / XREF flow
- Hex / memory view of decoded function bytes
- Reversible local NOP/RET patch proposals and patch manifest export
- Original-vs-proposed patch diff
- One-tap navigation back to Disassembler, CFG, and Pseudocode

Patch proposals stay as an in-memory / local manifest in the viewer; opening the analysis UI does not modify the source binary.

## Links

- Site: [tetherless.dev](https://tetherless.dev)
- OTA pack docs: [`server/ota/tetherless-ota.md`](server/ota/tetherless-ota.md)
- Native install: [`NATIVE_INSTALL.md`](NATIVE_INSTALL.md)
- ADID / MDID: [`MDID_IDENTITY.md`](MDID_IDENTITY.md)
