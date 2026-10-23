//
//  DecryptView.swift
//  Decrypt tab (lock icon). Search the App Store or paste a link, pick the latest
//  or an older version, and the AirShare backend decrypts it and hands back the IPA.
//  The IPA is saved to the Library inbox, ready to sign.
//
//  Backend routes (airshare.lol): /api/appsearch · /api/appinfo · /api/decrypt ·
//  /api/decrypt/versions · /api/decrypt/:id · /api/decrypt/history · /api/ipa/file/:up
//  Auth: Bearer account token when signed in, always X-AS-ADID (device ADID).
//

import SwiftUI

// MARK: - Models

struct DecryptApp: Identifiable, Hashable {
    let id: String
    let name: String
    let bundle: String
    let icon: URL?
    let dev: String
    let version: String
    let url: String
}

struct DecryptVersion: Identifiable, Hashable {
    let v: String
    let current: Bool
    var id: String { v }
}

struct DecryptHistoryItem: Identifiable, Hashable {
    let appID: String
    let vreq: String
    let name: String
    let bundle: String
    let version: String
    let size: Int64
    let icon: URL?
    let url: String
    let cached: Bool
    var id: String { appID + "|" + vreq }
}

struct DecryptError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - Client

@MainActor
final class DecryptClient: ObservableObject {
    static let shared = DecryptClient()

    enum Phase: Equatable { case idle, queued, running, downloading, done, failed }

    @Published var results: [DecryptApp] = []
    @Published var searching = false
    @Published var selected: DecryptApp?
    @Published var versions: [DecryptVersion] = []
    @Published var versionPage = 1
    @Published var versionPages = 1
    @Published var versionTotal = 0
    @Published var loadingVersions = false
    @Published var phase: Phase = .idle
    @Published var message = ""
    @Published var queue = 0
    @Published var error: String?
    @Published var history: [DecryptHistoryItem] = []
    @Published var finished: URL?
    @Published var finishedName = ""
    /// Set by other tabs (Library's DRM apps) to prefill the search box; the view consumes it.
    @Published var pendingQuery: String?
    /// Today's decrypt allowance, as the server counts it.
    @Published private(set) var quota: DecryptQuota?

    private var task: Task<Void, Never>?
    private init() {}

    var busy: Bool { phase == .queued || phase == .running || phase == .downloading }

    /// Site root (airshare.lol). Derived from the app API base; override with UserDefaults "as_site_base".
    nonisolated static var siteBase: String {
        let v = UserDefaults.standard.string(forKey: "as_site_base") ?? ""
        var b = v.isEmpty ? ZefvAccount.apiBase : v
        if b.hasSuffix("app/v1/") { b.removeLast("app/v1/".count) }
        return b.hasSuffix("/") ? b : b + "/"
    }

    // MARK: Networking

