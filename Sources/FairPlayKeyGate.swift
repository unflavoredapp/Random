//
// Brand: AppAssassin · https://fastdecrypt.ai
//  FairPlayKeyGate.swift
//  Hard gate: finish Apple ID → Store → FairPlay keys on the *host* before
//  packaging / opening FastDecryptBot. Keys cannot be pushed into the companion.
//

import Foundation

enum FairPlayKeyGateError: LocalizedError {
    case needsAppleIDLogin
    case needsStoreLogin(String)
    case notAcknowledged(String)
    case needsLiveInstall(bundleID: String, name: String)
    /// App may be installed, but LaunchServices/installd path is invisible without Native.
    case cannotSeeLiveInstall(bundleID: String, name: String)
    /// Live-install gate cannot run without a target bid — packaging would stamp the wrong app.
    case missingBundleID(name: String)

    var errorDescription: String? {
        switch self {
        case .needsAppleIDLogin:
            return "Sign in with Apple ID in Settings before FastDecryptBot. FairPlay keys stay on this iPhone — they cannot be pushed into the companion."
        case .needsStoreLogin(let email):
            let who = email.isEmpty ? "your Apple Account" : email
            return "Unlock Store login for \(who) in Settings (second Allow + code) before FastDecryptBot. Purchases / Media & Purchases must be ready on this iPhone."
        case .notAcknowledged(let email):
            let who = email.isEmpty ? "your Apple Account" : email
            return "Before companion decrypt, capture FairPlay keys for \(who): open App Store Account Settings (or Media & Purchases), sign in once as that Apple ID, then tap Confirm keys in AppAssassin."
        case .needsLiveInstall(let bid, let name):
            let label = name.isEmpty ? bid : name
            return "Optional check: install \(label) from the App Store on this iPhone (same Apple ID) so you know the license works. FairPlay decrypt itself uses EmbeddedPayload inside FastDecryptBot (iOS 16+ · Developer Mode)."
        case .cannotSeeLiveInstall(let bid, let name):
            let label = name.isEmpty ? bid : name
            return "\(label) may already be installed, but this sideloaded build can’t see its live App Store path yet. That path is optional for FairPlay — continue Get to embed Mach-Os + SC_Info, or Pair Native if you want the live-path hint stamped."
        case .missingBundleID(let name):
            let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let who = label.isEmpty ? "this app" : label
            return "Couldn't determine bundle ID for \(who). Re-run Get / Search so Store IPA Info.plist (or iTunesMetadata) includes CFBundleIdentifier before FastDecryptBot."
        }
    }
}

@MainActor
enum FairPlayKeyGate {
    private static let pendingSearchRetryKey = "tetherless.fairplay.pendingSearchRetry"

    static var enforce: Bool {
        get { UserDefaults.standard.object(forKey: "tetherless.fairplay.gate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tetherless.fairplay.gate") }
    }

    /// Soft live-install check before Get. FairPlayed remaps from EmbeddedPayload;
    /// live path is optional ownership/diagnostics. Default off.
    static var requireLiveInstallForCompanion: Bool {
        get { UserDefaults.standard.bool(forKey: "tetherless.fairplay.requireLiveInstall") }
        set { UserDefaults.standard.set(newValue, forKey: "tetherless.fairplay.requireLiveInstall") }
    }

    /// Remember that Search Get failed only for missing FairPlay ack — resume after Confirm.
    static func rememberPendingSearchRetry() {
        UserDefaults.standard.set(true, forKey: pendingSearchRetryKey)
    }

    static func clearPendingSearchRetry() {
        UserDefaults.standard.set(false, forKey: pendingSearchRetryKey)
    }

    /// After Confirm keys, retry the Search decrypt that was waiting on Media & Purchases.
    @discardableResult
    static func resumePendingSearchRetryIfNeeded() -> Bool {
        guard UserDefaults.standard.bool(forKey: pendingSearchRetryKey) else { return false }
        clearPendingSearchRetry()
        guard let app = DecryptClient.shared.selected else { return false }
        DeviceDecryptService.shared.decryptFromSearch(
            app,
            version: app.version.isEmpty ? nil : app.version,
            externalVersionId: app.externalVersionId.isEmpty ? nil : app.externalVersionId
        )
        return true
    }

    /// Ordered host readiness: Apple ID → Store unlock → FairPlay keys ack.
    /// Presents the matching Settings sheet and throws — never continues to companion.
    static func requireReady(email: String? = nil) throws {
        guard enforce else { return }

        let store = AppleIDStore.shared
        if !store.isSignedIn {
            AppNav.shared.goAppleIDLogin()
            throw FairPlayKeyGateError.needsAppleIDLogin
        }

        let email = (email ?? store.email).trimmingCharacters(in: .whitespacesAndNewlines)
        // Store step 2 must finish before keys / companion (separate sheet from Apple ID).
        if store.storeNeedsVerification
            || (!store.storeReady && store.isSignedIn)
            || (store.isSignedIn && !store.hasStoreDownloadSession) {
            AppNav.shared.goStoreUnlock()
            throw FairPlayKeyGateError.needsStoreLogin(email)
        }

        guard AppStoreDecryptGuide.isAcknowledged(email: email) else {
            FairPlayKeysFetcher.shared.presentCaptureSheet()
            throw FairPlayKeyGateError.notAcknowledged(email)
        }
    }

