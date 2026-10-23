# Native install (built-in VPN + device pairing)

Settings › **Install Method** switches every install (Signed, Library, Sign sheet, notification deep link)
between **OTA** (itms-services over the AirShare domain, unchanged) and **Native** (straight to this device
through idevice — no domain, TLS cert or install prompt).

## What was added
- `Sources/Device/*` — connection manager, local VPN controller, on-device pairing (iOS 27+), keychain pairing
  store, "restore my VPN" shortcut handoff, `NativeInstaller` + progress banner.
- `AirShareDeviceTunnel/` — packet-tunnel extension (`<app id>.DeviceTunnel`) that reflects the loopback /32.
- `Native/Device/*` + `.github/scripts/*` — pinned idevice Rust source, pairing bridge, IDeviceKit overlays.
  `build.sh` fetches IDeviceKit (`fetch_devicekit.py`), patches it, builds `IDevice.xcframework`, then archives.
- Project: `AirShareDeviceTunnel` target embedded in the app, local `IDeviceKit` package (IDeviceSwift + IDevice).
- `unzip-drop.entitlements` / extension entitlements: `packet-tunnel-provider`.

## Requirements
- Sign the app AND the appex with a profile that authorizes Network Extensions → packet-tunnel-provider
  (same team, matching bundle-id prefix). Ad-hoc signing only preserves the request.
- Built-in pairing on-device: iOS 27+, Developer Mode, Local Network permission, one-time PIN.
  Older iOS: Manual Setup with an imported `pairingFile.plist` + your own local VPN.
- First CI run compiles Rust for device + simulator (slow); later runs reuse the cache.

## CI
`build-unsigned-ipa.yml` now also runs `test_native_cache.py`, caches the idevice build, and by default
ad-hoc signs with the entitlement files (input `adhoc_entitlements`) so the request survives into your signer.

## Uninstalling apps
Settings › Install method › **Installed apps** lists the user-installed apps on this device (read from the device's
installer over the same VPN + pairing connection) and removes them with a swipe or long-press, after a confirmation.
`InstallationProxy.listUserApps()` / `.uninstall(bundleID:)` (Native/Device overlay) wrap idevice's
`installation_proxy_get_apps` and `installation_proxy_uninstall_with_callback`; `DeviceInstallationManager.installedApps` /
`.uninstall` run them under the same admission rules as installs. An uninstalled app is also dropped from auto-update tracking.
AirShare itself is hidden and refused.

Bulk uninstall mirrors bulk install: in **Installed apps** tap **Select**, pick apps (or long-press › Select Several), then
**Uninstall N Apps**. `NativeBatchUninstaller` runs them in one native session (shared tunnel, two in flight, pause/resume,
background hold, summary notification) and shows the same progress sheet as `BatchInstallSheet`.

## Device apps in the Library
Library › **On this device** lists every user-installed app (cached on disk; refreshed automatically when Native is selected
and the list is older than 5 minutes, or with the refresh button). App Store apps (Apple's own signature) that have no decrypted
copy in the Library show a red lock + **DRM · Locked**; tapping one offers **Decrypt**, which opens the Decrypt tab with the app's
name in the search box (`DecryptClient.sendToDecrypt`). Other apps show **Installed**. Both offer **Uninstall**.
DRM detection reads the device's `SignerIdentity` ("Apple iPhone OS Application Signing") / `ApplicationDSID`; icons come from SpringBoard.

## Device app tools
- **System apps are never listed.** The device is asked for `ApplicationType = User` with only the attributes AirShare needs
  (`installation_proxy_browse` + `ReturnAttributes`; `get_apps` is the fallback), and anything not `User`, plus Apple's built-in
  `com.apple.*` bundles that aren't App Store apps, is dropped.
- **Sizes** (static + data) show in Library and Installed apps; Installed apps can sort by Size and shows the total.
- **Clean up leftover uploads** (Installed apps) deletes stranded IPAs in the device's `/PublicStaging`; refused while an install runs.
- **Undo / Clean Reinstall**: after uninstalling an app you signed in AirShare, an Undo banner reinstalls the signed copy (without its
  data). Long-press › Clean Reinstall (or Library › app › Clean Reinstall) uninstalls then installs the newest signed copy.
- **Expiry radar**: apps you signed show "Expires in Nd" (Library pill within 7 days); one local notification per signing
  certificate fires two days before it expires. Toggle: Installed apps › Remind me before certificates expire.
- **App sets**: Installed apps › Select › Save Set; Installed apps › stack icon › App sets to install or uninstall a whole set.
- **Resumable batches**: batch installs and uninstalls are saved as they run. If iOS killed AirShare mid-batch, a banner offers
  to finish (or discard) what was left.
