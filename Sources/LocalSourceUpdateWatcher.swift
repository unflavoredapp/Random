//
//  LocalSourceUpdateWatcher.swift
//  Watches every source added to AirShare, detects version changes, optionally
//  signs new IPAs with the user's active certificate, and hands the result to
//  the existing local AirShare + notification flow.
//
import Foundation
import SwiftUI
import BackgroundTasks

@MainActor
final class LocalSourceUpdateWatcher: ObservableObject {
    static let shared = LocalSourceUpdateWatcher()

    @Published private(set) var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    @Published private(set) var automaticSigning: Bool {
        didSet { UserDefaults.standard.set(automaticSigning, forKey: Self.autoSignKey) }
    }
    @Published private(set) var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: Self.notifyKey) }
    }
    @Published private(set) var lastScan: Date?
    @Published private(set) var sourcesScanned = 0
    @Published private(set) var appsMonitored = 0
    @Published private(set) var updatesFound = 0
    @Published private(set) var lastMessage = "Waiting for first source scan"
    @Published private(set) var scanning = false

    private static let enabledKey = "msign.sourceWatcher.enabled"
    private static let autoSignKey = "msign.sourceWatcher.autoSign"
    private static let notifyKey = "msign.sourceWatcher.notifications"
    private static let versionsKey = "msign.sourceWatcher.versions"
    private static let lastRunKey = "msign.sourceWatcher.lastRun"

    private var baseline: [String: [String: String]] = [:]
    private var signingBundles = Set<String>()
    private var backgroundTask: Task<Void, Never>?

    private init() {
        enabled = UserDefaults.standard.object(forKey: Self.enabledKey) == nil ? true : UserDefaults.standard.bool(forKey: Self.enabledKey)
        automaticSigning = UserDefaults.standard.object(forKey: Self.autoSignKey) == nil ? false : UserDefaults.standard.bool(forKey: Self.autoSignKey)
        notificationsEnabled = UserDefaults.standard.object(forKey: Self.notifyKey) == nil ? true : UserDefaults.standard.bool(forKey: Self.notifyKey)
        if let data = UserDefaults.standard.data(forKey: Self.versionsKey),
           let value = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            baseline = value
        }
        lastScan = UserDefaults.standard.object(forKey: Self.lastRunKey) as? Date
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        if value { scheduleNextScan() }
    }

    func setAutomaticSigning(_ value: Bool) { automaticSigning = value }
    func setNotificationsEnabled(_ value: Bool) { notificationsEnabled = value }

    func scheduleNextScan() {
        let request = BGAppRefreshTaskRequest(identifier: "com.mrzefv.airshare.source-scan")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Foreground scanning still works; iOS may reject scheduling during development or when the task is already queued.
        }
    }

    func scanAllSources(reason: String = "manual") async {
        guard enabled, !scanning else { return }
        scanning = true
        defer { scanning = false }

        let sourceSnapshot = SourceStore.shared.sources
        var found = 0
        var appCount = 0
        var scanned = 0
        var newBaseline = baseline

        for source in sourceSnapshot {
            guard !Task.isCancelled else { break }
            do {
                let repo = try await SourceStore.shared.fetch(source)
                scanned += 1
                var current: [String: String] = [:]
                for group in repo.groups {
                    let app = group.latest
                    current[app.bundle] = app.version
                    appCount += 1

                    if let previous = baseline[source.id]?[app.bundle], isNewer(app.version, than: previous) {
                        found += 1
                        await handleUpdate(source: source, app: app, previousVersion: previous)
                    }
                }
                newBaseline[source.id] = current
            } catch {
                lastMessage = "Could not scan \(source.name): \(error.localizedDescription)"
            }
        }

        baseline = newBaseline
        persistBaseline()
        sourcesScanned = scanned
        appsMonitored = appCount
        updatesFound = found
        lastScan = Date()
        UserDefaults.standard.set(lastScan, forKey: Self.lastRunKey)
        if found == 0 && lastMessage.hasPrefix("Could not scan") == false {
            lastMessage = reason == "manual" ? "All monitored apps are up to date" : "Source scan complete"
        }
        scheduleNextScan()
    }

    private func handleUpdate(source: RepoSource, app: SourceApp, previousVersion: String) async {
        guard !signingBundles.contains(app.bundle) else { return }

        guard automaticSigning else {
            if notificationsEnabled {
                NotificationManager.shared.scheduleSourceUpdateNotification(source: source, app: app, previousVersion: previousVersion)
            }
            return
        }

        guard let downloadURL = app.downloadURL else {
            lastMessage = "Update found for \(app.name), but the source has no IPA URL"
            return
        }

        guard certsCanSign else {
            lastMessage = "Update found for \(app.name), but no active certificate is available"
            if notificationsEnabled {
                NotificationManager.shared.scheduleSourceUpdateNotification(source: source, app: app, previousVersion: previousVersion)
            }
            return
        }

        signingBundles.insert(app.bundle)
        defer { signingBundles.remove(app.bundle) }

        do {
            let tempRoot = AppPaths.dir("tmp").appendingPathComponent("source-updates", isDirectory: true)
            try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
            let ipaURL = tempRoot.appendingPathComponent("\(safeName(app.bundle))-\(safeName(app.version)).ipa")
            try await download(downloadURL, to: ipaURL)

            let material = try CertificateStore.shared.activeMaterial()
            var options = SignOptions()
            options.name = app.name
            options.bundleID = app.bundle
            options.version = app.version
            options.parallelSigning = true

            let outcome = try await Signer.signDetached(
                ipaURL: ipaURL,
                material: material,
                options: options,
                onLog: nil,
                captureOutput: false
            )

            let icon = (try? IPAMeta.read(outcome.ipaURL).iconPNG) ?? nil
            let entry = try SignedStore.shared.add(outcome: outcome, icon: icon, certName: material.name)
            let imageSmall = OTAInstaller.otaIconPNG(icon, side: 57)
            let imageLarge = OTAInstaller.otaIconPNG(icon, side: 512)
            _ = try LocalOTAServer(
                package: entry.ipaURL,
                metadata: InstallAppData(id: entry.bundleID, version: entry.version, name: entry.name),
                imageSmall: imageSmall,
                imageLarge: imageLarge
            )
            if notificationsEnabled {
                // SignedStore already schedules the install-ready notification.
                // This message records the reason for the automatic signing event.
                lastMessage = "Auto-signed \(app.name) \(app.version) and published AirShare"
            }
            try? FileManager.default.removeItem(at: ipaURL)
        } catch {
            lastMessage = "Auto-sign failed for \(app.name): \(error.localizedDescription)"
            if notificationsEnabled {
                NotificationManager.shared.scheduleSourceUpdateFailedNotification(app: app, reason: error.localizedDescription)
            }
        }
    }

    private var certsCanSign: Bool {
        (try? CertificateStore.shared.activeMaterial()) != nil
    }

    private func download(_ url: URL, to destination: URL) async throws {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("AirShare-SourceWatcher", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SourceWatcherError.downloadFailed
        }
        guard data.count > 4 else { throw SourceWatcherError.invalidIPA }
        try data.write(to: destination, options: .atomic)
    }

    private func persistBaseline() {
        if let data = try? JSONEncoder().encode(baseline) {
            UserDefaults.standard.set(data, forKey: Self.versionsKey)
        }
    }

    private func safeName(_ value: String) -> String {
        value.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
    }

    private func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }
        return lhs != rhs
    }
}

enum SourceWatcherError: LocalizedError {
    case downloadFailed
    case invalidIPA
    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "The source IPA could not be downloaded."
        case .invalidIPA: return "The source returned an invalid IPA payload."
        }
    }
}

