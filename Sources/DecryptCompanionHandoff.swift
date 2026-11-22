//
// Brand: Tetherless · https://tetherless.dev
//  DecryptCompanionHandoff.swift
//  Host → companion readiness snapshot (no passwords / tokens) + trust/resume helpers.
//

import Foundation
import UIKit

/// Safe cross-process hints for the AppAssassin Decrypt companion.
/// Never store Apple ID passwords, PETs, or store session JSON here.
/// Entire type is MainActor so FairPlay-ack reads stay isolation-safe under Swift 6.
@MainActor
enum DecryptCompanionHandoff {
    // Path helpers are nonisolated so download jobs / background queues can resolve
    // EncryptedIPAs without hopping onto the main actor (Swift 6 / build #204).
    nonisolated static let suiteName = TetherlessBrand.appGroup
    static let pendingBundleKey = "tetherless.decrypt.pendingCompanionBundle"
    static let pendingEmbedKey = "tetherless.decrypt.pendingEmbeddedName"
    static let pendingAtKey = "tetherless.decrypt.pendingCompanionAt"
    /// Metadata for a clear IPA the companion wants the host to import.
    static let clearExportMetaKey = "companion.clearIPA.export"
    static let clearExportDirName = "ClearExports"
    /// Host deep link — companion opens this after publishing a clear IPA.
    static let hostImportURLString = "appassassin://decrypt-export"
    /// Host deep link — companion opens this after on-device ENOMEM / hard FairPlay fail
    /// so the host can finish via Decrypt site URL (Mac HTTPS API / tetherless.dev).
    static let hostServerFallbackURLString = "appassassin://decrypt-server"
    nonisolated static let encryptedIPADirName = "EncryptedIPAs"
    private static let serverFallbackMetaKey = "companion.serverFallback"
    private static let storeURLKey = "companion.hostStoreURL"
    private static let storeVersionKey = "companion.hostStoreVersion"
    private static let storeDisplayKey = "companion.hostStoreDisplayName"

    private static var suite: UserDefaults? { UserDefaults(suiteName: suiteName) }
    private static var local: UserDefaults { .standard }