    private func makeRequest(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil, timeout: TimeInterval = 30) throws -> URLRequest {
        guard var c = URLComponents(string: Self.siteBase + path) else { throw DecryptError("Bad URL") }
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c.url else { throw DecryptError("Bad URL") }
        var r = URLRequest(url: url)
        r.timeoutInterval = timeout
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue(MDID.current, forHTTPHeaderField: "X-AS-ADID")
        if let t = ZefvAccount.shared.sessionToken, !t.isEmpty { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private func send(_ r: URLRequest) async throws -> [String: Any] {
        let (d, resp) = try await URLSession.shared.data(for: r)
        let o = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 || (o["ok"] as? Bool) == false {
            throw DecryptError((o["error"] as? String) ?? "Server error (\(code))")
        }
        return o
    }

    private func intValue(_ v: Any?) -> Int64 {
        if let i = v as? Int { return Int64(i) }
        if let d = v as? Double { return Int64(d) }
        if let s = v as? String, let i = Int64(s) { return i }
        return 0
    }

    func refreshQuota() async {
        if let o = try? await send(makeRequest("api/decrypt/quota")), let q = DecryptQuota(json: o) { quota = q }
    }

    // MARK: Search / select

    static func isStoreLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("https://apps.apple.com/") || t.hasPrefix("https://itunes.apple.com/")
    }

    func search(_ raw: String) async {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.count < 2 { results = []; searching = false; return }
        searching = true; error = nil
        defer { searching = false }
        do {
            if Self.isStoreLink(q) {
                let o = try await send(makeRequest("api/appinfo", query: ["url": q]))
                let icon = ((o["icon512"] as? String) ?? (o["icon"] as? String)).flatMap { URL(string: $0) }
                let app = DecryptApp(id: q, name: (o["name"] as? String) ?? "App", bundle: (o["bid"] as? String) ?? "",
                                     icon: icon, dev: (o["dev"] as? String) ?? (o["artist"] as? String) ?? "",
                                     version: (o["ver"] as? String) ?? (o["version"] as? String) ?? "", url: q)
                if !Task.isCancelled { results = [app] }
                return
            }
            let o = try await send(makeRequest("api/appsearch", query: ["q": q]))
            let items = (o["items"] as? [[String: Any]]) ?? []
            if Task.isCancelled { return }
            results = items.compactMap { i in
                guard let id = i["id"] as? String, let name = i["name"] as? String, let url = i["url"] as? String else { return nil }
                return DecryptApp(id: id, name: name, bundle: (i["bid"] as? String) ?? "", icon: (i["icon"] as? String).flatMap { URL(string: $0) },
                                  dev: (i["dev"] as? String) ?? "", version: (i["ver"] as? String) ?? "", url: url)
            }
        } catch {
            if Task.isCancelled { return }
            results = []
            self.error = error.localizedDescription
        }
    }

    func select(_ app: DecryptApp) {
        selected = app
        results = []
        versions = []; versionPage = 1; versionPages = 1; versionTotal = 0
        error = nil
    }

    func clearSelection() { selected = nil; versions = []; error = nil }

    // MARK: Versions

    func loadVersions(page: Int = 1) async {
        guard let app = selected else { return }
        loadingVersions = true; error = nil
        defer { loadingVersions = false }
        do {
            let o = try await send(makeRequest("api/decrypt/versions", body: ["url": app.url, "page": page], timeout: 150))
            let list = (o["versions"] as? [[String: Any]]) ?? []
            versions = list.compactMap { i in
                guard let v = i["v"] as? String else { return nil }
                return DecryptVersion(v: v, current: (i["current"] as? Bool) ?? false)
            }
            versionPage = Int(intValue(o["page"])).clamped(1, 500)
            versionPages = max(1, Int(intValue(o["pages"])))
            versionTotal = Int(intValue(o["total"]))
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Decrypt

    func start(url: String, version: String?, display: String) {
        guard !busy else { return }
        if let q = quota, q.exhausted {
            phase = .failed
            error = "You've used all \(q.limit ?? 0) decrypts for today." + (q.tier == "guest" ? " Sign in for more." : "") + " It resets at midnight UTC."
            return
        }
        task?.cancel()
        phase = .queued; message = "Queued"; queue = 0; error = nil; finished = nil; finishedName = display
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var body: [String: Any] = ["url": url]
                if let version, !version.isEmpty { body["version"] = version }
                let o = try await self.send(self.makeRequest("api/decrypt", body: body))
                guard let id = o["id"] as? String else { throw DecryptError("Server didn't start the job.") }
                if let q = (o["quota"] as? [String: Any]).flatMap({ DecryptQuota(json: $0) }) { self.quota = q }

                var up: String?
                var name = display, ver = ""
                var misses = 0
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    let s: [String: Any]
                    do { s = try await self.send(self.makeRequest("api/decrypt/\(id)")); misses = 0 }
                    catch let e as DecryptError { throw e }
                    catch { misses += 1; if misses >= 4 { throw error }; continue }
                    let st = (s["status"] as? String) ?? ""
                    if let m = s["msg"] as? String, !m.isEmpty { self.message = m }
                    self.queue = Int(self.intValue(s["queue"]))
                    if st == "done" {
                        up = s["up"] as? String
                        name = (s["name"] as? String) ?? name
                        ver = (s["ver"] as? String) ?? ""
                        break
                    }
                    if st == "error" { throw DecryptError((s["error"] as? String) ?? "Decrypt failed.") }
                    self.phase = st == "queued" ? .queued : .running
                }
                guard let up, !Task.isCancelled else { return }
                self.phase = .downloading; self.message = "Downloading IPA"
                let file = try await self.download(up: up, name: name, version: ver)
                self.finished = file; self.finishedName = name
                self.phase = .done; self.message = "Saved to Library"
                await self.loadHistory()
            } catch {
                if Task.isCancelled { return }
                self.phase = .failed
                self.error = error.localizedDescription
                await self.refreshQuota()      // a failed decrypt is refunded; a refused one shows 0 left
            }
        }
    }

