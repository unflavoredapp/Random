# On-device OTA over tetherless.dev

`tetherless.dev` is Decrypt.Team’s replacement for the discontinued **backloop.dev** loopback-HTTPS trick:

1. DNS: `*.tetherless.dev` → `127.0.0.1` (apex stays on the VPS).
2. Apex serves a Feather/backloop-shaped `pack.json` (leaf + split key + CA).
3. The app pulls the pack on launch (`OTABootstrap`) and offers a one-time CA trust profile.

## Generate the pack

```sh
./server/ota/scripts/gen-pack.sh
# → server/ota/public/{pack.json,server.crt,server.pem,ca.crt,commonName.txt}
```

## Deploy

Copy `server/ota/public/pack.json` (and optionally the PEMs) to the tetherless.dev VPS web root so `https://tetherless.dev/pack.json` returns 200.

Or run the **Publish OTA pack to certs branch** workflow; the app falls back to GitHub `certs` when the apex pack is unreachable.

## App settings

Default cert mode is **tetherless.dev pack**. Install host is a random one-label name under `*.tetherless.dev`. After the first pack pull, install the CA profile and enable **Full Trust**.
