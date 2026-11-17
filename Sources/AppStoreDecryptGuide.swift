//
// Brand: Tetherless · https://tetherless.dev
//  AppStoreDecryptGuide.swift
//  One-time App Store sign-in is required so iOS has decryption keys for an Apple ID.
//  TetherLess cannot mint those keys; this helper opens the App Store and tracks “I’ve signed in.”
//

import Foundation
import SwiftUI
import UIKit

@MainActor
enum AppStoreDecryptGuide {
    private static let ackPrefix = "tetherless.decrypt.appStoreSignInAck."

    /// Per–Apple ID acknowledgment that the user completed the one-time App Store sign-in on this device.
    static func isAcknowledged(email: String) -> Bool {
        let key = ackKey(email)
        guard !key.isEmpty else { return false }
        return UserDefaults.standard.bool(forKey: key)
    }

    static func setAcknowledged(_ on: Bool, email: String) {
        let key = ackKey(email)
        guard !key.isEmpty else { return }
        UserDefaults.standard.set(on, forKey: key)
    }

    static func ackKey(_ email: String) -> String {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !e.isEmpty else { return "" }
        return ackPrefix + e
    }

    /// Opens the App Store so the user can sign in with the decrypt Apple ID once.
    static func openAppStore() {
        open(urlString: "itms-apps://apps.apple.com", fallback: "https://apps.apple.com")
    }

    /// Best entry for FairPlay key capture: App Store account sheet (`itms-ui://`).
    /// Prefer account / purchase history so the user authenticates as the decrypt Apple ID.
    static func openAppStoreAccountSheet() {
        openCascade([
            "itms-ui://",
            "itms-apps://apps.apple.com/account",
            "itms-apps://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/purchaseHistory",
            "itms-apps://apps.apple.com",
            "https://apps.apple.com/account",
        ])
    }

    /// Purchase History often re-auths Media & Purchases for the active Apple ID.
    static func openPurchaseHistory() {
        openCascade([
            "itms-apps://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/purchaseHistory",
            "itms-ui://",
            "itms-apps://apps.apple.com/account",
            "https://apps.apple.com/account",
        ])
    }

    /// Settings → Apple Account → Media & Purchases (with public fallbacks).
    static func openMediaAndPurchases() {
        openCascade([
            "settings-navigation://com.apple.Settings.AppleAccount/STORE_SERVICE",
            "App-prefs:root=APPLE_ACCOUNT&path=STORE_SERVICE",
            "prefs:root=APPLE_ACCOUNT&path=STORE_SERVICE",
            UIApplication.openSettingsURLString,
        ])
    }

    private static func openCascade(_ urls: [String]) {
        func tryNext(_ index: Int) {
            guard index < urls.count else { return }
            guard let url = URL(string: urls[index]) else {
                tryNext(index + 1)
                return
            }
            UIApplication.shared.open(url) { ok in
                if !ok { tryNext(index + 1) }
            }
        }
        tryNext(0)
    }

    /// Opens a specific App Store product page (https or itms-apps) so the user can install with their own Apple ID.
    static func openAppStoreListing(_ storeURL: String) {
        let trimmed = storeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            openAppStore()
            return
        }
        // Prefer the App Store client scheme when given an https apps.apple.com link.
        if let https = URL(string: trimmed),
           let host = https.host?.lowercased(),
           host.contains("apps.apple.com") || host.contains("itunes.apple.com") {
            var comps = URLComponents(url: https, resolvingAgainstBaseURL: false)
            comps?.scheme = "itms-apps"
            if let itms = comps?.url?.absoluteString {
                open(urlString: itms, fallback: trimmed)
                return
            }
        }
        open(urlString: trimmed, fallback: "https://apps.apple.com")
    }

    private static func open(urlString: String, fallback: String) {
        if let app = URL(string: urlString) {
            UIApplication.shared.open(app) { ok in
                if !ok, let web = URL(string: fallback) {
                    UIApplication.shared.open(web)
                }
            }
            return
        }
        if let web = URL(string: fallback) {
            UIApplication.shared.open(web)
        }
    }

    /// Opens iOS Settings (best public entry for Apple Account / Media & Purchases).
    static func openSystemSettings() {
        openMediaAndPurchases()
    }

    nonisolated static var failureHint: String {
        let who = owningAppleIDDescription()
        return "FairPlay needs \(who)’s decryption keys on this iPhone. Sign in once in the App Store (or Settings → your name → Media & Purchases) with that account, keep ownership of the app, then try again. That one-time step stores the keys — switching the active App Store account afterward is fine."
    }

    /// Host email from standard defaults, App Group cache, or companion host snapshot.
    nonisolated private static func owningAppleIDDescription() -> String {
        let key = "tetherless.appleid.activeEmailCache"
        if let email = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            return email
        }
        if let email = UserDefaults(suiteName: "group.dev.tetherless.app")?
            .string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            return email
        }
        if let snap = UserDefaults(suiteName: "group.dev.tetherless.app")?
            .dictionary(forKey: "companion.hostSnapshot"),
           let email = (snap["hostEmail"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            return email
        }
        return "this Apple ID"
    }
}