    func cancel() {
        task?.cancel(); task = nil
        phase = .idle; message = ""; queue = 0
    }

    func reset() { phase = .idle; message = ""; finished = nil; error = nil }

    private func download(up: String, name: String, version: String) async throws -> URL {
        let r = try makeRequest("api/ipa/file/\(up)", timeout: 180)
        let (tmp, resp) = try await URLSession.shared.download(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw DecryptError(code == 404 ? "The file expired. Decrypt it again." : "Download failed (\(code)).")
        }
        let safe = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        let base = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let file = (base.isEmpty ? "App" : base) + (version.isEmpty ? "" : "-\(version)") + ".ipa"
        let dest = AppPaths.dir("inbox").appendingPathComponent(file)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    // MARK: History

    func loadHistory() async {
        guard let o = try? await send(makeRequest("api/decrypt/history")) else { return }
        let items = (o["items"] as? [[String: Any]]) ?? []
        history = items.compactMap { i in
            guard let aid = i["app_id"] as? String, let url = i["url"] as? String else { return nil }
            return DecryptHistoryItem(appID: aid, vreq: (i["vreq"] as? String) ?? "", name: (i["name"] as? String) ?? "App",
                                      bundle: (i["bid"] as? String) ?? "", version: (i["ver"] as? String) ?? "",
                                      size: intValue(i["size"]), icon: (i["icon"] as? String).flatMap { URL(string: $0) },
                                      url: url, cached: (i["cached"] as? Bool) ?? false)
        }
    }

    func clearHistory() async {
        _ = try? await send(makeRequest("api/decrypt/history/delete", body: ["all": true]))
        history = []
    }
}

private extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}

// MARK: - View

