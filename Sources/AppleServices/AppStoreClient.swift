//
//  AppStoreClient.swift
//  Silent App Store purchase + IPA download (ipatool-style MZFinance APIs).
//  Non-jailbroken: uses the signed-in Apple ID’s store passwordToken — no App Store UI.
//

import Foundation
import UIKit
import ZIPFoundation

/// Persisted iTunes Store session (passwordToken + storefront), separate from Xcode/GSA portal auth.
struct StorefrontSession: Codable, Equatable, Sendable {
    var email: String
    var passwordToken: String
    var dsid: String
    var storeFront: String
    var pod: String?
    var guid: String
    var createdAt: Date

    var isUsable: Bool {
        !passwordToken.isEmpty && !dsid.isEmpty && !storeFront.isEmpty
    }
}

/// One songList item from volumeStore / redownload (package URL + metadata).
struct StoreDownloadItem: @unchecked Sendable {
    var url: URL?
    var md5: String?
    var artworkURL: URL?
    var sinfCount: Int
    var metadata: [String: Any]

    var bundleID: String { stringMeta("softwareVersionBundleId") ?? stringMeta("bundleId") ?? "" }
    var displayVersion: String {
        stringMeta("bundleShortVersionString") ?? stringMeta("bundleVersion") ?? ""
    }
    var buildVersion: String { stringMeta("bundleVersion") ?? "" }
    var externalVersionId: String {
        stringMeta("softwareVersionExternalIdentifier") ?? ""
    }
    var allExternalVersionIds: [String] {
        if let arr = metadata["softwareVersionExternalIdentifiers"] as? [Any] {
            return arr.map { "\($0)" }.filter { !$0.isEmpty }
        }
        if let arr = metadata["softwareVersionExternalIdentifiers"] as? [Int] {
            return arr.map(String.init)
        }
        if let arr = metadata["softwareVersionExternalIdentifiers"] as? [String] {
            return arr.filter { !$0.isEmpty }
        }
        return []
    }
    var itemName: String { stringMeta("itemName") ?? stringMeta("playlistName") ?? "" }
    var artistName: String { stringMeta("artistName") ?? "" }
    var minimumOS: String? {
        stringMeta("minimumOSVersion") ?? stringMeta("MinimumOSVersion") ?? stringMeta("minOS")
    }

    private func stringMeta(_ key: String) -> String? {
        guard let any = metadata[key] else { return nil }
        if let s = any as? String, !s.isEmpty { return s }
        if let n = any as? NSNumber { return n.stringValue }
        let s = "\(any)"
        return s.isEmpty ? nil : s
    }
}

/// App listed on this Apple ID’s purchase / download history.
struct OwnedStoreApp: Identifiable, Hashable, Sendable {
    var adamId: Int
    var name: String
    var bundleId: String
    var version: String
    var artistName: String
    var iconURL: URL?

    var id: Int { adamId }

    var storeURL: String { "https://apps.apple.com/app/id\(adamId)" }

    var asDecryptApp: DecryptApp {
        DecryptApp(
            id: "owned-\(adamId)",
            name: name,
            bundle: bundleId,
            icon: iconURL,
            dev: artistName,
            version: version,
            url: storeURL
        )
    }
}

enum AppStoreClientError: LocalizedError {
    case message(String)
    case needsTwoFactor
    case tokenExpired
    case licenseRequired
    case paidApp
    case network(String)

    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        case .needsTwoFactor: return "App Store sign-in needs a verification code."
        case .tokenExpired: return "App Store session expired — sign in again under Store Access."
        case .licenseRequired: return "This Apple ID doesn’t own a license for that app."
        case .paidApp: return "Silent purchase only supports free apps. Buy it once in the App Store, then decrypt."
        case .network(let m): return m
        }
    }
}

/// Authenticated silent purchase + download against Apple’s private buy.itunes endpoints.
@MainActor
final class AppStoreClient: ObservableObject {
    static let shared = AppStoreClient()

    private let session = URLSession(configuration: .ephemeral)
    private let configuratorUA = "Configurator/2.15 (Macintosh; OS X 11.0.0; 16A5288f) AppleWebKit/0605.2.7.5"

