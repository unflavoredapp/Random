//
// Brand: Tetherless · https://tetherless.dev
//  DeviceDecryptService.swift
//  On-device decrypt: hardened FairPlay mremap on apps installed on this iPhone
//  (App Store keys + SC_Info). When the app isn’t installed yet, Device mode opens
//  the App Store listing for *your* Apple ID, waits for the install, then decrypts
//  locally — no Telegram bot fallback.
//

import Foundation
import IDeviceSwift
import SwiftUI
import ZIPFoundation

@MainActor
final class DeviceDecryptService: ObservableObject {
    static let shared = DeviceDecryptService()

    @Published private(set) var busy = false
    @Published var status = ""
    @Published var lastError: String?
    /// Last versions-sheet failure (auth/network) — not “no versions”.
    @Published var lastVersionError: String?
    /// Last batch / single-run detail line (counts, soft-fails).
    @Published var lastReportSummary = ""

    private init() {}

    /// App Store / TestFlight DRM apps on this device that can be decrypted with local keys.
    var drmApps: [DeviceApp] {
        let includeTF = FairPlayAdvancedOptions.includeTestFlightApps
        return DeviceLibrary.shared.apps.filter { $0.isDecryptTarget(includeTestFlight: includeTF) }
    }

    /// Known-free *third-party* App Store listing for Store → companion smoke tests.
    /// Do not use Apple system apps (TestFlight, etc.) — they are gated and often mremap-ENOMEM.
    static let smokeTestApp = DecryptApp(
        id: "smoke-duckduckgo",
        name: "DuckDuckGo",
        bundle: "com.duckduckgo.mobile.ios",
        icon: nil,
        dev: "DuckDuckGo",
        version: "",
        url: "https://apps.apple.com/app/id663592361"
    )

    /// One-tap path: silent download a free third-party app → companion FairPlay.
    func runStoreConnectionSmokeTest() {
        // Force device channel so Telegram bot mode can't swallow the smoke test.
        DecryptChannel.current = .device
        // Real-device identity only — wipe any leftover Store spoof prefs before smoke test.
        StoreDeviceSpoof.clearPersistedSpoof()
        decryptFromSearch(Self.smokeTestApp)
    }

    /// Version history: prefer authenticated MZFinance externalVersionIds, then public iTunes current build.
    func versionList(for app: DecryptApp) async -> (versions: [DecryptVersion], minOS: String?)? {
        lastVersionError = nil
        let store = await storeVersionHistory(for: app)
        let pub = await publicItunesVersionList(for: app)
        // iPadn third-party history feeds (Timbrd / Bilin / iosdump) — same sources
        // as mengangs/ipadn VersionService — fill gaps Store / iTunes omit.
        let adam = await resolveAdamIdString(for: app)
        let ipadn: [DecryptVersion]
        if IPadnOptional.isEnabled, let adam {
            ipadn = await IPadnVersionHistory.fetch(adamId: adam)
        } else {
            ipadn = []
        }
        let merged = Self.mergeVersionLists(store?.versions ?? [], pub?.versions ?? [], ipadn)
        guard !merged.isEmpty else { return nil }
        if !merged.isEmpty, store == nil, !ipadn.isEmpty {
            lastVersionError = nil
        }
        let minOS = store?.minOS ?? pub?.minOS ?? merged.first(where: \.current)?.minOS ?? merged.first?.minOS
        return (merged, minOS)
    }

    private func resolveAdamIdString(for app: DecryptApp) async -> String? {
        if let r = app.url.range(of: #"/id(\d+)"#, options: .regularExpression) {
            let digits = String(app.url[r]).filter(\.isNumber)
            if !digits.isEmpty { return digits }
        }
        if let id = app.id.split(separator: "-").dropFirst().first, id.allSatisfy(\.isNumber) {
            return String(id)
        }
        if let adam = try? await resolveAdamId(bundleID: app.bundle, storeURL: app.url) {
            return String(adam)
        }
        return nil
    }

