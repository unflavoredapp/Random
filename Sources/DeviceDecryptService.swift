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

    /// Version history: prefer authenticated MZFinance externalVersionIds, then public iTunes current build.
    func versionList(for app: DecryptApp) async -> (versions: [DecryptVersion], minOS: String?)? {
        if let store = await storeVersionHistory(for: app) {
            return store
        }
        return await publicItunesVersionList(for: app)
    }

    /// Apple ID purchase/download history (owned apps this account can redownload).
    func ownedStoreApps() async throws -> [OwnedStoreApp] {
        let account = try await AppleIDStore.shared.ensureStorefrontSession()
        return try await AppStoreClient.shared.purchaseHistory(account: account)
    }

    private func storeVersionHistory(for app: DecryptApp) async -> (versions: [DecryptVersion], minOS: String?)? {
        guard AppleIDStore.shared.isSignedIn else { return nil }
        do {
            let adam = try await resolveAdamId(bundleID: app.bundle, storeURL: app.url)
            guard let adam else { return nil }
            let account = try await AppleIDStore.shared.ensureStorefrontSession()
            let versions = try await AppStoreClient.shared.resolveVersionHistory(
                adamId: adam,
                account: account,
                limit: 40
            )
            guard !versions.isEmpty else { return nil }
            let minOS = versions.first(where: \.current)?.minOS ?? versions.first?.minOS
            return (versions, minOS)
        } catch {
            return nil
        }
    }

    private func publicItunesVersionList(for app: DecryptApp) async -> (versions: [DecryptVersion], minOS: String?)? {
        var adam: Int?
        if let r = app.url.range(of: #"/id(\d+)"#, options: .regularExpression) {
            adam = Int(String(app.url[r]).filter(\.isNumber))
        }
        let bundle = app.bundle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard adam != nil || !bundle.isEmpty else {
            if !app.version.isEmpty {
                return ([DecryptVersion(v: app.version, current: true, minOS: nil)], nil)
            }
            return nil
        }
        guard var comps = URLComponents(string: "https://itunes.apple.com/lookup") else { return nil }
        if let adam {
            comps.queryItems = [URLQueryItem(name: "id", value: "\(adam)"), URLQueryItem(name: "limit", value: "1")]
        } else {
            comps.queryItems = [URLQueryItem(name: "bundleId", value: bundle), URLQueryItem(name: "limit", value: "1")]
        }
        guard let url = comps.url else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let row = (json["results"] as? [[String: Any]])?.first else {
            if !app.version.isEmpty {
                return ([DecryptVersion(v: app.version, current: true, minOS: nil)], nil)
            }
            return nil
        }
        let ver = (row["version"] as? String) ?? app.version
        let minOS = (row["minimumOsVersion"] as? String)
        guard !ver.isEmpty else { return nil }
        return ([DecryptVersion(v: ver, current: true, minOS: minOS)], minOS)
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
                let known = await resolveInstalledAppURL(bundleID: app.bundleID)?.path
                let clear = try FairPlayDecrypt.decryptInstalledApp(
                    bundleID: app.bundleID,
                    displayName: app.name,
                    knownPath: known
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
            try await silentPurchaseDownloadDecrypt(
                bundleID: app.bundleID,
                displayName: app.name,
                storeURL: storeURL,
                version: version
            )
        } catch {
            lastError = error.localizedDescription
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = error.localizedDescription
            DecryptClient.shared.message = error.localizedDescription
            status = ""
        }
    }

    func decryptFromSearch(_ app: DecryptApp, version: String? = nil, externalVersionId: String? = nil) {
        switch DecryptChannel.current {
        case .telegram:
            DecryptClient.shared.select(app)
            DecryptClient.shared.start(url: app.url, version: version, display: app.name)
        case .device:
            DecryptClient.shared.select(app)
            DecryptClient.shared.phase = .running
            DecryptClient.shared.message = "Starting decrypt…"
            DecryptClient.shared.error = nil
            let deviceApp = DeviceApp(
                bundleID: app.bundle.isEmpty ? app.id : app.bundle,
                name: app.name,
                version: app.version,
                isAppStore: true
            )
            Task {
                await decryptOwnedStoreApp(
                    deviceApp,
                    storeURL: app.url,
                    version: version,
                    externalVersionId: externalVersionId
                )
            }
        }
    }

    /// Device-channel path for a Store listing: decrypt if already on-disk, otherwise silent
    /// purchase/download (never opens the App Store UI).
    func decryptOwnedStoreApp(
        _ app: DeviceApp,
        storeURL: String,
        version: String? = nil,
        externalVersionId: String? = nil
    ) async {
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
            // Version-pinned silent download always uses the store package (installed build may differ).
            let wantsPinned = !(version ?? "").isEmpty || !(externalVersionId ?? "").isEmpty
            if !wantsPinned, let installed = await resolveInstalledAppURL(bundleID: bid) {
                publishDecryptProgress("Decrypting \(app.name) on this device…")
                let clear = try FairPlayDecrypt.decryptInstalledApp(
                    bundleID: bid,
                    displayName: app.name,
                    knownPath: installed.path
                ) { [weak self] msg in
                    Task { @MainActor in self?.publishDecryptProgress(msg) }
                }
                finishSuccess(url: clear, name: app.name)
                return
            }
            let link = storeURL.isEmpty ? try await self.storeURL(forBundleID: bid) : storeURL
            try await silentPurchaseDownloadDecrypt(
                bundleID: bid,
                displayName: app.name,
                storeURL: link,
                version: version,
                externalVersionId: externalVersionId
            )
        } catch {
            let text = error.localizedDescription
            lastError = text
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = text
            DecryptClient.shared.message = text
            status = ""
        }
    }

    private func publishDecryptProgress(_ message: String) {
        status = message
        DecryptClient.shared.phase = .running
        DecryptClient.shared.message = message
        DecryptClient.shared.error = nil
    }

    /// ipatool-style silent buy + CDN download, then FairPlay. Never opens the App Store UI.
    private func silentPurchaseDownloadDecrypt(
        bundleID: String,
        displayName: String,
        storeURL: String,
        version: String? = nil,
        externalVersionId: String? = nil
    ) async throws {
        guard let adam = try await resolveAdamId(bundleID: bundleID, storeURL: storeURL) else {
            throw DecryptError("Couldn't resolve an App Store id for \(displayName). Try another search result.")
        }
        let spoof = StoreDeviceSpoof.current
        if spoof.enabled {
            publishDecryptProgress("Silent App Store session · spoof \(spoof.summaryLabel)…")
        } else {
            publishDecryptProgress("Silent App Store session…")
        }
        let account = try await AppleIDStore.shared.ensureStorefrontSession()

        // Explicit pin from Versions sheet, else spoof-compatible / display-version resolve inside client.
        var pinned = (externalVersionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if pinned.isEmpty {
            do {
                pinned = try await AppStoreClient.shared.resolveDownloadVersionId(
                    adamId: adam,
                    account: account,
                    version: version,
                    externalVersionId: nil
                ) ?? ""
            } catch {
                pinned = ""
            }
        }
        if spoof.enabled, pinned.isEmpty {
            publishDecryptProgress("Spoof \(spoof.summaryLabel) · downloading with store UA…")
        } else if let version, !version.isEmpty, pinned.isEmpty {
            publishDecryptProgress("Using latest owned build (couldn’t pin v\(version))…")
        } else if !pinned.isEmpty {
            publishDecryptProgress("Pinning store build \(pinned)…")
        }

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tetherless-silent", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let tag = pinned.isEmpty ? "\(adam)" : "\(adam)_\(pinned)"
        let dest = tmpDir.appendingPathComponent("\(bundleID.isEmpty ? "app" : bundleID)_\(tag).ipa")

        let ipa: URL
        let downloadedVersion: String
        let downloadedMinOS: String?
        do {
            let result = try await AppStoreClient.shared.purchaseAndDownload(
                adamId: adam,
                account: account,
                destination: dest,
                externalVersionId: pinned.isEmpty ? nil : pinned,
                version: version,
                onProgress: { [weak self] msg in
                    Task { @MainActor in self?.publishDecryptProgress(msg) }
                }
            )
            ipa = result.url
            downloadedVersion = result.item.displayVersion
            downloadedMinOS = result.item.minimumOS
            pinned = result.item.externalVersionId.isEmpty ? pinned : result.item.externalVersionId
        } catch AppStoreClientError.paidApp {
            throw DecryptError(
                "\(displayName) is paid — silent download only covers free/owned apps. Buy it once with this Apple ID, then decrypt again (still no App Store UI from TetherLess)."
            )
        } catch AppStoreClientError.licenseRequired {
            throw DecryptError(
                "This Apple ID doesn’t own a license for \(displayName). Buy or redeem it once, then decrypt again."
            )
        } catch AppStoreClientError.tokenExpired, AppStoreClientError.needsTwoFactor {
            throw DecryptError("App Store session needs refresh — sign in again under Settings › Store Access, then retry.")
        } catch AppStoreClientError.network(let detail) {
            throw DecryptError(
                "App Store download failed (\(detail)). Try: Settings › Store Access → Sign Out → Sign In, then decrypt again. If spoof is on, leave Auto-pick on and keep Client-Info rewrite off."
            )
        }

        // Prefer live install path only when we didn’t pin an older/different build.
        if pinned.isEmpty, let installed = await resolveInstalledAppURL(bundleID: bundleID) {
            publishDecryptProgress("License ready — decrypting installed \(displayName)…")
            let clear = try FairPlayDecrypt.decryptInstalledApp(
                bundleID: bundleID,
                displayName: displayName,
                knownPath: installed.path
            ) { [weak self] msg in
                Task { @MainActor in self?.publishDecryptProgress(msg) }
            }
            finishSuccess(url: clear, name: displayName)
            return
        }

        var label = downloadedVersion.isEmpty ? displayName : "\(displayName) v\(downloadedVersion)"
        if let min = downloadedMinOS, !min.isEmpty {
            label += " (iOS \(min)+)"
        }
        if spoof.enabled, let min = downloadedMinOS, !spoof.acceptsMinimumOS(min) {
            publishDecryptProgress("Warning: package wants iOS \(min)+ but spoof claims \(spoof.effectiveIOSVersion)…")
        }
        publishDecryptProgress("Decrypting silently downloaded \(label)…")
        do {
            let clear = try FairPlayDecrypt.decryptIPA(
                at: ipa,
                displayName: displayName
            ) { [weak self] msg in
                Task { @MainActor in self?.publishDecryptProgress(msg) }
            }
            finishSuccess(url: clear, name: displayName)
            return
        } catch let ipaError {
            // Optional: silent native install of the downloaded IPA (Pair), then decrypt from disk.
            if NativeInstaller.isSelected {
                publishDecryptProgress("FairPlay needs an on-device install — installing silently via Pair…")
                do {
                    try await NativeInstaller.shared.install(
                        ipaURL: ipa,
                        bundleID: bundleID,
                        name: displayName,
                        version: downloadedVersion
                    )
                    if let installed = await resolveInstalledAppURL(bundleID: bundleID) {
                        publishDecryptProgress("Installed — decrypting \(displayName)…")
                        let clear = try FairPlayDecrypt.decryptInstalledApp(
                            bundleID: bundleID,
                            displayName: displayName,
                            knownPath: installed.path
                        ) { [weak self] msg in
                            Task { @MainActor in self?.publishDecryptProgress(msg) }
                        }
                        finishSuccess(url: clear, name: displayName)
                        return
                    }
                } catch {
                    throw DecryptError(
                        "Silent download OK, Pair install/decrypt failed (\(error.localizedDescription)). Earlier FairPlay error: \(ipaError.localizedDescription). Ensure \(AppleIDStore.shared.email.isEmpty ? "this Apple ID" : AppleIDStore.shared.email) signed in to Media & Purchases once — TetherLess will not open the App Store."
                    )
                }
            }
            throw DecryptError(
                "Silent download succeeded, but FairPlay decrypt failed (\(ipaError.localizedDescription)). \(AppStoreDecryptGuide.failureHint) TetherLess does not open the App Store during decrypt."
            )
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

    /// LaunchServices is often sandboxed for other apps — also ask installd (Pair) + MobileInstallation.
    private func resolveInstalledAppURL(bundleID: String) async -> URL? {
        let fromLibrary = DeviceLibrary.shared.apps.first(where: { $0.bundleID == bundleID })?.installPath
        if let url = FairPlayDecrypt.installedAppURL(bundleID: bundleID, knownPath: fromLibrary) {
            return url
        }
        // Ask installd via Pair tunnel for Path — LaunchServices is often sandboxed for other apps.
        _ = await DeviceLibrary.shared.refreshAwaiting()
        let refreshed = DeviceLibrary.shared.apps.first(where: { $0.bundleID == bundleID })?.installPath
        if let url = FairPlayDecrypt.installedAppURL(bundleID: bundleID, knownPath: refreshed) {
            return url
        }
        return FairPlayDecrypt.installedAppURL(bundleID: bundleID)
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
                let known = await resolveInstalledAppURL(bundleID: app.bundleID)?.path
                let clear = try FairPlayDecrypt.decryptInstalledApp(
                    bundleID: app.bundleID,
                    displayName: app.name,
                    knownPath: known
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
