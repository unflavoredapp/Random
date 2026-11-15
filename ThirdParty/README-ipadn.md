# iPadn (optional)

Upstream: https://github.com/mengangs/ipadn (GPL-2.0)

- **`ThirdParty/ipadn`** — git submodule of the full upstream tree (reference / attribution).
- **`ThirdParty/ipadn-LICENSE.txt`** — GPL-2.0 license text.
- **`Sources/IPadn/`** — namespaced port of iPadn’s public store search (keyword, App ID, App Store link, multi-region / delisted stubs). Decrypt handoff uses TetherLess FairPlay / Installed — we do **not** compile iPadn’s WASM SAPRuntime or installer into the app (avoids collisions with existing AppleServices).

Enable in **Settings → iPadn search**, then use **Decrypt → iPadn Search**.
