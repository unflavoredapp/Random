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
    /// Metadata for a clear IPA the companion wants the host to import.
    static let clearExportMetaKey = "companion.clearIPA.export"
    static let clearExportDirName = "ClearExports"
    /// Host deep link — companion opens this after publishing a clear IPA.
    static let hostImportURLString = "tetherless://decrypt-export"

    private static var suite: UserDefaults? { UserDefaults(suiteName: suiteName) }
    private static var local: UserDefaults { .standard }

    /// App Group container when the provision still includes the group entitlement.
    static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)
    }

    /// True when we can read/write the shared group container (host + companion both need the group).
    static var appGroupAvailable: Bool {
        guard let root = sharedContainerURL else { return false }
        let probe = root.appendingPathComponent(".tl-group-probe")
        do {
            try "ok".write(to: probe, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    /// Companion → host clear-IPA export record (no secrets).
    struct ClearIPAExport: Codable, Equatable {
        var fileName: String
        var displayName: String
        var bundleID: String
        var version: String
        var verifySummary: String
        var exportedAt: TimeInterval
        /// Path relative to the App Group container (e.g. `ClearExports/Foo-decrypted.ipa`).
        var relativePath: String
        var bytes: Int64
    }

    private static let liveInstallPathKey = "companion.hostLiveInstallPath"
    private static let liveInstallBundleKey = "companion.hostLiveInstallBundleID"

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
        var snap: [String: Any] = [
            "hostSignedIn": !email.isEmpty,
            "hostStoreReady": storeReady,
            "hostFairPlayAck": AppStoreDecryptGuide.isAcknowledged(email: email),
            "hostEmailHint": hint,
            "hostSnapshotAt": ISO8601DateFormatter().string(from: Date()),
            // Explicit: no secrets.
            "secrets": false,
        ]
        // Carry the last stamped live Store path so the companion can FairPlay-mremap
        // even when LS/MI inside the companion sandbox can't resolve the app.
        if let path = (suite?.string(forKey: liveInstallPathKey) ?? local.string(forKey: liveInstallPathKey))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            snap["hostLiveInstallPath"] = path
        }
        if let bid = (suite?.string(forKey: liveInstallBundleKey) ?? local.string(forKey: liveInstallBundleKey))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bid.isEmpty {
            snap["bundleID"] = bid
        }
        return snap
    }

    /// Publish snapshot to App Group when the free/paid provision still has the group.
    static func publishHostSnapshot() {
        let snap = hostSnapshot()
        suite?.set(snap, forKey: "companion.hostSnapshot")
        local.set(snap, forKey: "companion.hostSnapshot")
    }

    /// Remember the live App Store `.app` path for the companion (Roblox EPERM path).
    static func publishLiveInstallPath(_ path: String, bundleID: String) {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let bid = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else {
            clearLiveInstallPath()
            return
        }
        suite?.set(p, forKey: liveInstallPathKey)
        local.set(p, forKey: liveInstallPathKey)
        if !bid.isEmpty {
            suite?.set(bid, forKey: liveInstallBundleKey)
            local.set(bid, forKey: liveInstallBundleKey)
        }
        publishHostSnapshot()
    }

    static func clearLiveInstallPath() {
        suite?.removeObject(forKey: liveInstallPathKey)
        local.removeObject(forKey: liveInstallPathKey)
        suite?.removeObject(forKey: liveInstallBundleKey)
        local.removeObject(forKey: liveInstallBundleKey)
        publishHostSnapshot()
    }

    /// Live Store path published by the host packager (App Group / local fallback).
    static func readLiveInstallPath() -> (path: String, bundleID: String)? {
        let path = (suite?.string(forKey: liveInstallPathKey)
            ?? local.string(forKey: liveInstallPathKey)
            ?? (suite?.dictionary(forKey: "companion.hostSnapshot")?["hostLiveInstallPath"] as? String)
            ?? (local.dictionary(forKey: "companion.hostSnapshot")?["hostLiveInstallPath"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return nil }
        let bid = (suite?.string(forKey: liveInstallBundleKey)
            ?? local.string(forKey: liveInstallBundleKey)
            ?? (suite?.dictionary(forKey: "companion.hostSnapshot")?["bundleID"] as? String)
            ?? (local.dictionary(forKey: "companion.hostSnapshot")?["bundleID"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (path, bid)
    }

    static func readHostSnapshot(fromManifest manifest: [String: Any]?) -> [String: Any] {
        if let snap = suite?.dictionary(forKey: "companion.hostSnapshot") { return snap }
        if let snap = local.dictionary(forKey: "companion.hostSnapshot") { return snap }
        guard let manifest else { return [:] }
        var out: [String: Any] = [:]
        for key in [
            "hostSignedIn", "hostStoreReady", "hostFairPlayAck", "hostEmailHint",
            "hostSnapshotAt", "hostLiveInstallPath", "bundleID"
        ] {
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

    // MARK: - Clear IPA export (companion → host)

    /// Companion: copy the clear IPA into the App Group and publish metadata.
    /// Returns `true` when the host can import via `consumePendingClearIPAExport()`.
    @discardableResult
    static func publishClearIPAExport(
        ipa: URL,
        displayName: String,
        bundleID: String,
        version: String,
        verifySummary: String
    ) -> Bool {
        guard appGroupAvailable, let root = sharedContainerURL else {
            clearClearIPAExport()
            return false
        }
        let fm = FileManager.default
        let dir = root.appendingPathComponent(clearExportDirName, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = sanitizeFileName(ipa.lastPathComponent.isEmpty ? "\(displayName)-decrypted.ipa" : ipa.lastPathComponent)
        let dest = dir.appendingPathComponent(safe)
        do {
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: ipa, to: dest)
        } catch {
            clearClearIPAExport()
            return false
        }
        let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        let meta = ClearIPAExport(
            fileName: safe,
            displayName: displayName.isEmpty ? dest.deletingPathExtension().lastPathComponent : displayName,
            bundleID: bundleID,
            version: version,
            verifySummary: verifySummary,
            exportedAt: Date().timeIntervalSince1970,
            relativePath: "\(clearExportDirName)/\(safe)",
            bytes: size
        )
        guard let data = try? JSONEncoder().encode(meta) else {
            try? fm.removeItem(at: dest)
            return false
        }
        suite?.set(data, forKey: clearExportMetaKey)
        local.set(data, forKey: clearExportMetaKey)
        return true
    }

    static func clearClearIPAExport() {
        suite?.removeObject(forKey: clearExportMetaKey)
        local.removeObject(forKey: clearExportMetaKey)
    }

    static func pendingClearIPAExport() -> ClearIPAExport? {
        let data = suite?.data(forKey: clearExportMetaKey) ?? local.data(forKey: clearExportMetaKey)
        guard let data, let meta = try? JSONDecoder().decode(ClearIPAExport.self, from: data) else {
            return nil
        }
        // Expire after 2 hours so stale exports don't surprise the user later.
        if Date().timeIntervalSince1970 - meta.exportedAt > 2 * 60 * 60 {
            clearClearIPAExport()
            return nil
        }
        return meta
    }

    /// Companion / host: open the main TetherLess app on the import deep link.
    static func openHostForClearIPAImport() {
        guard let url = URL(string: hostImportURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Host: copy a pending companion clear IPA into `AppPaths.dir("inbox")`, wire DecryptClient,
    /// and attach it to a matching Downloads job when possible.
    @discardableResult
    static func consumePendingClearIPAExport() -> URL? {
        guard let meta = pendingClearIPAExport() else { return nil }
        guard let root = sharedContainerURL else {
            clearClearIPAExport()
            return nil
        }
        let src = root.appendingPathComponent(meta.relativePath)
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            clearClearIPAExport()
            return nil
        }
        let inbox = AppPaths.dir("inbox")
        let dest = inbox.appendingPathComponent(sanitizeFileName(meta.fileName))
        do {
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: src, to: dest)
        } catch {
            return nil
        }
        // Best-effort cleanup of the shared copy (host keeps inbox).
        try? fm.removeItem(at: src)
        clearClearIPAExport()

        DecryptClient.shared.finished = dest
        DecryptClient.shared.finishedName = meta.displayName
        DecryptClient.shared.phase = .done
        DecryptClient.shared.error = nil
        let verify = meta.verifySummary.trimmingCharacters(in: .whitespacesAndNewlines)
        DecryptClient.shared.message = verify.isEmpty
            ? "Imported clear IPA from Tetherless Decrypt."
            : "Imported clear IPA from Tetherless Decrypt · \(verify)"
        SideloadIPACache.shared.remember(url: dest, kind: .decrypted, name: meta.displayName)
        IPadnDownloadManager.shared.attachCompanionClearIPA(
            url: dest,
            displayName: meta.displayName,
            bundleID: meta.bundleID
        )
        return dest
    }

    /// Host: import a clear IPA shared via Open In / Share (App Group unavailable path).
    @discardableResult
    static func importSharedClearIPA(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        guard url.pathExtension.lowercased() == "ipa" else { return nil }
        let inbox = AppPaths.dir("inbox")
        let dest = inbox.appendingPathComponent(sanitizeFileName(url.lastPathComponent))
        do {
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: url, to: dest)
        } catch {
            return nil
        }
        let name = dest.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-decrypted", with: "")
        DecryptClient.shared.finished = dest
        DecryptClient.shared.finishedName = name
        DecryptClient.shared.phase = .done
        DecryptClient.shared.error = nil
        DecryptClient.shared.message = "Imported clear IPA from Share."
        SideloadIPACache.shared.remember(url: dest, kind: .decrypted, name: name)
        IPadnDownloadManager.shared.attachCompanionClearIPA(
            url: dest,
            displayName: name,
            bundleID: ""
        )
        return dest
    }

    private static func sanitizeFileName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "decrypted.ipa" : trimmed
        return base
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
    }
}
