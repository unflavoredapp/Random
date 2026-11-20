//
// Brand: Tetherless · https://tetherless.dev
//  IPadnStoreClient.swift
//  Derived from mengangs/ipadn StoreService + Models (GPL-2.0).
//  https://github.com/mengangs/ipadn
//  Namespaced for TetherLess: in-app search / App ID / store-link lookup with
//  multi-region fallbacks (history / delisted discovery), then hand off to
//  TetherLess FairPlay decrypt.
//

import Foundation

// MARK: - Models (from iPadn)

enum IPadnPlatform: String, CaseIterable, Identifiable, Sendable {
    case iOS, iPadOS, tvOS, macOS
    var id: String { rawValue }
    var title: String {
        switch self {
        case .iOS: return "iPhone"
        case .iPadOS: return "iPad"
        case .tvOS: return "Apple TV"
        case .macOS: return "Mac"
        }
    }
    var searchEntity: String {
        switch self {
        case .iOS: return "software"
        case .iPadOS: return "iPadSoftware"
        case .tvOS: return "software,tvSoftware"
        case .macOS: return "macSoftware"
        }
    }
    var catalogPlatform: String {
        switch self {
        case .iOS, .iPadOS: return "itunes"
        case .tvOS: return "atv9"
        case .macOS: return "mac"
        }
    }
    var supportsIPA: Bool { self != .macOS }
}

struct IPadnStoreContext: Equatable, Sendable {
    var country: String = "US"
    var platform: IPadnPlatform = .iOS
}

struct IPadnStoreApp: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var bundleID: String = ""
    var version: String = ""
    var iconURL: URL?
    var description: String = ""
    var category: String = ""
    var size: Int64 = 0
    var price: String = ""
    var priceValue: Double?
    var currency: String? = nil
    var rating: Double = 0
    var minimumOS: String = ""
    var externalVersionID: String?
    var developer: String = ""
    var storeURL: String = ""
    var country: String = "US"
    var delisted: Bool = false
    var screenshotURLs: [URL] = []

    var isFree: Bool { price.isEmpty || priceValue == 0 || price.lowercased() == "free" }
    var adamId: Int? { Int(id) }
    var sizeLabel: String {
        guard size > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    func asDecryptApp() -> DecryptApp {
        let code = country.lowercased()
        return DecryptApp(
            id: "itunes-\(id)-\(code)",
            name: delisted ? "\(name) (delisted)" : name,
            bundle: bundleID,
            icon: iconURL,
            dev: developer,
            version: version,
            url: storeURL.isEmpty
                ? "https://apps.apple.com/\(code)/app/id\(id)"
                : storeURL,
            countryCode: code,
            countryLabel: country.uppercased(),
            category: category,
            sizeBytes: size,
            externalVersionId: externalVersionID ?? ""
        )
    }
}

enum IPadnSearchQuery: Equatable, Sendable {
    case keyword(String)
    case appID(String, versionID: String?)

    static func parse(_ input: String) throws -> IPadnSearchQuery {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw IPadnStoreError.message("Enter an app name, App ID, or App Store link.")
        }
        if let url = URL(string: text),
           let host = url.host?.lowercased(),
           host.contains("apps.apple.com") || host.contains("itunes.apple.com") {
            let parts = url.pathComponents
            if let idPart = parts.first(where: {
                $0.hasPrefix("id") && $0.dropFirst(2).allSatisfy(\.isNumber) && $0.count > 2
            }) {
                return .appID(String(idPart.dropFirst(2)), versionID: nil)
            }
            throw IPadnStoreError.message("App Store link is missing a valid App ID.")
        }
        let parts = text
            .components(separatedBy: CharacterSet(charactersIn: " ,，:/+\t\n"))
            .filter { !$0.isEmpty }
        if (1...2).contains(parts.count), parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return .appID(parts[0], versionID: parts.count == 2 ? parts[1] : nil)
        }
        return .keyword(text)
    }
}