    static var isReady: Bool {
        let store = AppleIDStore.shared
        guard store.isSignedIn else { return false }
        if store.storeNeedsVerification { return false }
        if !store.storeReady { return false }
        if !store.hasStoreDownloadSession { return false }
        return AppStoreDecryptGuide.isAcknowledged(email: store.email)
    }

    /// Resolve a live Store `.app` path for `bundleID`, refreshing Native DeviceLibrary first.
    /// Sideloaded hosts often get nil from LaunchServices until installd Path is known.
    static func resolveLiveInstallURL(bundleID: String, progress: ((String) -> Void)? = nil) async -> URL? {
        let bid = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bid.isEmpty else { return nil }

        func lookup() -> URL? {
            let known = DeviceLibrary.shared.apps.first {
                $0.bundleID.caseInsensitiveCompare(bid) == .orderedSame
            }?.installPath
            let live = FairPlayDecrypt.installedAppURL(bundleID: bid, knownPath: known)
            guard let live, FairPlayDecrypt.isLiveAppStoreInstall(live) else { return nil }
            return live
        }

        if let hit = lookup() { return hit }

        progress?("Refreshing Installed apps for live path…")
        _ = await DeviceLibrary.shared.refreshAwaiting()
        if let hit = lookup() { return hit }

        // One more LS/MI pass after library refresh — pathFallback / workspace enum.
        return FairPlayDecrypt.installedAppURL(bundleID: bid).flatMap {
            FairPlayDecrypt.isLiveAppStoreInstall($0) ? $0 : nil
        }
    }

    /// Visible host step before packaging/opening the companion: confirm Apple ID,
    /// Store unlock, Media & Purchases ack, optional live install — then publish snapshot.
    @discardableResult
    static func confirmReadyForCompanion(
        bundleID: String? = nil,
        displayName: String? = nil,
        progress: ((String) -> Void)? = nil
    ) async throws -> String {
        let store = AppleIDStore.shared
        let email = store.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = email.isEmpty ? "your Apple Account" : email

        progress?("Checking Apple ID…")
        if !store.isSignedIn {
            progress?("Open Settings → Apple ID login…")
            AppNav.shared.goAppleIDLogin()
            throw FairPlayKeyGateError.needsAppleIDLogin
        }

        progress?("Checking Store login…")
        // Match the green Store seal — sticky storeReady alone can be true with a dead session.
        if store.storeNeedsVerification || !store.storeReady || !store.hasStoreDownloadSession {
            progress?("Open Settings → Show Store login…")
            AppNav.shared.goStoreUnlock()
            throw FairPlayKeyGateError.needsStoreLogin(email)
        }

        progress?("Confirming FairPlay keys for \(who)…")
        try requireReady(email: email.isEmpty ? nil : email)

        let bid = (bundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Bundle ID is still required so packaging stamps the correct target.
        if bid.isEmpty {
            progress?("Missing bundle ID — cannot package FastDecryptBot for the right app…")
            throw FairPlayKeyGateError.missingBundleID(name: name)
        }
        progress?("Checking live App Store install for \(bid) (optional hint)…")
        if let live = await resolveLiveInstallURL(bundleID: bid, progress: progress) {
            DecryptCompanionHandoff.publishLiveInstallPath(live.path, bundleID: bid)
            progress?("Live install path (hint): \(live.path)")
        } else if requireLiveInstallForCompanion {
            let inLibrary = DeviceLibrary.shared.apps.contains {
                $0.bundleID.caseInsensitiveCompare(bid) == .orderedSame
            }
            let paired = DevicePairingStore.hasSavedPairing
            let native = NativeInstaller.isSelected
            if inLibrary || paired || native || DeviceLibrary.shared.apps.isEmpty {
                progress?(
                    "Live install path: (none visible) — Pair Native + refresh Installed, then retry Get…"
                )
                AppNav.shared.goPair()
                throw FairPlayKeyGateError.cannotSeeLiveInstall(bundleID: bid, name: name)
            }
            progress?("Live install path: (none) — install \(name.isEmpty ? bid : name) from the App Store, then retry Get…")
            AppStoreDecryptGuide.openAppStore()
            throw FairPlayKeyGateError.needsLiveInstall(bundleID: bid, name: name)
        } else {
            progress?(
                "No live path for \(bid) — OK. FairPlay uses EmbeddedPayload (Developer Mode · iOS 16+)."
            )
        }

        // Companion reads email / ack / live path via App Group — publish before packaging.
        DecryptCompanionHandoff.publishHostSnapshot()
        if enforce {
            progress?("FairPlay ready on host · \(who) — packaging FastDecryptBot…")
        } else {
            progress?("FairPlay key gate off — continuing without Media & Purchases ack")
        }
        return email
    }
}
