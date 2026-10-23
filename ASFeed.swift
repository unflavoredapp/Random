import Foundation
import SwiftUI

// MARK: - Config

nonisolated enum ASConfig {
    /// AltStore-format source. Apps + news come from here.
    static let feedURL = URL(string: "https://airshare.lol/air.json")!
    static let siteBase = "https://airshare.lol"
    /// Orange "MRZefv" line above "Powered by" in the detail sheet.
    static let showsBrandLine = true
}

enum ASTheme {
    static let red = Color(red: 1.0, green: 0.27, blue: 0.36)
    static let redSoft = Color(red: 1.0, green: 0.62, blue: 0.69)
    static let grey = Color(white: 0.62)
    static let brand = Color(red: 1.0, green: 0.69, blue: 0.40)
}

// MARK: - Categories (same order and names as airshare.lol)

nonisolated enum ASCategory: String, CaseIterable, Identifiable, Hashable, Sendable {
    case all, emulators, jailbreak, media, social, carplay, paid, tools

    var id: String { rawValue }

    var title: String { rawValue.uppercased() }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2.fill"
        case .emulators: return "gamecontroller.fill"
        case .jailbreak: return "lock.open.fill"
        case .media: return "photo.on.rectangle.angled"
        case .social: return "person.3.fill"
        case .carplay: return "car.fill"
        case .paid: return "dollarsign"
        case .tools: return "wrench.and.screwdriver.fill"
        }
    }

    /// Site ids: /?cat=2 ... /?cat=8
    static func fromSiteID(_ n: Int) -> ASCategory? {
        switch n {
        case 2: return .emulators
        case 3: return .jailbreak
        case 4: return .media
        case 5: return .social
        case 6: return .carplay
        case 7: return .paid
        case 8: return .tools
        default: return nil
        }
    }

    static func fromText(_ raw: String) -> ASCategory? {
        let t = raw.lowercased()
        if t.contains("emulator") { return .emulators }
        if t.contains("jailbreak") { return .jailbreak }
        if t.contains("media") || t.contains("music") || t.contains("video") || t.contains("photo") { return .media }
        if t.contains("social") { return .social }
        if t.contains("carplay") { return .carplay }
        if t.contains("paid") { return .paid }
        if t.contains("tool") || t.contains("utilit") { return .tools }
        return nil
    }

    /// Only used when the feed carries no category info at all.
    static func guess(name: String, desc: String) -> [ASCategory] {
        let t = (name + " " + desc).lowercased()
        var out: [ASCategory] = []
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        if has(["emulator", "gba", "snes", "nintendo", "psp", "retro", "scummvm"]) { out.append(.emulators) }
        if has(["jailbreak", "trollstore", "dopamine", "palera", "tweak", "sileo"]) { out.append(.jailbreak) }
        if has(["music", "video", "player", "stream", "audio", "podcast", "photo", "movie", "tv"]) { out.append(.media) }
        if has(["facebook", "messenger", "reddit", "discord", "instagram", "tiktok", "snapchat", "twitter", "telegram", "social"]) { out.append(.social) }
        if has(["carplay"]) { out.append(.carplay) }
        if has(["unlocked", "premium", "pro "]) { out.append(.paid) }
        if has(["tool", "utility", "scanner", "translator", "speedtest", "vpn", "downloader", "editor", "browser"]) { out.append(.tools) }
        return out
    }
}

// MARK: - Models

nonisolated struct ASRGB: Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    static func parse(_ s: String?) -> ASRGB? {
        guard var t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        if t.contains(",") {
            let p = t.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard p.count >= 3 else { return nil }
            let scale: Double = (p.max() ?? 255) <= 1.0 ? 1.0 : 255.0
            return ASRGB(r: p[0] / scale, g: p[1] / scale, b: p[2] / scale)
        }
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        return ASRGB(r: Double((v >> 16) & 255) / 255.0,
                     g: Double((v >> 8) & 255) / 255.0,
                     b: Double(v & 255) / 255.0)
    }
}

nonisolated struct ASVersion: Hashable, Sendable {
    var version: String
    var date: Date?
    var size: Int64?
    var downloadURL: URL?
    var notes: String
}

nonisolated struct ASApp: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var bundleID: String
    var developer: String
    var desc: String
    var iconURL: URL?
    var tint: ASRGB?
    var screenshots: [URL]
    var version: String
    var versionDate: Date?
    var versionNotes: String
    var size: Int64
    var downloadURL: URL?
    var versions: [ASVersion]
    var categories: [ASCategory]
    var isStaffPick: Bool
    var downloads: Int?
    var views: Int?
}