    private enum Paths {
        static let authenticate = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"
        static let purchase = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct"
        static let downloadHost = "https://p25-buy.itunes.apple.com"
        static let downloadPath = "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"
        static let redownload = "https://downloaddispatch.itunes.apple.com/r/redownload"
        static let purchaseHistory = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/purchaseHistory"
    }

    private init() {}

    private var storeUserAgent: String {
        StoreDeviceSpoof.current.storeUserAgent(fallbackConfigurator: configuratorUA)
    }

    // MARK: - Public API

    /// Sign in to the iTunes Store (passwordToken). Appends a 6-digit code when required.
    func authenticate(
        email: String,
        password: String,
        authCode: String? = nil
    ) async throws -> StorefrontSession {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let code = (authCode ?? "").filter(\.isNumber)
        guard e.contains("@"), !password.isEmpty else {
            throw AppStoreClientError.message("Enter Apple ID and password for Store downloads.")
        }

        let anisette = try await AnisetteClient.shared.fetch()
        let guid = Self.deviceGUID(from: anisette)
        var redirect: String? = nil
        var last: [String: Any] = [:]
        var headers: [String: String] = [:]

        for attempt in 1...4 {
            let url = redirect ?? Paths.authenticate
            let (dict, respHeaders, status) = try await postPlist(
                url: url,
                body: [
                    "appleId": e,
                    "attempt": "\(attempt)",
                    "guid": guid,
                    "password": password + code,
                    "rmp": "0",
                    "why": "signIn"
                ],
                anisette: anisette,
                extraHeaders: [
                    "Content-Type": "application/x-apple-plist",
                    "User-Agent": storeUserAgent
                ],
                allowRedirectCapture: true
            )
            last = dict
            headers = respHeaders

            if let loc = headers["Location"] ?? headers["location"], status >= 300, status < 400 {
                redirect = loc
                continue
            }

            let failure = string(dict["failureType"])
            let customer = string(dict["customerMessage"])
            if failure == "-5000", attempt == 1, code.isEmpty {
                continue // retry once like ipatool
            }
            if (failure.isEmpty && customer.contains("BadLogin")) || customer.localizedCaseInsensitiveContains("incorrect verification") {
                if code.isEmpty { throw AppStoreClientError.needsTwoFactor }
                throw AppStoreClientError.message("Incorrect App Store password or verification code.")
            }
            if !failure.isEmpty {
                throw AppStoreClientError.message(customer.isEmpty ? "App Store sign-in failed (\(failure))." : customer)
            }

            let token = string(dict["passwordToken"])
            var dsid = string(dict["dsPersonId"])
            if dsid.isEmpty { dsid = headers["X-Dsid"] ?? headers["x-dsid"] ?? "" }
            let storeFront = headers["X-Set-Apple-Store-Front"]
                ?? headers["x-set-apple-store-front"]
                ?? headers["X-Apple-Store-Front"]
                ?? headers["x-apple-store-front"]
                ?? ""
            let pod = headers["pod"] ?? headers["Pod"]

            guard !token.isEmpty, !dsid.isEmpty else {
                if code.isEmpty { throw AppStoreClientError.needsTwoFactor }
                throw AppStoreClientError.message("App Store sign-in returned no password token.")
            }
            guard !storeFront.isEmpty else {
                throw AppStoreClientError.message("App Store sign-in missing storefront.")
            }

            return StorefrontSession(
                email: e,
                passwordToken: token,
                dsid: dsid,
                storeFront: storeFront,
                pod: pod,
                guid: guid,
                createdAt: Date()
            )
        }

        let customer = string(last["customerMessage"])
        throw AppStoreClientError.message(customer.isEmpty ? "App Store sign-in failed after retries." : customer)
    }

