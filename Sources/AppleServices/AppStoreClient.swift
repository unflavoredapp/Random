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
    /// `name=value; …` from authenticate Set-Cookie (mz_at / itspod). ApplePackage keeps these
    /// on the Account; without them cold remints often get empty songList / soft 5002.
    var cookieHeader: String? = nil

    var isUsable: Bool {
        !passwordToken.isEmpty && !dsid.isEmpty && !storeFront.isEmpty
    }

    /// True when the mint is older than `maxAge` (used for quiet remint, not a hard expiry).
    func isAged(maxAge: TimeInterval) -> Bool {
        Date().timeIntervalSince(createdAt) > maxAge
    }

    /// ipatool expects a 6-byte (12 hex) GUID on commerce URLs/bodies.
    func normalizedForCommerce() -> StorefrontSession {
        var copy = self
        let hex = guid.uppercased().filter(\.isHexDigit)
        if hex.count >= 12 {
            copy.guid = String(hex.prefix(12))
        }
        return copy
    }

    /// Merge fresh Set-Cookie values into the persisted jar (name → name=value).
    func mergingCookies(_ header: String?) -> StorefrontSession {
        guard let header, !header.isEmpty else { return self }
        var byName: [String: String] = [:]
        for piece in (cookieHeader ?? "").split(separator: ";") {
            let nv = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = nv.firstIndex(of: "=") else { continue }
            byName[String(nv[..<eq])] = nv
        }
        for piece in header.split(separator: ";") {
            let nv = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = nv.firstIndex(of: "=") else { continue }
            byName[String(nv[..<eq])] = nv
        }
        var copy = self
        copy.cookieHeader = byName.isEmpty ? cookieHeader : byName.values.sorted().joined(separator: "; ")
        return copy
    }
}

/// FairPlay license blob from `songList[].sinfs` (injected into IPA `SC_Info` after CDN download).
struct StoreSinf: Sendable {
    var id: Int64
    var data: Data
}

/// One songList item from volumeStore / redownload (package URL + metadata).
struct StoreDownloadItem: @unchecked Sendable {
    var url: URL?
    var md5: String?
    var artworkURL: URL?
    var sinfs: [StoreSinf]
    var metadata: [String: Any]

    var sinfCount: Int { sinfs.count }

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
    /// Purchase / redownload timestamp from DAAP `asdp` when available.
    var purchaseDate: Date? = nil

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