struct DecryptView: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read accent live (auto-cycle) without rebuilding
    @ObservedObject private var c = DecryptClient.shared
    @State private var query = ""
    @State private var versionsOpen = false
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea().task { await c.refreshQuota() }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if showSearch {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(Theme.subtle)
                            TextField("Search the App Store or paste a link", text: $query)
                                .autocorrectionDisabled().textInputAutocapitalization(.never).foregroundStyle(Theme.text)
                                .focused($searchFocused).submitLabel(.search)
                                .onSubmit { Task { await c.search(query) }; closeSearch() }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(Color.white.opacity(0.06)).clipShape(Capsule())
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if c.searching {
                        HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }.padding(.vertical, 6)
                    }
                    if let q = c.quota {
                        HStack(spacing: 6) {
                            Image(systemName: q.unlimited ? "infinity" : "lock.open.fill").font(.system(size: 11))
                            Text(q.summary).font(.system(size: 12, weight: .semibold))
                            if q.tier == "guest" { Text("\u{00B7} sign in for more").font(.system(size: 12)).foregroundStyle(Theme.subtle) }
                        }
                        .foregroundStyle(q.exhausted ? Color.orange : Theme.subtle)
                        .frame(maxWidth: .infinity)
                    }
                    if let err = c.error, c.phase != .failed {
                        Card { Text(err).font(.caption).foregroundStyle(.orange) }
                    }
                    if !c.results.isEmpty { resultsCard }
                    if let app = c.selected { selectedCard(app) }
                    if c.phase != .idle { jobCard }
                    if c.results.isEmpty && c.selected == nil && c.phase == .idle { emptyCard }
                    if !c.history.isEmpty { historyCard }
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 24)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                TabTitleBar(title: "Decrypt", custom: AnyView(botTitle)) {
                    HStack(spacing: 14) {
                        Button { openSearch() } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain).disabled(c.busy).opacity(c.busy ? 0.4 : 1)
                        Image(systemName: "lock.fill").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 450_000_000)
            if Task.isCancelled { return }
            await c.search(query)
        }
        .task { await c.loadHistory() }
        .onAppear { consumePendingQuery() }
        .onChange(of: c.pendingQuery) { _ in consumePendingQuery() }
    }

    /// An app sent over from the Library: show its name in the search box (the debounced search then runs by itself).
    private func consumePendingQuery() {
        guard let name = c.pendingQuery else { return }
        c.pendingQuery = nil
        if !c.busy { c.clearSelection() }
        query = name
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showSearch = true }
    }

    private func openSearch() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showSearch = true }
        searchFocused = true
    }

    private func closeSearch() {
        searchFocused = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showSearch = false }
    }

    /// Percent parsed from the server message ("... 6%"), nil when none is reported.
    private var percent: Double? {
        let m = c.message
        guard let r = m.range(of: #"(\d{1,3}(?:\.\d+)?)\s*%"#, options: .regularExpression) else { return nil }
        let num = m[r].filter { $0.isNumber || $0 == "." }
        guard let v = Double(num) else { return nil }
        return Swift.min(Swift.max(v, 0), 100) / 100
    }

    /// Title: bot icon in a square + "FastDecryptBot". Tapping opens the bot in Telegram.
    private var botTitle: some View {
        Button {
            if let u = URL(string: "https://t.me/FastDecryptBot") { UIApplication.shared.open(u) }
        } label: {
            HStack(spacing: 8) {
                Group {
                    if UIImage(named: "fastdecrypt_logo") != nil {
                        Image("fastdecrypt_logo").resizable().scaledToFill()
                    } else {
                        ZStack { Color(red: 0.55, green: 0.08, blue: 0.08); Image(systemName: "lock.open.fill").foregroundStyle(.white) }
                    }
                }
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text("FastDecryptBot").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open FastDecryptBot in Telegram")
    }

    // MARK: Cards

    private var emptyCard: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "lock.open.fill").font(.system(size: 22)).foregroundStyle(Theme.accent).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Decrypt any App Store app").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text("Search above or paste an apps.apple.com link. The decrypted IPA lands in your Library, ready to sign.")
                        .font(.system(size: 12)).foregroundStyle(Theme.subtle)
                }
            }
        }
    }

    private var resultsCard: some View {
        Card {
            VStack(spacing: 0) {
                ForEach(Array(c.results.enumerated()), id: \.element.id) { idx, app in
                    Button { c.select(app); query = ""; closeSearch(); versionsOpen = false } label: {
                        appRow(icon: app.icon, title: app.name, subtitle: [app.dev, app.version.isEmpty ? "" : "v\(app.version)"].filter { !$0.isEmpty }.joined(separator: " · "), trailing: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    if idx < c.results.count - 1 { Divider().overlay(Theme.stroke).padding(.leading, 62) }
                }
            }
        }
    }

    private func selectedCard(_ app: DecryptApp) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    iconView(app.icon, size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text).lineLimit(2)
                        if !app.bundle.isEmpty { Text(app.bundle).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.subtle).lineLimit(1) }
                        if !app.dev.isEmpty { Text(app.dev).font(.system(size: 12)).foregroundStyle(Theme.subtle).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                    Button { c.clearSelection(); versionsOpen = false } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.subtle)
                    }
                    .buttonStyle(.plain).disabled(c.busy)
                }
                HStack(spacing: 10) {
                    Button {
                        c.start(url: app.url, version: nil, display: app.name)
                    } label: {
                        Label(app.version.isEmpty ? "Decrypt latest" : "Decrypt v\(app.version)", systemImage: "lock.open.fill")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .background(Theme.accent).clipShape(Capsule())
                    }
                    .buttonStyle(.plain).disabled(c.busy).opacity(c.busy ? 0.5 : 1)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { versionsOpen.toggle() }
                        if versionsOpen { Task { await c.loadVersions(page: 1) } }
                    } label: {
                        Label("Versions", systemImage: versionsOpen ? "chevron.up" : "clock.arrow.circlepath")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity).frame(height: 42)
                            .background(Theme.accent.opacity(0.14)).clipShape(Capsule())
                    }
                    .buttonStyle(.plain).disabled(c.busy).opacity(c.busy ? 0.5 : 1)
                }

                if versionsOpen { versionsInline(app) }
            }
        }
    }

    /// Versions shown right under the app, in the same card — not a popup. Each row carries the app icon.
    @ViewBuilder
    private func versionsInline(_ app: DecryptApp) -> some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.stroke).padding(.top, 4)
            if c.loadingVersions && c.versions.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.accent)
                    Text("Asking the decrypt bot for versions…").font(.caption).foregroundStyle(Theme.subtle)
                }
                .padding(.vertical, 16)
            } else if let err = c.error, c.versions.isEmpty {
                Text(err).font(.caption).foregroundStyle(.orange).padding(.vertical, 14)
            } else {
                ForEach(Array(c.versions.enumerated()), id: \.element.id) { idx, v in
                    Button {
                        c.start(url: app.url, version: v.v, display: app.name)
                        withAnimation(.easeInOut(duration: 0.2)) { versionsOpen = false }
                    } label: {
                        HStack(spacing: 12) {
                            iconView(app.icon, size: 34)
                            Text("v\(v.v)").font(.system(size: 15, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                            if v.current {
                                Text("CURRENT").font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(Theme.accent.opacity(0.16)).clipShape(Capsule())
                            }
                            Spacer()
                            Image(systemName: "lock.open.fill").font(.system(size: 13)).foregroundStyle(Theme.accent)
                        }
                        .padding(.vertical, 10).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(c.busy)
                    if idx < c.versions.count - 1 { Divider().overlay(Theme.stroke).padding(.leading, 46) }
                }
                if c.versionPages > 1 {
                    HStack(spacing: 16) {
                        Button { Task { await c.loadVersions(page: c.versionPage - 1) } } label: { Image(systemName: "chevron.left") }
                            .disabled(c.versionPage <= 1 || c.loadingVersions)
                        Text("Page \(c.versionPage) / \(c.versionPages)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.subtle)
                        Button { Task { await c.loadVersions(page: c.versionPage + 1) } } label: { Image(systemName: "chevron.right") }
                            .disabled(c.versionPage >= c.versionPages || c.loadingVersions)
                        if c.loadingVersions { ProgressView().tint(Theme.accent).scaleEffect(0.8) }
                    }
                    .foregroundStyle(Theme.accent).padding(.vertical, 12)
                }
            }
        }
    }

    private var jobCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    switch c.phase {
                    case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    default: ProgressView().tint(Theme.accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(titleForPhase).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                        if c.busy {
                            SlimProgress(value: c.phase == .downloading ? nil : percent)
                        } else {
                            Text(c.phase == .failed ? (c.error ?? "Decrypt failed.") : subtitleForPhase)
                                .font(.system(size: 12)).foregroundStyle(c.phase == .failed ? Color.orange : Theme.subtle)
                        }
                    }
                    Spacer(minLength: 0)
                    if c.busy {
                        Button("Cancel") { c.cancel() }.font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                }
                if c.phase == .done, let file = c.finished {
                    HStack(spacing: 10) {
                        Button { SignQueue.shared.enqueue(file) } label: {
                            Label("Sign", systemImage: "signature")
                                .font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                                .frame(maxWidth: .infinity).frame(height: 40).background(Theme.accent).clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        Button { AppNav.shared.go(1) } label: {
                            Label("Library", systemImage: "square.grid.2x2.fill")
                                .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity).frame(height: 40).background(Theme.accent.opacity(0.14)).clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                if c.phase == .done || c.phase == .failed {
                    Button("Dismiss") { c.reset() }.font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.subtle)
                }
            }
        }
    }

    private var titleForPhase: String {
        switch c.phase {
        case .queued: return c.queue > 0 ? "In queue (\(c.queue))" : "Queued"
        case .running: return "Decrypting \(c.finishedName)"
        case .downloading: return "Downloading"
        case .done: return "\(c.finishedName) is ready"
        case .failed: return "Decrypt failed"
        case .idle: return ""
        }
    }
    private var subtitleForPhase: String {
        switch c.phase {
        case .done: return "Saved to your Library as an unsigned IPA."
        default: return c.message.isEmpty ? "Working…" : c.message
        }
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RECENT").font(.system(size: 12, weight: .semibold)).kerning(1.1).foregroundStyle(Theme.subtle)
                Spacer()
                Button("Clear") { Task { await c.clearHistory() } }.font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(c.history.enumerated()), id: \.element.id) { idx, h in
                        Button {
                            c.start(url: h.url, version: h.vreq.isEmpty ? nil : h.vreq, display: h.name)
                        } label: {
                            appRow(icon: h.icon, title: h.name,
                                   subtitle: [h.version.isEmpty ? "" : "v\(h.version)", h.size > 0 ? ByteCountFormatter.string(fromByteCount: h.size, countStyle: .file) : "", h.cached ? "ready" : ""]
                                       .filter { !$0.isEmpty }.joined(separator: " · "),
                                   trailing: "arrow.down.circle")
                        }
                        .buttonStyle(.plain).disabled(c.busy)
                        if idx < c.history.count - 1 { Divider().overlay(Theme.stroke).padding(.leading, 62) }
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    // MARK: Versions sheet

    // MARK: Pieces

    private func iconView(_ url: URL?, size: CGFloat) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            default: Color.white.opacity(0.08).overlay(Image(systemName: "app.fill").foregroundStyle(Theme.subtle))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }

    private func appRow(icon: URL?, title: String, subtitle: String, trailing: String) -> some View {
        HStack(spacing: 12) {
            iconView(icon, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if !subtitle.isEmpty { Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.subtle).lineLimit(1) }
            }
            Spacer(minLength: 6)
            Image(systemName: trailing).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
        }
        .padding(.vertical, 8).contentShape(Rectangle())
    }
}

// MARK: - Slim progress bar

struct SlimProgress: View {
    /// 0...1, or nil for an indeterminate sweep.
    let value: Double?
    @State private var sweep = false

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    if let value {
                        Capsule().fill(Theme.accent)
                            .frame(width: Swift.max(4, g.size.width * value))
                            .animation(.easeOut(duration: 0.4), value: value)
                    } else {
                        Capsule().fill(Theme.accent)
                            .frame(width: g.size.width * 0.3)
                            .offset(x: sweep ? g.size.width * 0.7 : 0)
                            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: sweep)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 5)
            if let value {
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.subtle)
            }
        }
        .onAppear { sweep = true }
    }
}
