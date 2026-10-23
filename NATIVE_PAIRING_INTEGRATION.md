# SideInstaller native pairing integration (initial build stage)

AirCore now vendors the supplied Rust FFI core under `Native/SideInstallerFFI/` and builds it in GitHub Actions on a macOS runner as `build/native/SideInstallerFFI.xcframework` for iOS device and simulator architectures. The generated XCFramework is linked by `unzip-drop.xcodeproj` and uploaded as a separate CI artifact for diagnostics/reuse.

## What this stage does

- Builds the Rust FFI (`sideinstaller_ffi`) for `aarch64-apple-ios` and `aarch64-apple-ios-sim`.
- Packages the `sideinstaller.h` and `idevice.h` C interface into a `SideInstallerFFI` Clang module.
- Links the resulting static XCFramework into the app target.
- Keeps the existing unsigned IPA build and OTA installer path intact.

## Not yet complete

This does **not** yet ship the pairing UX or a working device tunnel. The supplied `PairingController.swift` depends on SideInstaller-specific application services (`Engine`, `PrivateStore`, `LocalNetworkAuthorization`, `KeepAlive`, `PairingLiveActivity`, etc.). The native implementation also includes a separate `KsignDeviceTunnel` Network Extension, which needs its own Xcode target, extension bundle identifier, entitlements, and signing/provisioning setup. These must be adapted to AirCore rather than copied blindly.

The CI workflow is the first integration milestone: it will fail early if the Rust core cannot compile for the requested Apple targets. Once it succeeds, the next patch can adapt the Swift controller to AirCore and add the tunnel extension target. Physical iOS testing remains necessary to verify pairing, VPN/tunnel establishment, and app installation.
