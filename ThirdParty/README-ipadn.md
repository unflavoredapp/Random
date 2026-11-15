# iPadn (optional)

Upstream: https://github.com/mengangs/ipadn (GPL-2.0)

- **`ThirdParty/ipadn`** — git submodule of the full upstream tree (reference / attribution).
- **`ThirdParty/ipadn-LICENSE.txt`** — GPL-2.0 license text.
- **`Sources/IPadn/`** — namespaced ports of:
  - **Search** — keyword / App ID / multi-region / delisted stubs
  - **Store login** — bag.xml authenticate, Configurator redirects, AMD proof loop → `StorefrontSession` (wired into Settings › Store Access)
  - **WASM SAPRuntime** — `IPadnWASMSPSigner` + `IPadnLoopbackServer` + bundled `Resources/SAPRuntime` (`sap.wasm`, ADI libs) for ActionSignature and ADI store-proof headers (AMD-Action SP/RP), matching iPadn’s path. Provenance: `Sources/IPadn/Resources/SAPRuntime/PROVENANCE.json`.
- Primary login uses WASM store-proof. If WASM fails, login falls back once to native **StoreSAP** + **Anisette** AMD.

Enable search in **Settings → iPadn search**. Store login runs automatically on Sign In / Retry Store unlock.