    /// Obtain a free license (`buyProduct`). Paid apps are rejected.
    func purchaseFreeLicense(
        adamId: Int,
        account: StorefrontSession,
        price: Double = 0,
        externalVersionId: String? = nil
    ) async throws {
        guard price <= 0 else { throw AppStoreClientError.paidApp }
        let anisette = try await AnisetteClient.shared.fetch()
        do {
            try await purchaseOnce(
                adamId: adamId,
                account: account,
                anisette: anisette,
                pricing: "STDQ",
                externalVersionId: externalVersionId
            )
        } catch AppStoreClientError.message(let m) where m.localizedCaseInsensitiveContains("unavailable") {
            try await purchaseOnce(
                adamId: adamId,
                account: account,
                anisette: anisette,
                pricing: "GAME",
                externalVersionId: externalVersionId
            )
        }
    }

    /// Request download metadata (+ optional version pin) without downloading the IPA.
    func fetchDownloadItem(
        adamId: Int,
        account: StorefrontSession,
        externalVersionId: String? = nil
    ) async throws -> StoreDownloadItem {
        let anisette = try await AnisetteClient.shared.fetch()
        return try await downloadProduct(
            adamId: adamId,
            account: account,
            anisette: anisette,
            externalVersionId: externalVersionId
        )
    }

    /// List external version IDs Apple still serves for this adamId (newest last when present).
    func listExternalVersionIds(
        adamId: Int,
        account: StorefrontSession
    ) async throws -> (ids: [String], latest: String?, item: StoreDownloadItem) {
        let item = try await fetchDownloadItem(adamId: adamId, account: account, externalVersionId: nil)
        var ids = item.allExternalVersionIds
        if ids.isEmpty, !item.externalVersionId.isEmpty {
            ids = [item.externalVersionId]
        }
        let latest = item.externalVersionId.isEmpty ? ids.last : item.externalVersionId
        return (ids, latest, item)
    }

    /// Resolve display versions for external IDs (capped + concurrent).
    func resolveVersionHistory(
        adamId: Int,
        account: StorefrontSession,
        limit: Int = 40
    ) async throws -> [DecryptVersion] {
        let listed = try await listExternalVersionIds(adamId: adamId, account: account)
        let newestFirst = Array(listed.ids.reversed())
        let slice = Array(newestFirst.prefix(max(1, limit)))
        let latest = listed.latest

        var resolved: [DecryptVersion] = []
        resolved.reserveCapacity(slice.count)

        // Cap concurrency to avoid store throttling.
        let chunk = 5
        var index = 0
        while index < slice.count {
            let end = min(index + chunk, slice.count)
            let batch = Array(slice[index..<end])
            let parts: [DecryptVersion] = await withTaskGroup(of: DecryptVersion?.self, returning: [DecryptVersion].self) { group in
                for ext in batch {
                    group.addTask { @MainActor in
                        do {
                            let item = try await self.fetchDownloadItem(
                                adamId: adamId,
                                account: account,
                                externalVersionId: ext
                            )
                            let label = item.displayVersion.isEmpty ? ext : item.displayVersion
                            return DecryptVersion(
                                v: label,
                                current: ext == latest,
                                minOS: item.minimumOS,
                                externalId: ext
                            )
                        } catch {
                            return DecryptVersion(v: ext, current: ext == latest, minOS: nil, externalId: ext)
                        }
                    }
                }
                var out: [DecryptVersion] = []
                for await v in group {
                    if let v { out.append(v) }
                }
                return out
            }
            // Keep newest-first order from `batch`.
            let byId = Dictionary(uniqueKeysWithValues: parts.map { ($0.externalId ?? $0.v, $0) })
            for ext in batch {
                if let v = byId[ext] { resolved.append(v) }
            }
            index = end
        }

        if resolved.isEmpty, !listed.item.displayVersion.isEmpty {
            return [
                DecryptVersion(
                    v: listed.item.displayVersion,
                    current: true,
                    minOS: listed.item.minimumOS,
                    externalId: latest
                )
            ]
        }
        return resolved
    }

