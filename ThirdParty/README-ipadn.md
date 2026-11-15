# iPadn (optional)

Upstream: https://github.com/mengangs/ipadn (GPL-2.0)

- **`ThirdParty/ipadn`** — git submodule of the full upstream tree (reference / attribution).
- **`ThirdParty/ipadn-LICENSE.txt`** — GPL-2.0 license text.
- **`Sources/IPadn/`** — namespaced ports of:
  - **Search** — keyword / App ID / multi-region / delisted stubs
  - **Store login** — bag.xml authenticate, Configurator redirects, AMD proof loop → `StorefrontSession` (wired into Settings › Store Access)
- ActionSignature uses TetherLess **StoreSAP** (native). AMD uses **Anisette**. We do **not** compile iPadn’s WASM SAPRuntime / ADI into the app.

Enable search in **Settings → iPadn search**. Store login runs automatically on Sign In / Retry Store unlock.