    var asIPadnStoreApp: IPadnStoreApp {
        IPadnStoreApp(
            id: "\(adamId)",
            name: name,
            bundleID: bundleId,
            version: version,
            iconURL: iconURL,
            developer: artistName,
            storeURL: storeURL,
            country: "US"
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
        case .tokenExpired: return "App Store session expired — TetherLess will refresh it automatically; sign in again under Account only if refresh fails."
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
        /// Bag updateProduct recovery when redownload returns empty HTTP 500 (ApplePackage).
        static let updateProduct = "https://downloaddispatch.itunes.apple.com/up/updateProduct"
        static let purchaseHistory = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/purchaseHistory"
    }

    private init() {}

    /// Live jar merged from authenticate + commerce Set-Cookie (cold start still uses session.cookieHeader).
    private var liveCookieHeader: String?

    private var storeUserAgent: String {
        StoreDeviceSpoof.current.storeUserAgent(fallbackConfigurator: configuratorUA)
    }

    // MARK: - Public API

    /// Prefetch anisette + SAP so the first buy/download isn't paying handshake latency.
    func warmConnection() async {
        async let a: Void = AnisetteClient.shared.prefetchIfNeeded()
        async let s: Void = SAPSigner.warm()
        _ = await (a, s)
    }

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

        // Real-device identity only — never mint under a leftover Store spoof profile.
        StoreDeviceSpoof.clearPersistedSpoof()

        // SAP ActionSignature is required for Apple's current store edge (ipatool #525 /
        // ApplePackage). Unsigned posts get HTML 301-without-Location or empty 204.
        var sapSigner: SAPSigner
        do {
            sapSigner = try await SAPSigner.connect()
        } catch {
            SAPSigner.invalidateCache()
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
                // Soft 204 / 302-without-Location often means a stale ActionSignature —
                // remint SAP before the next starter instead of burning pods with a dead signer.
                if Self.shouldRotateAuthenticateEndpoint(lastError) {
                    SAPSigner.invalidateCache()
                    do {
                        sapSigner = try await SAPSigner.connect()
                    } catch {
                        lastError = AppStoreClientError.message(
                            "Store SAP setup failed (\(error.localizedDescription)). Tap Retry Store unlock — or Sign Out and Sign In once."
                        )
                        continue
                    }
                }
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
                    // Fold Set-Cookie from the redirect hop before re-POSTing (mz_at / itspod).
                    if let hopCookies = Self.cookieHeader(
                        from: headers,
                        session: session,
                        urls: [endpoint, "https://buy.itunes.apple.com/", "https://auth.itunes.apple.com/"]
                    ) {
                        liveCookieHeader = Self.mergeCookieStrings(liveCookieHeader, hopCookies)
                    }
                    let loc = Self.extractRedirectLocation(from: headers, excludingEndpoint: endpoint)
                    if loc.isEmpty {
                        // 301/302 without usable Location — soft reject; rotate endpoint.
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
                            "Store authenticate redirected (HTTP \(status)) to the same endpoint (soft reject)."
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

                let cookies = Self.cookieHeader(
                    from: headers,
                    session: session,
                    urls: [endpoint, "https://buy.itunes.apple.com/"]
                )
                liveCookieHeader = Self.mergeCookieStrings(liveCookieHeader, cookies)
                return StorefrontSession(
                    email: email,
                    passwordToken: token,
                    dsid: dsid,
                    storeFront: resolvedFront,
                    pod: pod,
                    guid: guid,
                    createdAt: Date(),
                    cookieHeader: liveCookieHeader ?? cookies
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
            || m.contains("same endpoint")
            || m.contains("soft reject")
            || m.contains("empty or non-plist")
            || m.contains("non-plist")
    }

    /// Prefer real Location / Apple jingle redirect headers; ignore self-echo URLs.
    private static func extractRedirectLocation(
        from headers: [String: String],
        excludingEndpoint: String
    ) -> String {
        let preferredKeys = [
            "Location", "location",
            "X-Apple-jingle-redirect-location", "x-apple-jingle-redirect-location"
        ]
        var candidates: [String] = []
        for key in preferredKeys {
            if let v = headers[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                candidates.append(v)
            }
        }
        for (key, value) in headers {
            let lk = key.lowercased()
            guard lk == "location"
                || lk.hasSuffix("redirect-location")
                || lk.contains("jingle-redirect") else { continue }
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { candidates.append(v) }
        }
        let cur = URL(string: excludingEndpoint)
        for raw in candidates {
            guard let resolved = URL(string: raw, relativeTo: cur)?.absoluteURL else {
                if !raw.isEmpty { return raw }
                continue
            }
            if resolved.host?.lowercased() == cur?.host?.lowercased(),
               resolved.path == cur?.path {
                continue // self-echo from cancelled redirect — not a usable hop
            }
            return resolved.absoluteString
        }
        return ""
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
        let account = account.normalizedForCommerce()
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
        let account = account.normalizedForCommerce()
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
        } catch {
            // Fall through to legacy MZFinance — never escalate Owned failures to tokenExpired
            // here (that used to wipe green Store Access).
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
            // Legacy expiry codes: soft-empty for Owned listing (downloads remint on demand).
            if failure == "2034" || failure == "2042" || failure == "1008" || failure == "9610" {
                return []
            }
            if !failure.isEmpty {
                throw AppStoreClientError.message(customer.isEmpty ? "Purchase history failed (\(failure))." : customer)
            }
            return parseLegacyPurchaseHistory(dict)
        } catch {
            // Soft: Owned list is convenience — empty is better than wiping Store Access.
            let m = error.localizedDescription.lowercased()
            if m.contains("404") || m.contains("204") || m.contains("non-plist") || m.contains("403")
                || m.contains("owned list") || m.contains("token expired") {
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
    /// Transport / SAP failures rethrow — only true “no license” returns false.
    func hasLicense(adamId: Int, account: StorefrontSession) async throws -> Bool {
        do {
            _ = try await fetchDownloadItem(adamId: adamId, account: account)
            return true
        } catch AppStoreClientError.licenseRequired {
            return false
        } catch AppStoreClientError.paidApp {
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
        let account = account.normalizedForCommerce()
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
        onProgress?("Writing iTunesMetadata + FairPlay licenses…")
        do {
            try writeiTunesMetadata(item.metadata, email: account.email, intoIPA: destination)
        } catch {
            onProgress?("iTunesMetadata write failed (\(error.localizedDescription)) — continuing.")
        }
        // CDN package has no SC_Info — inject songList sinfs so companion FairPlay can run
        // without a live App Store install (ApplePackage SignatureInjector).
        if !item.sinfs.isEmpty {
            do {
                try injectSinfs(item.sinfs, intoIPA: destination)
                onProgress?("Embedded \(item.sinfs.count) FairPlay license(s)…")
            } catch {
                throw AppStoreClientError.message(
                    "Couldn't embed FairPlay licenses into the IPA (\(error.localizedDescription)). Sign in again under Account and retry."
                )
            }
        }
        // Fold commerce Set-Cookie into the persisted Store jar for the next cold start.
        if let live = liveCookieHeader {
            AppleIDStore.shared.mergeLiveStoreCookies(live)
        }
        return (destination, item)
    }

    /// Device mints SAP-signed commerce + anisette headers; TetherLess backend hits Apple/CDN.
    /// FairPlay stays on-device — used after phone volumeStore HTTP 403 remint fails.
    @discardableResult
    func downloadIPAViaBackend(
        adamId: Int,
        account: StorefrontSession,
        destination: URL,
        externalVersionId: String? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> (url: URL, item: StoreDownloadItem) {
        let account = account.normalizedForCommerce()
        let anisette = try await AnisetteClient.shared.fetch()
        onProgress?("Preparing signed Store request for backend fetch…")

        var body: [String: Any] = [
            "creditDisplay": "",
            "guid": account.guid,
            "salableAdamId": adamId,
            "serialNumber": "0",
        ]
        let pin = (externalVersionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !pin.isEmpty {
            body["externalVersionId"] = pin
        }
        let bodyData = try PropertyListSerialization.data(
            fromPropertyList: body, format: .xml, options: 0
        )
        let signer = try await SAPSigner.connect()
        let signature = try await signer.sign(bodyData)

        var headers = commerceHeaders(account)
        headers["X-Apple-ActionSignature"] = signature.base64EncodedString()
        // Commerce anisette (authenticate-style + pristine Client-Info). Prefer WASM ADI
        // AMD when available — same store-proof Apple expects after login.
        headers["X-MMe-Client-Info"] = anisette.clientInfo
        headers["X-Apple-I-MD-LU"] = anisette.localUserID
        headers["X-Apple-I-MD-RINFO"] = anisette.routingInfo
        headers["X-Mme-Device-Id"] = anisette.deviceID
        headers["X-Apple-I-SRL-NO"] = anisette.serialNumber
        headers["X-Apple-I-Client-Time"] = anisette.clientTime
        headers["X-Apple-Locale"] = anisette.locale
        headers["X-Apple-I-TimeZone"] = anisette.timeZone
        headers["User-Agent"] = configuratorUA
        let guid = IPadnStoreLogin.storeGUID()
        if let proof = try? await IPadnWASMSPSigner.shared.storeProofHeaders(guid: guid, useCache: true) {
            for (k, v) in proof where !v.isEmpty { headers[k] = v }
        } else {
            headers["X-Apple-AMD"] = anisette.oneTimePassword
            headers["X-Apple-AMD-M"] = anisette.machineID
        }

        var endpoints = volumeStoreCandidates(account: account)
        endpoints.append(Paths.redownload)
        if !pin.isEmpty {
            endpoints.append("\(Paths.updateProduct)?guid=\(account.guid)")
        }

        let payload: [String: Any] = [
            "adamId": adamId,
            "guid": account.guid,
            "externalVersionId": pin,
            "bodyPlistBase64": bodyData.base64EncodedString(),
            "headers": headers,
            "endpoints": endpoints,
        ]
        onProgress?("Backend Store fetch (Apple commerce + CDN)…")
        let req = try LocalDecryptBridge.request("api/store/fetch-ipa", body: payload, timeout: 600)
        let (_, json) = try await LocalDecryptBridge.sendRaw(req)
        guard let jobId = json["id"] as? String, !jobId.isEmpty else {
            throw AppStoreClientError.message("Backend Store fetch returned no job id.")
        }
        let sinfs = Self.parseSinfsFromBackend(json["sinfs"])
        var meta = (json["metadata"] as? [String: Any]) ?? [:]
        if meta.isEmpty {
            if let name = json["name"] as? String, !name.isEmpty { meta["itemName"] = name }
            if let ver = json["version"] as? String, !ver.isEmpty {
                meta["bundleShortVersionString"] = ver
            }
        }
        let item = StoreDownloadItem(
            url: nil,
            md5: nil,
            artworkURL: nil,
            sinfs: sinfs,
            metadata: meta
        )

        onProgress?("Downloading encrypted IPA from TetherLess…")
        var dl = try LocalDecryptBridge.request("api/store/ipa/\(jobId)", timeout: 600)
        dl.httpMethod = "GET"
        dl.setValue(nil, forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: dl)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code), data.count > 100 else {
            let err = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw AppStoreClientError.network(
                err ?? "Backend IPA download failed (HTTP \(code))."
            )
        }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)

        onProgress?("Writing iTunesMetadata + FairPlay licenses…")
        do {
            try writeiTunesMetadata(item.metadata, email: account.email, intoIPA: destination)
        } catch {
            onProgress?("iTunesMetadata write failed (\(error.localizedDescription)) — continuing.")
        }
        if !item.sinfs.isEmpty {
            do {
                try injectSinfs(item.sinfs, intoIPA: destination)
                onProgress?("Embedded \(item.sinfs.count) FairPlay license(s)…")
            } catch {
                throw AppStoreClientError.message(
                    "Couldn't embed FairPlay licenses into the IPA (\(error.localizedDescription)). Sign in again under Account and retry."
                )
            }
        }
        return (destination, item)
    }

    private static func parseSinfsFromBackend(_ any: Any?) -> [StoreSinf] {
        guard let rows = any as? [[String: Any]] else { return [] }
        var out: [StoreSinf] = []
        out.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() {
            let id: Int64
            if let n = row["id"] as? Int64 { id = n }
            else if let n = row["id"] as? Int { id = Int64(n) }
            else if let n = row["id"] as? NSNumber { id = n.int64Value }
            else { id = Int64(i) }
            let b64 = (row["data"] as? String) ?? (row["sinf"] as? String) ?? ""
            guard let data = Data(base64Encoded: b64), !data.isEmpty else { continue }
            out.append(StoreSinf(id: id, data: data))
        }
        return out
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
        let account = account.normalizedForCommerce()
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

        // Prefer owned volumeStore/redownload first — free Apple apps (TestFlight) and already-
        // purchased titles often 403 on buyProduct while redownload still works.
        do {
            var result = try await downloadIPA(
                adamId: adamId,
                account: account,
                destination: destination,
                externalVersionId: pin.isEmpty ? nil : pin,
                onProgress: onProgress
            )
            return try await finishPurchaseDownload(
                result: result,
                adamId: adamId,
                account: account,
                pin: pin,
                destination: destination,
                onProgress: onProgress
            )
        } catch let first as AppStoreClientError where Self.shouldAttemptLicenseThenDownload(first) {
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
                if case .paidApp = e { throw e }
                if case .licenseRequired = e { throw e }
                // License already exists often surfaces as HTTP 500 in ipatool — continue.
            }
            let result = try await downloadIPA(
                adamId: adamId,
                account: account,
                destination: destination,
                externalVersionId: pin.isEmpty ? nil : pin,
                onProgress: onProgress
            )
            return try await finishPurchaseDownload(
                result: result,
                adamId: adamId,
                account: account,
                pin: pin,
                destination: destination,
                onProgress: onProgress
            )
        }
    }

    /// After a failed owned download, buy+download may recover (missing license / soft 5002).
    private static func shouldAttemptLicenseThenDownload(_ error: AppStoreClientError) -> Bool {
        switch error {
        case .licenseRequired:
            return true
        case .message(let m):
            let lower = m.lowercased()
            return lower.contains("no download")
                || lower.contains("5002")
                || lower.contains("license")
                || lower.contains("empty")
        case .network(let m):
            let lower = m.lowercased()
            // Don't buy-first on identity 403 — remint/session fix is the right recovery.
            return lower.contains("204")
                || lower.contains("404")
                || lower.contains("500")
                || lower.contains("non-plist")
        default:
            return false
        }
    }

    private func finishPurchaseDownload(
        result: (url: URL, item: StoreDownloadItem),
        adamId: Int,
        account: StorefrontSession,
        pin: String,
        destination: URL,
        onProgress: ((String) -> Void)?
    ) async throws -> (url: URL, item: StoreDownloadItem) {
        var result = result
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
        // Match ipatool / ApplePackage: SAP-signed body + Configurator UA + token.
        let (dict, respHeaders, status) = try await postCommercePlist(
            url: host,
            body: body,
            anisette: anisette,
            account: account
        )
        rememberCommerceCookies(from: respHeaders)
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
            if !isSoftDownloadFailure(error) { throw error }
            lastError = error
        }

        // ApplePackage: empty redownload HTTP 500 → bag updateProduct with pinned version.
        let pin = (externalVersionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !pin.isEmpty {
            do {
                return try await downloadProductOnce(
                    adamId: adamId,
                    account: account,
                    anisette: anisette,
                    endpoint: "\(Paths.updateProduct)?guid=\(account.guid)",
                    versionKey: "appExtVrsId",
                    externalVersionId: pin
                )
            } catch {
                if isSoftDownloadFailure(error), let lastError {
                    throw lastError
                }
                throw error
            }
        }
        if let lastError { throw lastError }
        throw AppStoreClientError.message("App Store returned no download items.")
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
        // Commerce download: SAP ActionSignature + X-Token (ipatool / ApplePackage).
        // Keep spoof OS headers off — pin via externalVersionId instead.
        let (dict, respHeaders, _) = try await postCommercePlist(
            url: endpoint,
            body: body,
            anisette: anisette,
            account: account
        )
        rememberCommerceCookies(from: respHeaders)
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
        let meta = (item["metadata"] as? [String: Any]) ?? [:]
        return StoreDownloadItem(
            url: urlString.flatMap(URL.init(string:)),
            md5: stringOptional(item["md5"]),
            artworkURL: artwork.flatMap(URL.init(string:)),
            sinfs: Self.parseSinfs(item["sinfs"]),
            metadata: meta
        )
    }

    private static func parseSinfs(_ any: Any?) -> [StoreSinf] {
        guard let rows = any as? [[String: Any]] else { return [] }
        var out: [StoreSinf] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            let id: Int64
            if let n = row["id"] as? Int64 {
                id = n
            } else if let n = row["id"] as? Int {
                id = Int64(n)
            } else if let n = row["id"] as? NSNumber {
                id = n.int64Value
            } else {
                id = Int64(out.count)
            }
            let data: Data?
            if let d = row["sinf"] as? Data {
                data = d
            } else if let d = row["sinf"] as? NSData {
                data = d as Data
            } else if let s = row["sinf"] as? String {
                data = Data(base64Encoded: s) ?? s.data(using: .utf8)
            } else {
                data = nil
            }
            guard let data, !data.isEmpty else { continue }
            out.append(StoreSinf(id: id, data: data))
        }
        return out
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
        if let cookie = account.cookieHeader, !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
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

    /// buyProduct / volumeStore / redownload / updateProduct — ipatool-shaped headers.
    private func commerceHeaders(_ account: StorefrontSession) -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": "application/x-apple-plist",
            "User-Agent": configuratorUA,
            "iCloud-DSID": account.dsid,
            "X-Dsid": account.dsid,
            "X-Apple-Store-Front": account.storeFront,
            "X-Token": account.passwordToken
        ]
        if let cookie = Self.mergeCookieStrings(account.cookieHeader, liveCookieHeader), !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        return headers
    }

    /// SAP-sign commerce POST bodies + iPadn WASM ADI store-proof on buy/volumeStore/redownload.
    /// Anisette AMD alone is what produced phone HTTP 403 after login already used WASM proof.
    private func postCommercePlist(
        url: String,
        body: [String: Any],
        anisette: AnisetteHeaders,
        account: StorefrontSession
    ) async throws -> (dict: [String: Any], headers: [String: String], status: Int) {
        let bodyData = try PropertyListSerialization.data(
            fromPropertyList: body, format: .xml, options: 0
        )
        var headers = commerceHeaders(account)
        do {
            let signer = try await SAPSigner.connect()
            let signature = try await signer.sign(bodyData)
            headers["X-Apple-ActionSignature"] = signature.base64EncodedString()
        } catch {
            // Unsigned commerce often HTML-403s on current pods — surface a clear remint hint.
            throw AppStoreClientError.message(
                "Store SAP signing failed (\(error.localizedDescription)). Tap Retry Store unlock."
            )
        }
        guard let endpoint = URL(string: url) else {
            throw AppStoreClientError.message("Bad App Store URL.")
        }

        // iPadn applies WASM ADI store-proof to volumeStore / buyProduct / redownload.
        // Do not fall through to Anisette-only after a real Apple 403 — that just
        // repeats the phone failure that remint already couldn't fix.
        if IPadnAppleAuthentication.needsStoreProof(endpoint) {
            return try await postCommerceWithStoreProof(
                endpoint: endpoint,
                body: body,
                bodyData: bodyData,
                baseHeaders: headers,
                anisette: anisette,
                account: account
            )
        }

        return try await postPlist(
            url: url,
            body: body,
            bodyData: bodyData,
            anisette: anisette,
            extraHeaders: headers,
            forcePristineClientInfo: true,
            stripSpoofIdentity: true,
            authenticateAnisetteStyle: true
        )
    }

    /// Commerce POST wrapped in iPadn `withStoreProof` (WASM ADI → Anisette fallback).
    private func postCommerceWithStoreProof(
        endpoint: URL,
        body: [String: Any],
        bodyData: Data,
        baseHeaders: [String: String],
        anisette: AnisetteHeaders,
        account: StorefrontSession
    ) async throws -> (dict: [String: Any], headers: [String: String], status: Int) {
        let guid = IPadnStoreLogin.storeGUID()
        let wasm = IPadnWASMSPSigner.shared
        var lastHeaders: [String: String] = [:]
        var lastStatus = 0

        let (raw, response) = try await IPadnAppleAuthentication.withStoreProof(
            endpoint: endpoint,
            baseHeaders: baseHeaders,
            loadProof: {
                do {
                    if let h = try await wasm.storeProofHeaders(guid: guid, useCache: true) {
                        return h
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // WASM not ready — Anisette AMD for this attempt.
                }
                let a = try await AnisetteClient.shared.fetch()
                return [
                    "X-Apple-AMD": a.oneTimePassword,
                    "X-Apple-AMD-M": a.machineID
                ]
            },
            provisionProof: { challenge in
                do {
                    return try await wasm.provisionStoreProof(
                        challenge: challenge,
                        guid: guid,
                        useCache: true
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    await AnisetteClient.shared.invalidate(resetProvisioning: false)
                    let a = try await AnisetteClient.shared.fetch()
                    return [
                        "X-Apple-AMD": a.oneTimePassword,
                        "X-Apple-AMD-M": a.machineID
                    ]
                }
            },
            resetProof: {
                wasm.resetStoreProof(guid: guid)
            },
            execute: { headerProvider in
                let merged = try await headerProvider(endpoint)
                let (dict, hdrs, status) = try await self.postPlist(
                    url: endpoint.absoluteString,
                    body: body,
                    bodyData: bodyData,
                    anisette: anisette,
                    extraHeaders: merged,
                    forcePristineClientInfo: true,
                    stripSpoofIdentity: true,
                    // Proof headers already carry AMD — don't also stamp Anisette aliases.
                    authenticateAnisetteStyle: false
                )
                lastHeaders = hdrs
                lastStatus = status
                // Synthesize enough of HTTPURLResponse for SP/RP header reads.
                let http = HTTPURLResponse(
                    url: endpoint,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: hdrs
                ) ?? HTTPURLResponse()
                return (dict, http)
            }
        )
        _ = response
        return (raw, lastHeaders, lastStatus)
    }

    private func rememberCommerceCookies(from headers: [String: String]) {
        let fresh = Self.cookieHeader(
            from: headers,
            session: session,
            urls: [
                "https://buy.itunes.apple.com/",
                "https://downloaddispatch.itunes.apple.com/"
            ]
        )
        liveCookieHeader = Self.mergeCookieStrings(liveCookieHeader, fresh)
    }

    private static func mergeCookieStrings(_ a: String?, _ b: String?) -> String? {
        var byName: [String: String] = [:]
        for raw in [a, b] {
            guard let raw, !raw.isEmpty else { continue }
            for piece in raw.split(separator: ";") {
                let nv = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let eq = nv.firstIndex(of: "=") else { continue }
                byName[String(nv[..<eq])] = nv
            }
        }
        guard !byName.isEmpty else { return nil }
        return byName.values.sorted().joined(separator: "; ")
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
               k == "X-Apple-I-OS-Version"
                || k == "X-Apple-I-Requested-Model"
                || k == "X-Apple-I-Device-Type"
                || k == "X-Apple-Client-Application" {
                continue
            }
            req.setValue(v, forHTTPHeaderField: k)
        }
        if stripSpoofIdentity {
            // Prefer a non-spoofed configurator UA when recovering from 403.
            req.setValue(configuratorUA, forHTTPHeaderField: "User-Agent")
        }
        // Carry authenticate hop cookies across pod redirects (session jar alone can miss mz_at).
        if allowRedirectCapture,
           let cookie = liveCookieHeader?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cookie.isEmpty {
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
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
        if let http {
            for key in ["Location", "X-Apple-jingle-redirect-location"] {
                if let loc = http.value(forHTTPHeaderField: key)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty {
                    headerMap["Location"] = loc
                    break
                }
            }
        }
        // iOS often omits Location from allHeaderFields when the redirect is cancelled —
        // recover it from the redirect delegate's newRequest.url / jingle header.
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
                "Non-plist App Store response (HTTP 204). Sign in again under Account if needed (Client-Info rewrite is cleared automatically) — stay signed in."
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
                ? "Store rejected this device identity (HTTP 403). Sign in again under Account."
                : "Non-plist App Store response (HTTP 403). Sign in again under Account."
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
            return "Store request failed (HTTP \(status)). Sign in again under Account if this keeps happening."
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
        // Match commerce: plain Configurator UA when spoof is off (no invented iOS/build tokens).
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

    /// Inject `songList` sinfs into `Payload/<App>.app/SC_Info/…` (ApplePackage SignatureInjector).
    private func injectSinfs(_ sinfs: [StoreSinf], intoIPA ipa: URL) throws {
        guard !sinfs.isEmpty else { return }
        let archive = try Archive(url: ipa, accessMode: .update)
        let bundleName = try Self.payloadAppBundleName(in: archive)
        let appPrefix = "Payload/\(bundleName).app/"

        if let paths = try Self.readSinfPathsFromManifest(in: archive, appPrefix: appPrefix), !paths.isEmpty {
            for (index, rel) in paths.enumerated() where index < sinfs.count {
                let path = appPrefix + rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                try Self.addOrReplaceZipEntry(archive, path: path, data: sinfs[index].data)
            }
            return
        }

        // No Manifest.plist — place the first sinf next to CFBundleExecutable.
        guard let exe = try Self.readBundleExecutable(in: archive, appPrefix: appPrefix) else {
            throw AppStoreClientError.message("Could not locate app executable for SINF inject.")
        }
        let path = "\(appPrefix)SC_Info/\(exe).sinf"
        try Self.addOrReplaceZipEntry(archive, path: path, data: sinfs[0].data)
    }

    private static func addOrReplaceZipEntry(_ archive: Archive, path: String, data: Data) throws {
        if let existing = archive[path] {
            try archive.remove(existing)
        }
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position) ..< Int(position) + size)
        }
    }

    private static func payloadAppBundleName(in archive: Archive) throws -> String {
        for entry in archive {
            let path = entry.path
            guard path.contains(".app/Info.plist"), !path.contains("/Watch/") else { continue }
            let parts = path.split(separator: "/")
            guard parts.count >= 2 else { continue }
            let app = parts[parts.count - 2]
            if app.hasSuffix(".app") {
                return String(app.dropLast(4))
            }
        }
        throw AppStoreClientError.message("Could not find Payload/*.app in downloaded IPA.")
    }

    private static func readSinfPathsFromManifest(in archive: Archive, appPrefix: String) throws -> [String]? {
        let path = appPrefix + "SC_Info/Manifest.plist"
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let paths = plist["SinfPaths"] as? [String], !paths.isEmpty else {
            return nil
        }
        return paths
    }

    private static func readBundleExecutable(in archive: Archive, appPrefix: String) throws -> String? {
        let path = appPrefix + "Info.plist"
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return plist?["CFBundleExecutable"] as? String
    }

    // MARK: - GUID

    /// Stable 6-byte store GUID as 12 hex chars (ipatool / Store AMD). Longer values break commerce.
    static func deviceGUID(from anisette: AnisetteHeaders) -> String {
        let raw = (anisette.deviceID + anisette.localUserID)
            .uppercased()
            .filter(\.isHexDigit)
        if raw.count >= 12 {
            return String(raw.prefix(12))
        }
        if let id = UIDevice.current.identifierForVendor?.uuidString {
            let hex = id.replacingOccurrences(of: "-", with: "").uppercased().filter(\.isHexDigit)
            if hex.count >= 12 { return String(hex.prefix(12)) }
        }
        let fallback = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
        return String(fallback.prefix(12))
    }

    /// Persist authenticate Set-Cookie values for later buy/download (cold start has no URLSession jar).
    private static func cookieHeader(
        from headers: [String: String],
        session: URLSession,
        urls: [String]
    ) -> String? {
        var byName: [String: String] = [:]
        // Prefer the session cookie jar (handles multiple Set-Cookie correctly).
        let storage = session.configuration.httpCookieStorage
        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            for cookie in storage?.cookies(for: url) ?? [] {
                byName[cookie.name] = "\(cookie.name)=\(cookie.value)"
            }
        }
        if let all = storage?.cookies {
            for cookie in all {
                let domain = cookie.domain.lowercased()
                if domain.contains("itunes.apple.com") || domain.contains("apple.com") {
                    byName[cookie.name] = "\(cookie.name)=\(cookie.value)"
                }
            }
        }
        // Fallback: single Set-Cookie echoed in header map (iOS often collapses multiples).
        if byName.isEmpty {
            for (key, value) in headers where key.lowercased() == "set-cookie" {
                let nameValue = value.split(separator: ";").first.map(String.init)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let eq = nameValue.firstIndex(of: "=") else { continue }
                let name = String(nameValue[..<eq])
                guard !name.isEmpty else { continue }
                byName[name] = nameValue
            }
        }
        guard !byName.isEmpty else { return nil }
        return byName.values.sorted().joined(separator: "; ")
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
        if location.isEmpty {
            location = response.value(forHTTPHeaderField: "X-Apple-jingle-redirect-location")?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
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