    /// Prefer Store rows (minOS / current), then fill missing external IDs from public / iPadn feeds.
    private static func mergeVersionLists(_ store: [DecryptVersion], _ pub: [DecryptVersion], _ ipadn: [DecryptVersion]) -> [DecryptVersion] {
        var byKey: [String: DecryptVersion] = [:]
        var order: [String] = []
        func key(_ v: DecryptVersion) -> String {
            let ext = (v.externalId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !ext.isEmpty { return "e:\(ext)" }
            return "v:\(v.v)"
        }
        func ingest(_ list: [DecryptVersion], preferIncomingMinOS: Bool) {
            for item in list {
                let k = key(item)
                if let existing = byKey[k] {
                    byKey[k] = DecryptVersion(
                        v: item.v.count > existing.v.count || existing.v == "—" ? item.v : existing.v,
                        current: existing.current || item.current,
                        minOS: preferIncomingMinOS ? (item.minOS ?? existing.minOS) : (existing.minOS ?? item.minOS),
                        externalId: existing.externalId ?? item.externalId
                    )
                } else {
                    byKey[k] = item
                    order.append(k)
                }
            }
        }
        ingest(store, preferIncomingMinOS: true)
        ingest(pub, preferIncomingMinOS: false)
        ingest(ipadn, preferIncomingMinOS: false)
        var out = order.compactMap { byKey[$0] }
        if let first = out.firstIndex(where: \.current) {
            // Keep a single "Latest" flag.
            for i in out.indices where i != first {
                if out[i].current {
                    out[i] = DecryptVersion(v: out[i].v, current: false, minOS: out[i].minOS, externalId: out[i].externalId)
                }
            }
        } else if !out.isEmpty {
            let i = 0
            out[i] = DecryptVersion(v: out[i].v, current: true, minOS: out[i].minOS, externalId: out[i].externalId)
        }
        return out
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
        let apps: [OwnedStoreApp]
        if let existing = AppleIDStore.shared.storefrontSession(), existing.isUsable {
            apps = try await history(existing)
        } else {
            let account = try await AppleIDStore.shared.ensureStorefrontSession()
            apps = try await history(account)
        }
        // DAAP purchase rows omit artwork — hydrate from public iTunes lookup.
        return await Self.hydrateOwnedArtwork(apps)
    }

    /// Batch-fill `iconURL` via `itunes.apple.com/lookup` (comma-separated adam IDs),
    /// then fall back to per-app bundle ID / store URL lookup for any still missing.
    private static func hydrateOwnedArtwork(_ apps: [OwnedStoreApp]) async -> [OwnedStoreApp] {
        var out = apps
        let missing = out.enumerated().compactMap { idx, app -> (Int, Int)? in
            app.iconURL == nil && app.adamId != 0 ? (idx, app.adamId) : nil
        }

        let chunkSize = 40
        var cursor = 0
        while cursor < missing.count {
            let end = min(cursor + chunkSize, missing.count)
            let chunk = Array(missing[cursor..<end])
            cursor = end
            let idList = chunk.map { String($0.1) }.joined(separator: ",")
            guard var comps = URLComponents(string: "https://itunes.apple.com/lookup") else { continue }
            comps.queryItems = [URLQueryItem(name: "id", value: idList)]
            guard let url = comps.url,
                  let (data, resp) = try? await URLSession.shared.data(from: url),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = json["results"] as? [[String: Any]] else { continue }

            var byAdam: [Int: URL] = [:]
            for row in rows {
                let adam: Int?
                if let n = row["trackId"] as? Int { adam = n }
                else if let n = row["trackId"] as? Int64 { adam = Int(n) }
                else if let s = row["trackId"] as? String { adam = Int(s) }
                else { adam = nil }
                guard let adam else { continue }
                let icon = (row["artworkUrl512"] as? String).flatMap(URL.init(string:))
                    ?? (row["artworkUrl100"] as? String)
                        .map { $0.replacingOccurrences(of: "100x100", with: "200x200") }
                        .flatMap(URL.init(string:))
                if let icon { byAdam[adam] = icon }
            }
            for (idx, adam) in chunk {
                if let icon = byAdam[adam] { out[idx].iconURL = icon }
            }
        }

        // Bundle-ID / store-URL fallback when adam batch missed a row (region / delisted / empty id).
        for i in out.indices where out[i].iconURL == nil {
            let bid = out[i].bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !bid.isEmpty || out[i].adamId != 0 else { continue }
            if let icon = await artworkURL(bundleID: bid.isEmpty ? nil : bid, storeURL: out[i].storeURL) {
                out[i].iconURL = icon
            }
        }
        return out
    }

    /// iPadn DownloadDispatch fetch (no remint / anisette rotate / backend IPA).
    private func purchaseAndDownloadWithStoreRefresh(
        adamId: Int,
        account: inout StorefrontSession,
        destination: URL,
        externalVersionId: String?,
        version: String?
    ) async throws -> (url: URL, item: StoreDownloadItem) {
        _ = version
        return try await IPadnStoreDownload.purchaseAndDownload(
            adamId: adamId,
            account: account,
            destination: destination,
            externalVersionId: externalVersionId,
            onProgress: { [weak self] msg in
                Task { @MainActor in self?.publishDecryptProgress(msg) }
            }
        )
    }

    private func storeVersionHistory(for app: DecryptApp) async -> (versions: [DecryptVersion], minOS: String?)? {
        guard AppleIDStore.shared.isSignedIn else { return nil }
        do {
            let adam = try await resolveAdamId(bundleID: app.bundle, storeURL: app.url)
            guard let adam else {
                lastVersionError = "Couldn't resolve an App Store id for \(app.name)."
                return nil
            }
            let account = AppleIDStore.shared.storefrontSession()?.isUsable == true
                ? AppleIDStore.shared.storefrontSession()!
                : try await AppleIDStore.shared.ensureStorefrontSession()
            // DownloadDispatch tickets (same path as Get/Download) — not volumeStore.
            let versions = try await IPadnStoreDownload.resolveVersionHistory(
                adamId: adam,
                account: account,
                limit: 40
            )
            guard !versions.isEmpty else { return nil }
            let minOS = versions.first(where: \.current)?.minOS ?? versions.first?.minOS
            return (versions, minOS)
        } catch {
            lastVersionError = error.localizedDescription
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

    /// Public iTunes artwork for job cards when a DecryptApp / download was created without an icon.
    static func artworkURL(bundleID: String?, storeURL: String?) async -> URL? {
        if let storeURL,
           let r = storeURL.range(of: #"/id(\d+)"#, options: .regularExpression) {
            let adam = String(storeURL[r]).filter(\.isNumber)
            if let url = await artworkURL(adamId: adam) { return url }
        }
        let bid = (bundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bid.isEmpty else { return nil }
        guard var comps = URLComponents(string: "https://itunes.apple.com/lookup") else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "bundleId", value: bid),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let url = comps.url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let row = (json["results"] as? [[String: Any]])?.first
        return (row?["artworkUrl512"] as? String).flatMap(URL.init(string:))
            ?? (row?["artworkUrl100"] as? String).flatMap(URL.init(string:))
    }

    private static func artworkURL(adamId: String) async -> URL? {
        guard !adamId.isEmpty,
              var comps = URLComponents(string: "https://itunes.apple.com/lookup") else { return nil }
        comps.queryItems = [URLQueryItem(name: "id", value: adamId), URLQueryItem(name: "limit", value: "1")]
        guard let url = comps.url else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        let row = (json["results"] as? [[String: Any]])?.first
        return (row?["artworkUrl512"] as? String).flatMap(URL.init(string:))
            ?? (row?["artworkUrl100"] as? String).flatMap(URL.init(string:))
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
            throw DecryptError("No App Store listing for \(id). Install it from the App Store with the Apple ID you use under Account, then try again.")
        }
        if let track = first["trackViewUrl"] as? String, !track.isEmpty { return track }
        if let trackId = first["trackId"] as? Int {
            return "https://apps.apple.com/app/id\(trackId)"
        }
        throw DecryptError("Couldn't find an App Store link for \(id).")
    }

    /// Public iTunes search across every linked Store Access storefront — no FastDecryptBot / Telegram.
    /// Store search powered by vendored iPadn StoreService logic (name / App ID /
    /// apps.apple.com link, multi-region + delisted stubs). Falls back to the
    /// legacy iTunes-only path if iPadn is disabled or the query fails.
    func searchAppStore(_ term: String) async throws -> [DecryptApp] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }

        let linked = AppleIDStore.shared.linkedStorefrontCountryCodes()
        guard IPadnOptional.isEnabled else {
            if DecryptClient.isStoreLink(q) {
                return try await [appInfo(url: q)]
            }
            return try await legacyItunesSearch(q, countries: linked.isEmpty ? ["us"] : linked)
        }

        let accountCountry = linked.first?.uppercased()
        let country = UserDefaults.standard.string(forKey: IPadnOptional.countryKey)
            ?? accountCountry
            ?? "US"
        let platformRaw = UserDefaults.standard.string(forKey: IPadnOptional.platformKey) ?? IPadnPlatform.iOS.rawValue
        let platform = IPadnPlatform(rawValue: platformRaw) ?? .iOS
        let ctx = IPadnStoreContext(country: country.uppercased(), platform: platform)

        do {
            let apps = try await IPadnStoreClient.search(
                q,
                context: ctx,
                accountCountry: accountCountry,
                limit: 30
            )
            if !apps.isEmpty {
                return apps.map { $0.asDecryptApp() }
            }
            // Empty keyword search — try legacy multi-storefront iTunes as a second pass.
            if let parsed = try? IPadnSearchQuery.parse(q), case .keyword = parsed {
                return try await legacyItunesSearch(q, countries: linked.isEmpty ? ["us"] : linked)
            }
            return []
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if DecryptClient.isStoreLink(q) {
                return try await [appInfo(url: q)]
            }
            return try await legacyItunesSearch(q, countries: linked.isEmpty ? ["us"] : linked)
        }
    }

