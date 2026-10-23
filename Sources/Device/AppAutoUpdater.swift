//
//  AppAutoUpdater.swift
//  Keeps the apps you installed through AirShare up to date. For every tracked
//  app it checks your sources for a newer version, downloads the IPA, signs it
//  with your active certificate and installs it with the Native installer — no
//  Apple prompt, no taps. Runs when AirShare opens or returns to the foreground.
//
//  Tracked apps = apps AirShare installed natively, plus anything added with
//  "Track apps I've signed". Remove an app from the list to stop updating it.
//

import Foundation
import SwiftUI
import UIKit
import UserNotifications
import Network

struct TrackedApp: Codable, Identifiable, Equatable {
    var id: String { bundleID }
    let bundleID: String
    var name: String
    var version: String
    var autoUpdate: Bool? = nil      // nil / true = include in automatic updates
    var skipped: String? = nil       // source version the user chose to skip

    var isAuto: Bool { autoUpdate != false }
}

@MainActor
final class AppAutoUpdater: ObservableObject {
    static let shared = AppAutoUpdater()
    static let enabledKey = "AirShare.autoUpdateApps"
    static let wifiOnlyKey = "AirShare.autoUpdateWifiOnly"
    static let chargingOnlyKey = "AirShare.autoUpdateChargingOnly"
    static let certRefreshKey = "AirShare.autoCertRefresh"
    private static let trackedKey = "AirShare.trackedApps"
    private static let lastCheckKey = "AirShare.lastAppUpdateCheck"

    @Published private(set) var tracked: [TrackedApp] = []
    @Published private(set) var available: [String: String] = [:]   // bundleID -> newer source version
    @Published private(set) var busy = false
    @Published private(set) var status = ""

