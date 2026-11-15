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
        stringMeta("minimumOSVersion")
            ?? stringMeta("MinimumOSVersion")
            ?? stringMeta("minimumOsVersion")
            ?? stringMeta("minOS")
            ?? stringMeta("systemVersion")
            ?? stringMeta("requiredOS")
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
        case .tokenExpired: return "App Store session expired — TetherLess will refresh it automatically; open Store Access only if refresh fails."
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

    /// Same pattern as GSA: do not auto-follow redirects. Authenticate must re-POST the
    /// plist to `Location` (URLSession would otherwise convert POST→GET onto HTML 404/500).
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config, delegate: StoreRedirectBlocker.shared, delegateQueue: nil)
    }()
    private let configuratorUA = "Configurator/2.15 (Macintosh; OS X 11.0.0; 16A5288f) AppleWebKit/0605.2.7.5"

    private enum Paths {
        static let authenticate = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"
        /// Modern bag endpoint (trailing slash required — ipatool #507 / blacktop ipsw).
        static let authenticateNativeFast = "https://auth.itunes.apple.com/auth/v1/native/fast/"
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

        // SAP ActionSignature is required for Apple's current store edge (ipatool #525 /
        // ApplePackage). Unsigned posts get HTML 301-without-Location or empty 204.
        let sapSigner: SAPSigner
        do {
            sapSigner = try await SAPSigner.connect()
        } catch {
            throw AppStoreClientError.message(
                "Store SAP setup failed (\(error.localizedDescription)). Tap Retry Store unlock — or Sign Out and Sign In once."
            )
        }

        // Legacy MZFinance first — native/fast/ often 204/404s before credentials are checked
        // (ipatool #513/#530). Then try common buy pods when the edge never redirects.
        var lastError: Error = AppStoreClientError.message("App Store sign-in failed after retries.")
        let starters: [(String) -> String] = [
            Self.authenticateURL,
            Self.authenticateNativeURL,
            { Self.authenticatePodURL(pod: 7, guid: $0) },
            { Self.authenticatePodURL(pod: 25, guid: $0) },
            { Self.authenticatePodURL(pod: 35, guid: $0) }
        ]
        for (index, makeURL) in starters.enumerated() {
            if index > 0 {
                await AnisetteClient.shared.invalidate(resetProvisioning: false)
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            let anisette = try await AnisetteClient.shared.fetch()
            let guid = Self.deviceGUID(from: anisette)
            do {
                return try await authenticateOnce(
                    email: e,
                    passwordWithCode: password + code,
                    guid: guid,
                    anisette: anisette,
                    startEndpoint: makeURL(guid),
                    hadAuthCode: !code.isEmpty,
                    sapSigner: sapSigner
                )
            } catch {
                lastError = error
                if let ase = error as? AppStoreClientError {
                    switch ase {
                    case .needsTwoFactor, .message:
                        // Credential / 2FA answers are definitive — don't burn more endpoints.
                        throw ase
                    case .network where Self.shouldRotateAuthenticateEndpoint(ase):
                        continue
                    default:
                        continue
                    }
                }
                if Self.shouldRotateAuthenticateEndpoint(error) { continue }
                continue
            }
        }
        throw lastError
    }

    private func authenticateOnce(
        email: String,
        passwordWithCode: String,
        guid: String,
        anisette: AnisetteHeaders,
        startEndpoint: String,
        hadAuthCode: Bool,
        sapSigner: SAPSigner
    ) async throws -> StorefrontSession {
        var endpoint = startEndpoint
        var attempt = 1
        var redirects = 0
        var last: [String: Any] = [:]
        var headers: [String: String] = [:]
        var lastTransient: Error?

        while attempt <= 3, redirects <= 4 {
            do {
                let body: [String: Any] = [
                    "appleId": email,
                    "attempt": "\(attempt)",
                    "guid": guid,
                    "password": passwordWithCode,
                    "rmp": "0",
                    "why": "signIn"
                ]
                let bodyData = try PropertyListSerialization.data(
                    fromPropertyList: body, format: .xml, options: 0
                )
                // Signature must cover the exact POST bytes (ApplePackage / ipatool).
                let signature = try await sapSigner.sign(bodyData)
                let authHeaders: [String: String] = [
                    "Content-Type": "application/x-apple-plist",
                    "User-Agent": configuratorUA,
                    "X-Apple-ActionSignature": signature.base64EncodedString()
                ]

                let (dict, respHeaders, status) = try await postPlist(
                    url: endpoint,
                    body: body,
                    bodyData: bodyData,
                    anisette: anisette,
                    extraHeaders: authHeaders,
                    allowRedirectCapture: true,
                    forcePristineClientInfo: true,
                    stripSpoofIdentity: true,
                    authenticateAnisetteStyle: true
                )
                last = dict
                headers = respHeaders
                lastTransient = nil

                if (300..<400).contains(status) {
                    let loc = headers["Location"] ?? headers["location"] ?? ""
                    if loc.isEmpty {
                        // 301/302 without Location — common soft reject; rotate endpoint.
                        throw AppStoreClientError.network(
                            "Store authenticate redirected (HTTP \(status)) without Location."
                        )
                    }
                    let next = try Self.resolveAuthenticateRedirect(
                        from: endpoint,
                        location: loc,
                        guid: guid
                    )
                    // newRequest.url can echo the current URL when Location was missing —
                    // that is a soft edge reject, not a real pod hop.
                    let nextURL = URL(string: next)
                    let curURL = URL(string: endpoint)
                    if nextURL?.host?.lowercased() == curURL?.host?.lowercased(),
                       nextURL?.path == curURL?.path {
                        throw AppStoreClientError.network(
                            "Store authenticate redirected (HTTP \(status)) without Location."
                        )
                    }
                    endpoint = next
                    redirects += 1
                    continue // same attempt payload (ipatool) — re-sign happens next loop
                }

                let failure = string(dict["failureType"])
                let customer = string(dict["customerMessage"])
                if failure == "-5000", attempt == 1, !hadAuthCode {
                    attempt += 1
                    continue // retry once like ipatool
                }
                if (failure.isEmpty && customer.contains("BadLogin"))
                    || customer.localizedCaseInsensitiveContains("incorrect verification") {
                    if !hadAuthCode { throw AppStoreClientError.needsTwoFactor }
                    throw AppStoreClientError.message("Incorrect App Store password or verification code.")
                }
                if !failure.isEmpty {
                    throw AppStoreClientError.message(
                        customer.isEmpty ? "App Store sign-in failed (\(failure))." : customer
                    )
                }

                let token = Self.passwordToken(from: dict, headers: headers)
                var dsid = string(dict["dsPersonId"])
                if dsid.isEmpty { dsid = headers["X-Dsid"] ?? headers["x-dsid"] ?? "" }
                if dsid.isEmpty {
                    dsid = Self.dsidFromSetCookie(headers) ?? ""
                }
                let storeFront = headers["X-Set-Apple-Store-Front"]
                    ?? headers["x-set-apple-store-front"]
                    ?? headers["X-Apple-Store-Front"]
                    ?? headers["x-apple-store-front"]
                    ?? ""
                let pod = headers["pod"] ?? headers["Pod"]

                guard !token.isEmpty, !dsid.isEmpty else {
                    // Empty success-shaped plist — needs code or wrong PET/password.
                    throw AppStoreClientError.needsTwoFactor
                }
                // Some pods omit storefront on the body response — default US so Decrypt can proceed.
                let resolvedFront = storeFront.isEmpty ? "143441-1,29" : storeFront

                return StorefrontSession(
                    email: email,
                    passwordToken: token,
                    dsid: dsid,
                    storeFront: resolvedFront,
                    pod: pod,
                    guid: guid,
                    createdAt: Date()
                )
            } catch let err as AppStoreClientError {
                // Empty 204/403/404 from this host — bubble out so caller rotates endpoint
                // instead of hammering the same URL (ipatool #513).
                if case .network = err, Self.shouldRotateAuthenticateEndpoint(err) {
                    throw err
                }
                // Transient 5xx at pod — reset and retry same start.
                if case .network(let msg) = err, Self.isTransientAuthenticateFailure(msg) {
                    lastTransient = err
                    endpoint = startEndpoint
                    attempt += 1
                    redirects = 0
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                throw err
            }
        }

        if let lastTransient { throw lastTransient }
        let customer = string(last["customerMessage"])
        throw AppStoreClientError.message(customer.isEmpty ? "App Store sign-in failed after retries." : customer)
    }

    private static func shouldRotateAuthenticateEndpoint(_ error: Error) -> Bool {
        let m = (error as? LocalizedError)?.errorDescription?.lowercased()
            ?? error.localizedDescription.lowercased()
        return m.contains("http 204")
            || m.contains("http 403")
            || m.contains("http 404")
            || m.contains("without location")
            || m.contains("empty or non-plist")
            || m.contains("non-plist")
    }

    private static func authenticateURL(guid: String) -> String {
        "\(Paths.authenticate)?guid=\(guid)"
    }

    private static func authenticateNativeURL(guid: String) -> String {
        "\(Paths.authenticateNativeFast)?guid=\(guid)"
    }

    private static func authenticatePodURL(pod: Int, guid: String) -> String {
        "https://p\(pod)-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate?guid=\(guid)&Pod=\(pod)&PRH=\(pod)"
    }

    private static func resolveAuthenticateRedirect(
        from endpoint: String,
        location: String,
        guid: String
    ) throws -> String {
        guard let base = URL(string: endpoint) else {
            throw AppStoreClientError.message("Bad App Store authenticate URL.")
        }
        guard let resolved = URL(string: location, relativeTo: base)?.absoluteURL else {
            throw AppStoreClientError.message("Bad App Store redirect.")
        }
        let host = (resolved.host ?? "").lowercased()
        guard host == "apple.com" || host.hasSuffix(".apple.com") else {
            throw AppStoreClientError.message("App Store redirected to an unexpected host.")
        }
        var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false)
        var path = components?.path ?? resolved.path
        // Modern /native/ authenticate endpoints require a trailing slash (ipatool).
        if path.localizedCaseInsensitiveContains("/native"), !path.hasSuffix("/") {
            path += "/"
            components?.path = path
        }
        var items = components?.queryItems ?? []
        if !items.contains(where: { $0.name.lowercased() == "guid" }) {
            items.append(URLQueryItem(name: "guid", value: guid))
        }
        components?.queryItems = items
        return components?.string ?? resolved.absoluteString
    }

    private static func isTransientAuthenticateFailure(_ message: String) -> Bool {
        let m = message.lowercased()
        // 204/403/404 rotate endpoints at the outer loop — only 5xx stays on-host transient.
        return m.contains("http 500")
            || m.contains("http 502")
            || m.contains("http 503")
            || m.contains("http 429")
    }

    private static func dsidFromSetCookie(_ headers: [String: String]) -> String? {
        let cookie = headers.first { $0.key.lowercased() == "set-cookie" }?.value ?? ""
        guard let range = cookie.range(of: #"mz_at(?:0|_ssl)-([0-9]+)="#, options: .regularExpression) else {
            return nil
        }
        let slice = String(cookie[range])
        let digits = slice.filter(\.isNumber)
        return digits.isEmpty ? nil : digits
    }

    private static func passwordToken(from dict: [String: Any], headers: [String: String]) -> String {
        let direct = {
            if let s = dict["passwordToken"] as? String, !s.isEmpty { return s }
            if let n = dict["passwordToken"] as? NSNumber { return n.stringValue }
            return ""
        }()
        if !direct.isEmpty { return direct }
        if let account = dict["accountInfo"] as? [String: Any] {
            if let s = account["passwordToken"] as? String, !s.isEmpty { return s }
        }
        // Some pods echo the token only on Set-Cookie / X-Token.
        for (key, value) in headers {
            let k = key.lowercased()
            if k == "x-token", !value.isEmpty { return value }
            if k == "set-cookie", value.lowercased().contains("x-token=") {
                if let r = value.range(of: #"(?i)x-token=([^;]+)"#, options: .regularExpression) {
                    let raw = String(value[r])
                    if let eq = raw.split(separator: "=").last {
                        let token = String(eq).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !token.isEmpty, token != "\"\"" { return token }
                    }
                }
            }
        }
        return ""
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

    /// When Store iOS spoof is on, pick the newest externalVersionId whose min iOS
    /// fits the claimed OS (or latest when claiming “newest”).
    func resolveSpoofCompatibleVersionId(
        adamId: Int,
        account: StorefrontSession
    ) async throws -> String? {
        let spoof = StoreDeviceSpoof.current
        guard spoof.enabled, spoof.autoSelectCompatibleVersion else { return nil }

        let listed = try await listExternalVersionIds(adamId: adamId, account: account)
        if spoof.claimsNewestOS {
            return listed.latest ?? listed.ids.last
        }

        // Walk newest → oldest; resolve metadata until minOS fits claimed iOS.
        let newestFirst = Array(listed.ids.reversed())
        let probeLimit = min(newestFirst.count, 48)
        for ext in newestFirst.prefix(probeLimit) {
            do {
                let item = try await fetchDownloadItem(
                    adamId: adamId,
                    account: account,
                    externalVersionId: ext
                )
                if spoof.acceptsMinimumOS(item.minimumOS) {
                    return ext
                }
            } catch {
                continue
            }
        }
        // Fall back to latest — UA spoof may still influence the unpinned path.
        return listed.latest ?? listed.ids.last
    }

    /// Resolve pin from explicit version string, else spoof-compatible auto pin.
    func resolveDownloadVersionId(
        adamId: Int,
        account: StorefrontSession,
        version: String? = nil,
        externalVersionId: String? = nil
    ) async throws -> String? {
        let explicit = (externalVersionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !explicit.isEmpty { return explicit }
        if let fromLabel = try await resolveExternalVersionId(adamId: adamId, account: account, version: version) {
            return fromLabel
        }
        return try await resolveSpoofCompatibleVersionId(adamId: adamId, account: account)
    }

    /// Best-effort purchase / download history for this Apple ID.
    /// Prefer modern Purchase DAAP (SAP-signed). Legacy MZFinance purchaseHistory often 404s.
    func purchaseHistory(account: StorefrontSession) async throws -> [OwnedStoreApp] {
        do {
            // DAAP success (including empty library) is authoritative.
            return try await StoreOwnedAppsClient.fetch(account: account)
        } catch AppStoreClientError.tokenExpired {
            throw AppStoreClientError.tokenExpired
        } catch {
            // Fall through to legacy MZFinance for older sessions / partial rollout.
        }

        do {
            let anisette = try await AnisetteClient.shared.fetch()
            var headers = storeHeaders(account, includeSpoofIdentity: false)
            // Match authenticate: Configurator UA + pristine Client-Info (not itunesstored spoof).
            headers["User-Agent"] = configuratorUA
            let (dict, _, _) = try await postPlist(
                url: Paths.purchaseHistory,
                body: [
                    "guid": account.guid,
                    "requestId": UUID().uuidString.lowercased()
                ],
                anisette: anisette,
                extraHeaders: headers,
                forcePristineClientInfo: true,
                stripSpoofIdentity: true,
                authenticateAnisetteStyle: true
            )
            let failure = string(dict["failureType"])
            let customer = string(dict["customerMessage"])
            if failure == "2034" || failure == "2042" || failure == "1008" || failure == "9610" {
                throw AppStoreClientError.tokenExpired
            }
            if !failure.isEmpty {
                throw AppStoreClientError.message(customer.isEmpty ? "Purchase history failed (\(failure))." : customer)
            }
            return parseLegacyPurchaseHistory(dict)
        } catch AppStoreClientError.tokenExpired {
            throw AppStoreClientError.tokenExpired
        } catch {
            // Soft: Owned list is convenience — don't fail Decrypt when Store Access is green.
            let m = error.localizedDescription.lowercased()
            if m.contains("404") || m.contains("204") || m.contains("non-plist") || m.contains("403") {
                return []
            }
            throw error
        }
    }

    private func parseLegacyPurchaseHistory(_ dict: [String: Any]) -> [OwnedStoreApp] {

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
        try await downloadFileResumable(from: cdn, to: destination, onProgress: onProgress)
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
        version: String? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> (url: URL, item: StoreDownloadItem) {
        var pin = (externalVersionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if pin.isEmpty {
            if let resolved = try? await resolveDownloadVersionId(
                adamId: adamId,
                account: account,
                version: version,
                externalVersionId: nil
            ) {
                pin = resolved
            }
        }
        if !pin.isEmpty {
            let spoof = StoreDeviceSpoof.current
            if spoof.enabled {
                onProgress?("Spoof \(spoof.summaryLabel) · pinning \(pin)…")
            } else {
                onProgress?("Pinning store build \(pin)…")
            }
        }

        onProgress?("Ensuring App Store license…")
        do {
            try await purchaseFreeLicense(
                adamId: adamId,
                account: account,
                price: price,
                externalVersionId: pin.isEmpty ? nil : pin
            )
        } catch AppStoreClientError.message(let m)
            where m.localizedCaseInsensitiveContains("already") || m.localizedCaseInsensitiveContains("license") {
            // Already owned — continue.
        } catch let e as AppStoreClientError {
            if case .tokenExpired = e { throw e }
            // License already exists often surfaces as HTTP 500 in ipatool — continue to download.
        }

        var result = try await downloadIPA(
            adamId: adamId,
            account: account,
            destination: destination,
            externalVersionId: pin.isEmpty ? nil : pin,
            onProgress: onProgress
        )

        // If spoof wanted a lower OS but Apple still handed a newer-min package, walk older IDs.
        let spoof = StoreDeviceSpoof.current
        if spoof.enabled,
           spoof.autoSelectCompatibleVersion,
           !spoof.claimsNewestOS,
           !spoof.acceptsMinimumOS(result.item.minimumOS) {
            onProgress?("Package needs iOS \(result.item.minimumOS ?? "?")+ — finding older build for spoof…")
            if let older = try? await resolveSpoofCompatibleVersionId(adamId: adamId, account: account),
               older != pin {
                result = try await downloadIPA(
                    adamId: adamId,
                    account: account,
                    destination: destination,
                    externalVersionId: older,
                    onProgress: onProgress
                )
            }
        }
        return result
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
        // Try volumeStore (pod → p25 → bare) then redownload. Treat 204/404/5002 as soft fails.
        var lastError: Error?
        for endpoint in volumeStoreCandidates(account: account) {
            do {
                return try await downloadProductOnce(
                    adamId: adamId,
                    account: account,
                    anisette: anisette,
                    endpoint: endpoint,
                    versionKey: "externalVersionId",
                    externalVersionId: externalVersionId
                )
            } catch {
                if isSoftDownloadFailure(error) {
                    lastError = error
                    continue
                }
                throw error
            }
        }

        do {
            return try await downloadProductOnce(
                adamId: adamId,
                account: account,
                anisette: anisette,
                endpoint: Paths.redownload,
                versionKey: "appExtVrsId",
                externalVersionId: externalVersionId
            )
        } catch {
            if isSoftDownloadFailure(error), let lastError {
                throw lastError
            }
            throw error
        }
    }

    private func volumeStoreCandidates(account: StorefrontSession) -> [String] {
        var hosts: [String] = []
        if let pod = account.pod, !pod.isEmpty {
            hosts.append("https://p\(pod)-buy.itunes.apple.com")
        }
        hosts.append(Paths.downloadHost) // p25
        hosts.append("https://buy.itunes.apple.com")
        // Dedup while preserving order.
        var seen = Set<String>()
        return hosts.compactMap { host in
            guard seen.insert(host).inserted else { return nil }
            return "\(host)\(Paths.downloadPath)?guid=\(account.guid)"
        }
    }

    private func isSoftDownloadFailure(_ error: Error) -> Bool {
        if let e = error as? AppStoreClientError {
            switch e {
            case .tokenExpired:
                // Probe next endpoint before forcing re-login (owned-app 5002 was once mapped here).
                return true
            case .message(let m):
                let lower = m.lowercased()
                return m.contains("5002")
                    || lower.contains("no download")
                    || lower.contains("no longer available")
                    || lower.contains("empty")
                    || lower.contains("204")
                    || lower.contains("404")
                    || lower.contains("non-plist")
            case .network(let m):
                let lower = m.lowercased()
                return lower.contains("204")
                    || lower.contains("404")
                    || lower.contains("403")
                    || lower.contains("non-plist")
                    || lower.contains("502")
                    || lower.contains("503")
            default:
                return false
            }
        }
        return false
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
            "salableAdamId": adamId,
            "serialNumber": "0"
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

    private func storeHeaders(
        _ account: StorefrontSession,
        includeSpoofIdentity: Bool = true
    ) -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": "application/x-apple-plist",
            "User-Agent": storeUserAgent,
            "iCloud-DSID": account.dsid,
            "X-Dsid": account.dsid,
            "X-Apple-Store-Front": account.storeFront,
            "X-Token": account.passwordToken
        ]
        let identity = StoreDeviceSpoof.current.storeIdentityHeaders()
        // Device-type / client-application are safe on account endpoints.
        if let dt = identity["X-Apple-I-Device-Type"] {
            headers["X-Apple-I-Device-Type"] = dt
        }
        if let ca = identity["X-Apple-Client-Application"] {
            headers["X-Apple-Client-Application"] = ca
        }
        // Spoofed OS/model headers belong on package download — not purchaseHistory /
        // authenticate. Sending them there is a frequent HTTP 204/404 cause.
        if includeSpoofIdentity {
            for (k, v) in identity {
                if k == "X-Apple-I-Device-Type" || k == "X-Apple-Client-Application" { continue }
                headers[k] = v
            }
        }
        return headers
    }

    // MARK: - HTTP helpers

    private func postPlist(
        url: String,
        body: [String: Any],
        bodyData: Data? = nil,
        anisette: AnisetteHeaders,
        extraHeaders: [String: String],
        allowRedirectCapture: Bool = false,
        forcePristineClientInfo: Bool = false,
        stripSpoofIdentity: Bool = false,
        authenticateAnisetteStyle: Bool = false
    ) async throws -> (dict: [String: Any], headers: [String: String], status: Int) {
        guard let endpoint = URL(string: url) else {
            throw AppStoreClientError.message("Bad App Store URL.")
        }
        // Prefer pre-serialized bytes when a SAP signature was computed over them.
        let plist = try bodyData ?? PropertyListSerialization.data(fromPropertyList: body, format: .xml, options: 0)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = plist
        req.httpShouldHandleCookies = true
        applyAnisette(
            &req,
            anisette,
            forcePristineClientInfo: forcePristineClientInfo,
            authenticateStyle: authenticateAnisetteStyle
        )
        for (k, v) in extraHeaders {
            if stripSpoofIdentity,
               k == "X-Apple-I-OS-Version" || k == "X-Apple-I-Requested-Model" {
                continue
            }
            req.setValue(v, forHTTPHeaderField: k)
        }
        if stripSpoofIdentity {
            // Prefer a non-spoofed configurator UA when recovering from 403.
            req.setValue(configuratorUA, forHTTPHeaderField: "User-Agent")
        }

        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        var headerMap: [String: String] = [:]
        if let fields = http?.allHeaderFields {
            for (k, v) in fields {
                headerMap[String(describing: k)] = String(describing: v)
            }
        }
        if let http, let loc = http.value(forHTTPHeaderField: "Location"), !loc.isEmpty {
            headerMap["Location"] = loc
        }
        // iOS often omits Location from allHeaderFields when the redirect is cancelled —
        // recover it from the redirect delegate's newRequest.url.
        if (300..<400).contains(status),
           (headerMap["Location"] ?? headerMap["location"] ?? "").isEmpty,
           let captured = StoreRedirectBlocker.shared.takeLastRedirectLocation() {
            headerMap["Location"] = captured
        }
        if (300..<400).contains(status) {
            if allowRedirectCapture {
                return ([:], headerMap, status)
            }
            // Non-auth calls: follow one hop manually with the same method/body.
            if let loc = headerMap["Location"] ?? headerMap["location"], !loc.isEmpty,
               let next = URL(string: loc, relativeTo: endpoint)?.absoluteString {
                return try await postPlist(
                    url: next,
                    body: body,
                    bodyData: bodyData,
                    anisette: anisette,
                    extraHeaders: extraHeaders,
                    allowRedirectCapture: false,
                    forcePristineClientInfo: forcePristineClientInfo,
                    stripSpoofIdentity: stripSpoofIdentity,
                    authenticateAnisetteStyle: authenticateAnisetteStyle
                )
            }
            throw AppStoreClientError.network("Store redirected (HTTP \(status)) without a usable Location.")
        }
        // Empty / no-content: usually spoof identity / Client-Info fighting anisette.
        // Retry once with pristine headers before surfacing HTTP 204 (owned list used to
        // throw immediately here and never recover).
        if status == 204 || (data.isEmpty && (status == 0 || status == 204)) {
            if !stripSpoofIdentity || !forcePristineClientInfo {
                return try await postPlist(
                    url: url,
                    body: body,
                    bodyData: bodyData,
                    anisette: anisette,
                    extraHeaders: extraHeaders,
                    allowRedirectCapture: allowRedirectCapture,
                    forcePristineClientInfo: true,
                    stripSpoofIdentity: true,
                    authenticateAnisetteStyle: authenticateAnisetteStyle
                )
            }
            throw AppStoreClientError.network(
                "Non-plist App Store response (HTTP 204). Tap Retry Store unlock under Settings › Store Access (Client-Info rewrite is cleared automatically) — stay signed in."
            )
        }
        if data.isEmpty, status == 500 {
            return (["failureType": "5002"], headerMap, status)
        }
        if status == 404 {
            if !stripSpoofIdentity || !forcePristineClientInfo {
                return try await postPlist(
                    url: url,
                    body: body,
                    bodyData: bodyData,
                    anisette: anisette,
                    extraHeaders: extraHeaders,
                    allowRedirectCapture: allowRedirectCapture,
                    forcePristineClientInfo: true,
                    stripSpoofIdentity: true,
                    authenticateAnisetteStyle: authenticateAnisetteStyle
                )
            }
            throw AppStoreClientError.network(Self.friendlyNonPlistError(status: 404, data: data))
        }
        if status == 403 {
            // Spoofed OS identity (especially literal iOS 99) often yields HTML 403.
            if !stripSpoofIdentity || !forcePristineClientInfo {
                return try await postPlist(
                    url: url,
                    body: body,
                    bodyData: bodyData,
                    anisette: anisette,
                    extraHeaders: extraHeaders,
                    allowRedirectCapture: allowRedirectCapture,
                    forcePristineClientInfo: true,
                    stripSpoofIdentity: true,
                    authenticateAnisetteStyle: authenticateAnisetteStyle
                )
            }
            throw AppStoreClientError.network(Self.friendlyNonPlistError(status: 403, data: data))
        }
        guard let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            // Retry with pristine Client-Info and without spoof OS headers — common 204/403/404 cause.
            if !forcePristineClientInfo || !stripSpoofIdentity {
                return try await postPlist(
                    url: url,
                    body: body,
                    bodyData: bodyData,
                    anisette: anisette,
                    extraHeaders: extraHeaders,
                    allowRedirectCapture: allowRedirectCapture,
                    forcePristineClientInfo: true,
                    stripSpoofIdentity: true,
                    authenticateAnisetteStyle: authenticateAnisetteStyle
                )
            }
            throw AppStoreClientError.network(Self.friendlyNonPlistError(status: status, data: data))
        }
        return (dict, headerMap, status)
    }

    /// Never dump Apple HTML 404/500 pages into the Settings UI.
    private static func friendlyNonPlistError(status: Int, data: Data) -> String {
        let raw = String(data: data, encoding: .utf8) ?? ""
        let looksHTML = raw.localizedCaseInsensitiveContains("<html")
            || raw.localizedCaseInsensitiveContains("<!DOCTYPE")
            || raw.localizedCaseInsensitiveContains("<head>")
        if status == 403 {
            return looksHTML
                ? "Store rejected this device identity (HTTP 403). In Settings › Store Access set spoof to This iPhone, then Retry Store unlock."
                : "Non-plist App Store response (HTTP 403). Turn spoof off or use This iPhone, then Retry Store unlock."
        }
        if status == 404 {
            return "Store endpoint returned HTTP 404. Tap Retry Store unlock — or Sign Out and Sign In once. Stay signed in."
        }
        if status >= 500 {
            return "Apple’s store servers returned HTTP \(status). Wait a moment, then tap Retry Store unlock."
        }
        if looksHTML {
            return "Store request failed (HTTP \(status)). Tap Retry Store unlock, or Sign Out and Sign In once if this keeps happening."
        }
        let snippet = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if snippet.isEmpty {
            return "Store request failed (HTTP \(status)). Sign in again under Store Access if this keeps happening."
        }
        return "Store request failed (HTTP \(status)). \(snippet.prefix(80))"
    }

    private func applyAnisette(
        _ req: inout URLRequest,
        _ a: AnisetteHeaders,
        forcePristineClientInfo: Bool = false,
        authenticateStyle: Bool = false
    ) {
        // Keep Client-Info aligned with anisette MID/OTP unless user explicitly enables rewrite.
        let clientInfo: String
        if forcePristineClientInfo {
            clientInfo = a.clientInfo
        } else {
            clientInfo = StoreDeviceSpoof.current.rewritingClientInfo(a.clientInfo)
        }
        req.setValue(clientInfo, forHTTPHeaderField: "X-MMe-Client-Info")
        req.setValue(a.localUserID, forHTTPHeaderField: "X-Apple-I-MD-LU")
        req.setValue(a.routingInfo, forHTTPHeaderField: "X-Apple-I-MD-RINFO")
        req.setValue(a.deviceID, forHTTPHeaderField: "X-Mme-Device-Id")
        req.setValue(a.serialNumber, forHTTPHeaderField: "X-Apple-I-SRL-NO")
        req.setValue(a.clientTime, forHTTPHeaderField: "X-Apple-I-Client-Time")
        req.setValue(a.locale, forHTTPHeaderField: "X-Apple-Locale")
        req.setValue(a.timeZone, forHTTPHeaderField: "X-Apple-I-TimeZone")
        // Authenticate (ipatool): AMD aliases only — duplicate I-MD / I-MD-M can soft-204.
        req.setValue(a.oneTimePassword, forHTTPHeaderField: "X-Apple-AMD")
        req.setValue(a.machineID, forHTTPHeaderField: "X-Apple-AMD-M")
        if !authenticateStyle {
            req.setValue(a.machineID, forHTTPHeaderField: "X-Apple-I-MD-M")
            req.setValue(a.oneTimePassword, forHTTPHeaderField: "X-Apple-I-MD")
        }
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

/// Blocks HTTP redirects so authenticate can re-POST to pod `Location` (ipatool-style).
/// Captures Location from both response headers and `newRequest.url` — on iOS,
/// cancelled redirects often omit Location from `allHeaderFields` even when present.
private final class StoreRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = StoreRedirectBlocker()
    private let lock = NSLock()
    private var lastRedirectLocation: String?

    func takeLastRedirectLocation() -> String? {
        lock.lock()
        defer { lock.unlock() }
        let value = lastRedirectLocation
        lastRedirectLocation = nil
        return value
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var location = response.value(forHTTPHeaderField: "Location")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if location.isEmpty, let url = request.url?.absoluteString, !url.isEmpty {
            // newRequest is built from Location even when allHeaderFields later drops it.
            location = url
        }
        if !location.isEmpty {
            lock.lock()
            lastRedirectLocation = location
            lock.unlock()
        }
        completionHandler(nil)
    }
}
