# decrypt.software XPC

Hand-rolled **XPC** (C `<xpc/xpc.h>`, not NSXPC proxies) branded **decrypt.software**.

| | |
|---|---|
| Brand | `decrypt.software` |
| Service | `software.decrypt.xpc` |
| Site | https://decrypt.software |
| Wire | `op` dictionaries: `ping` · `version` · `status` · `decrypt` |

## Why XPC here

The iOS companion path stays an installed FairPlay worker (EmbeddedPayload / cryptid=2). This XPC is the **Mac** privilege/crash boundary and the branded IPC product: host apps talk to `software.decrypt.xpc` instead of shelling unfairplay in-process.

## Build (macOS + Xcode CLT)

```bash
cd DecryptSoftwareXPC
make
```

Produces:

```
build/software.decrypt.xpc/Contents/MacOS/software.decrypt.xpc
build/software.decrypt.xpc/Contents/Info.plist
build/ds-xpc
```

Embed `software.decrypt.xpc` in a Mac app’s `Contents/XPCServices/`, or load it under launchd with matching MachServices.

## CLI

```bash
./build/ds-xpc ping
./build/ds-xpc version
./build/ds-xpc decrypt ./encrypted.ipa ./clear.ipa
```

`decrypt` prefers `UNFAIRPLAY_BIN` (default `unfairplay`). If the backend is missing, the service copies bytes and returns `status=staged` so the XPC path is still testable.

## Protocol (request)

```
{ "op": "decrypt", "in_path": "…", "out_path": "…" }
```

## Protocol (reply)

```
{ "ok": true, "brand": "decrypt.software", "version": "1.0.0", "status": "…", "detail": "…" }
```

## Layout

```
DecryptSoftwareXPC/
  include/ds_xpc.h
  src/ds_xpc_protocol.c
  src/ds_xpc_server.c
  src/ds_xpc_client.c
  macos/main.c
  macos/Info.plist
  client/ds_xpc_cli.c
  Makefile
```