nonisolated struct ASNews: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var caption: String
    var date: Date?
    var tint: ASRGB?
    var imageURL: URL?
    var url: URL?
    var appID: String?
}

nonisolated struct ASFeed: Sendable {
    var apps: [ASApp]
    var news: [ASNews]
    var picks: [ASApp]
}

// MARK: - Parser (tolerant: AltStore v1/v2 + optional pick/category fields)

nonisolated enum ASFeedParser {

    static func parse(_ data: Data) -> ASFeed? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        let rawApps = root["apps"] as? [[String: Any]] ?? []
        let pickList = stringList(root["staffPicks"]) + stringList(root["staff_picks"])
            + stringList(root["featuredApps"]) + stringList(root["featured"]) + stringList(root["pinned"])
        let pickSet = Set(pickList.map { $0.lowercased() })

        var hasAnyCategory = false
        var seen: [String: Int] = [:]
        var apps: [ASApp] = []
        apps.reserveCapacity(rawApps.count)

        for d in rawApps {
            let bundle = string(d, "bundleIdentifier", "bundleID", "bundle") ?? ""
            let name = string(d, "name", "title") ?? bundle
            if name.isEmpty { continue }

            let n = seen[bundle, default: 0]
            seen[bundle] = n + 1
            let uid = n == 0 ? bundle : "\(bundle)#\(n)"

            var versions: [ASVersion] = []
            if let vs = d["versions"] as? [[String: Any]] {
                for v in vs {
                    versions.append(ASVersion(
                        version: string(v, "version") ?? "",
                        date: date(v, "date", "versionDate"),
                        size: int64(v, "size"),
                        downloadURL: url(v, "downloadURL", "downloadUrl"),
                        notes: string(v, "localizedDescription", "versionDescription") ?? ""))
                }
            }

            let version = string(d, "version") ?? versions.first?.version ?? ""
            var cats: [ASCategory] = []
            if let c = string(d, "category", "categoryName"), let m = ASCategory.fromText(c) { cats.append(m) }
            if let arr = d["categories"] as? [String] {
                for c in arr { if let m = ASCategory.fromText(c), !cats.contains(m) { cats.append(m) } }
            }
            if let num = int64(d, "cat", "categoryID", "categoryId"), let m = ASCategory.fromSiteID(Int(num)), !cats.contains(m) {
                cats.append(m)
            }
            if !cats.isEmpty { hasAnyCategory = true }

            let flagged = bool(d, "staffPick", "staff_pick", "isStaffPick", "featured", "pinned", "pick")
            let shots = urlList(d["screenshotURLs"]) + screenshotsV2(d["screenshots"])

            apps.append(ASApp(
                id: uid,
                name: name,
                bundleID: bundle,
                developer: string(d, "developerName", "developer", "author") ?? "",
                desc: string(d, "localizedDescription", "description") ?? "",
                iconURL: url(d, "iconURL", "iconUrl", "icon"),
                tint: ASRGB.parse(string(d, "tintColor", "tint")),
                screenshots: shots,
                version: version,
                versionDate: date(d, "versionDate", "date"),
                versionNotes: string(d, "versionDescription") ?? "",
                size: int64(d, "size") ?? versions.first?.size ?? 0,
                downloadURL: url(d, "downloadURL", "downloadUrl") ?? versions.first?.downloadURL,
                versions: versions,
                categories: cats,
                isStaffPick: flagged || pickSet.contains(bundle.lowercased()),
                downloads: int64(d, "downloads", "downloadCount").map { Int($0) },
                views: int64(d, "views", "viewCount").map { Int($0) }))
        }

        if !hasAnyCategory {
            for i in apps.indices { apps[i].categories = ASCategory.guess(name: apps[i].name, desc: apps[i].desc) }
        }

        apps.sort { ($0.versionDate ?? .distantPast) > ($1.versionDate ?? .distantPast) }

        var picks: [ASApp] = []
        var pickSeen = Set<String>()
        for a in apps where a.isStaffPick {
            if pickSeen.insert(a.bundleID.lowercased()).inserted { picks.append(a) }
        }
        if !pickList.isEmpty {
            let order = pickList.map { $0.lowercased() }
            picks.sort {
                (order.firstIndex(of: $0.bundleID.lowercased()) ?? Int.max)
                    < (order.firstIndex(of: $1.bundleID.lowercased()) ?? Int.max)
            }
        }

        var news: [ASNews] = []
        if let items = root["news"] as? [[String: Any]] {
            for (i, d) in items.enumerated() {
                guard let title = string(d, "title") else { continue }
                news.append(ASNews(
                    id: string(d, "identifier") ?? "news-\(i)",
                    title: title,
                    caption: string(d, "caption", "description") ?? "",
                    date: date(d, "date"),
                    tint: ASRGB.parse(string(d, "tintColor")),
                    imageURL: url(d, "imageURL", "imageUrl"),
                    url: url(d, "url"),
                    appID: string(d, "appID", "appId")))
            }
            news.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }

        return ASFeed(apps: apps, news: news, picks: picks)
    }

    // MARK: helpers

    private static func string(_ d: [String: Any], _ keys: String...) -> String? {
        for k in keys {
            if let s = d[k] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            } else if let n = d[k] as? NSNumber {
                return n.stringValue
            }
        }
        return nil
    }

    private static func int64(_ d: [String: Any], _ keys: String...) -> Int64? {
        for k in keys {
            if let n = d[k] as? NSNumber { return n.int64Value }
            if let s = d[k] as? String, let v = Double(s) { return Int64(v) }
        }
        return nil
    }

    private static func bool(_ d: [String: Any], _ keys: String...) -> Bool {
        for k in keys {
            if let b = d[k] as? Bool, b { return true }
            if let n = d[k] as? NSNumber, n.intValue == 1 { return true }
            if let s = d[k] as? String, ["true", "1", "yes"].contains(s.lowercased()) { return true }
        }
        return false
    }

    private static func makeURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if let u = URL(string: t) { return u }
        if let enc = t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { return URL(string: enc) }
        return nil
    }

    private static func url(_ d: [String: Any], _ keys: String...) -> URL? {
        for k in keys {
            if let s = d[k] as? String, let u = makeURL(s) { return u }
        }
        return nil
    }

    private static func urlList(_ any: Any?) -> [URL] {
        if let a = any as? [String] { return a.compactMap { makeURL($0) } }
        return []
    }

    private static func screenshotsV2(_ any: Any?) -> [URL] {
        if let a = any as? [String] { return a.compactMap { makeURL($0) } }
        if let a = any as? [[String: Any]] {
            return a.compactMap { ($0["imageURL"] as? String).flatMap { makeURL($0) } }
        }
        return []
    }

    private static func stringList(_ any: Any?) -> [String] {
        if let a = any as? [String] { return a }
        if let a = any as? [[String: Any]] {
            return a.compactMap { ($0["bundleIdentifier"] as? String) ?? ($0["bundleID"] as? String) }
        }
        return []
    }

    private static func date(_ d: [String: Any], _ keys: String...) -> Date? {
        for k in keys {
            guard let s = d[k] as? String else { continue }
            if let v = parseDate(s) { return v }
        }
        return nil
    }

    private static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let v = iso.date(from: s) { return v }
        iso.formatOptions = [.withInternetDateTime]
        if let v = iso.date(from: s) { return v }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let v = f.date(from: s) { return v }
        }
        return nil
    }
}

