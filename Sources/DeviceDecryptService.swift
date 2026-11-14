//
//  DeviceDecryptService.swift
//  On-device decrypt: hardened FairPlay mremap on apps installed on this iPhone
//  (App Store keys + SC_Info). Falls back to Store download + local FairPlay only
//  when the install path is missing — not when FairPlay fails (that needs App Store sign-in).
//

import Foundation
import SwiftUI

@MainActor
final class DeviceDecryptService: ObservableObject {
    static let shared = DeviceDecryptService()

    @Published private(set) var busy = false
    @Published var status = ""
    @Published var lastError: String?
    /// Last batch / single-run detail line (counts, soft-fails).
    @Published var lastReportSummary = ""

    private init() {}

    /// App Store / DRM apps on this device that can be decrypted with local keys.
    var drmApps: [DeviceApp] {
        DeviceLibrary.shared.apps.filter(\.isAppStore)
    }

    /// Resolve an App Store URL for a bundle ID via Apple’s public lookup (on-device, no bot).
    func storeURL(forBundleID bundleID: String) async throws -> String {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { throw DecryptError("Missing bundle ID.") }
        guard var comps = URLComponents(string: "https://itunes.apple.com/lookup") else {
            throw DecryptError("Bad lookup URL.")
        }
        comps.queryItems = [
            URLQueryItem(name: "bundleId", value: id),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = comps.url else { throw DecryptError("Bad lookup URL.") }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw DecryptError("App Store lookup failed (\(code)).") }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let results = json["results"] as? [[String: Any]] ?? []
        guard let first = results.first else {
            throw DecryptError("No App Store listing for \(id). Install it from the App Store with the Apple ID you use in Store Access, then try again.")
        }
        if let track = first["trackViewUrl"] as? String, !track.isEmpty { return track }
        if let trackId = first["trackId"] as? Int {
            return "https://apps.apple.com/app/id\(trackId)"
        }
        throw DecryptError("Couldn't find an App Store link for \(id).")
    }