    private func legacyItunesSearch(_ q: String, countries: [String]) async throws -> [DecryptApp] {
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
            throw DecryptError("Sign in under Account first.")
        }
        if AppleSystemAppGate.isBlocked(bundleID: nil, storeURL: storeURL) {
            throw DecryptError(AppleSystemAppGate.userMessage)
        }
        try FairPlayKeyGate.requireReady()
        let adam = try await resolveAdamId(bundleID: "", storeURL: storeURL)
        guard let adam else {
            throw DecryptError("Couldn't resolve an App Store id from that link.")
        }
        guard var account = AppleIDStore.shared.storefrontSession(), account.isUsable else {
            throw DecryptError("Sign in under Account first.")
        }
        let pinned = (version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
        // Prefer a live App Store install’s SC_Info when present — IPA-only mremap usually fails.
        // Best reliability: install the app once from the Store on this device, then keep Phone Worker on.
        progress?("Decrypting on this iPhone (live install licenses when available)…")
        let clear: URL
        do {
            clear = try FairPlayDecrypt.decryptIPA(
                at: result.url,
                displayName: name,
                preferIPAContentsOnly: false
            ) { msg in
                progress?(msg)
            }
        } catch {
            let text = error.localizedDescription
            if text.localizedCaseInsensitiveContains("still encrypted")
                || text.localizedCaseInsensitiveContains("cryptid")
                || text.localizedCaseInsensitiveContains("eperm")
                || text.localizedCaseInsensitiveContains("operation not permitted") {
                throw DecryptError(
                    "Phone Worker FairPlay needs this app installed from the App Store on this iPhone (same Apple ID), or use Get → companion. \(text)"
                )
            }
            throw error
        }
        if let verify = try? FairPlayDecrypt.verifyIPA(at: clear), !verify.isFullyClear {
            throw DecryptError(
                "Phone Worker left encrypted Mach-Os (\(verify.summary)). Install the app from the App Store on this device, confirm FairPlay keys, then retry — or use Get → FastDecryptBot companion."
            )
        }
        return (clear, name, result.item.displayVersion)
    }

