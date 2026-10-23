//
//  AppStats.swift
//  View + download counters for apps in the AirShare source. The website and the app write to the
//  same counters on airshare.lol, so the numbers shown here are website + app combined.
//

import Foundation

@MainActor
final class AppStatsStore: ObservableObject {
    static let shared = AppStatsStore()

    struct Stat: Equatable { var views: Int; var downloads: Int }

    @Published private(set) var stats: [String: Stat] = [:]
    private var lastFetch: Date?

    private init() {}

    private var base: URL? { URL(string: ZefvAccount.apiBase) }

    /// Pull the combined website + app totals (cached for a minute).
    func refresh(force: Bool = false) async {
        if !force, let t = lastFetch, Date().timeIntervalSince(t) < 60 { return }
        guard let url = base?.appendingPathComponent("apps/stats") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, r) = try? await URLSession.shared.data(for: req),
              (r as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let raw = obj["stats"] as? [String: [String: Any]] else { return }
        var out: [String: Stat] = [:]
        for (k, v) in raw {
            out[k] = Stat(views: (v["views"] as? Int) ?? 0, downloads: (v["downloads"] as? Int) ?? 0)
        }
        stats = out
        lastFetch = Date()
    }

    /// Counts one view every time an app's page is opened.
    func reportView(bundle: String) async {
        guard !bundle.isEmpty, bundle != "unknown.bundle",
              let url = base?.appendingPathComponent("apps/view") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(MDID.current, forHTTPHeaderField: "X-AS-ADID")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["key": bundle])
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              (obj["counted"] as? Bool) == true else { return }
        var s = stats[bundle] ?? Stat(views: 0, downloads: 0)
        s.views += 1
        stats[bundle] = s
    }

    /// The server counts the download itself (the app sends its device id to /dl/); mirror it locally.
    func noteDownload(_ app: SourceApp) {
        guard let host = app.downloadURL?.host, host == base?.host else { return }
        var s = stats[app.bundle] ?? Stat(views: 0, downloads: 0)
        s.downloads += 1
        stats[app.bundle] = s
        Task { try? await Task.sleep(nanoseconds: 2_000_000_000); await refresh(force: true) }
    }

    // MARK: Display

    static func format(_ n: Int) -> String {
        switch n {
        case 1_000_000...: return String(format: "%.1fM", Double(n) / 1_000_000)
        case 10_000...:    return "\(n / 1000)K"
        case 1_000...:     return String(format: "%.1fK", Double(n) / 1000)
        default:           return "\(n)"
        }
    }

    func downloadsText(_ app: SourceApp) -> String {
        if let s = stats[app.bundle] { return Self.format(s.downloads) }
        return app.downloads
    }
    func viewsText(_ app: SourceApp) -> String {
        stats[app.bundle].map { Self.format($0.views) } ?? "—"
    }
}
