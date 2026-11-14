//
//  DeviceDecryptService.swift
//  On-device decrypt: hardened FairPlay mremap on apps installed on this iPhone
//  (App Store keys + SC_Info). When the app isn’t installed yet, Device mode opens
//  the App Store listing for *your* Apple ID, waits for the install, then decrypts
//  locally — no Telegram bot fallback.
//

import Foundation
import IDeviceSwift
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
                finishSuccess(url: clear, name: app.name)
                return
            } catch FairPlayDecryptError.noInstalledApp {
                status = "Not installed — trying silent App Store download…"
            } catch let e as FairPlayDecryptError {
                // Keys / FairPlay failure — do NOT mask with a remote download.
                lastError = e.localizedDescription
                DecryptClient.shared.phase = .failed
                DecryptClient.shared.error = e.localizedDescription
                status = ""
                return
            }

            let storeURL = try await storeURL(forBundleID: app.bundleID)
            if await trySilentPurchaseDownloadDecrypt(
                bundleID: app.bundleID,
                displayName: app.name,
                storeURL: storeURL
            ) {
                return
            }
            try await waitForStoreInstallThenDecrypt(
                bundleID: app.bundleID,
                displayName: app.name,
                storeURL: storeURL
            )
        } catch {
            lastError = error.localizedDescription
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = error.localizedDescription
            status = ""
        }
    }

    func decryptFromSearch(_ app: DecryptApp, version: String? = nil) {
        switch DecryptChannel.current {
        case .telegram:
            DecryptClient.shared.select(app)
            DecryptClient.shared.start(url: app.url, version: version, display: app.name)
        case .device:
            let deviceApp = DeviceApp(
                bundleID: app.bundle.isEmpty ? app.id : app.bundle,
                name: app.name,
                version: app.version,
                isAppStore: true
            )
            Task { await decryptOwnedStoreApp(deviceApp, storeURL: app.url, version: version) }
        }
    }

    /// Device-channel path for a Store listing: decrypt if installed, otherwise open the listing
    /// under the signed-in Apple ID, wait for install, then FairPlay locally (never Telegram).
    func decryptOwnedStoreApp(_ app: DeviceApp, storeURL: String, version: String? = nil) async {
        guard !busy else { return }
        busy = true
        lastError = nil
        defer { busy = false }
        do {
            guard AppleIDStore.shared.isSignedIn else {
                throw DecryptError("Sign in under Settings › Store Access with the Apple ID that owns this app.")
            }
            let bid = app.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bid.isEmpty else {
                throw DecryptError("Missing bundle ID — search again or paste an App Store link.")
            }
            if FairPlayDecrypt.installedAppURL(bundleID: bid) != nil {
                status = "Decrypting \(app.name) on this device…"
                let clear = try FairPlayDecrypt.decryptInstalledApp(
                    bundleID: bid,
                    displayName: app.name
                ) { [weak self] msg in
                    Task { @MainActor in self?.status = msg }
                }
                finishSuccess(url: clear, name: app.name)
                return
            }
            let link = storeURL.isEmpty ? try await self.storeURL(forBundleID: bid) : storeURL
            // Silent purchase + download (no App Store UI). Falls back to install-wait if needed.
            if await trySilentPurchaseDownloadDecrypt(
                bundleID: bid,
                displayName: app.name,
                storeURL: link
            ) {
                return
            }
            try await waitForStoreInstallThenDecrypt(
                bundleID: bid,
                displayName: app.name,
                storeURL: link
            )
        } catch {
            lastError = error.localizedDescription
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = error.localizedDescription
            status = ""
        }
    }

    /// ipatool-style silent buy + CDN download, then FairPlay. Returns true if finished successfully.
    @discardableResult
    private func trySilentPurchaseDownloadDecrypt(
        bundleID: String,
        displayName: String,
        storeURL: String
    ) async -> Bool {
        do {
            guard let adam = try await resolveAdamId(bundleID: bundleID, storeURL: storeURL) else {
                status = "Couldn't resolve App Store id — falling back to App Store install…"
                return false
            }
            status = "Silent App Store session…"
            DecryptClient.shared.phase = .running
            DecryptClient.shared.message = status
            let account = try await AppleIDStore.shared.ensureStorefrontSession()

            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tetherless-silent", isDirectory: true)
            try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
            let dest = tmpDir.appendingPathComponent("\(bundleID.isEmpty ? "app" : bundleID)_\(adam).ipa")

            let ipa = try await AppStoreClient.shared.purchaseAndDownload(
                adamId: adam,
                account: account,
                destination: dest,
                onProgress: { [weak self] msg in
                    Task { @MainActor in
                        self?.status = msg
                        DecryptClient.shared.message = msg
                    }
                }
            )

            // Prefer decrypt via installed path once the silent purchase made the license live;
            // otherwise attempt IPA-path FairPlay (needs readable SC_Info / keys on device).
            if FairPlayDecrypt.installedAppURL(bundleID: bundleID) != nil {
                status = "License ready — decrypting installed \(displayName)…"
                let clear = try FairPlayDecrypt.decryptInstalledApp(
                    bundleID: bundleID,
                    displayName: displayName
                ) { [weak self] msg in
                    Task { @MainActor in
                        self?.status = msg
                        DecryptClient.shared.message = msg
                    }
                }
                finishSuccess(url: clear, name: displayName)
                return true
            }

            status = "Decrypting silently downloaded \(displayName)…"
            DecryptClient.shared.message = status
            do {
                let clear = try FairPlayDecrypt.decryptIPA(
                    at: ipa,
                    displayName: displayName
                ) { [weak self] msg in
                    Task { @MainActor in
                        self?.status = msg
                        DecryptClient.shared.message = msg
                    }
                }
                finishSuccess(url: clear, name: displayName)
                return true
            } catch {
                // Keep the encrypted IPA; fall through to App Store install for fairplayd path.
                status = "Downloaded encrypted IPA — install once so FairPlay keys can finish decrypt…"
                DecryptClient.shared.message = status
                return false
            }
        } catch AppStoreClientError.paidApp {
            status = "Paid app — install from the App Store once, then decrypt on-device…"
            return false
        } catch AppStoreClientError.tokenExpired, AppStoreClientError.needsTwoFactor {
            status = "App Store session needs refresh — open Store Access, then retry…"
            return false
        } catch {
            status = "Silent download unavailable (\(error.localizedDescription)) — opening App Store…"
            return false
        }
    }

    private func resolveAdamId(bundleID: String, storeURL: String) async throws -> Int? {
        if let r = storeURL.range(of: #"/id(\d+)"#, options: .regularExpression) {
            let digits = String(storeURL[r]).filter(\.isNumber)
            if let n = Int(digits) { return n }
        }
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        guard var comps = URLComponents(string: "https://itunes.apple.com/lookup") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "bundleId", value: id),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = comps.url else { return nil }
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let results = json["results"] as? [[String: Any]] ?? []
        if let track = results.first?["trackId"] as? Int { return track }
        if let track = results.first?["trackId"] as? NSNumber { return track.intValue }
        return nil
    }

    private func waitForStoreInstallThenDecrypt(
        bundleID: String,
        displayName: String,
        storeURL: String
    ) async throws {
        DecryptClient.shared.phase = .running
        DecryptClient.shared.message = "Install \(displayName) from the App Store — decrypt runs automatically on this device"
        DecryptClient.shared.error = nil
        status = "Opening App Store — install with \(AppleIDStore.shared.email.isEmpty ? "your Apple ID" : AppleIDStore.shared.email)…"
        AppStoreDecryptGuide.openAppStoreListing(storeURL)

        let deadline = Date().addingTimeInterval(10 * 60)
        var spins = 0
        while Date() < deadline {
            try Task.checkCancellation()
            // Refresh paired/library lists so newly installed App Store apps show up quickly.
            if spins % 3 == 0 {
                await DeviceLibrary.shared.refresh()
            }
            if let _ = FairPlayDecrypt.installedAppURL(bundleID: bundleID) {
                status = "Installed — decrypting \(displayName) on this device…"
                DecryptClient.shared.message = status
                let clear = try FairPlayDecrypt.decryptInstalledApp(
                    bundleID: bundleID,
                    displayName: displayName
                ) { [weak self] msg in
                    Task { @MainActor in
                        self?.status = msg
                        DecryptClient.shared.message = msg
                    }
                }
                finishSuccess(url: clear, name: displayName)
                return
            }
            spins += 1
            // Re-nudge the App Store every ~30s so Get/Install stays in front of the user.
            if spins % 15 == 0 {
                status = "Still waiting — reopening App Store for \(displayName)…"
                DecryptClient.shared.message = status
                AppStoreDecryptGuide.openAppStoreListing(storeURL)
            } else if spins % 5 == 0 {
                status = "Waiting for \(displayName) to finish installing…"
                DecryptClient.shared.message = status
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw DecryptError(
            "Timed out waiting for \(displayName) to install. Open the App Store, install it with the Apple ID in Store Access, then tap Decrypt again."
        )
    }

    private func finishSuccess(url: URL, name: String) {
        let nameTag = url.lastPathComponent
        if nameTag.contains("-PARTIAL") {
            lastReportSummary = "PARTIAL IPA (main clear · some frameworks still encrypted)"
        } else if nameTag.contains("-decrypted-soft") {
            lastReportSummary = "Saved with optional Watch/widget leftovers encrypted"
        } else {
            lastReportSummary = "Full Mach-O coverage (main + frameworks + nested)"
        }
        if let verify = try? FairPlayDecrypt.verifyIPA(at: url) {
            lastReportSummary += " · \(verify.summary)"
        }
        DecryptClient.shared.finished = url
        DecryptClient.shared.finishedName = name
        DecryptClient.shared.phase = .done
        DecryptClient.shared.message = "Decrypted on this device · \(lastReportSummary)"
        DecryptClient.shared.error = nil
        status = ""
        AppNav.shared.go(AppTab.library.rawValue)
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
