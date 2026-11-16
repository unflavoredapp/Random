# iPadn (store login + download)

Upstream: https://github.com/mengangs/ipadn (GPL-2.0)

- **`ThirdParty/ipadn`** — git submodule of the full upstream tree (reference / attribution).
- **`ThirdParty/ipadn-LICENSE.txt`** — GPL-2.0 license text.
- **`Sources/IPadn/`** — namespaced ports of:
  - **Search** — keyword / App ID / multi-region / delisted stubs
  - **Store login** — bag.xml authenticate, Configurator redirects, AMD proof loop → `StorefrontSession` (Account tab)
  - **Store download** — DownloadDispatch `ent/download` + WASM `kbsync` (`IPadnStoreDownload`)
  - **WASM SAPRuntime** — `IPadnWASMSPSigner` + `IPadnLoopbackServer` + bundled `Resources/SAPRuntime` (`sap.wasm`, ADI libs) for ActionSignature and ADI store-proof headers (AMD-Action SP/RP), matching iPadn’s path. Provenance: `Sources/IPadn/Resources/SAPRuntime/PROVENANCE.json`.

FairPlay decrypt and TrustCore signing stay in TetherLess. Do not stack the legacy Store Access / volumeStore / remint / tetherless.dev anisette path on top of iPadn Get/Download.
