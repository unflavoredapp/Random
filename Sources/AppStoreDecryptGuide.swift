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
        // Prefer the App Store URL scheme; fall back to https (no LSApplicationQueriesSchemes needed for open).
        if let app = URL(string: "itms-apps://apps.apple.com") {
            UIApplication.shared.open(app) { ok in
                if !ok, let web = URL(string: "https://apps.apple.com") {
                    UIApplication.shared.open(web)
                }
            }
            return
        }
        if let web = URL(string: "https://apps.apple.com") {
            UIApplication.shared.open(web)
        }
    }

    /// Opens iOS Settings (best public entry for Apple Account / Media & Purchases).
    static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    static let failureHint =
        "If decrypt failed right after the download, this Apple ID may never have signed in to the App Store on this iPhone. Sign in once in the App Store (or Settings → your name → Media & Purchases), then try again. That one-time step stores the decryption keys on the device."
}