    /// Match a UI version string (display or external id) to an externalVersionId.
    func resolveExternalVersionId(
        adamId: Int,
        account: StorefrontSession,
        version: String?
    ) async throws -> String? {
        let raw = (version ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.allSatisfy(\.isNumber), raw.count >= 6 {
            return raw
        }
        let history = try await resolveVersionHistory(adamId: adamId, account: account, limit: 60)
        if let hit = history.first(where: { $0.v == raw || $0.externalId == raw }) {
            return hit.externalId ?? raw
        }
        // Case-insensitive / prefix match on display version.
        if let hit = history.first(where: {
            $0.v.localizedCaseInsensitiveCompare(raw) == .orderedSame
        }) {
            return hit.externalId
        }
        return nil
    }

    /// Best-effort purchase / download history for this Apple ID.
    func purchaseHistory(account: StorefrontSession) async throws -> [OwnedStoreApp] {
        let anisette = try await AnisetteClient.shared.fetch()
        let (dict, _, _) = try await postPlist(
            url: Paths.purchaseHistory,
            body: [
                "guid": account.guid,
                "requestId": UUID().uuidString.lowercased()
            ],
            anisette: anisette,
            extraHeaders: storeHeaders(account)
        )
        let failure = string(dict["failureType"])
        let customer = string(dict["customerMessage"])
        if failure == "2034" || failure == "2042" || failure == "1008" {
            throw AppStoreClientError.tokenExpired
        }
        if !failure.isEmpty {
            throw AppStoreClientError.message(customer.isEmpty ? "Purchase history failed (\(failure))." : customer)
        }

        let rows: [[String: Any]] = {
            if let a = dict["purchaseHistoryInfo"] as? [[String: Any]] { return a }
            if let a = dict["songList"] as? [[String: Any]] { return a }
            if let a = dict["purchases"] as? [[String: Any]] { return a }
            if let nested = dict["purchaseHistory"] as? [String: Any] {
                if let a = nested["purchaseHistoryInfo"] as? [[String: Any]] { return a }
                if let a = nested["songList"] as? [[String: Any]] { return a }
            }
            return []
        }()

        var out: [OwnedStoreApp] = []
        var seen = Set<Int>()
        for row in rows {
            let adam = intValue(row["itemId"])
                ?? intValue(row["trackId"])
                ?? intValue(row["adamId"])
                ?? intValue(row["songId"])
                ?? intValue(row["advertisingItemId"])
                ?? 0
            guard adam > 0, !seen.contains(adam) else { continue }
            // Prefer software / iOS apps when a kind/type is present.
            let kind = (stringOptional(row["kind"]) ?? stringOptional(row["product-type"]) ?? "")
                .lowercased()
            if !kind.isEmpty,
               !(kind.contains("software") || kind.contains("ios") || kind == "c" || kind.contains("app")) {
                continue
            }
            seen.insert(adam)
            let name = stringOptional(row["itemName"])
                ?? stringOptional(row["playlistName"])
                ?? stringOptional(row["trackName"])
                ?? "App \(adam)"
            let bundle = stringOptional(row["softwareVersionBundleId"])
                ?? stringOptional(row["bundleId"])
                ?? ""
            let version = stringOptional(row["bundleShortVersionString"])
                ?? stringOptional(row["version"])
                ?? ""
            let artist = stringOptional(row["artistName"]) ?? ""
            let icon = (stringOptional(row["artworkURL"]) ?? stringOptional(row["artworkUrl100"]))
                .flatMap(URL.init(string:))
            out.append(OwnedStoreApp(
                adamId: adam,
                name: name,
                bundleId: bundle,
                version: version,
                artistName: artist,
                iconURL: icon
            ))
        }
        return out
    }

    /// Check whether this account can download `adamId` (owns a license).
    func hasLicense(adamId: Int, account: StorefrontSession) async -> Bool {
        do {
            _ = try await fetchDownloadItem(adamId: adamId, account: account)
            return true
        } catch AppStoreClientError.licenseRequired {
            return false
        } catch {
            return false
        }
    }

    /// Request download metadata + CDN URL, then save the encrypted IPA to `destination`.
    @discardableResult
    func downloadIPA(
        adamId: Int,
        account: StorefrontSession,
        destination: URL,
        externalVersionId: String? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> (url: URL, item: StoreDownloadItem) {
        let anisette = try await AnisetteClient.shared.fetch()
        onProgress?("Requesting App Store package…")
        let item = try await downloadProduct(
            adamId: adamId,
            account: account,
            anisette: anisette,
            externalVersionId: externalVersionId
        )
        guard let cdn = item.url else {
            throw AppStoreClientError.message("App Store download response missing package URL.")
        }
        onProgress?("Downloading encrypted IPA\(item.displayVersion.isEmpty ? "" : " v\(item.displayVersion)")…")
        try await downloadFile(from: cdn, to: destination)
        onProgress?("Writing iTunesMetadata…")
        try? writeiTunesMetadata(item.metadata, email: account.email, intoIPA: destination)
        return (destination, item)
    }

    /// Purchase (if needed) + download for a free/owned adamId.
    func purchaseAndDownload(
        adamId: Int,
        account: StorefrontSession,
        destination: URL,
        price: Double = 0,
        externalVersionId: String? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> (url: URL, item: StoreDownloadItem) {
        onProgress?("Ensuring App Store license…")
        do {
            try await purchaseFreeLicense(
                adamId: adamId,
                account: account,
                price: price,
                externalVersionId: externalVersionId
            )
        } catch AppStoreClientError.message(let m)
            where m.localizedCaseInsensitiveContains("already") || m.localizedCaseInsensitiveContains("license") {
            // Already owned — continue.
        } catch let e as AppStoreClientError {
            if case .tokenExpired = e { throw e }
            // License already exists often surfaces as HTTP 500 in ipatool — continue to download.
        }
        return try await downloadIPA(
            adamId: adamId,
            account: account,
            destination: destination,
            externalVersionId: externalVersionId,
            onProgress: onProgress
        )
    }

    // MARK: - Purchase / download wire

    private func purchaseOnce(
        adamId: Int,
        account: StorefrontSession,
        anisette: AnisetteHeaders,
        pricing: String,
        externalVersionId: String?
    ) async throws {
        var host = Paths.purchase
        if let pod = account.pod, !pod.isEmpty {
            host = "https://p\(pod)-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct"
        }
        var body: [String: Any] = [
            "appExtVrsId": externalVersionId?.isEmpty == false ? (externalVersionId ?? "0") : "0",
            "hasAskedToFulfillPreorder": "true",
            "buyWithoutAuthorization": "true",
            "hasDoneAgeCheck": "true",
            "guid": account.guid,
            "needDiv": "0",
            "origPage": "Software-\(adamId)",
            "origPageLocation": "Buy",
            "price": "0",
            "pricingParameters": pricing,
            "productType": "C",
            "salableAdamId": adamId
        ]
        if let ext = externalVersionId, !ext.isEmpty {
            body["externalVersionId"] = ext
        }
        let (dict, _, status) = try await postPlist(
            url: host,
            body: body,
            anisette: anisette,
            extraHeaders: storeHeaders(account)
        )
        let failure = string(dict["failureType"])
        let customer = string(dict["customerMessage"])
        if failure == "2034" || failure == "2042" || failure == "1008" {
            throw AppStoreClientError.tokenExpired
        }
        if failure == "5002" || status == 500 {
            return // license already exists
        }
        if failure == "2059" {
            throw AppStoreClientError.message("temporarily unavailable")
        }
        if customer.localizedCaseInsensitiveContains("Subscription Required") {
            throw AppStoreClientError.message(customer)
        }
        if !failure.isEmpty {
            throw AppStoreClientError.message(customer.isEmpty ? "Purchase failed (\(failure))." : customer)
        }
        let doc = string(dict["jingleDocType"])
        let st = (dict["status"] as? Int) ?? (dict["status"] as? NSNumber)?.intValue ?? -1
        if doc != "purchaseSuccess" || st != 0 {
            // Some free re-downloads omit jingleDocType — allow empty failure.
            if doc.isEmpty && failure.isEmpty { return }
            throw AppStoreClientError.message(customer.isEmpty ? "Purchase failed." : customer)
        }
    }

    private func downloadProduct(
        adamId: Int,
        account: StorefrontSession,
        anisette: AnisetteHeaders,
        externalVersionId: String?
    ) async throws -> StoreDownloadItem {
        // volumeStore uses externalVersionId; redownload uses appExtVrsId.
        do {
            return try await downloadProductOnce(
                adamId: adamId,
                account: account,
                anisette: anisette,
                endpoint: volumeStoreURL(account: account),
                versionKey: "externalVersionId",
                externalVersionId: externalVersionId
            )
        } catch let e as AppStoreClientError {
            // Owned apps often return 5002 / empty items on volumeStore — fall back to redownload.
            switch e {
            case .message(let m)
                where m.contains("5002")
                    || m.localizedCaseInsensitiveContains("no download")
                    || m.localizedCaseInsensitiveContains("no longer available")
                    || m.localizedCaseInsensitiveContains("empty"):
                break
            case .tokenExpired:
                // Historical bug: some owned-app 5002s were mapped to token expiry.
                // Probe redownload before failing the session.
                break
            default:
                throw e
            }
        }

        return try await downloadProductOnce(
            adamId: adamId,
            account: account,
            anisette: anisette,
            endpoint: Paths.redownload,
            versionKey: "appExtVrsId",
            externalVersionId: externalVersionId
        )
    }

    private func volumeStoreURL(account: StorefrontSession) -> String {
        var host = Paths.downloadHost
        if let pod = account.pod, !pod.isEmpty {
            host = "https://p\(pod)-buy.itunes.apple.com"
        }
        return "\(host)\(Paths.downloadPath)?guid=\(account.guid)"
    }

    private func downloadProductOnce(
        adamId: Int,
        account: StorefrontSession,
        anisette: AnisetteHeaders,
        endpoint: String,
        versionKey: String,
        externalVersionId: String?
    ) async throws -> StoreDownloadItem {
        var body: [String: Any] = [
            "creditDisplay": "",
            "guid": account.guid,
            "salableAdamId": adamId
        ]
        if let ext = externalVersionId, !ext.isEmpty {
            body[versionKey] = ext
        }
        let (dict, _, _) = try await postPlist(
            url: endpoint,
            body: body,
            anisette: anisette,
            extraHeaders: storeHeaders(account)
        )
        let failure = string(dict["failureType"])
        let customer = string(dict["customerMessage"])
        if failure == "2034" || failure == "2042" || failure == "1008" {
            throw AppStoreClientError.tokenExpired
        }
        if failure == "9610" {
            throw AppStoreClientError.licenseRequired
        }
        if failure == "5002" {
            // Signal caller to try redownload — do not treat as expired token.
            throw AppStoreClientError.message("5002")
        }
        if !failure.isEmpty {
            throw AppStoreClientError.message(customer.isEmpty ? "Download failed (\(failure))." : customer)
        }
        let items = dict["songList"] as? [[String: Any]] ?? []
        guard let first = items.first else {
            throw AppStoreClientError.message(
                customer.isEmpty ? "App Store returned no download items." : customer
            )
        }
        return parseDownloadItem(first)
    }

    private func parseDownloadItem(_ item: [String: Any]) -> StoreDownloadItem {
        let urlString = stringOptional(item["URL"]) ?? stringOptional(item["url"])
        let artwork = stringOptional(item["artworkURL"]) ?? stringOptional(item["artworkUrl"])
        let sinfs = item["sinfs"] as? [Any] ?? []
        let meta = (item["metadata"] as? [String: Any]) ?? [:]
        return StoreDownloadItem(
            url: urlString.flatMap(URL.init(string:)),
            md5: stringOptional(item["md5"]),
            artworkURL: artwork.flatMap(URL.init(string:)),
            sinfCount: sinfs.count,
            metadata: meta
        )
    }

    private func storeHeaders(_ account: StorefrontSession) -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": "application/x-apple-plist",
            "User-Agent": storeUserAgent,
            "iCloud-DSID": account.dsid,
            "X-Dsid": account.dsid,
            "X-Apple-Store-Front": account.storeFront,
            "X-Token": account.passwordToken
        ]
        // Always advertise device/OS identity (real or spoofed) — UA alone is not enough
        // for every buy.itunes / redownload path.
        for (k, v) in StoreDeviceSpoof.current.storeIdentityHeaders() {
            headers[k] = v
        }
        return headers
    }

    // MARK: - HTTP helpers

    private func postPlist(
        url: String,
        body: [String: Any],
        anisette: AnisetteHeaders,
        extraHeaders: [String: String],
        allowRedirectCapture: Bool = false
    ) async throws -> (dict: [String: Any], headers: [String: String], status: Int) {
        guard let endpoint = URL(string: url) else {
            throw AppStoreClientError.message("Bad App Store URL.")
        }
        let plist = try PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = plist
        req.httpShouldHandleCookies = true
        applyAnisette(&req, anisette)
        for (k, v) in extraHeaders { req.setValue(v, forHTTPHeaderField: k) }

        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        var headerMap: [String: String] = [:]
        if let fields = http?.allHeaderFields {
            for (k, v) in fields {
                headerMap[String(describing: k)] = String(describing: v)
            }
        }
        if allowRedirectCapture, (300..<400).contains(status) {
            return ([:], headerMap, status)
        }
        if data.isEmpty, status == 500 {
            return (["failureType": "5002"], headerMap, status)
        }
        guard let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw AppStoreClientError.network("Non-plist App Store response (HTTP \(status)): \(raw.prefix(160))")
        }
        return (dict, headerMap, status)
    }

