//
//  DeviceDecryptService.swift
//  On-device decrypt: use apps already installed on this iPhone (with this device’s
//  App Store decryption keys), not a Telegram bot. Resolves a Store URL for an
//  installed App Store app and hands it to DecryptClient for a DRM-free IPA.
//

import Foundation
import SwiftUI

@MainActor
final class DeviceDecryptService: ObservableObject {
    static let shared = DeviceDecryptService()

    @Published private(set) var busy = false
    @Published var status = ""
    @Published var lastError: String?

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
        // Prefer device-local iTunes lookup when we can parse an id; else keep the link as-is.
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

    /// Decrypt an app that is (or will be) owned on this device — uses this iPhone’s App Store keys, not a TG bot.
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
            status = "Looking up App Store listing…"
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
            status = "Decrypting on this device…"
            DecryptClient.shared.start(url: storeURL, version: version, display: display)
            status = ""
        } catch {
            lastError = error.localizedDescription
            status = ""
        }
    }

    func decryptFromSearch(_ app: DecryptApp, version: String? = nil) {
        DecryptClient.shared.select(app)
        DecryptClient.shared.start(url: app.url, version: version, display: app.name)
    }
}