    /// Decrypt an app already on this iPhone: Store IPA → companion when possible,
    /// otherwise embed the live install into the companion. No in-app FairPlay.
    func decryptInstalled(_ app: DeviceApp, version: String? = nil) async {
        guard !busy else { return }
        if AppleSystemAppGate.isBlocked(bundleID: app.bundleID, storeURL: nil) {
            lastError = AppleSystemAppGate.userMessage
            status = AppleSystemAppGate.userMessage
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = AppleSystemAppGate.userMessage
            DecryptClient.shared.message = AppleSystemAppGate.userMessage
            return
        }
        busy = true
        lastError = nil
        status = "Preparing \(app.name)…"
        defer { busy = false }
        do {
            let icon = await Self.artworkURL(bundleID: app.bundleID, storeURL: nil)
            DecryptClient.shared.select(
                DecryptApp(
                    id: app.bundleID,
                    name: app.name,
                    bundle: app.bundleID,
                    icon: icon,
                    dev: "",
                    version: app.version,
                    url: ""
                )
            )
            DecryptClient.shared.phase = .running

            // 1) Store package → companion when Store is green. Companion verifies DRM
            //    and decrypts; host must not stall on “Auditing FairPlay DRM on install path…”.
            if AppleIDStore.shared.storefrontSession()?.isUsable == true {
                publishDecryptProgress("Fetching Store package for \(app.name)…")
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
                    publishDecryptProgress("Store package failed — \(error.localizedDescription)")
                }
            }

            // 2) Live install embed only when Store isn’t available / package fetch failed.
            // Same-device sandbox often can't read foreign FairPlay binaries (Flutter
            // Runner.app) — prefer Account Store download when live embed finds no Mach-Os.
            if let installed = await resolveInstalledAppURL(bundleID: app.bundleID) {
                publishDecryptProgress("Embedding installed \(app.name) into companion…")
                do {
                    try await decryptFromInstalledPath(installed, displayName: app.name)
                    return
                } catch {
                    let text = error.localizedDescription
                    if text.localizedCaseInsensitiveContains("mach-o")
                        || text.localizedCaseInsensitiveContains("no mach-os") {
                        throw DecryptError(
                            "Couldn’t read Mach-Os from the live \(app.name) install (sandbox). Sign in under Account so Get can download the Store IPA and embed EncryptedSource.ipa, then retry. (\(text))"
                        )
                    }
                    throw error
                }
            }

            throw FairPlayDecryptError.noInstalledApp(
                "Can’t find \(app.name) on disk (\(app.bundleID)). Pair Native and refresh Installed, or sign in under Account to download."
            )
        } catch {
            lastError = error.localizedDescription
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = error.localizedDescription
            DecryptClient.shared.message = error.localizedDescription
            status = ""
        }
    }

    /// Companion embed from a live install — no in-app FairPlay. Prefer Store IPA → companion.
    private func decryptFromInstalledPath(
        _ installed: URL,
        displayName: String
    ) async throws {
        let info = NSDictionary(contentsOf: installed.appendingPathComponent("Info.plist")) as? [String: Any]
        let bid = (info?["CFBundleIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _ = try await FairPlayKeyGate.confirmReadyForCompanion(
            bundleID: bid.isEmpty ? nil : bid,
            displayName: displayName
        ) { [weak self] msg in
            self?.publishDecryptProgress(msg)
        }
        publishDecryptProgress("Building FastDecryptBot companion for \(displayName)…")
        // Stamp the live path before packaging so the companion FairPlay input is ready
        // even when open(2) of the FairPlay binary EPERMs under the host sandbox.
        if !bid.isEmpty {
            DecryptCompanionHandoff.publishLiveInstallPath(installed.path, bundleID: bid)
            publishDecryptProgress("Live install path: \(installed.path)")
        } else {
            publishDecryptProgress("Live install path: \(installed.path) (bundle ID unknown)")
        }
        let companionID = try await DecryptCompanionInstaller.installAndOpen(
            embeddingInstalledApp: installed,
            displayName: displayName
        ) { [weak self] msg in
            Task { @MainActor in self?.publishDecryptProgress(msg) }
        }
        markCompanionHandoff(displayName: displayName, companionBundleID: companionID)
    }

    func decryptFromSearch(_ app: DecryptApp, version: String? = nil, externalVersionId: String? = nil) {
        if !app.countryCode.isEmpty {
            AppleIDStore.shared.selectAccountMatching(countryCode: app.countryCode)
        }
        if AppleSystemAppGate.isBlocked(app) {
            DecryptClient.shared.select(app)
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = AppleSystemAppGate.userMessage
            DecryptClient.shared.message = AppleSystemAppGate.userMessage
            return
        }
        switch DecryptChannel.current {
        case .telegram:
            DecryptClient.shared.select(app)
            DecryptClient.shared.start(url: app.url, version: version, display: app.name)
        case .device:
            DecryptClient.shared.select(app)
            // Server-only: skip companion FairPlay — job hits Decrypt site URL (Linux/Mac).
            if DecryptMacRouting.macOnly {
                DecryptMacRouting.startMacDecrypt(
                    storeURL: app.url,
                    version: version,
                    displayName: app.name
                )
                return
            }
            // Don't set .running before winning the busy lock — that left the UI stuck
            // with no worker when a decrypt was already in flight.
            if busy {
                DecryptClient.shared.phase = .failed
                DecryptClient.shared.error = "Already decrypting — wait for the current job to finish."
                DecryptClient.shared.message = DecryptClient.shared.error ?? ""
                return
            }
            DecryptClient.shared.error = nil
            DecryptClient.shared.message = "Starting…"
            let deviceApp = DeviceApp(
                bundleID: app.bundle,
                name: app.name,
                version: app.version,
                isAppStore: true
            )
            Task {
                if app.icon == nil,
                   let icon = await Self.artworkURL(bundleID: app.bundle, storeURL: app.url) {
                    DecryptClient.shared.finishedIcon = icon
                    // Update artwork without `select()` so search results stay visible.
                    if DecryptClient.shared.selected?.id == app.id {
                        DecryptClient.shared.selected = DecryptApp(
                            id: app.id,
                            name: app.name,
                            bundle: app.bundle,
                            icon: icon,
                            dev: app.dev,
                            version: app.version,
                            url: app.url,
                            countryCode: app.countryCode,
                            countryLabel: app.countryLabel,
                            category: app.category,
                            sizeBytes: app.sizeBytes,
                            externalVersionId: app.externalVersionId
                        )
                    }
                }
                await decryptOwnedStoreApp(
                    deviceApp,
                    storeURL: app.url,
                    version: version,
                    externalVersionId: externalVersionId
                )
            }
        }
    }

    /// Device-channel path for a Store listing: silent purchase/download, then hand
    /// FairPlay to the development-cert companion IPA (never opens the App Store UI).
    /// When `DecryptMacRouting.macOnly`, skips companion and queues Decrypt site URL.
    func decryptOwnedStoreApp(
        _ app: DeviceApp,
        storeURL: String,
        version: String? = nil,
        externalVersionId: String? = nil
    ) async {
        let bid = app.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let linkHint = storeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if DecryptMacRouting.macOnly {
            var link = linkHint
            if link.isEmpty, !bid.isEmpty {
                link = (try? await self.storeURL(forBundleID: bid)) ?? ""
            }
            await DecryptMacRouting.startMacDecryptAndWait(
                storeURL: link,
                version: version,
                displayName: app.name
            )
            return
        }
        guard !busy else {
            if DecryptClient.shared.phase != .running && DecryptClient.shared.phase != .downloading {
                DecryptClient.shared.phase = .failed
                DecryptClient.shared.error = "Already decrypting — wait for the current job to finish."
                DecryptClient.shared.message = DecryptClient.shared.error ?? ""
            }
            return
        }
        busy = true
        lastError = nil
        DecryptClient.shared.phase = .running
        DecryptClient.shared.message = "Starting…"
        DecryptClient.shared.error = nil
        defer { busy = false }
        do {
            guard AppleIDStore.shared.isSignedIn else {
                throw DecryptError("Sign in under Account with the Apple ID that owns this app.")
            }
            // Gate Media & Purchases *before* any Store purchase/download so a missing
            // FairPlay ack never looks like an App Store outage.
            _ = try await FairPlayKeyGate.confirmReadyForCompanion { [weak self] msg in
                self?.publishDecryptProgress(msg)
            }
            let link: String
            if !linkHint.isEmpty {
                link = linkHint
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
            // Prefer Store package → companion. On Store 403 / backend TLS failure,
            // fall back to installed companion embed when the app is already on disk
            // (packager skips hanging live cryptid audits; companion verifies DRM).
            do {
                try await silentPurchaseDownloadDecrypt(
                    bundleID: bid,
                    displayName: app.name,
                    storeURL: link,
                    version: version,
                    externalVersionId: externalVersionId
                )
            } catch {
                if error is FairPlayKeyGateError { throw error }
                guard !bid.isEmpty,
                      let installed = await resolveInstalledAppURL(bundleID: bid) else {
                    throw error
                }
                publishDecryptProgress(
                    "Store package unavailable — embedding installed \(app.name) into companion…"
                )
                publishDecryptProgress(error.localizedDescription)
                try FairPlayKeyGate.requireReady()
                try await decryptFromInstalledPath(installed, displayName: app.name)
            }
        } catch {
            let text = error.localizedDescription
            lastError = text
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = text
            DecryptClient.shared.message = text
            status = ""
            if error is FairPlayKeyGateError {
                FairPlayKeyGate.rememberPendingSearchRetry()
            }
        }
    }

    private func publishDecryptProgress(_ message: String) {
        status = message
        DecryptClient.shared.phase = .running
        DecryptClient.shared.message = message
        DecryptClient.shared.error = nil
    }

    /// Host finished packaging — FairPlay console continues in the installed companion IPA.
    /// Terminal for the host: not busy, so further decrypts / pipeline can proceed.
    private func markCompanionHandoff(displayName: String, companionBundleID: String? = nil) {
        DecryptClient.shared.phase = .handedOff
        DecryptClient.shared.message =
            "Open FastDecryptBot to finish FairPlay (Trust under Settings › General › VPN & Device Management if asked). The clear IPA returns here for Sign → Install."
        DecryptClient.shared.error = nil
        DecryptClient.shared.finishedName = displayName
        if let companionBundleID, !companionBundleID.isEmpty {
            status = "Companion installed for \(displayName) · \(companionBundleID)"
        } else {
            status = "Companion installed for \(displayName)"
        }
        DecryptCompanionController.shared.dismiss()
        // If a previous companion export is already waiting, import it now.
        _ = DecryptCompanionHandoff.consumePendingClearIPAExport()
    }

    /// iPadn DownloadDispatch fetch + FairPlay handoff. No remint / anisette / backend IPA stack.
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
        guard var account = AppleIDStore.shared.storefrontSession(), account.isUsable else {
            throw DecryptError("Sign in under Account with the Apple ID that owns this app.")
        }

        let pinned = (externalVersionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !pinned.isEmpty {
            publishDecryptProgress("Pinning store build \(pinned)…")
        }

        // Hold the encrypted Store IPA in a durable folder (not ephemeral tmp) so
        // FairPlay / companion can re-open the stamped URL after download.
        let tag = pinned.isEmpty ? "\(adam)" : "\(adam)_\(pinned)"
        let dest = DecryptCompanionHandoff.encryptedIPADirectory()
            .appendingPathComponent("\(bundleID.isEmpty ? "app" : bundleID)_\(tag).ipa")

        do {
            let result = try await purchaseAndDownloadWithStoreRefresh(
                adamId: adam,
                account: &account,
                destination: dest,
                externalVersionId: pinned.isEmpty ? nil : pinned,
                version: version
            )
            // Cookie jar may have refreshed during download — keep it for the next Get.
            AppleIDStore.shared.mergeStoreCookies(from: account)
            AppleIDStore.shared.clearStoreVerificationIfSessionUsable()
            // Prefer Search bid; fall back to DownloadDispatch ticket / IPA peek so
            // companion packaging never loses CFBundleIdentifier (Tubi Info.plist miss).
            let ticketBid = result.item.bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedBid = bundleID.isEmpty ? ticketBid : bundleID
            let finalBid = resolvedBid.isEmpty
                ? (IPadnIPAPackager.bundleID(fromIPA: result.url) ?? "")
                : resolvedBid
            if bundleID.isEmpty, !finalBid.isEmpty {
                publishDecryptProgress("Recovered bundle ID \(finalBid) from Store ticket / IPA")
            }
            DecryptCompanionHandoff.publishStoreDecryptTarget(
                url: storeURL,
                version: result.item.displayVersion.isEmpty ? version : result.item.displayVersion,
                displayName: displayName,
                bundleID: finalBid
            )
            try await handoffStoreIPAToCompanion(
                ipa: result.url,
                displayName: displayName,
                downloadedVersion: result.item.displayVersion,
                bundleID: finalBid
            )
            AppleIDStore.shared.clearStoreVerificationIfSessionUsable()
        } catch {
            // Never wrap the FairPlay Media & Purchases gate as a Store download failure.
            if error is FairPlayKeyGateError { throw error }
            let detail = error.localizedDescription
            let lower = detail.lowercased()
            if lower.contains("capture fairplay keys")
                || lower.contains("before companion decrypt")
                || lower.contains("media & purchases") {
                throw error
            }
            // Installed companion embed only — no remint / backend IPA fallback.
            if !bundleID.isEmpty,
               let installed = await resolveInstalledAppURL(bundleID: bundleID) {
                publishDecryptProgress(
                    "Store package unavailable — embedding installed \(displayName) into companion…"
                )
                publishDecryptProgress(detail)
                try FairPlayKeyGate.requireReady()
                try await decryptFromInstalledPath(installed, displayName: displayName)
                AppleIDStore.shared.clearStoreVerificationIfSessionUsable()
                return
            }
            if lower.contains("timed out") || lower.contains("timeout") || lower.contains("network connection was lost") {
                throw DecryptError(
                    "App Store download timed out. Check Wi‑Fi and retry Get — you usually don’t need to sign in again."
                )
            }
            // Keep a still-green session — don't tell the user to Sign Out for the next app.
            if AppleIDStore.shared.storefrontSession()?.isUsable == true {
                AppleIDStore.shared.clearStoreVerificationIfSessionUsable()
                throw DecryptError(
                    "App Store download failed (\(detail)). Stay signed in and retry Get."
                )
            }
            throw DecryptError(
                "App Store download failed (\(detail)). Unlock Store under Account if needed — you usually don’t need a full Sign Out."
            )
        }
    }

    /// Push a Store IPA already on disk through the companion (Downloads Get → purchaseAndDownload).
    /// Mac-only: ignore the local IPA and decrypt via Decrypt site URL using the stamped Store link.
    func decryptDownloadedStoreIPA(at ipa: URL, displayName: String, bundleID: String? = nil) async {
        if DecryptMacRouting.macOnly {
            let snap = DecryptCompanionHandoff.readHostSnapshot(fromManifest: nil)
            var link = ((snap["hostStoreURL"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let ver = ((snap["hostStoreVersion"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            if link.isEmpty, let bid = bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !bid.isEmpty {
                link = (try? await storeURL(forBundleID: bid)) ?? ""
            }
            // Prefer job-stamped Store URL; publish from Downloads before companion enqueue when possible.
            if link.isEmpty {
                DecryptClient.shared.phase = .failed
                DecryptClient.shared.error =
                    "Mac decrypt needs an App Store link on this job — retry Get from Search."
                DecryptClient.shared.message = DecryptClient.shared.error ?? ""
                return
            }
            DecryptCompanionHandoff.publishStoreDecryptTarget(
                url: link,
                version: ver.isEmpty ? nil : ver,
                displayName: name.isEmpty ? "App" : name,
                bundleID: bundleID ?? ""
            )
            await DecryptMacRouting.startMacDecryptAndWait(
                storeURL: link,
                version: ver.isEmpty ? nil : ver,
                displayName: name.isEmpty ? "App" : name
            )
            return
        }
        guard FileManager.default.fileExists(atPath: ipa.path) else {
            let text = "Downloaded IPA missing — retry Get."
            lastError = text
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = text
            DecryptClient.shared.message = text
            return
        }
        if busy {
            // Wait briefly for an in-flight job (Downloads queue serializes callers).
            for _ in 0..<120 {
                if !busy { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if busy {
                let text = "Already decrypting — wait for the current job to finish."
                lastError = text
                DecryptClient.shared.phase = .failed
                DecryptClient.shared.error = text
                DecryptClient.shared.message = text
                return
            }
        }
        busy = true
        lastError = nil
        DecryptClient.shared.phase = .running
        DecryptClient.shared.message = "Preparing companion for \(displayName)…"
        DecryptClient.shared.error = nil
        defer { busy = false }
        do {
            try await handoffStoreIPAToCompanion(
                ipa: ipa,
                displayName: displayName,
                downloadedVersion: "",
                bundleID: bundleID
            )
            AppleIDStore.shared.clearStoreVerificationIfSessionUsable()
        } catch {
            let text = error.localizedDescription
            lastError = text
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = text
            DecryptClient.shared.message = text
            status = ""
        }
    }

    /// After Store download: keep the encrypted IPA in durable temp, stamp its URL for
    /// FairPlay, prefer live-install embed when present, otherwise embed the retained IPA.
    private func handoffStoreIPAToCompanion(
        ipa: URL,
        displayName: String,
        downloadedVersion: String,
        bundleID: String? = nil
    ) async throws {
        let label = downloadedVersion.isEmpty ? displayName : "\(displayName) v\(downloadedVersion)"
        let resolvedBid = (bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? Self.bundleIDFromStoreIPA(ipa) ?? ""

        // Host gate with bid so live App Store install is required before FastDecryptBot.
        _ = try await FairPlayKeyGate.confirmReadyForCompanion(
            bundleID: resolvedBid.isEmpty ? nil : resolvedBid,
            displayName: displayName
        ) { [weak self] msg in
            self?.publishDecryptProgress(msg)
        }

        // Always retain + stamp the encrypted Store IPA path for FairPlay capture.
        let retained = try DecryptCompanionHandoff.retainEncryptedIPA(
            ipa,
            bundleID: resolvedBid,
            displayName: displayName
        )
        let fpOpts = FairPlayAdvancedOptions.Resolved.current
        DecryptCompanionHandoff.publishHostSnapshot()
        publishDecryptProgress("Encrypted IPA held for FairPlay: \(retained.lastPathComponent)")
        publishDecryptProgress("Temp URL: \(retained.path)")
        if DecryptCompanionHandoff.encryptedIPADirectoryIsShared {
            publishDecryptProgress("Encrypted IPA is in App Group (companion-readable).")
        } else {
            publishDecryptProgress(
                "App Group unavailable (common on free Apple ID certs) — live install path must still be stamped for FairPlay. Delete any old FastDecryptBot app before Get so the new package is installed."
            )
        }
        if fpOpts.pathDiagnostics {
            publishDecryptProgress(
                "Advanced FairPlay · Live install only · retries \(fpOpts.retryRounds)"
                + (fpOpts.verboseConsole ? " · verbose" : "")
            )
        }

        publishDecryptProgress("Building FastDecryptBot companion for \(label)…")
        _ = await DeviceLibrary.shared.refreshAwaiting()

        // FairPlay mremap only from the live App Store install — EncryptedSource is packaging
        // only. Always surface the live path (or its absence) after a Store IPA fetch.
        if !resolvedBid.isEmpty {
            if let live = await resolveInstalledAppURL(bundleID: resolvedBid) {
                DecryptCompanionHandoff.publishLiveInstallPath(live.path, bundleID: resolvedBid)
                publishDecryptProgress("Live install path: \(live.path)")
            } else {
                DecryptCompanionHandoff.clearLiveInstallPath()
                publishDecryptProgress(
                    "Live install path: (none) for \(resolvedBid) — install \(displayName) from the App Store (same Apple ID) before FastDecryptBot."
                )
            }
        } else {
            DecryptCompanionHandoff.clearLiveInstallPath()
            publishDecryptProgress("Live install path: (none) — missing bundle ID on Store IPA.")
        }

        do {
            let companionID = try await DecryptCompanionInstaller.installAndOpen(
                embedding: retained,
                displayName: displayName
            ) { [weak self] msg in
                Task { @MainActor in self?.publishDecryptProgress(msg) }
            }
            markCompanionHandoff(displayName: displayName, companionBundleID: companionID)
        } catch {
            // Last resort: try live-install embed if IPA packaging failed for another reason.
            if !resolvedBid.isEmpty,
               let live = await resolveInstalledAppURL(bundleID: resolvedBid) {
                publishDecryptProgress(
                    "IPA companion failed (\(error.localizedDescription)) — trying live-install embed…"
                )
                do {
                    let companionID = try await DecryptCompanionInstaller.installAndOpen(
                        embeddingInstalledApp: live,
                        displayName: displayName
                    ) { [weak self] msg in
                        Task { @MainActor in self?.publishDecryptProgress(msg) }
                    }
                    markCompanionHandoff(displayName: displayName, companionBundleID: companionID)
                    return
                } catch {
                    throw DecryptError(
                        "Couldn't install the companion (\(error.localizedDescription)). Create a 7-day Apple ID certificate under Account › Settings › Installation › Certificate, trust it under Settings › General › VPN & Device Management, then retry. Encrypted IPA kept at \(retained.path)."
                    )
                }
            }
            throw DecryptError(
                "Couldn't install the companion with this IPA (\(error.localizedDescription)). Create a 7-day Apple ID certificate under Account › Settings › Installation › Certificate, trust it under Settings › General › VPN & Device Management, then retry. Encrypted IPA kept at \(retained.path)."
            )
        }
    }

    /// Peek CFBundleIdentifier from a Store IPA zip without extracting the whole archive.
    private static func bundleIDFromStoreIPA(_ ipa: URL) -> String? {
        IPadnIPAPackager.bundleID(fromIPA: ipa)
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
            AppNav.shared.goLibrary()
        } else {
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = lastError ?? "Decrypt All failed."
            status = ""
        }
    }
}