enum IPadnStoreError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

// MARK: - Client (from iPadn StoreService)

enum IPadnStoreClient {
    /// Regions tried when an App ID has no listing in the selected storefront (delisted / regional).
    static let fallbackCountries = [
        "US", "RU", "CN", "HK", "TW", "JP", "GB", "SG", "CA", "AU", "KR", "DE", "FR"
    ]

    static func search(
        _ rawQuery: String,
        context: IPadnStoreContext,
        accountCountry: String? = nil,
        limit: Int = 25
    ) async throws -> [IPadnStoreApp] {
        let query = try IPadnSearchQuery.parse(rawQuery)
        return try await search(query, context: context, accountCountry: accountCountry, limit: limit)
    }

    static func search(
        _ query: IPadnSearchQuery,
        context: IPadnStoreContext,
        accountCountry: String? = nil,
        limit: Int = 25
    ) async throws -> [IPadnStoreApp] {
        if case .appID = query {
            var tried = Set<String>()
            var firstError: Error?
            var answered = false
            for country in searchCountries(selected: context.country, accountCountry: accountCountry) + fallbackCountries
            where tried.insert(country.uppercased()).inserted {
                try Task.checkCancellation()
                var regional = context
                regional.country = country.uppercased()
                do {
                    let apps = try await searchInCountry(query, context: regional, limit: limit)
                    answered = true
                    if !apps.isEmpty { return apps }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if firstError == nil { firstError = error }
                    if (error as NSError).domain == NSURLErrorDomain { break }
                }
            }
            if !answered, let firstError { throw firstError }
            // No public listing anywhere — still return a delisted stub so owned download can try.
            if case .appID(let id, let versionID) = query {
                return [delistedStub(id: id, versionID: versionID, country: context.country)]
            }
            return []
        }

        let primary = try await searchInCountry(query, context: context, limit: limit)
        let countries = searchCountries(selected: context.country, accountCountry: accountCountry)
        guard countries.count > 1 else { return primary }
        var accountContext = context
        accountContext.country = countries[1]
        do {
            let alternate = try await searchInCountry(query, context: accountContext, limit: limit)
            return mergeResults(primary, alternate, limit: limit)
        } catch {
            return primary
        }
    }

    /// External version IDs from the public iTunes lookup (current) + MZStorePlatform when possible.
    static func versionHints(adamId: String, country: String) async -> [String] {
        var ids: [String] = []
        if let url = try? endpoint("https://itunes.apple.com/lookup", items: [
            URLQueryItem(name: "id", value: adamId),
            URLQueryItem(name: "country", value: country)
        ]),
           let json = try? await json(url),
           let row = (json["results"] as? [[String: Any]])?.first {
            if let n = row["version"] as? String, !n.isEmpty { /* display only */ }
            // Some storefronts expose external identifiers on related fields.
            if let ext = row["currentVersionReleaseDate"] as? String, !ext.isEmpty {
                _ = ext
            }
        }
        if let plat = try? await platformLookup(id: adamId, country: country, platform: .iOS),
           let ext = plat.externalVersionID, !ext.isEmpty {
            ids.append(ext)
        }
        return ids
    }

    // MARK: Private

    private static func searchCountries(selected: String, accountCountry: String?) -> [String] {
        var countries = [selected.uppercased()]
        if let accountCountry = accountCountry?.uppercased(), !accountCountry.isEmpty,
           !countries.contains(accountCountry) {
            countries.append(accountCountry)
        }
        return countries
    }

