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

    /// Known-free App Store listing used for one-tap Store → download → companion smoke tests.
    /// TestFlight is free on every storefront and small enough to validate the path quickly.
    static let smokeTestApp = DecryptApp(
        id: "smoke-testflight",
        name: "TestFlight",
        bundle: "com.apple.TestFlight",
        icon: nil,
        dev: "Apple",
        version: "",
        url: "https://apps.apple.com/app/id899247664"
    )

    /// One-tap path: reinforce Store → silent download TestFlight → companion install/open.
    func runStoreConnectionSmokeTest() {
        // Force device channel so Telegram bot mode can't swallow the smoke test.
        DecryptChannel.current = .device
        // Real-device identity only — wipe any leftover Store spoof prefs before smoke test.
        StoreDeviceSpoof.clearPersistedSpoof()
        decryptFromSearch(Self.smokeTestApp)
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
        AppleIDStore.shared.sanitizeStoreIdentityForAccountAPIs()

        func history(_ account: StorefrontSession) async throws -> [OwnedStoreApp] {
            try await AppStoreClient.shared.purchaseHistory(account: account)
        }

        // Prefer any persisted store session. Never clear/remint Store Access just to list
        // Owned — Purchase DAAP failures are not proof the MZFinance passwordToken is dead
        // (wiping here flipped Settings from green → HTTP 404 after Retry).
        if let existing = AppleIDStore.shared.storefrontSession(), existing.isUsable {
            return try await history(existing)
        }

        let account = try await AppleIDStore.shared.ensureStorefrontSession()
        return try await history(account)
    }

    /// purchaseAndDownload with one automatic store-token remint on expiry (PET cascade; no sign-out).
    private func purchaseAndDownloadWithStoreRefresh(
        adamId: Int,
        account: inout StorefrontSession,
        destination: URL,
        externalVersionId: String?,
        version: String?
    ) async throws -> (url: URL, item: StoreDownloadItem) {
        func run(_ session: StorefrontSession) async throws -> (url: URL, item: StoreDownloadItem) {
            try await AppStoreClient.shared.purchaseAndDownload(
                adamId: adamId,
                account: session,
                destination: destination,
                externalVersionId: externalVersionId,
                version: version,
                onProgress: { [weak self] msg in
                    Task { @MainActor in self?.publishDecryptProgress(msg) }
                }
            )
        }
        do {
            return try await run(account)
        } catch AppStoreClientError.tokenExpired {
            publishDecryptProgress("Refreshing App Store download session…")
            AppleIDStore.shared.invalidateStorefrontSession()
            let refreshed = try await AppleIDStore.shared.ensureStorefrontSession(forceRefresh: true)
            account = refreshed
            return try await run(refreshed)
        } catch AppStoreClientError.licenseRequired {
            // Owned but license probe failed — remint once then retry buy+download.
            publishDecryptProgress("Re-checking App Store license…")
            AppleIDStore.shared.invalidateStorefrontSession()
            let refreshed = try await AppleIDStore.shared.ensureStorefrontSession(forceRefresh: true)
            account = refreshed
            return try await run(refreshed)
        }
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
        var items: [URLQueryItem]
        if let adam {
            items = [URLQueryItem(name: "id", value: "\(adam)"), URLQueryItem(name: "limit", value: "1")]
        } else {
            items = [URLQueryItem(name: "bundleId", value: bundle), URLQueryItem(name: "limit", value: "1")]
        }
        if !app.countryCode.isEmpty {
            items.append(URLQueryItem(name: "country", value: app.countryCode))
        }
        comps.queryItems = items
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

    /// Public iTunes search across every linked Store Access storefront — no FastDecryptBot / Telegram.
    func searchAppStore(_ term: String) async throws -> [DecryptApp] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        if DecryptClient.isStoreLink(q) {
            return try await [appInfo(url: q)]
        }
        let linked = AppleIDStore.shared.linkedStorefrontCountryCodes()
        let countries = linked.isEmpty ? ["us"] : linked
        let batches = await withTaskGroup(of: [DecryptApp].self, returning: [[DecryptApp]].self) { group in
            for country in countries {
                group.addTask {
                    await Self.searchItunes(term: q, country: country)
                }
            }
            var out: [[DecryptApp]] = []
            for await batch in group {
                out.append(batch)
            }
            return out
        }
        var merged: [DecryptApp] = []
        var seen = Set<String>()
        for batch in batches {
            for app in batch {
                if seen.insert(app.id).inserted {
                    merged.append(app)
                }
            }
        }
        return merged.sorted {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return $0.countryLabel < $1.countryLabel
        }
    }

    /// One-country iTunes software search (nonisolated so storefronts run in parallel).
    nonisolated private static func searchItunes(term: String, country: String) async -> [DecryptApp] {
        let code = country.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !code.isEmpty else { return [] }
        guard var comps = URLComponents(string: "https://itunes.apple.com/search") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "software"),
            URLQueryItem(name: "country", value: code),
            URLQueryItem(name: "limit", value: "25")
        ]
        guard let url = comps.url else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            return []
        }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let results = json["results"] as? [[String: Any]] ?? []
        let label = StorefrontCountry.label(forCode: code)
        return results.compactMap { row in
            guard let trackId = row["trackId"] as? Int else { return nil }
            let name = (row["trackName"] as? String) ?? "App"
            let bundle = (row["bundleId"] as? String) ?? ""
            let artist = (row["artistName"] as? String) ?? ""
            let version = (row["version"] as? String) ?? ""
            let link = (row["trackViewUrl"] as? String)
                ?? "https://apps.apple.com/\(code)/app/id\(trackId)"
            let icon = (row["artworkUrl512"] as? String).flatMap(URL.init(string:))
                ?? (row["artworkUrl100"] as? String).flatMap(URL.init(string:))
            return DecryptApp(
                id: "itunes-\(trackId)-\(code)",
                name: name,
                bundle: bundle,
                icon: icon,
                dev: artist,
                version: version,
                url: link,
                countryCode: code,
                countryLabel: label
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
        let country = StorefrontCountry.code(fromAppStoreURL: url) ?? ""
        let label = country.isEmpty ? "" : StorefrontCountry.label(forCode: country)
        if let id, var comps = URLComponents(string: "https://itunes.apple.com/lookup") {
            var items = [URLQueryItem(name: "id", value: id)]
            if !country.isEmpty {
                items.append(URLQueryItem(name: "country", value: country))
            }
            comps.queryItems = items
            if let u = comps.url {
                let (data, _) = try await URLSession.shared.data(from: u)
                let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                if let row = (json["results"] as? [[String: Any]])?.first {
                    let name = (row["trackName"] as? String) ?? "App"
                    let bundle = (row["bundleId"] as? String) ?? ""
                    let artist = (row["artistName"] as? String) ?? ""
                    let version = (row["version"] as? String) ?? ""
                    let icon = (row["artworkUrl512"] as? String).flatMap(URL.init(string:))
                    return DecryptApp(
                        id: url,
                        name: name,
                        bundle: bundle,
                        icon: icon,
                        dev: artist,
                        version: version,
                        url: url,
                        countryCode: country,
                        countryLabel: label
                    )
                }
            }
        }
        return DecryptApp(
            id: url,
            name: "App",
            bundle: "",
            icon: nil,
            dev: "",
            version: "",
            url: url,
            countryCode: country,
            countryLabel: label
        )
    }

    /// Phone-worker / TG-bot path: silent Store download + **in-process** FairPlay so a clear
    /// IPA file exists on this host for upload (skips companion install UI).
    func decryptForWorkerUpload(
        storeURL: String,
        displayName: String = "App",
        version: String? = nil,
        progress: ((String) -> Void)? = nil
    ) async throws -> (url: URL, name: String, version: String) {
        guard AppleIDStore.shared.isSignedIn else {
            throw DecryptError("Sign in under Settings › Store Access first.")
        }
        try FairPlayKeyGate.requireReady()
        let adam = try await resolveAdamId(bundleID: "", storeURL: storeURL)
        guard let adam else {
            throw DecryptError("Couldn't resolve an App Store id from that link.")
        }
        progress?("Reinforcing Store connection…")
        guard let reinforced = await AppleIDStore.shared.reinforceStoreConnection() else {
            throw DecryptError("Sign in under Settings › Store Access first.")
        }
        var account = reinforced
        var pinned = ""
        if let version, !version.isEmpty {
            pinned = (try? await AppStoreClient.shared.resolveDownloadVersionId(
                adamId: adam,
                account: account,
                version: version,
                externalVersionId: nil
            )) ?? ""
        }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tetherless-worker", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dest = tmpDir.appendingPathComponent("worker_\(adam).ipa")
        progress?("Downloading encrypted IPA…")
        let result = try await purchaseAndDownloadWithStoreRefresh(
            adamId: adam,
            account: &account,
            destination: dest,
            externalVersionId: pinned.isEmpty ? nil : pinned,
            version: version
        )
        let name = displayName.isEmpty ? "App" : displayName
        progress?("Decrypting on this iPhone…")
        let clear = try FairPlayDecrypt.decryptIPA(
            at: result.url,
            displayName: name
        ) { msg in
            progress?(msg)
        }
        return (clear, name, result.item.displayVersion)
    }

    /// Decrypt an app already on this iPhone via companion FairPlay.
    /// Prefers the live install path so Store Access / silent download is optional.
    func decryptInstalled(_ app: DeviceApp, version: String? = nil) async {
        guard !busy else { return }
        busy = true
        lastError = nil
        status = "Preparing \(app.name)…"
        defer { busy = false }
        do {
            DecryptClient.shared.select(
                DecryptApp(
                    id: app.bundleID,
                    name: app.name,
                    bundle: app.bundleID,
                    icon: nil,
                    dev: "",
                    version: app.version,
                    url: ""
                )
            )
            DecryptClient.shared.phase = .running

            // 1) Live install → companion (no Store session required — FairPlay keys are
            //    already on-device from the App Store install of this title).
            if let installed = await resolveInstalledAppURL(bundleID: app.bundleID) {
                publishDecryptProgress("Using installed \(app.name) — Store login not required…")
                try await decryptFromInstalledPath(installed, displayName: app.name, bundleID: app.bundleID)
                return
            }

            // 2) Optional Store download only when install path is missing and Store is green.
            if AppleIDStore.shared.storefrontSession()?.isUsable == true {
                publishDecryptProgress("Install path missing — trying Store package…")
                do {
                    let storeURL = try await storeURL(forBundleID: app.bundleID)
                    try await silentPurchaseDownloadDecrypt(
                        bundleID: app.bundleID,
                        displayName: app.name,
                        storeURL: storeURL,
                        version: version
                    )
                    return
                } catch {
                    publishDecryptProgress(error.localizedDescription)
                }
            }

            throw FairPlayDecryptError.noInstalledApp(
                "Can’t find \(app.name) on disk (\(app.bundleID)). Pair Native and refresh Installed, or unlock Store Access to download."
            )
        } catch {
            lastError = error.localizedDescription
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = error.localizedDescription
            DecryptClient.shared.message = error.localizedDescription
            status = ""
        }
    }

    /// Companion embed from a live `/var/containers/Bundle/Application/…/*.app`, then
    /// in-process FairPlay if companion signing/install fails.
    private func decryptFromInstalledPath(
        _ installed: URL,
        displayName: String,
        bundleID: String
    ) async throws {
        publishDecryptProgress("Building Tetherless Decrypt companion for \(displayName)…")
        do {
            _ = try await DecryptCompanionInstaller.installAndOpen(
                embeddingInstalledApp: installed,
                displayName: displayName
            ) { [weak self] msg in
                Task { @MainActor in self?.publishDecryptProgress(msg) }
            }
            markCompanionHandoff(displayName: displayName)
            return
        } catch {
            publishDecryptProgress("Companion install failed — trying in-app FairPlay…")
            publishDecryptProgress(error.localizedDescription)
            let clear = try FairPlayDecrypt.decryptInstalledApp(
                bundleID: bundleID,
                displayName: displayName,
                knownPath: installed.path
            ) { [weak self] msg in
                Task { @MainActor in self?.publishDecryptProgress(msg) }
            }
            finishSuccess(url: clear, name: displayName)
        }
    }

    func decryptFromSearch(_ app: DecryptApp, version: String? = nil, externalVersionId: String? = nil) {
        if !app.countryCode.isEmpty {
            AppleIDStore.shared.selectAccountMatching(countryCode: app.countryCode)
        }
        switch DecryptChannel.current {
        case .telegram:
            DecryptClient.shared.select(app)
            DecryptClient.shared.start(url: app.url, version: version, display: app.name)
        case .device:
            DecryptClient.shared.select(app)
            DecryptClient.shared.phase = .running
            DecryptClient.shared.message = "Starting…"
            DecryptClient.shared.error = nil
            let deviceApp = DeviceApp(
                bundleID: app.bundle,
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

    /// Device-channel path for a Store listing: silent purchase/download (or live-install
    /// embed), then hand FairPlay to the companion IPA (never opens the App Store UI).
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
            let link: String
            if !storeURL.isEmpty {
                link = storeURL
            } else if !bid.isEmpty {
                link = try await self.storeURL(forBundleID: bid)
            } else {
                throw DecryptError("Missing App Store link or bundle ID — search again or paste an App Store link.")
            }
            // Adam ID in the store URL is enough for silent download (iPadn delisted stubs).
            let hasAdam = link.range(of: #"/id\d+"#, options: .regularExpression) != nil
            guard !bid.isEmpty || hasAdam else {
                throw DecryptError("Missing bundle ID — search again or paste an App Store link.")
            }
            // Always hand FairPlay to the separate “Tetherless Decrypt” companion IPA
            // (store package preferred; live install embed if download fails).
            do {
                try await silentPurchaseDownloadDecrypt(
                    bundleID: bid,
                    displayName: app.name,
                    storeURL: link,
                    version: version,
                    externalVersionId: externalVersionId
                )
                return
            } catch {
                guard !bid.isEmpty, let installed = await resolveInstalledAppURL(bundleID: bid) else { throw error }
                publishDecryptProgress("Store package failed — embedding installed \(app.name) into companion…")
                publishDecryptProgress(error.localizedDescription)
                try FairPlayKeyGate.requireReady()
                _ = try await DecryptCompanionInstaller.installAndOpen(
                    embeddingInstalledApp: installed,
                    displayName: app.name
                ) { [weak self] msg in
                    Task { @MainActor in self?.publishDecryptProgress(msg) }
                }
                markCompanionHandoff(displayName: app.name)
            }
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

    /// Host finished packaging — FairPlay console continues in the installed companion IPA.
    private func markCompanionHandoff(displayName: String) {
        DecryptClient.shared.phase = .running
        DecryptClient.shared.message =
            "Open Tetherless Decrypt — Trust your Apple ID under Settings › General › VPN & Device Management if iOS asks."
        DecryptClient.shared.error = nil
        status = "Companion installed for \(displayName)"
        DecryptCompanionController.shared.dismiss()
    }

    /// ipatool-style silent buy + CDN download, then companion IPA FairPlay. Never opens the App Store UI.
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
        publishDecryptProgress("Contacting Apple…")
        StoreDeviceSpoof.clearPersistedSpoof()
        publishDecryptProgress("Reinforcing Store connection…")
        guard let reinforced = await AppleIDStore.shared.reinforceStoreConnection() else {
            throw DecryptError("Sign in under Settings › Store Access with the Apple ID that owns this app.")
        }
        var account = reinforced

        // Explicit pin from Versions sheet, else display-version resolve inside client.
        var pinned = (externalVersionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if pinned.isEmpty {
            do {
                pinned = try await AppStoreClient.shared.resolveDownloadVersionId(
                    adamId: adam,
                    account: account,
                    version: version,
                    externalVersionId: nil
                ) ?? ""
            } catch AppStoreClientError.tokenExpired {
                AppleIDStore.shared.invalidateStorefrontSession()
                account = try await AppleIDStore.shared.ensureStorefrontSession(forceRefresh: true)
                pinned = (try? await AppStoreClient.shared.resolveDownloadVersionId(
                    adamId: adam,
                    account: account,
                    version: version,
                    externalVersionId: nil
                )) ?? ""
            } catch {
                pinned = ""
            }
        }
        if let version, !version.isEmpty, pinned.isEmpty {
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
        var identityRetryUsed = false
        downloadAttempt: while true {
            do {
                let result = try await purchaseAndDownloadWithStoreRefresh(
                    adamId: adam,
                    account: &account,
                    destination: dest,
                    externalVersionId: pinned.isEmpty ? nil : pinned,
                    version: version
                )
                ipa = result.url
                downloadedVersion = result.item.displayVersion
                pinned = result.item.externalVersionId.isEmpty ? pinned : result.item.externalVersionId
                break downloadAttempt
            } catch AppStoreClientError.paidApp {
                throw DecryptError(
                    "\(displayName) is paid — silent download only covers free/owned apps. Buy it once with this Apple ID, then decrypt again (still no App Store UI from TetherLess)."
                )
            } catch AppStoreClientError.licenseRequired {
                throw DecryptError(
                    "This Apple ID doesn’t own a license for \(displayName). Buy or redeem it once, then decrypt again."
                )
            } catch AppStoreClientError.needsTwoFactor {
                AppleIDStore.shared.noteStoreNeedsVerification()
                throw DecryptError(
                    "Store needs the first Sign In trust. In Settings › Store Access, Sign Out then Sign In once — the Allow / verification code unlocks Store automatically (no second text)."
                )
            } catch AppStoreClientError.tokenExpired {
                throw DecryptError(
                    "App Store session couldn’t refresh automatically — open Settings › Store Access and tap refresh, then retry. You should still be signed in."
                )
            } catch AppStoreClientError.network(let detail) {
                let lower = detail.lowercased()
                if (lower.contains("403") || lower.contains("client identity")), !identityRetryUsed {
                    identityRetryUsed = true
                    StoreDeviceSpoof.clearPersistedSpoof()
                    // SideStore-style: rotate anisette server, then remint passwordToken.
                    let nextAni = await AnisetteClient.shared.rotateServer()
                    publishDecryptProgress(
                        "Store HTTP 403 — rotated anisette to \(nextAni.host ?? "server"), reminting session…"
                    )
                    await AnisetteClient.shared.invalidate(resetProvisioning: true)
                    SAPSigner.invalidateCache()
                    AppleIDStore.shared.invalidateStorefrontSession()
                    if let refreshed = await AppleIDStore.shared.reinforceStoreConnection(forceRemint: true) {
                        account = refreshed
                    }
                    continue downloadAttempt
                }
                if lower.contains("403") || lower.contains("client identity") {
                    // Option 2: phone keeps FairPlay; backend runs volumeStore + CDN with the
                    // device-minted SAP signature / anisette / passwordToken.
                    publishDecryptProgress(
                        "Phone Store still 403 — trying backend encrypted-IPA fetch…"
                    )
                    do {
                        let result = try await AppStoreClient.shared.downloadIPAViaBackend(
                            adamId: adam,
                            account: account,
                            destination: dest,
                            externalVersionId: pinned.isEmpty ? nil : pinned
                        ) { [weak self] msg in
                            Task { @MainActor in self?.publishDecryptProgress(msg) }
                        }
                        ipa = result.url
                        downloadedVersion = result.item.displayVersion
                        pinned = result.item.externalVersionId.isEmpty ? pinned : result.item.externalVersionId
                        break downloadAttempt
                    } catch {
                        throw DecryptError(
                            "App Store download failed (\(detail)). Backend fetch also failed: \(error.localizedDescription). Remint Store Access and retry."
                        )
                    }
                }
                throw DecryptError(
                    "App Store download failed (\(detail)). Retry from Settings › Store Access if needed."
                )
            }
        }

        let label = downloadedVersion.isEmpty ? displayName : "\(displayName) v\(downloadedVersion)"
        // Competition path: build/sign/install a real “Tetherless Decrypt” companion
        // IPA (EmbeddedPayload + user’s Apple ID cert). The console UI runs only there.
        publishDecryptProgress("Building Tetherless Decrypt companion for \(label)…")
        try FairPlayKeyGate.requireReady()
        do {
            _ = try await DecryptCompanionInstaller.installAndOpen(
                embedding: ipa,
                displayName: displayName
            ) { [weak self] msg in
                Task { @MainActor in self?.publishDecryptProgress(msg) }
            }
            markCompanionHandoff(displayName: displayName)
            return
        } catch {
            // Last-resort fallback: in-process IPA decrypt (no companion console UI on host).
            publishDecryptProgress("Companion install failed — trying in-app FairPlay…")
            publishDecryptProgress(error.localizedDescription)
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
                if NativeInstaller.isSelected {
                    publishDecryptProgress("Uploading target app to iPhone for install-path decrypt…")
                    do {
                        try await NativeInstaller.shared.install(
                            ipaURL: ipa,
                            bundleID: bundleID,
                            name: displayName,
                            version: downloadedVersion
                        )
                        if let installed = await resolveInstalledAppURL(bundleID: bundleID) {
                            // Prefer companion embed from the fresh install over host console.
                            do {
                                _ = try await DecryptCompanionInstaller.installAndOpen(
                                    embeddingInstalledApp: installed,
                                    displayName: displayName
                                ) { [weak self] msg in
                                    Task { @MainActor in self?.publishDecryptProgress(msg) }
                                }
                                markCompanionHandoff(displayName: displayName)
                                return
                            } catch {
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
                        }
                    } catch {
                        throw DecryptError(
                            "Companion + Pair fallback failed (\(error.localizedDescription)). Earlier FairPlay error: \(ipaError.localizedDescription)."
                        )
                    }
                }
                // Ack without real Media & Purchases keys → clear so Decrypt UI re-prompts sign-in.
                AppStoreDecryptGuide.setAcknowledged(false, email: AppleIDStore.shared.email)
                throw DecryptError(
                    "Silent download succeeded, but FairPlay decrypt failed (\(ipaError.localizedDescription)). \(AppStoreDecryptGuide.failureHint)"
                )
            }
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
        SideloadIPACache.shared.remember(url: url, kind: .decrypted, name: name)
    }

    /// Decrypt every listed App Store app with on-device FairPlay (main + frameworks + nested).
    /// Uses live install paths — Store Access is not required.
    func decryptAllInstalled(stopOnError: Bool = false) async {
        guard !busy else { return }
        let apps = drmApps
        guard !apps.isEmpty else {
            lastError = "No App Store apps listed. Pair Native and refresh."
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
