# AirCore protection-analysis modules

This build splits five focused detection profiles into separate Swift files and keeps them connected to the existing `ProtectionAnalysis.scan(ipaURL:)` flow:

- `SSLPinningAnalysis.swift` — trust evaluation, certificate/public-key pinning indicators
- `ReceiptAttestationAnalysis.swift` — App Store receipt, DeviceCheck, and App Attest indicators
- `StoreKitGateAnalysis.swift` — StoreKit purchase and entitlement indicators, labeled **In-app purchase gates**
- `LoadedTweakAnalysis.swift` — dyld image enumeration and instrumentation indicators
- `ScreenCaptureAnalysis.swift` — screenshot/screen-recording observer indicators
- `ProtectionProfile.swift` — shared profile model and registry

The scanner uses the existing Mach-O string sections, imported stub map, ARM64 direct-call scan, function starts, and symbol map. It reports static-analysis leads with virtual addresses/file offsets where available. A match is not proof that the behavior executes, is effective, or is vulnerable; CFG inspection and runtime tests are still required.

## Scope and server note

These modules are detection and authorized-review only. They do not patch or disable third-party app protections, forge receipts, alter purchase state, suppress capture restrictions, or intercept protected traffic. For apps you own, use test certificates/configuration, StoreKit sandbox or StoreKit Configuration files, and explicit development validation modes.

The supplied AirCore project includes a local iOS analysis flow but does not include a Vapor server project or a defined report endpoint. Consequently this package keeps the analysis local and does not invent a server URL or silently upload IPA contents. A Vapor integration can be added once the actual endpoint contract and authentication scheme are available; the appropriate payload is a sanitized findings report, not the binary itself by default.

## Validation

Swift frontend syntax parsing passed for all changed Swift files, including `SigningSheet.swift`. A full iOS build and device/runtime validation were not performed in this environment.

## Read-only patch learning preview

The **Change Impact** sheet now reopens the same local IPA and decodes the original ARM64 instructions around a resolved imported-call site. String-only findings are deliberately not treated as executable code. It also contains a fixed, valid ARM64 lab example showing `B.EQ` (`40 00 00 54`) versus `B.NE` (`41 00 00 54`), explains the condition change, and lists behavior-specific repercussions and verification steps.

The lab patch is isolated from the selected binary: the preview has no save, copy, export, apply, or binary-write operation. It does not synthesize a ready-to-apply patch for arbitrary third-party protection or entitlement checks. The original instructions shown from the selected binary are real; the alternate instruction is explicitly a teaching fixture, not a claim that the selected app contains or should receive that change.
