# Build compatibility fix

The project previously allowed SwiftPM to select the newest Vapor 4 release. Newer Vapor
releases can pull Swift Crypto 4.x, whose `CryptoExtras` sources require a newer Swift package
graph than this app's existing iOS target expected.

This revision pins:
- Vapor 4.104.0
- swift-crypto 3.13.0
- project Swift language mode 5.10
- GitHub Actions Xcode 26.2

The exact compiler diagnostic in the screenshot was truncated, so this is a dependency-graph
fix targeted at the visible `CryptoExtras`/`RSA*.swift` failure rather than a claim that every
possible CI failure is resolved.