    private func applyAnisette(_ req: inout URLRequest, _ a: AnisetteHeaders) {
        req.setValue(a.clientInfo, forHTTPHeaderField: "X-MMe-Client-Info")
        req.setValue(a.machineID, forHTTPHeaderField: "X-Apple-I-MD-M")
        req.setValue(a.oneTimePassword, forHTTPHeaderField: "X-Apple-I-MD")
        req.setValue(a.localUserID, forHTTPHeaderField: "X-Apple-I-MD-LU")
        req.setValue(a.routingInfo, forHTTPHeaderField: "X-Apple-I-MD-RINFO")
        req.setValue(a.deviceID, forHTTPHeaderField: "X-Mme-Device-Id")
        req.setValue(a.serialNumber, forHTTPHeaderField: "X-Apple-I-SRL-NO")
        req.setValue(a.clientTime, forHTTPHeaderField: "X-Apple-I-Client-Time")
        req.setValue(a.locale, forHTTPHeaderField: "X-Apple-Locale")
        req.setValue(a.timeZone, forHTTPHeaderField: "X-Apple-I-TimeZone")
        // Configurator-style AMD aliases some clients still send.
        req.setValue(a.oneTimePassword, forHTTPHeaderField: "X-Apple-AMD")
        req.setValue(a.machineID, forHTTPHeaderField: "X-Apple-AMD-M")
    }