    /// Public iTunes search (on-device) — no FastDecryptBot / Telegram.
    func searchAppStore(_ term: String) async throws -> [DecryptApp] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        if DecryptClient.isStoreLink(q) {
            return try await [appInfo(url: q)]
        }
        guard var comps = URLComponents(string: "https://itunes.apple.com/search") else {
            throw DecryptError("Bad search URL.")
        }
        comps.queryItems = [
            URLQueryItem(name: "term", value: q),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "limit", value: "25")
        ]
        guard let url = comps.url else { throw DecryptError("Bad search URL.") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let results = json["results"] as? [[String: Any]] ?? []
        return results.compactMap { row in
            guard let trackId = row["trackId"] as? Int else { return nil }
            let name = (row["trackName"] as? String) ?? "App"
            let bundle = (row["bundleId"] as? String) ?? ""
            let artist = (row["artistName"] as? String) ?? ""
            let version = (row["version"] as? String) ?? ""
            let link = (row["trackViewUrl"] as? String) ?? "https://apps.apple.com/app/id\(trackId)"
            let icon = (row["artworkUrl512"] as? String).flatMap(URL.init(string:))
                ?? (row["artworkUrl100"] as? String).flatMap(URL.init(string:))
            return DecryptApp(
                id: "itunes-\(trackId)",
                name: name,
                bundle: bundle,
                icon: icon,
                dev: artist,
                version: version,
                url: link
            )
        }
    }

    private func appInfo(url: String) async throws -> DecryptApp {
        let id: String? = {
            if let r = url.range(of: #"/id(\d+)"#, options: .regularExpression) {
                return String(url[r]).filter(\.isNumber)
            }
            return nil
        }()
        if let id, var comps = URLComponents(string: "https://itunes.apple.com/lookup") {
            comps.queryItems = [URLQueryItem(name: "id", value: id)]
            if let u = comps.url {
                let (data, _) = try await URLSession.shared.data(from: u)
                let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                if let row = (json["results"] as? [[String: Any]])?.first {
                    let name = (row["trackName"] as? String) ?? "App"
                    let bundle = (row["bundleId"] as? String) ?? ""
                    let artist = (row["artistName"] as? String) ?? ""
                    let version = (row["version"] as? String) ?? ""
                    let icon = (row["artworkUrl512"] as? String).flatMap(URL.init(string:))
                    return DecryptApp(id: url, name: name, bundle: bundle, icon: icon, dev: artist, version: version, url: url)
                }
            }
        }
        return DecryptApp(id: url, name: "App", bundle: "", icon: nil, dev: "", version: "", url: url)
    }

    /// Decrypt an installed App Store app with this device’s FairPlay keys (mremap_encrypted).
    func decryptInstalled(_ app: DeviceApp, version: String? = nil) async {
        guard !busy else { return }
        busy = true
        lastError = nil
        status = "Preparing \(app.name)…"
        defer { busy = false }
        do {
            guard AppleIDStore.shared.isSignedIn else {
                throw DecryptError("Sign in under Settings › Store Access with the Apple ID that owns this app.")
            }
            if !AppStoreDecryptGuide.isAcknowledged(email: AppleIDStore.shared.email) {
                status = "Confirm this Apple ID has signed in to the App Store on this iPhone once…"
            }

            status = "Decrypting \(app.name) on this device…"
            do {
                let clear = try FairPlayDecrypt.decryptInstalledApp(
                    bundleID: app.bundleID,
                    displayName: app.name
                ) { [weak self] msg in
                    Task { @MainActor in self?.status = msg }
                }
                lastReportSummary = clear.lastPathComponent.contains("-decrypted-soft")
                    ? "Saved with optional Watch/widget leftovers encrypted"
                    : "Full Mach-O coverage (main + frameworks + nested)"
                DecryptClient.shared.finished = clear
                DecryptClient.shared.finishedName = app.name
                DecryptClient.shared.phase = .done
                DecryptClient.shared.message = "Decrypted on this device · \(lastReportSummary)"
                DecryptClient.shared.error = nil
                status = ""
                AppNav.shared.go(AppTab.library.rawValue)
                return
            } catch FairPlayDecryptError.noInstalledApp {
                status = "App path not found — trying Store IPA…"
            } catch let e as FairPlayDecryptError {
                // Keys / FairPlay failure — do NOT mask with a remote download.
                lastError = e.localizedDescription
                DecryptClient.shared.phase = .failed
                DecryptClient.shared.error = e.localizedDescription
                status = ""
                return
            }

            let storeURL = try await storeURL(forBundleID: app.bundleID)
            let display = app.name
            let clientApp = DecryptApp(
                id: app.bundleID,
                name: app.name,
                bundle: app.bundleID,
                icon: nil,
                dev: "",
                version: version ?? app.version,
                url: storeURL
            )
            DecryptClient.shared.select(clientApp)
            status = "Downloading + decrypting on this device…"
            DecryptClient.shared.start(url: storeURL, version: version, display: display)
            status = ""
        } catch {
            lastError = error.localizedDescription
            status = ""
        }
    }

    func decryptFromSearch(_ app: DecryptApp, version: String? = nil) {
        switch DecryptChannel.current {
        case .telegram:
            DecryptClient.shared.select(app)
            DecryptClient.shared.start(url: app.url, version: version, display: app.name)
        case .device:
            if !app.bundle.isEmpty, FairPlayDecrypt.installedAppURL(bundleID: app.bundle) != nil {
                let deviceApp = DeviceApp(bundleID: app.bundle, name: app.name, version: app.version, isAppStore: true)
                Task { await decryptInstalled(deviceApp, version: version) }
                return
            }
            DecryptClient.shared.select(app)
            DecryptClient.shared.start(url: app.url, version: version, display: app.name)
        }
    }

    /// Decrypt every listed App Store app with on-device FairPlay (main + frameworks + nested).
    func decryptAllInstalled(stopOnError: Bool = false) async {
        guard !busy else { return }
        let apps = drmApps
        guard !apps.isEmpty else {
            lastError = "No App Store apps listed. Pair Native and refresh."
            return
        }
        guard AppleIDStore.shared.isSignedIn else {
            lastError = "Sign in under Settings › Store Access with the Apple ID that owns these apps."
            return
        }
        busy = true
        lastError = nil
        lastReportSummary = ""
        defer { busy = false }

        var ok = 0
        var fail = 0
        var lastURL: URL?
        var lastName = ""
        for (i, app) in apps.enumerated() {
            status = "[\(i + 1)/\(apps.count)] \(app.name)…"
            do {
                let clear = try FairPlayDecrypt.decryptInstalledApp(
                    bundleID: app.bundleID,
                    displayName: app.name
                ) { [weak self] msg in
                    Task { @MainActor in
                        self?.status = "[\(i + 1)/\(apps.count)] \(app.name) · \(msg)"
                    }
                }
                ok += 1
                lastURL = clear
                lastName = app.name
            } catch {
                fail += 1
                lastError = "\(app.name): \(error.localizedDescription)"
                if stopOnError { break }
            }
        }

        lastReportSummary = "\(ok) decrypted · \(fail) failed of \(apps.count)"
        if let lastURL {
            DecryptClient.shared.finished = lastURL
            DecryptClient.shared.finishedName = lastName
            DecryptClient.shared.phase = .done
            DecryptClient.shared.message = "Decrypt All finished · \(lastReportSummary)"
            DecryptClient.shared.error = fail == 0 ? nil : lastError
            status = lastReportSummary
            AppNav.shared.go(AppTab.library.rawValue)
        } else {
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = lastError ?? "Decrypt All failed."
            status = ""
        }
    }
}
