//
// Brand: Tetherless · https://tetherless.dev
//  DecryptCompanionHandoff.swift
//  Host → companion readiness snapshot (no passwords / tokens) + trust/resume helpers.
//

import Foundation
import UIKit

/// Safe cross-process hints for the Tetherless Decrypt companion.
/// Never store Apple ID passwords, PETs, or store session JSON here.
/// Entire type is MainActor so FairPlay-ack reads stay isolation-safe under Swift 6.
@MainActor
enum DecryptCompanionHandoff {
    static let suiteName = "group.dev.tetherless.app"
    static let pendingBundleKey = "tetherless.decrypt.pendingCompanionBundle"
    static let pendingEmbedKey = "tetherless.decrypt.pendingEmbeddedName"
    static let pendingAtKey = "tetherless.decrypt.pendingCompanionAt"

    private static var suite: UserDefaults? { UserDefaults(suiteName: suiteName) }
    private static var local: UserDefaults { .standard }

    /// Snapshot the host Apple ID / FairPlay gate state into a plist-safe dictionary.
    /// Calls `AppStoreDecryptGuide.isAcknowledged` (never passwords / tokens).
    static func hostSnapshot() -> [String: Any] {
        let email = (UserDefaults.standard.string(forKey: "tetherless.appleid.activeEmailCache") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hint: String = {
            guard !email.isEmpty else { return "" }
            if let at = email.firstIndex(of: "@") {
                let user = email[..<at]
                let domain = email[email.index(after: at)...]
                let keep = min(2, user.count)
                return String(user.prefix(keep)) + String(repeating: "•", count: max(0, user.count - keep)) + "@" + domain
            }
            return String(email.prefix(2)) + "•••"
        }()
        let storeReady = UserDefaults.standard.bool(forKey: "tetherless.appleid.storeReady")
        return [
            "hostSignedIn": !email.isEmpty,
            "hostStoreReady": storeReady,
            "hostFairPlayAck": AppStoreDecryptGuide.isAcknowledged(email: email),
            "hostEmailHint": hint,
            "hostSnapshotAt": ISO8601DateFormatter().string(from: Date()),
            // Explicit: no secrets.
            "secrets": false,
        ]
    }

    /// Publish snapshot to App Group when the free/paid provision still has the group.
    static func publishHostSnapshot() {
        let snap = hostSnapshot()
        suite?.set(snap, forKey: "companion.hostSnapshot")
        local.set(snap, forKey: "companion.hostSnapshot")
    }

    static func readHostSnapshot(fromManifest manifest: [String: Any]?) -> [String: Any] {
        if let snap = suite?.dictionary(forKey: "companion.hostSnapshot") { return snap }
        if let snap = local.dictionary(forKey: "companion.hostSnapshot") { return snap }
        guard let manifest else { return [:] }
        var out: [String: Any] = [:]
        for key in ["hostSignedIn", "hostStoreReady", "hostFairPlayAck", "hostEmailHint", "hostSnapshotAt"] {
            if let v = manifest[key] { out[key] = v }
        }
        return out
    }

    /// Remember a companion that installed but may still need Trust before it opens.
    static func markPendingOpen(bundleID: String, embeddedName: String) {
        local.set(bundleID, forKey: pendingBundleKey)
        local.set(embeddedName, forKey: pendingEmbedKey)
        local.set(Date().timeIntervalSince1970, forKey: pendingAtKey)
        suite?.set(bundleID, forKey: pendingBundleKey)
        suite?.set(embeddedName, forKey: pendingEmbedKey)
    }

    static func clearPendingOpen() {
        local.removeObject(forKey: pendingBundleKey)
        local.removeObject(forKey: pendingEmbedKey)
        local.removeObject(forKey: pendingAtKey)
        suite?.removeObject(forKey: pendingBundleKey)
        suite?.removeObject(forKey: pendingEmbedKey)
        suite?.removeObject(forKey: pendingAtKey)
    }

    static func pendingOpen() -> (bundleID: String, embeddedName: String)? {
        let bid = (local.string(forKey: pendingBundleKey) ?? suite?.string(forKey: pendingBundleKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (local.string(forKey: pendingEmbedKey) ?? suite?.string(forKey: pendingEmbedKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bid.isEmpty else { return nil }
        let at = local.double(forKey: pendingAtKey)
        // Expire after 30 minutes so stale Trust prompts don't reopen forever.
        if at > 0, Date().timeIntervalSince1970 - at > 30 * 60 {
            clearPendingOpen()
            return nil
        }
        return (bid, name.isEmpty ? "App" : name)
    }

    /// Best public entry for “Trust this developer” after a companion install.
    static func openTrustSettings() {
        // General → VPN & Device Management isn’t a stable public URL; Settings root is.
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    /// On host foreground: retry opening a companion that needed Trust.
    @discardableResult
    static func resumePendingOpenIfNeeded() async -> Bool {
        guard let pending = pendingOpen() else { return false }
        let opened = await DecryptCompanionInstaller.openCompanion(
            bundleID: pending.bundleID,
            embeddedName: pending.embeddedName
        )
        if opened { clearPendingOpen() }
        return opened
    }
}
