//
//  FairPlayKeyGate.swift
//  Hard gate: require one-time App Store / Media & Purchases sign-in before silent download.
//

import Foundation

enum FairPlayKeyGateError: LocalizedError {
    case notAcknowledged(String)

    var errorDescription: String? {
        switch self {
        case .notAcknowledged(let email):
            let who = email.isEmpty ? "your Store Access Apple ID" : email
            return "Before silent download, sign in once to the App Store (Media & Purchases) with \(who) on this iPhone, then tap “I’ve signed in on this iPhone” under Decrypt. That stores FairPlay keys iOS needs."
        }
    }
}

@MainActor
enum FairPlayKeyGate {
    static var enforce: Bool {
        get { UserDefaults.standard.object(forKey: "tetherless.fairplay.gate") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "tetherless.fairplay.gate") }
    }

    static func requireReady(email: String = AppleIDStore.shared.email) throws {
        guard enforce else { return }
        guard AppleIDStore.shared.isSignedIn else {
            throw DecryptError("Sign in under Settings › Store Access first.")
        }
        guard AppStoreDecryptGuide.isAcknowledged(email: email) else {
            throw FairPlayKeyGateError.notAcknowledged(email)
        }
    }

    static var isReady: Bool {
        AppleIDStore.shared.isSignedIn && AppStoreDecryptGuide.isAcknowledged(email: AppleIDStore.shared.email)
    }
}
