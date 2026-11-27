# decrypt.software

```
     _                            _
  __| | ___  ___ _ __ _   _ _ __ | |_
 / _` |/ _ \/ __| '__| | | | '_ \| __|
| (_| |  __/ (__| |  | |_| | |_) | |_
 \__,_|\___|\___|_|   \__, | .__/ \__|
                      |___/|_|
              .software
```

| | |
|:--|:--|
| **Brand** | **`decrypt.software`** |
| **Version** | **`1.0.0`** |
| **XPC service** | **`software.decrypt.xpc`** |
| **Site** | **https://decrypt.software** |
| **Wire** | hand-rolled C `<xpc/xpc.h>` · not NSXPC |

```text
Brand:   decrypt.software
Version: 1.0.0
Service: software.decrypt.xpc
Stamp:   Brand: decrypt.software · XPC software.decrypt.xpc
```

Every reply dictionary carries:

```json
{
  "ok": true,
  "brand": "decrypt.software",
  "version": "1.0.0"
}
```

---

## What it is

Mac **XPC** privilege/crash boundary for FairPlay clear. Hosts talk to `software.decrypt.xpc` instead of running unfairplay in-process.

iPhone FairPlay stays on the installed companion (EmbeddedPayload / cryptid=2). This package is the **decrypt.software** Mac IPC product.

## Ops

| `op` | Role |
|:--|:--|
| `ping` | liveness · `status=alive` |
| `version` | returns **`1.0.0`** + brand |
| `status` | `ready` · hand-rolled XPC |
| `decrypt` | `in_path` → `out_path` (unfairplay, or staged copy) |

### Request

```json
{ "op": "decrypt", "in_path": "…", "out_path": "…" }
```

### Reply

```json
{
  "ok": true,
  "brand": "decrypt.software",
  "version": "1.0.0",
  "status": "decrypted",
  "detail": "unfairplay"
}
```

---

## Build (macOS + Xcode CLT)

```bash
cd DecryptSoftwareXPC
make
```

```text
build/software.decrypt.xpc/Contents/MacOS/software.decrypt.xpc
build/software.decrypt.xpc/Contents/Info.plist
build/ds-xpc
```

Embed `software.decrypt.xpc` in `Contents/XPCServices/`, or register under launchd.

## CLI

```bash
./build/ds-xpc ping
./build/ds-xpc version
./build/ds-xpc status
./build/ds-xpc decrypt ./encrypted.ipa ./clear.ipa
```

`decrypt` prefers `UNFAIRPLAY_BIN` (default `unfairplay`). Without it, bytes are copied and `status=staged`.

---

## Layout

```text
DecryptSoftwareXPC/
  include/ds_xpc.h          # DS_XPC_BRAND · DS_XPC_VERSION · DS_XPC_SERVICE_NAME
  src/ds_xpc_protocol.c
  src/ds_xpc_server.c
  src/ds_xpc_client.c
  macos/main.c
  macos/Info.plist
  client/ds_xpc_cli.c
  docs/README.md
  Makefile
```

**Version source of truth:** `DS_XPC_VERSION` in `include/ds_xpc.h` (`1.0.0`).
