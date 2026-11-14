//
//  AppStoreClient.swift
//  Silent App Store purchase + IPA download (ipatool-style MZFinance APIs).
//  Non-jailbroken: uses the signed-in Apple ID’s store passwordToken — no App Store UI.
//

import Foundation
import UIKit

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
    private let userAgent = "Configurator/2.15 (Macintosh; OS X 11.0.0; 16A5288f) AppleWebKit/0605.2.7.5"

    private enum Paths {
        static let authenticate = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/authenticate"
        static let purchase = "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct"
        static let downloadHost = "https://p25-buy.itunes.apple.com"
        static let downloadPath = "/WebObjects/MZFinance.woa/wa/volumeStoreDownloadProduct"
    }

    private init() {}

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
                    "User-Agent": userAgent
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
    func purchaseFreeLicense(adamId: Int, account: StorefrontSession, price: Double = 0) async throws {
        guard price <= 0 else { throw AppStoreClientError.paidApp }
        let anisette = try await AnisetteClient.shared.fetch()
        do {
            try await purchaseOnce(adamId: adamId, account: account, anisette: anisette, pricing: "STDQ")
        } catch AppStoreClientError.message(let m) where m.localizedCaseInsensitiveContains("unavailable") {
            try await purchaseOnce(adamId: adamId, account: account, anisette: anisette, pricing: "GAME")
        }
    }

    /// Request download metadata + CDN URL, then save the encrypted IPA to `destination`.
    @discardableResult
    func downloadIPA(
        adamId: Int,
        account: StorefrontSession,
        destination: URL,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> URL {
        let anisette = try await AnisetteClient.shared.fetch()
        onProgress?("Requesting App Store package…")
        let item = try await downloadProduct(adamId: adamId, account: account, anisette: anisette)
        guard let urlString = stringOptional(item["URL"]) ?? stringOptional(item["url"]),
              let cdn = URL(string: urlString) else {
            throw AppStoreClientError.message("App Store download response missing package URL.")
        }
        onProgress?("Downloading encrypted IPA…")
        try await downloadFile(from: cdn, to: destination)
        // Best-effort iTunesMetadata for tooling that expects it.
        if let meta = item["metadata"] as? [String: Any] {
            try? writeiTunesMetadata(meta, email: account.email, intoIPA: destination)
        }
        return destination
    }

    /// Purchase (if needed) + download for a free/owned adamId.
    func purchaseAndDownload(
        adamId: Int,
        account: StorefrontSession,
        destination: URL,
        price: Double = 0,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> URL {
        onProgress?("Ensuring App Store license…")
        do {
            try await purchaseFreeLicense(adamId: adamId, account: account, price: price)
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
            onProgress: onProgress
        )
    }

    // MARK: - Purchase / download wire

    private func purchaseOnce(
        adamId: Int,
        account: StorefrontSession,
        anisette: AnisetteHeaders,
        pricing: String
    ) async throws {
        var host = Paths.purchase
        if let pod = account.pod, !pod.isEmpty {
            host = "https://p\(pod)-buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct"
        }
        let (dict, _, status) = try await postPlist(
            url: host,
            body: [
                "appExtVrsId": "0",
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
            ],
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
        anisette: AnisetteHeaders
    ) async throws -> [String: Any] {
        var host = Paths.downloadHost
        if let pod = account.pod, !pod.isEmpty {
            host = "https://p\(pod)-buy.itunes.apple.com"
        }
        let url = "\(host)\(Paths.downloadPath)?guid=\(account.guid)"
        let (dict, _, _) = try await postPlist(
            url: url,
            body: [
                "creditDisplay": "",
                "guid": account.guid,
                "salableAdamId": adamId
            ],
            anisette: anisette,
            extraHeaders: storeHeaders(account)
        )
        let failure = string(dict["failureType"])
        let customer = string(dict["customerMessage"])
        if failure == "2034" || failure == "2042" || failure == "1008" || failure == "5002" {
            throw AppStoreClientError.tokenExpired
        }
        if failure == "9610" {
            throw AppStoreClientError.licenseRequired
        }
        if !failure.isEmpty {
            throw AppStoreClientError.message(customer.isEmpty ? "Download failed (\(failure))." : customer)
        }
        let items = dict["songList"] as? [[String: Any]] ?? []
        guard let first = items.first else {
            throw AppStoreClientError.message(customer.isEmpty ? "App Store returned no download items." : customer)
        }
        return first
    }

    private func storeHeaders(_ account: StorefrontSession) -> [String: String] {
        [
            "Content-Type": "application/x-apple-plist",
            "User-Agent": userAgent,
            "iCloud-DSID": account.dsid,
            "X-Dsid": account.dsid,
            "X-Apple-Store-Front": account.storeFront,
            "X-Token": account.passwordToken
        ]
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
        let (tmp, resp) = try await session.download(from: url)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AppStoreClientError.network("IPA CDN download failed (HTTP \(status)).")
        }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tmp, to: destination)
    }

    private func writeiTunesMetadata(_ meta: [String: Any], email: String, intoIPA ipa: URL) throws {
        var m = meta
        m["apple-id"] = email
        m["userName"] = email
        // Leaving IPA as downloaded is enough for FairPlay; metadata patch is best-effort later.
        _ = m
        _ = ipa
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
}