// MARK: - Store

@MainActor
final class ASFeedStore: ObservableObject {
    @Published var apps: [ASApp] = []
    @Published var news: [ASNews] = []
    @Published var picks: [ASApp] = []
    @Published var loading = false
    @Published var failed = false

    private let cacheURL: URL

    init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheURL = dir.appendingPathComponent("airshare-feed.json")
        Task { await bootstrap() }
    }

    func app(forBundle id: String) -> ASApp? {
        apps.first { $0.bundleID.caseInsensitiveCompare(id) == .orderedSame }
    }

    private func apply(_ feed: ASFeed) {
        apps = feed.apps
        news = feed.news
        picks = feed.picks
    }

    private func bootstrap() async {
        let url = cacheURL
        let cached = await Task.detached(priority: .userInitiated) { () -> ASFeed? in
            guard let d = try? Data(contentsOf: url) else { return nil }
            return ASFeedParser.parse(d)
        }.value
        if let cached, apps.isEmpty { apply(cached) }
        await refresh()
    }

    func refresh() async {
        if loading { return }
        loading = true
        defer { loading = false }
        var req = URLRequest(url: ASConfig.feedURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 45
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let feed = await Task.detached(priority: .userInitiated) { () -> ASFeed? in
                ASFeedParser.parse(data)
            }.value
            if let feed {
                apply(feed)
                failed = false
                try? data.write(to: cacheURL, options: .atomic)
            } else {
                failed = apps.isEmpty
            }
        } catch {
            failed = apps.isEmpty
        }
    }
}
