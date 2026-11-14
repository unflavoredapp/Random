//
//  DecryptView.swift
//  Decrypt tab (lock icon). Two channels:
//    • This Device — FairPlay mremap on installed apps (SC_Info + App Store keys)
//    • Telegram Bot — server bridge to @FastDecryptBot for App Store links
//

import SwiftUI
import UniformTypeIdentifiers

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
        // Active Store Access Apple ID so multi-account switching affects decrypt jobs.
        let appleEmail = AppleIDStore.shared.email
        if !appleEmail.isEmpty {
            r.setValue(appleEmail, forHTTPHeaderField: "X-AS-Apple-ID")
            r.setValue(AppleIDStore.shared.activeAccountID ?? "", forHTTPHeaderField: "X-AS-Apple-ID-Account")
        }
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
            // On-device App Store search (iTunes) — no Telegram / FastDecryptBot.
            let found = try await DeviceDecryptService.shared.searchAppStore(q)
            if !Task.isCancelled { results = found }
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
        // Telegram bot IPAs should already be clear; still verify / finish with FairPlay when needed.
        if DecryptChannel.current == .telegram {
            let still = dest.path.withCString { fp_has_encrypted_slice($0) }
            if still != 1 {
                message = "Saved from Telegram bot · Library"
                return dest
            }
        }
        do {
            let clear = try FairPlayDecrypt.decryptIPA(at: dest, displayName: name) { [weak self] msg in
                Task { @MainActor in self?.message = msg }
            }
            if clear != dest {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: clear, to: dest)
            }
            message = DecryptChannel.current == .telegram
                ? "Telegram IPA finished with on-device FairPlay · Library"
                : "Decrypted on this device · saved to Library"
            return dest
        } catch {
            if DecryptChannel.current == .telegram {
                // Bot claimed success but FairPlay couldn't finish — keep file, surface warning.
                message = "Saved from Telegram (FairPlay verify failed: \(error.localizedDescription))"
                return dest
            }
            try? FileManager.default.removeItem(at: dest)
            throw DecryptError("On-device FairPlay decrypt failed: \(error.localizedDescription)")
        }
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
    @ObservedObject private var liveTheme = AppTheme.shared
    @ObservedObject private var c = DecryptClient.shared
    @ObservedObject private var store = AppleIDStore.shared
    @State private var query = ""
    @State private var versionsApp: DecryptApp?
    @State private var pickingIPA = false
    @State private var pickMessage: String?
    @FocusState private var searchFocused: Bool

    private var showingIdleHero: Bool {
        store.isSignedIn && c.results.isEmpty && c.selected == nil && c.phase == .idle
            && query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea().task {
                await c.refreshQuota()
                if store.isSignedIn { await c.loadHistory() }
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    if showingIdleHero { DecryptHeroBlock() }

                    if store.isSignedIn {
                        DecryptSignedInCard(email: store.email, onSignOut: store.signOut)
                        if showingIdleHero {
                            DecryptChannelPicker()
                            if DecryptChannel.current == .device {
                                DecryptAppStoreSignInHint()
                                DecryptDeviceAppsSection()
                            }
                        }
                        DecryptSearchBar(query: $query, focused: $searchFocused) {
                            Task { await c.search(query) }
                        }
                        if showingIdleHero, DecryptChannel.current == .device {
                            DecryptPickIPACard { pickingIPA = true }
                        }
                    } else {
                        DecryptHeroBlock()
                        DecryptStoreGateCard { AppNav.shared.go(AppTab.settings.rawValue) }
                        DecryptAppStoreSignInHint()
                    }

                    if c.searching {
                        ProgressView().tint(TetherlessPalette.accent).frame(maxWidth: .infinity)
                    }
                    if let err = c.error, c.phase != .failed {
                        GlassCard { Text(err).font(.caption).foregroundStyle(.orange) }
                    }
                    if let pickMessage {
                        GlassCard { Text(pickMessage).font(.caption).foregroundStyle(.white.opacity(0.7)) }
                    }

                    if c.phase != .idle, let app = c.selected ?? c.results.first {
                        decryptJobCard(for: app)
                    } else if let app = c.selected {
                        resultAppCard(app, downloading: false)
                    }

                    ForEach(c.results.filter { $0.id != c.selected?.id }) { app in
                        resultAppCard(app, downloading: false)
                    }

                    if store.isSignedIn, !c.history.isEmpty, c.results.isEmpty, c.phase == .idle {
                        historySection
                    }
                }
                .padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 120)
            }
        }
        .sheet(item: $versionsApp) { app in
            DecryptVersionsSheet(app: app)
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $pickingIPA) {
            DocPicker(types: [UTType(filenameExtension: "ipa") ?? .data]) { urls in
                handlePickedIPAs(urls)
            }
        }
        .onAppear { consumePendingQuery() }
        .onChange(of: c.pendingQuery) { _ in consumePendingQuery() }
    }

    private func consumePendingQuery() {
        guard let name = c.pendingQuery else { return }
        c.pendingQuery = nil
        if !c.busy { c.clearSelection() }
        query = name
        searchFocused = true
        Task { await c.search(query) }
    }

    private func handlePickedIPAs(_ urls: [URL]) {
        guard let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let clear = try FairPlayDecrypt.decryptIPA(
                at: url,
                displayName: url.deletingPathExtension().lastPathComponent
            )
            pickMessage = "Decrypted on this device → \(clear.lastPathComponent)"
            AppNav.shared.go(AppTab.library.rawValue)
        } catch {
            // Prefer install-path decrypt: import encrypted only as a last resort for later retry.
            let dest = AppPaths.dir("inbox").appendingPathComponent(url.lastPathComponent)
            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                pickMessage = "FairPlay failed (\(error.localizedDescription)). Imported encrypted IPA — install the app on this iPhone and decrypt from On This Device."
            } catch {
                pickMessage = error.localizedDescription
            }
        }
    }

    private var percent: Double? {
        let m = c.message
        guard let r = m.range(of: #"(\d{1,3}(?:\.\d+)?)\s*%"#, options: .regularExpression) else { return nil }
        let num = m[r].filter { $0.isNumber || $0 == "." }
        guard let v = Double(num) else { return nil }
        return Swift.min(Swift.max(v, 0), 100) / 100
    }

    // MARK: Cards

    private func resultAppCard(_ app: DecryptApp, downloading: Bool) -> some View {
        GlassCard(corner: 22) {
            HStack(spacing: 12) {
                iconView(app.icon, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name).font(.headline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
                    Text([app.dev, app.version.isEmpty ? "" : "v\(app.version)"].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                if downloading {
                    SlimProgress(value: percent)
                        .frame(width: 72)
                } else {
                    HStack(spacing: 8) {
                        Button {
                            versionsApp = app
                            c.select(app)
                            Task { await c.loadVersions(page: 1) }
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(.white.opacity(0.10), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(c.busy)
                        Button {
                            DeviceDecryptService.shared.decryptFromSearch(app)
                        } label: {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(.white.opacity(0.10), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(c.busy || DeviceDecryptService.shared.busy)
                    }
                }
            }
        }
    }

    private func decryptJobCard(for app: DecryptApp) -> some View {
        GlassCard(corner: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    iconView(app.icon, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name.isEmpty ? c.finishedName : app.name)
                            .font(.headline.weight(.semibold)).foregroundStyle(.white)
                        Text(app.dev).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        Text(c.phase == .downloading ? (c.message.isEmpty ? "Downloading…" : c.message)
                               : (c.phase == .done ? "Downloaded" : c.phase == .failed ? "Failed" : "Downloaded"))
                            .font(.caption).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    if c.phase == .done || c.phase == .running || c.phase == .queued {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if c.phase == .failed {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if c.phase == .downloading {
                        SlimProgress(value: percent).frame(width: 64)
                    }
                }

                if c.busy || c.phase == .running || c.phase == .queued || c.phase == .downloading {
                    Divider().overlay(.white.opacity(0.12))
                    HStack(alignment: .top, spacing: 12) {
                        ProgressView().tint(TetherlessPalette.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.phase == .downloading
                                  ? "Downloading \(app.name)…"
                                  : "Preparing to decrypt \(app.name.isEmpty ? c.finishedName : app.name)…")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text(c.message.isEmpty ? "Working…" : c.message)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }

                if c.phase == .done, let file = c.finished {
                    VStack(spacing: 10) {
                        Text("Confirm the install — it'll open automatically once it's ready.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                        Button {
                            SignQueue.shared.enqueue(file)
                        } label: {
                            Text("Done")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(TetherlessPalette.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Button("Dismiss") { c.reset() }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                if c.phase == .failed {
                    Text(c.error ?? "Decrypt failed.")
                        .font(.caption).foregroundStyle(.orange)
                    DecryptAppStoreSignInHint(compact: true)
                    Button("Dismiss") { c.reset() }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RECENT")
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(1.1)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button("Clear") { Task { await c.clearHistory() } }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TetherlessPalette.accent)
            }
            ForEach(c.history) { h in
                GlassCard(corner: 22) {
                    Button {
                        c.start(url: h.url, version: h.vreq.isEmpty ? nil : h.vreq, display: h.name)
                    } label: {
                        HStack(spacing: 12) {
                            iconView(h.icon, size: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(h.name).font(.headline.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                Text([h.version.isEmpty ? "" : "v\(h.version)",
                                       h.size > 0 ? ByteCountFormatter.string(fromByteCount: h.size, countStyle: .file) : ""]
                                    .filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.white.opacity(0.55))
                            }
                            Spacer()
                            Image(systemName: "arrow.down.circle").foregroundStyle(TetherlessPalette.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(c.busy)
                }
            }
        }
        .padding(.top, 4)
    }

    private func iconView(_ url: URL?, size: CGFloat) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            default: Color.white.opacity(0.08).overlay(Image(systemName: "app.fill").foregroundStyle(.white.opacity(0.45)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}

// MARK: - Versions sheet

private struct DecryptVersionsSheet: View {
    let app: DecryptApp
    @ObservedObject private var c = DecryptClient.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground().ignoresSafeArea()
                List {
                    if c.loadingVersions && c.versions.isEmpty {
                        HStack {
                            ProgressView().tint(TetherlessPalette.accent)
                            Text("Loading versions…").foregroundStyle(.white.opacity(0.7))
                        }
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(c.versions) { v in
                            Button {
                                DeviceDecryptService.shared.decryptFromSearch(app, version: v.v)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(v.v).foregroundStyle(.white)
                                    Spacer()
                                    if v.current {
                                        Text("Latest").font(.subheadline).foregroundStyle(.white.opacity(0.45))
                                    }
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.06))
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("\(app.name) — Versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
        }
        .task { await c.loadVersions(page: 1) }
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
