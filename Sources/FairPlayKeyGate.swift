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
            return "Install \(label) from the App Store on this iPhone (same Apple ID) before opening FastDecryptBot. fairplayd needs the live install path — EncryptedSource alone often EPERMs."
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

    /// When true (default), refuse companion packaging without a live App Store install
    /// for the target bid — the failure mode in Host EPERM screenshots.
    static var requireLiveInstallForCompanion: Bool {
        get {
            UserDefaults.standard.object(forKey: "tetherless.fairplay.requireLiveInstall") as? Bool ?? true
        }
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
        if store.storeNeedsVerification || (!store.storeReady && store.isSignedIn) {
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
        return AppStoreDecryptGuide.isAcknowledged(email: store.email)
    }

    /// Visible host step before packaging/opening the companion: confirm Apple ID,
    /// Store unlock, Media & Purchases ack, optional live install — then publish snapshot.
    @discardableResult
    static func confirmReadyForCompanion(
        bundleID: String? = nil,
        displayName: String? = nil,
        progress: ((String) -> Void)? = nil
    ) throws -> String {
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
        if store.storeNeedsVerification || !store.storeReady {
            progress?("Open Settings → Show Store login…")
            AppNav.shared.goStoreUnlock()
            throw FairPlayKeyGateError.needsStoreLogin(email)
        }

        progress?("Confirming FairPlay keys for \(who)…")
        try requireReady(email: email.isEmpty ? nil : email)

        let bid = (bundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if requireLiveInstallForCompanion, !bid.isEmpty {
            progress?("Checking live App Store install for \(bid)…")
            let known = DeviceLibrary.shared.apps.first(where: { $0.bundleID == bid })?.installPath
            let live = FairPlayDecrypt.installedAppURL(bundleID: bid, knownPath: known)
            if let live, FairPlayDecrypt.isLiveAppStoreInstall(live) {
                DecryptCompanionHandoff.publishLiveInstallPath(live.path, bundleID: bid)
                progress?("Live install ready · \(live.lastPathComponent)")
            } else {
                let name = (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                progress?("Install \(name.isEmpty ? bid : name) from the App Store, then retry Get…")
                AppStoreDecryptGuide.openAppStore()
                throw FairPlayKeyGateError.needsLiveInstall(bundleID: bid, name: name)
            }
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