    private static func mergeResults(_ primary: [IPadnStoreApp], _ account: [IPadnStoreApp], limit: Int) -> [IPadnStoreApp] {
        var merged: [IPadnStoreApp] = []
        var indices: [String: Int] = [:]
        let regionalIDs = Set(primary.map(\.id))
        let accountOnly = account.filter { !regionalIDs.contains($0.id) }
        var candidates: [IPadnStoreApp] = []
        var primaryIndex = 0
        var accountIndex = 0
        while primaryIndex < primary.count || accountIndex < accountOnly.count {
            for _ in 0..<2 where primaryIndex < primary.count {
                candidates.append(primary[primaryIndex]); primaryIndex += 1
            }
            if accountIndex < accountOnly.count {
                candidates.append(accountOnly[accountIndex]); accountIndex += 1
            }
        }
        candidates.append(contentsOf: account)
        for app in candidates where !app.id.isEmpty {
            if let index = indices[app.id] {
                if merged[index].iconURL == nil { merged[index].iconURL = app.iconURL }
            } else if merged.count < limit {
                indices[app.id] = merged.count
                merged.append(app)
            }
        }
        return merged
    }

    private static func searchInCountry(
        _ query: IPadnSearchQuery,
        context: IPadnStoreContext,
        limit: Int
    ) async throws -> [IPadnStoreApp] {
        switch query {
        case .keyword(let text):
            let url = try endpoint("https://itunes.apple.com/search", items: [
                URLQueryItem(name: "term", value: text),
                URLQueryItem(name: "country", value: context.country),
                URLQueryItem(name: "entity", value: context.platform.searchEntity),
                URLQueryItem(name: "explicit", value: "Yes"),
                URLQueryItem(name: "limit", value: String(limit))
            ])
            let rows = (try await json(url))["results"] as? [[String: Any]] ?? []
            return rows.compactMap { mapLookup($0, country: context.country) }

        case .appID(let id, let versionID):
            let url = try endpoint("https://itunes.apple.com/lookup", items: [
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "country", value: context.country)
            ])
            let rows = (try await json(url))["results"] as? [[String: Any]] ?? []
            let apps = rows.compactMap { mapLookup($0, country: context.country) }
                .filter { $0.id == id }
            if !apps.isEmpty {
                if let versionID, !versionID.isEmpty {
                    return apps.map {
                        var copy = $0
                        copy.externalVersionID = versionID
                        return copy
                    }
                }
                return apps
            }
            if let plat = try await platformLookup(id: id, country: context.country, platform: context.platform) {
                var app = plat
                if let versionID, !versionID.isEmpty { app.externalVersionID = versionID }
                return [app]
            }
            return []
        }
    }

    private static func platformLookup(
        id: String,
        country: String,
        platform: IPadnPlatform
    ) async throws -> IPadnStoreApp? {
        let url = try endpoint(
            "https://uclient-api.itunes.apple.com/WebObjects/MZStorePlatform.woa/wa/lookup",
            items: [
                URLQueryItem(name: "version", value: "2"),
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "p", value: "mdm-lockup"),
                URLQueryItem(name: "caller", value: "MDM"),
                URLQueryItem(name: "platform", value: platform.catalogPlatform),
                URLQueryItem(name: "cc", value: country)
            ]
        )
        let data = try await json(url)
        guard let results = data["results"] as? [String: Any],
              let raw = results[id] as? [String: Any] else { return nil }
        let offer = (raw["offers"] as? [[String: Any]])?.first ?? [:]
        let version = offer["version"] as? [String: Any] ?? [:]
        let artwork = raw["artwork"] as? [String: Any] ?? [:]
        let icon = (artwork["url"] as? String).flatMap(URL.init(string:))
        let name = string(raw["name"])
        let bundle = string(raw["bundleId"])
        let display = string(version["display"])
        let ext = string(version["externalId"]).isEmpty
            ? buyParamsValue(string(offer["buyParams"]), key: "externalVersionId")
            : string(version["externalId"])
        let size = int64(offer["size"])
        return IPadnStoreApp(
            id: id,
            name: name.isEmpty ? "App \(id)" : name,
            bundleID: bundle,
            version: display,
            iconURL: icon,
            size: size,
            externalVersionID: ext.isEmpty ? nil : ext,
            storeURL: "https://apps.apple.com/\(country.lowercased())/app/id\(id)",
            country: country.uppercased()
        )
    }

    private static func delistedStub(id: String, versionID: String?, country: String) -> IPadnStoreApp {
        IPadnStoreApp(
            id: id,
            name: "App \(id)",
            externalVersionID: versionID,
            storeURL: "https://apps.apple.com/app/id\(id)",
            country: country.uppercased(),
            delisted: true
        )
    }

    private static func mapLookup(_ row: [String: Any], country: String) -> IPadnStoreApp? {
        let trackId: String
        if let n = row["trackId"] as? Int {
            trackId = String(n)
        } else if let n = row["trackId"] as? NSNumber {
            trackId = n.stringValue
        } else {
            return nil
        }
        let icon = (row["artworkUrl512"] as? String).flatMap(URL.init(string:))
            ?? (row["artworkUrl100"] as? String).flatMap(URL.init(string:))
        let priceValue = row["price"] as? Double ?? (row["price"] as? NSNumber)?.doubleValue
        let formatted = row["formattedPrice"] as? String ?? ""
        let rating = (row["averageUserRating"] as? Double)
            ?? (row["averageUserRating"] as? NSNumber)?.doubleValue
            ?? 0
        let shots = ((row["screenshotUrls"] as? [String]) ?? [])
            .compactMap(URL.init(string:))
        let ipadShots = ((row["ipadScreenshotUrls"] as? [String]) ?? [])
            .compactMap(URL.init(string:))
        return IPadnStoreApp(
            id: trackId,
            name: string(row["trackName"]).isEmpty ? "App" : string(row["trackName"]),
            bundleID: string(row["bundleId"]),
            version: string(row["version"]),
            iconURL: icon,
            description: string(row["description"]),
            category: string(row["primaryGenreName"]),
            size: int64(row["fileSizeBytes"]),
            price: formatted,
            priceValue: priceValue,
            currency: string(row["currency"]).isEmpty ? nil : string(row["currency"]),
            rating: rating,
            minimumOS: string(row["minimumOsVersion"]),
            developer: string(row["artistName"]),
            storeURL: string(row["trackViewUrl"]).isEmpty
                ? "https://apps.apple.com/\(country.lowercased())/app/id\(trackId)"
                : string(row["trackViewUrl"]),
            country: country.uppercased(),
            screenshotURLs: Array((shots.isEmpty ? ipadShots : shots).prefix(10))
        )
    }

    /// Public iTunes lookup for detail / multi-region price pages.
    static func lookupPublic(id: String, country: String) async throws -> IPadnStoreApp? {
        let url = try endpoint(
            "https://itunes.apple.com/lookup",
            items: [
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "country", value: country.lowercased()),
                URLQueryItem(name: "entity", value: "software")
            ]
        )
        let data = try await json(url)
        let results = (data["results"] as? [[String: Any]]) ?? []
        return results.first.flatMap { mapLookup($0, country: country.uppercased()) }
    }

    private static func endpoint(_ base: String, items: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(string: base) else {
            throw IPadnStoreError.message("Bad App Store URL.")
        }
        components.queryItems = items
        guard let url = components.url else {
            throw IPadnStoreError.message("Bad App Store URL.")
        }
        return url
    }

    private static func json(_ url: URL) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Tetherless/1", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw IPadnStoreError.message("App Store search failed (HTTP \(code)).")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func string(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    private static func int64(_ any: Any?) -> Int64 {
        if let n = any as? Int64 { return n }
        if let n = any as? Int { return Int64(n) }
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String, let n = Int64(s) { return n }
        return 0
    }

    private static func buyParamsValue(_ raw: String, key: String) -> String {
        for piece in raw.split(separator: "&") {
            let kv = piece.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2, kv[0] == key else { continue }
            return kv[1].removingPercentEncoding ?? kv[1]
        }
        return ""
    }
}