    private let monitor = NWPathMonitor()
    private var path: NWPath?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.trackedKey),
           let list = try? JSONDecoder().decode([TrackedApp].self, from: data) { tracked = list }
        monitor.pathUpdateHandler = { [weak self] p in Task { @MainActor in self?.path = p } }
        monitor.start(queue: DispatchQueue(label: "airshare.netpath"))
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    static var autoEnabled: Bool { NativeInstaller.isSelected && UserDefaults.standard.bool(forKey: enabledKey) }

    // MARK: Tracking

    /// Called by NativeInstaller after every successful install.
    func recordInstalled(bundleID: String, name: String, version: String) {
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        if let i = tracked.firstIndex(where: { $0.bundleID == bundleID }) {
            tracked[i].version = version; tracked[i].name = name
        } else {
            tracked.append(TrackedApp(bundleID: bundleID, name: name, version: version))
        }
        available[bundleID] = nil
        persist()
    }

    func untrack(_ app: TrackedApp) {
        tracked.removeAll { $0.bundleID == app.bundleID }
        available[app.bundleID] = nil
        persist()
    }

    /// Adds every app you've signed in AirShare (latest signed version of each).
    func trackSignedApps() {
        for e in SignedStore.shared.entries where e.bundleID != Bundle.main.bundleIdentifier {
            guard !tracked.contains(where: { $0.bundleID == e.bundleID }) else { continue }
            tracked.append(TrackedApp(bundleID: e.bundleID, name: e.name, version: e.version))
        }
        persist()
        status = "Tracking \(tracked.count) app\(tracked.count == 1 ? "" : "s")"
    }

    func setAuto(_ on: Bool, for app: TrackedApp) { mutate(app) { $0.autoUpdate = on ? nil : false } }
    func skip(_ app: TrackedApp) {
        guard let v = available[app.bundleID] else { return }
        mutate(app) { $0.skipped = v }
        available[app.bundleID] = nil
    }
    private func mutate(_ app: TrackedApp, _ f: (inout TrackedApp) -> Void) {
        guard let i = tracked.firstIndex(where: { $0.bundleID == app.bundleID }) else { return }
        f(&tracked[i]); persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(tracked) { UserDefaults.standard.set(data, forKey: Self.trackedKey) }
    }

    // MARK: Conditions

    /// Why automatic updates must wait right now (nil = go ahead). Manual actions ignore this.
    private var blocker: String? {
        let d = UserDefaults.standard
        if d.bool(forKey: Self.wifiOnlyKey) {
            let p = path ?? monitor.currentPath
            if !(p.status == .satisfied && p.usesInterfaceType(.wifi) && !p.isExpensive) { return "Waiting for Wi-Fi" }
        }
        if d.bool(forKey: Self.chargingOnlyKey) {
            let s = UIDevice.current.batteryState
            if s != .charging && s != .full { return "Waiting for the charger" }
        }
        return nil
    }

    // MARK: Triggers

    func autoCheckIfDue() {
        guard Self.autoEnabled, !busy, !tracked.isEmpty else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 30 * 60 else { return }
        if let why = blocker { status = why; return }
        Task { await run(.auto) }
    }

    func updateNow() { Task { await run(.all) } }
    func checkOnly() { Task { await run(.check) } }
    func update(_ app: TrackedApp) { Task { await run(.one(app.bundleID)) } }
    func refreshCertificates() { Task { await run(.certs) } }
    func rollBack(_ app: TrackedApp) { Task { await rollBackNow(app) } }

    /// The signed build an app would return to (newest one with a different version than the installed one).
    func rollbackTarget(for app: TrackedApp) -> SignedEntry? {
        SignedStore.shared.entries.first { $0.bundleID == app.bundleID && $0.version != app.version
            && FileManager.default.fileExists(atPath: $0.ipaURL.path) }
    }

    /// Latest signed build was made with a different certificate than the active one.
    func needsCertRefresh(_ app: TrackedApp) -> Bool {
        guard let active = CertificateStore.shared.active,
              let e = SignedStore.shared.entries.first(where: { $0.bundleID == app.bundleID }) else { return false }
        return e.certName != active.name
    }

    // MARK: Update loop

    enum Mode: Equatable { case auto, all, check, one(String), certs }

    private func beginBackground() -> () -> Void {
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "airshare-app-updates") {
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
        }
        return { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid } }
    }

    private func run(_ mode: Mode) async {
        guard !busy else { return }
        guard !NativeInstaller.shared.isActive else { status = "Waiting — another install is running"; return }
        busy = true
        if mode == .auto { UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey) }
        let endBackground = beginBackground()
        defer { busy = false; endBackground() }

        var updated = 0, failed = 0, refreshed = 0
        var jobs: [(TrackedApp, SourceApp, URL)] = []
        let trackedNow = tracked

        if mode != .certs {
            status = "Checking sources…"
            var latest: [String: SourceApp] = [:]
            for source in SourceStore.shared.sources {
                guard let repo = try? await SourceStore.shared.fetch(source) else { continue }
                for group in repo.groups {
                    let app = group.latest
                    guard trackedNow.contains(where: { Self.sourceBundle($0) == app.bundle }) else { continue }
                    if let cur = latest[app.bundle], !Self.isNewer(app.version, than: cur.version) { continue }
                    latest[app.bundle] = app
                }
            }
            var avail: [String: String] = [:]
            for t in trackedNow {
                guard let app = latest[Self.sourceBundle(t)],
                      Self.isNewer(app.version, than: Self.installedSourceVersion(t)) else { continue }
                avail[t.bundleID] = app.version
                if t.skipped == app.version, mode != .one(t.bundleID) { continue }
                switch mode {
                case .auto: guard t.isAuto else { continue }
                case .one(let id): guard id == t.bundleID else { continue }
                default: break
                }
                if mode == .check { continue }
                guard let url = app.downloadURL else { failed += 1; continue }
                jobs.append((t, app, url))
            }
            available = avail
            if mode == .check {
                status = avail.isEmpty ? "All tracked apps are up to date" : "\(avail.count) update\(avail.count == 1 ? "" : "s") available"
                return
            }
        }

        // One VPN / tunnel session for the whole batch instead of one per app.
        let batch = UUID()
        var holding = false
        func hold() { if !holding { DeviceInstallationManager.shared.retainWorkflow(batch); holding = true } }
        defer { if holding { DeviceInstallationManager.shared.releaseWorkflow(batch) } }
        if jobs.count > 1 { hold() }

        for (t, app, url) in jobs {
            status = "Updating \(app.name) \(Self.installedSourceVersion(t)) → \(app.version)…"
            do {
                try await update(app, from: url, tracked: t)
                updated += 1
                mutate(t) { $0.skipped = nil }
                available[t.bundleID] = nil
            } catch {
                failed += 1
                status = "\(app.name): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }

        // Re-sign apps whose build was signed with a different (older) certificate.
        let wantCerts = mode == .certs || ((mode == .auto || mode == .all) && UserDefaults.standard.bool(forKey: Self.certRefreshKey))
        if wantCerts {
            let updatedIDs = Set(jobs.map { $0.0.bundleID })
            let todo = tracked.filter { !updatedIDs.contains($0.bundleID) && needsCertRefresh($0) && ($0.isAuto || mode == .certs) }
            if todo.count > 1 { hold() }
            for t in todo {
                status = "Re-signing \(t.name) with \(CertificateStore.shared.active?.name ?? "active certificate")…"
                do { try await resign(t); refreshed += 1 }
                catch {
                    failed += 1
                    status = "\(t.name): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
                }
            }
        }

        if updated == 0 && failed == 0 && refreshed == 0 {
            status = mode == .certs ? "All apps already use the active certificate" : "All tracked apps are up to date"
        } else if failed == 0 {
            var parts: [String] = []
            if updated > 0 { parts.append("Updated \(updated) app\(updated == 1 ? "" : "s")") }
            if refreshed > 0 { parts.append("Re-signed \(refreshed) app\(refreshed == 1 ? "" : "s")") }
            status = parts.joined(separator: " · ")
        } else if updated + refreshed > 0 { status = "Done \(updated + refreshed), \(failed) failed" }
        // single failure keeps its specific message
        if updated + refreshed > 0 { notify("Updated \(updated + refreshed) app\(updated + refreshed == 1 ? "" : "s") in AirShare") }
    }

    /// Bundle ID the sources list for this app (differs from the installed one if it was renamed / randomized when signed).
    private static func sourceBundle(_ t: TrackedApp) -> String {
        SignProfileStore.shared.profile(forSigned: t.bundleID)?.sourceBundleID ?? t.bundleID
    }
    /// Version of the source IPA that is installed (not any version override applied at signing).
    private static func installedSourceVersion(_ t: TrackedApp) -> String {
        SignProfileStore.shared.profile(forSigned: t.bundleID)?.sourceVersion ?? t.version
    }

    private func update(_ app: SourceApp, from url: URL, tracked t: TrackedApp) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("appupdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("AirShare-AutoUpdate", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SourceWatcherError.downloadFailed
        }
        let ipa = work.appendingPathComponent("app.ipa")
        try FileManager.default.moveItem(at: tmp, to: ipa)

        let material = try CertificateStore.shared.activeMaterial()
        // Same options the app was originally signed with (bundle ID, name, icon, dylibs, entitlements…).
        let options: SignOptions
        if let profile = SignProfileStore.shared.profile(forSigned: t.bundleID) {
            options = SignProfileStore.shared.options(for: profile, newVersion: app.version, fallbackName: app.name)
        } else {
            var o = SignOptions()
            o.name = t.name; o.bundleID = t.bundleID; o.version = app.version
            options = o
        }
        let outcome = try await Task.detached(priority: .userInitiated) {
            try await Signer.signDetached(ipaURL: ipa, material: material, options: options, onLog: nil, captureOutput: false)
        }.value
        let icon = (try? IPAMeta.read(outcome.ipaURL).iconPNG) ?? nil
        let entry = try SignedStore.shared.add(outcome: outcome, icon: icon, certName: material.name)
        NativeInstaller.registerOriginal(ipa, forSigned: entry.ipaURL)
        try await NativeInstaller.shared.install(entry)   // records the new version via recordInstalled
        SignProfileStore.shared.setSourceVersion(app.version, forSigned: t.bundleID)
    }

    /// Re-signs the newest signed build of an app with the active certificate and installs it (same version).
    private func resign(_ t: TrackedApp) async throws {
        guard let e = SignedStore.shared.entries.first(where: { $0.bundleID == t.bundleID }),
              FileManager.default.fileExists(atPath: e.ipaURL.path) else { throw SourceWatcherError.downloadFailed }
        let material = try CertificateStore.shared.activeMaterial()
        var o = SignOptions()
        o.name = e.name; o.bundleID = e.bundleID; o.version = e.version
        let options = o, src = e.ipaURL
        let outcome = try await Task.detached(priority: .userInitiated) {
            try await Signer.signDetached(ipaURL: src, material: material, options: options, onLog: nil, captureOutput: false)
        }.value
        let icon = (try? IPAMeta.read(outcome.ipaURL).iconPNG) ?? nil
        let entry = try SignedStore.shared.add(outcome: outcome, icon: icon, certName: material.name)
        NativeInstaller.carryOriginal(from: e.ipaURL, to: entry.ipaURL)
        try await NativeInstaller.shared.install(entry)
    }

    /// Reinstalls the previous signed build and skips the version it replaced.
    private func rollBackNow(_ t: TrackedApp) async {
        guard !busy else { return }
        guard !NativeInstaller.shared.isActive else { status = "Waiting — another install is running"; return }
        guard let prev = rollbackTarget(for: t) else { status = "No earlier build of \(t.name) to roll back to"; return }
        busy = true
        let endBackground = beginBackground()
        defer { busy = false; endBackground() }
        let from = Self.installedSourceVersion(t)
        status = "Rolling \(t.name) back to v\(prev.version)…"
        do {
            try await NativeInstaller.shared.install(prev)
            SignProfileStore.shared.setSourceVersion(prev.version, forSigned: t.bundleID)
            mutate(t) { $0.skipped = from }
            available[t.bundleID] = nil
            status = "\(t.name) is back on v\(prev.version) — v\(from) skipped"
        } catch {
            status = "\(t.name): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }

    private func notify(_ text: String) {
        let c = UNMutableNotificationContent()
        c.title = "AirShare"; c.body = text; c.sound = .default
        let request = UNNotificationRequest(identifier: "airshare.appupdates", content: c,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    private static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let av = i < a.count ? a[i] : 0, bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}