    private func downloadFile(from url: URL, to destination: URL) async throws {
        var req = URLRequest(url: url)
        req.setValue(storeUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (k, v) in StoreDeviceSpoof.current.storeIdentityHeaders() {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (tmp, resp) = try await session.download(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AppStoreClientError.network("IPA CDN download failed (HTTP \(status)).")
        }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tmp, to: destination)
    }

    /// Write / replace root `iTunesMetadata.plist` inside the IPA zip.
    private func writeiTunesMetadata(_ meta: [String: Any], email: String, intoIPA ipa: URL) throws {
        var m = meta
        m["apple-id"] = email
        m["userName"] = email
        let data = try PropertyListSerialization.data(fromPropertyList: m, format: .binary, options: 0)
        let archive = try Archive(url: ipa, accessMode: .update)
        if let existing = archive["iTunesMetadata.plist"] {
            try archive.remove(existing)
        }
        try archive.addEntry(with: "iTunesMetadata.plist", type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position) ..< Int(position) + size)
        }
    }

    // MARK: - GUID

    /// Stable store GUID: 12+ hex chars (ipatool uses MAC; on iPhone we derive from anisette device id).
    static func deviceGUID(from anisette: AnisetteHeaders) -> String {
        let raw = (anisette.deviceID + anisette.localUserID)
            .uppercased()
            .filter(\.isHexDigit)
        if raw.count >= 12 {
            return String(raw.prefix(16))
        }
        if let id = UIDevice.current.identifierForVendor?.uuidString {
            return id.replacingOccurrences(of: "-", with: "").uppercased()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    }

    private func string(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    private func stringOptional(_ any: Any?) -> String? {
        let s = string(any)
        return s.isEmpty ? nil : s
    }

    private func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let i = Int(s) { return i }
        return nil
    }
}
