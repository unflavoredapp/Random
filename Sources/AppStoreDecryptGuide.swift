//
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
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    nonisolated static var failureHint: String {
        let email = UserDefaults.standard.string(forKey: "tetherless.appleid.activeEmailCache") ?? ""
        let who = email.isEmpty ? "this Apple ID" : email
        return "If decrypt failed right after the download, \(who) may never have signed in to the App Store on this iPhone. Sign in once in the App Store (or Settings → your name → Media & Purchases) with that account, then try again. That one-time step stores the decryption keys on the device."
    }
}