    /// App Group container when the provision still includes the group entitlement.
    nonisolated static var sharedContainerURL: URL? {
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
    private static let encryptedIPAPathKey = "companion.hostEncryptedIPAPath"
    private static let encryptedIPABundleKey = "companion.hostEncryptedIPABundleID"

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
            // Explicit: no secrets (password / PET / session never stored).
            "secrets": false,
        ]
        // Advanced FairPlay controls for the companion (source mode, verbose, retries).
        for (k, v) in FairPlayAdvancedOptions.Resolved.current.snapshotFields() {
            snap[k] = v
        }
        // Full email for companion FairPlay failure copy (UserDefaults + App Group).
        if !email.isEmpty {
            snap["hostEmail"] = email
            suite?.set(email, forKey: "tetherless.appleid.activeEmailCache")
            local.set(email, forKey: "tetherless.appleid.activeEmailCache")
        }
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
        // Durable temp Store IPA path — FairPlay / companion can re-open this encrypted package.
        if let path = (suite?.string(forKey: encryptedIPAPathKey) ?? local.string(forKey: encryptedIPAPathKey))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            snap["hostEncryptedIPAPath"] = path
        }
        if let bid = (suite?.string(forKey: encryptedIPABundleKey) ?? local.string(forKey: encryptedIPABundleKey))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bid.isEmpty,
           snap["bundleID"] == nil {
            snap["bundleID"] = bid
        }
        if let url = (suite?.string(forKey: storeURLKey) ?? local.string(forKey: storeURLKey))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty {
            snap["hostStoreURL"] = url
        }
        if let ver = (suite?.string(forKey: storeVersionKey) ?? local.string(forKey: storeVersionKey))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !ver.isEmpty {
            snap["hostStoreVersion"] = ver
        }
        if let name = (suite?.string(forKey: storeDisplayKey) ?? local.string(forKey: storeDisplayKey))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            snap["hostStoreDisplayName"] = name
        }
        return snap
    }

    /// Remember App Store URL / version so companion ENOMEM can bounce to Mac/server decrypt.
    static func publishStoreDecryptTarget(url: String, version: String?, displayName: String, bundleID: String = "") {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let v = (version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let n = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bid = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty else { return }
        suite?.set(u, forKey: storeURLKey)
        local.set(u, forKey: storeURLKey)
        if !v.isEmpty {
            suite?.set(v, forKey: storeVersionKey)
            local.set(v, forKey: storeVersionKey)
        } else {
            suite?.removeObject(forKey: storeVersionKey)
            local.removeObject(forKey: storeVersionKey)
        }
        if !n.isEmpty {
            suite?.set(n, forKey: storeDisplayKey)
            local.set(n, forKey: storeDisplayKey)
        }
        if !bid.isEmpty {
            suite?.set(bid, forKey: encryptedIPABundleKey)
            local.set(bid, forKey: encryptedIPABundleKey)
        }
        publishHostSnapshot()
    }

    struct ServerFallbackRequest: Codable, Equatable {
        var storeURL: String
        var version: String
        var displayName: String
        var bundleID: String
        var reason: String
        var requestedAt: TimeInterval
    }

    /// Companion: after on-device FairPlay can't finish (ENOMEM…), ask host to decrypt on the API host.
    static func requestServerFallback(reason: String) {
        let snap = readHostSnapshot(fromManifest: nil)
        let url = ((snap["hostStoreURL"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        let req = ServerFallbackRequest(
            storeURL: url,
            version: ((snap["hostStoreVersion"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            displayName: ((snap["hostStoreDisplayName"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            bundleID: ((snap["bundleID"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            reason: String(reason.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)),
            requestedAt: Date().timeIntervalSince1970
        )
        guard let data = try? JSONEncoder().encode(req) else { return }
        suite?.set(data, forKey: serverFallbackMetaKey)
        local.set(data, forKey: serverFallbackMetaKey)
        guard let deep = URL(string: hostServerFallbackURLString) else { return }
        UIApplication.shared.open(deep)
    }

    /// Host: start `DecryptClient` against Decrypt site URL (Mac HTTPS / tetherless.dev).
    @discardableResult
    static func consumePendingServerFallback() -> Bool {
        let data = suite?.data(forKey: serverFallbackMetaKey) ?? local.data(forKey: serverFallbackMetaKey)
        suite?.removeObject(forKey: serverFallbackMetaKey)
        local.removeObject(forKey: serverFallbackMetaKey)
        guard let data,
              let req = try? JSONDecoder().decode(ServerFallbackRequest.self, from: data) else {
            return false
        }
        if Date().timeIntervalSince1970 - req.requestedAt > 30 * 60 { return false }
        let url = req.storeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return false }
        let name = req.displayName.isEmpty ? "App" : req.displayName
        let ver = req.version.isEmpty ? nil : req.version
        // Don't set .queued before start() — busy guard would no-op the job.
        DecryptClient.shared.error = nil
        DecryptClient.shared.finishedName = name
        DecryptClient.shared.start(url: url, version: ver, display: name)
        if DecryptClient.shared.busy {
            DecryptClient.shared.message = DecryptMacRouting.macOnly
                ? "Decrypting on server…"
                : "On-device companion FairPlay failed — decrypting on backup server…"
        }
        return true
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

    /// Bundled encrypted IPA name inside the companion `.app` (readable without App Group).
    nonisolated static let bundledEncryptedIPAName = "EncryptedSource.ipa"

    /// Durable folder for App Store encrypted IPAs.
    /// Prefer App Group so the companion can re-open the stamped URL; Documents-only
    /// paths are host-private and caused “No live install / stamped IPA” → EmbeddedPayload EPERM.
    nonisolated static func encryptedIPADirectory() -> URL {
        if let root = sharedContainerURL {
            let dir = root.appendingPathComponent(encryptedIPADirName, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Best-effort migrate leftover host-Documents copies into the group.
            let legacy = AppPaths.documents.appendingPathComponent("encrypted-ipas", isDirectory: true)
            if FileManager.default.fileExists(atPath: legacy.path),
               let items = try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
                for item in items where item.pathExtension.lowercased() == "ipa" {
                    let dest = dir.appendingPathComponent(item.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: dest.path) {
                        try? FileManager.default.copyItem(at: item, to: dest)
                    }
                }
            }
            return dir
        }
        return AppPaths.dir("encrypted-ipas")
    }

    /// True when EncryptedIPAs land in the App Group (companion-readable).
    nonisolated static var encryptedIPADirectoryIsShared: Bool {
        guard let root = sharedContainerURL else { return false }
        let dir = encryptedIPADirectory()
        return dir.path.hasPrefix(root.path)
    }

    /// Copy/move a Store download into the durable temp folder and stamp its URL for FairPlay.
    @discardableResult
    static func retainEncryptedIPA(
        _ source: URL,
        bundleID: String,
        displayName: String
    ) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw DecryptError("Encrypted IPA missing at \(source.lastPathComponent).")
        }
        let bid = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBid = (bid.isEmpty ? "app" : bid)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        let safeName = displayName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        let fileName = "\(safeBid)_\(safeName.isEmpty ? "store" : safeName).ipa"
        let dest = encryptedIPADirectory().appendingPathComponent(fileName)
        if source.standardizedFileURL == dest.standardizedFileURL {
            publishEncryptedIPAPath(dest.path, bundleID: bid)
            return dest
        }
        try? fm.removeItem(at: dest)
        do {
            try fm.copyItem(at: source, to: dest)
        } catch {
            // Same-volume move is fine when copy fails (e.g. already in our temp dir).
            try fm.moveItem(at: source, to: dest)
        }
        publishEncryptedIPAPath(dest.path, bundleID: bid)
        return dest
    }

    static func publishEncryptedIPAPath(_ path: String, bundleID: String) {
        let p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let bid = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty else {
            clearEncryptedIPAPath()
            return
        }
        suite?.set(p, forKey: encryptedIPAPathKey)
        local.set(p, forKey: encryptedIPAPathKey)
        if !bid.isEmpty {
            suite?.set(bid, forKey: encryptedIPABundleKey)
            local.set(bid, forKey: encryptedIPABundleKey)
        }
        publishHostSnapshot()
    }

    static func clearEncryptedIPAPath() {
        suite?.removeObject(forKey: encryptedIPAPathKey)
        local.removeObject(forKey: encryptedIPAPathKey)
        suite?.removeObject(forKey: encryptedIPABundleKey)
        local.removeObject(forKey: encryptedIPABundleKey)
        publishHostSnapshot()
    }

    /// Delete the stamped EncryptedIPAs file (advanced: Keep encrypted IPA off) and clear the stamp.
    static func purgeRetainedEncryptedIPA() {
        if let stamped = readEncryptedIPAPath() {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: stamped.path))
        }
        clearEncryptedIPAPath()
    }

    static func readEncryptedIPAPath() -> (path: String, bundleID: String)? {
        let path = (suite?.string(forKey: encryptedIPAPathKey)
            ?? local.string(forKey: encryptedIPAPathKey)
            ?? (suite?.dictionary(forKey: "companion.hostSnapshot")?["hostEncryptedIPAPath"] as? String)
            ?? (local.dictionary(forKey: "companion.hostSnapshot")?["hostEncryptedIPAPath"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        let bid = (suite?.string(forKey: encryptedIPABundleKey)
            ?? local.string(forKey: encryptedIPABundleKey)
            ?? (suite?.dictionary(forKey: "companion.hostSnapshot")?["bundleID"] as? String)
            ?? (local.dictionary(forKey: "companion.hostSnapshot")?["bundleID"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (path, bid)
    }

    /// Resolve stamped encrypted IPA URL (App Group / defaults / manifest / bundled).
    static func resolveEncryptedIPAURL(manifest: [String: Any]?) -> URL? {
        if let stamped = readEncryptedIPAPath() {
            return URL(fileURLWithPath: stamped.path)
        }
        let path = ((manifest?["hostEncryptedIPAPath"] as? String)
            ?? (readHostSnapshot(fromManifest: nil)["hostEncryptedIPAPath"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Companion-bundled copy — works even when App Group / host Documents path is invisible.
        let bundled = Bundle.main.bundleURL.appendingPathComponent(bundledEncryptedIPAName)
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        // Last resort: any IPA left in the shared EncryptedIPAs folder.
        if let root = sharedContainerURL {
            let dir = root.appendingPathComponent(encryptedIPADirName, isDirectory: true)
            if let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                let bid = ((manifest?["bundleID"] as? String)
                    ?? (readHostSnapshot(fromManifest: nil)["bundleID"] as? String))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !bid.isEmpty,
                   let match = items.first(where: {
                       $0.pathExtension.lowercased() == "ipa"
                           && $0.lastPathComponent.localizedCaseInsensitiveContains(bid)
                   }) {
                    return match
                }
                if let any = items.first(where: { $0.pathExtension.lowercased() == "ipa" }) {
                    return any
                }
            }
        }
        return nil
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
            "hostSignedIn", "hostStoreReady", "hostFairPlayAck", "hostEmailHint", "hostEmail",
            "hostSnapshotAt", "hostLiveInstallPath", "hostEncryptedIPAPath", "bundleID",
            "fpSourceMode", "fpVerbose", "fpKeepEncryptedIPA", "fpRetryRounds",
            "fpPathDiagnostics", "fpRequireAllFrameworks", "fpIncludeTestFlight",
        ] {
            if let v = manifest[key] { out[key] = v }
        }
        // Seed companion defaults so FairPlay failure copy names the owning Apple ID.
        if let email = (out["hostEmail"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            local.set(email, forKey: "tetherless.appleid.activeEmailCache")
            suite?.set(email, forKey: "tetherless.appleid.activeEmailCache")
        }
        return out
    }

    /// Resolve the live App Store `.app` the host stamped for FairPlay mremap.
    /// Prefer App Group / defaults, then companion EmbeddedPayload `manifest.plist`.
    static func resolveLiveInstallURL(manifest: [String: Any]?) -> URL? {
        if let stamped = readLiveInstallPath() {
            let url = URL(fileURLWithPath: stamped.path)
            if FileManager.default.fileExists(atPath: url.path) {
                return url.resolvingSymlinksInPath().standardizedFileURL
            }
        }
        let path = ((manifest?["hostLiveInstallPath"] as? String)
            ?? (readHostSnapshot(fromManifest: nil)["hostLiveInstallPath"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url.resolvingSymlinksInPath().standardizedFileURL
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
            ? "Imported clear IPA from AppAssassin Decrypt."
            : "Imported clear IPA from AppAssassin Decrypt · \(verify)"
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
