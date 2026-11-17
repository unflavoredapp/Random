//
// Brand: Tetherless · https://tetherless.dev
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
            return "Before companion decrypt, capture FairPlay keys for \(who): open App Store / Media & Purchases, sign in once on this iPhone, then confirm in Get FairPlay keys."
        }
    }
}

@MainActor
enum FairPlayKeyGate {
    static var enforce: Bool {
        get { UserDefaults.standard.object(forKey: "tetherless.fairplay.gate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tetherless.fairplay.gate") }
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
