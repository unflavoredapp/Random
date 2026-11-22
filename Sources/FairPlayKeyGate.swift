//
// Brand: AppAssassin · https://fastdecrypt.ai
//  FairPlayKeyGate.swift
//  Hard gate: require one-time App Store / Media & Purchases sign-in before silent download.
//

import Foundation

enum FairPlayKeyGateError: LocalizedError {
    case notAcknowledged(String)

    var errorDescription: String? {
        switch self {
        case .notAcknowledged(let email):
            let who = email.isEmpty ? "your Apple Account" : email
            return "Before companion decrypt, capture FairPlay keys for \(who): open App Store Account Settings (or Media & Purchases), sign in once as that Apple ID, then tap Confirm keys in AppAssassin."
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

    /// Resolve email inside the body — default-arg expressions are nonisolated and
    /// cannot read `@MainActor` `AppleIDStore.shared.email` (Xcode 16 EmitSwiftModule).
    static func requireReady(email: String? = nil) throws {
        guard enforce else { return }
        guard AppleIDStore.shared.isSignedIn else {
            throw DecryptError("Sign in under Account first.")
        }
        let email = email ?? AppleIDStore.shared.email
        guard AppStoreDecryptGuide.isAcknowledged(email: email) else {
            // Surface the capture sheet so the user can finish Media & Purchases without hunting.
            FairPlayKeysFetcher.shared.presentCaptureSheet()
            throw FairPlayKeyGateError.notAcknowledged(email)
        }
    }

    static var isReady: Bool {
        AppleIDStore.shared.isSignedIn && AppStoreDecryptGuide.isAcknowledged(email: AppleIDStore.shared.email)
    }

    /// Visible host step before packaging/opening the companion: confirm Media & Purchases
    /// ack for the active Apple ID, publish the snapshot to App Group, report progress.
    @discardableResult
    static func confirmReadyForCompanion(progress: ((String) -> Void)? = nil) throws -> String {
        let email = AppleIDStore.shared.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let who = email.isEmpty ? "your Apple Account" : email
        progress?("Confirming FairPlay keys for \(who)…")
        try requireReady(email: email.isEmpty ? nil : email)
        // Companion reads email / ack via App Group — publish before packaging.
        DecryptCompanionHandoff.publishHostSnapshot()
        if enforce {
            progress?("FairPlay keys ready · \(who)")
        } else {
            progress?("FairPlay key gate off — continuing without Media & Purchases ack")
        }
        return email
    }
}
