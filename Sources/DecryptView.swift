//
//  DecryptView.swift
//  Decrypt tab (lock icon). Two channels:
//    • This Device — FairPlay mremap on installed apps (SC_Info + App Store keys)
//    • Telegram Bot — own bot + Phone Worker (on-device FairPlay; not FastDecryptBot)
//

import SwiftUI
import UIKit
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
    /// ISO storefront code from iTunes `country=` / URL (e.g. `us`, `jp`). Empty when unknown.
    var countryCode: String = ""
    /// Short badge label (e.g. `US`, `JP`).
    var countryLabel: String = ""
}

struct DecryptVersion: Identifiable, Hashable {
    let v: String
    let current: Bool
    /// App Store minimum iOS for this build, when known (e.g. "15.0").
    var minOS: String? = nil
    /// MZFinance `softwareVersionExternalIdentifier` for version-pinned silent download.
    var externalId: String? = nil
    var id: String { externalId ?? v }
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

    enum Phase: Equatable {
        case idle, queued, running, downloading, done, failed
        /// Companion IPA installed — FairPlay continues there. Not busy.
        case handedOff
    }

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

    /// Site root for LocalDecryptBridge / store fetch. Derived from the app API base
    /// (`https://tetherless.dev/` — same apex as OTA). Override with UserDefaults
    /// `as_site_base`; legacy airshare.lol / zefv overrides are ignored.
    nonisolated static var siteBase: String {
        let raw = UserDefaults.standard.string(forKey: "as_site_base") ?? ""
        let lower = raw.lowercased()
        var b: String
        if raw.isEmpty || lower.contains("airshare.lol") || lower.contains("zefv.dev") || lower.contains("mrzefv.com") {
            b = ZefvAccount.apiBase
        } else {
            b = raw
        }
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
        // iPadn accepts App IDs / store links at length 1+; keyword needs 2+.
        let isAppIDOrLink: Bool = {
            if Self.isStoreLink(q) { return true }
            if let parsed = try? IPadnSearchQuery.parse(q), case .appID = parsed { return true }
            return false
        }()
        if q.isEmpty || (!isAppIDOrLink && q.count < 2) {
            results = []
            searching = false
            return
        }
        searching = true; error = nil
        defer { searching = false }
        do {
            // iPadn StoreService-backed search (name / App ID / link, multi-region, delisted).
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

        // This Device: authenticated store version IDs (externalVersionId) first.
        if DecryptChannel.current == .device {
            if let local = await DeviceDecryptService.shared.versionList(for: app) {
                versions = local.versions
                versionPage = 1
                versionPages = 1
                versionTotal = local.versions.count
                error = nil
                return
            }
            if let verErr = DeviceDecryptService.shared.lastVersionError, !verErr.isEmpty {
                // Keep going to public iTunes fallback below, but remember the Store error.
                error = verErr
            }
        }

        // Telegram / server archive history (paged).
        do {
            let o = try await send(makeRequest("api/decrypt/versions", body: ["url": app.url, "page": page], timeout: 150))
            let list = (o["versions"] as? [[String: Any]]) ?? []
            let mapped = list.compactMap { i -> DecryptVersion? in
                guard let v = i["v"] as? String, !v.isEmpty else { return nil }
                let minOS = (i["min_ios"] as? String) ?? (i["minimumOsVersion"] as? String)
                let ext = (i["external_id"] as? String) ?? (i["externalVersionId"] as? String)
                return DecryptVersion(
                    v: v,
                    current: (i["current"] as? Bool) ?? false,
                    minOS: minOS,
                    externalId: ext
                )
            }
            if !mapped.isEmpty {
                versions = mapped
                versionPage = Int(intValue(o["page"])).clamped(1, 500)
                versionPages = max(1, Int(intValue(o["pages"])))
                versionTotal = Int(intValue(o["total"]))
                return
            }
        } catch {
            if DecryptChannel.current == .telegram {
                self.error = error.localizedDescription
                return
            }
        }

        // Fallback: public iTunes current build (or store history if device path missed it).
        if let local = await DeviceDecryptService.shared.versionList(for: app) {
            versions = local.versions
            versionPage = 1
            versionPages = 1
            versionTotal = local.versions.count
            error = nil
        } else if versions.isEmpty {
            error = DeviceDecryptService.shared.lastVersionError
                ?? "Couldn't load version history. Try again, or decrypt the latest build from search."
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

    func reset() { phase = .idle; message = ""; finished = nil; finishedName = ""; error = nil }

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
            if let verify = try? FairPlayDecrypt.verifyIPA(at: dest), verify.isFullyClear {
                message = "Saved from Telegram bot · \(verify.summary)"
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
            let verifyNote = (try? FairPlayDecrypt.verifyIPA(at: dest))?.summary
            if DecryptChannel.current == .telegram {
                message = "Telegram IPA finished with on-device FairPlay" + (verifyNote.map { " · \($0)" } ?? "")
            } else {
                message = "Decrypted on this device · saved to Library" + (verifyNote.map { " · \($0)" } ?? "")
            }
            return dest
        } catch {
            if DecryptChannel.current == .telegram {
                // Bot claimed success but FairPlay couldn't finish — keep file, surface warning.
                let verifyNote = (try? FairPlayDecrypt.verifyIPA(at: dest))?.summary
                message = "Saved from Telegram (FairPlay verify failed: \(error.localizedDescription))"
                    + (verifyNote.map { " · \($0)" } ?? "")
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
    @AppStorage(IPadnOptional.countryKey) private var country = "US"
    @AppStorage(IPadnOptional.platformKey) private var platform = IPadnPlatform.iOS.rawValue
    @State private var query = ""
    @State private var versionsApp: DecryptApp?
    @State private var pickingIPA = false
    @State private var pickMessage: String?
    @State private var recentSearches: [String] = DecryptSearchHistory.load()

    /// Idle like iPadn SearchView: no query results yet — show suggestions / purchased.
    private var showingIdleSuggestions: Bool {
        store.isSignedIn && c.results.isEmpty && c.selected == nil && c.phase == .idle
            && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !c.searching
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea().task {
                await c.refreshQuota()
                if store.isSignedIn { await c.loadHistory() }
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // iPadn Search: large title + account avatar on one line.
                    IPadnPageHeader(title: "Decrypt") {
                        IPadnAccountMenuButton()
                    }

                    if store.isSignedIn {
                        // Capsule search (iPadn SearchInput).
                        IPadnCapsuleSearch(
                            text: $query,
                            placeholder: "Name, App ID, or apps.apple.com link",
                            onSubmit: { runSearch() },
                            onClear: {
                                c.results = []
                                c.error = nil
                            }
                        )

                        // Region / platform chips (iPadn filter row).
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Menu {
                                    Picker("Store region", selection: $country) {
                                        ForEach(IPadnBrowserModel.countries, id: \.self) { Text($0).tag($0) }
                                    }
                                } label: {
                                    IPadnFilterChip(title: country, symbol: "globe")
                                }
                                Menu {
                                    Picker("Platform", selection: $platform) {
                                        Text("iPhone").tag(IPadnPlatform.iOS.rawValue)
                                        Text("iPad").tag(IPadnPlatform.iPadOS.rawValue)
                                    }
                                } label: {
                                    IPadnFilterChip(
                                        title: (IPadnPlatform(rawValue: platform) ?? .iOS).title,
                                        symbol: platform == IPadnPlatform.iPadOS.rawValue ? "ipad" : "iphone"
                                    )
                                }
                                if store.hasStoreDownloadSession {
                                    IPadnFilterChip(title: "Store ready", symbol: "checkmark.seal.fill")
                                        .allowsHitTesting(false)
                                        .opacity(0.85)
                                }
                            }
                        }

                        if c.searching {
                            HStack(spacing: 10) {
                                ProgressView().tint(TetherlessPalette.accent)
                                Text("Searching…")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.55))
                                Spacer()
                            }
                            .padding(.vertical, 4)
                        }

                        if let err = c.error, c.phase != .failed, c.results.isEmpty {
                            Text(err)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let pickMessage {
                            Text(pickMessage)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                        }

                        // Active decrypt job (TetherLess-specific).
                        if c.phase != .idle, let app = c.selected ?? c.results.first {
                            decryptJobCard(for: app)
                        }

                        // Results — iPadn AppRow + Get capsule.
                        if !c.results.isEmpty {
                            Text("\(c.results.count) result\(c.results.count == 1 ? "" : "s")")
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.white)
                            ForEach(c.results) { app in
                                IPadnDecryptAppRow(
                                    app: app,
                                    onGet: {
                                        DeviceDecryptService.shared.decryptFromSearch(app)
                                    },
                                    onVersions: {
                                        versionsApp = app
                                        c.select(app)
                                        Task { await c.loadVersions(page: 1) }
                                    }
                                )
                                Divider().overlay(.white.opacity(0.08))
                            }
                        } else if showingIdleSuggestions {
                            if !recentSearches.isEmpty {
                                IPadnRecentSearchChips(
                                    terms: recentSearches,
                                    onSelect: { term in
                                        query = term
                                        runSearch()
                                    },
                                    onDelete: { term in
                                        DecryptSearchHistory.remove(term)
                                        recentSearches = DecryptSearchHistory.load()
                                    },
                                    onClearAll: {
                                        DecryptSearchHistory.clear()
                                        recentSearches = []
                                    }
                                )
                            }

                            DecryptChannelPicker()
                            if DecryptChannel.current == .device {
                                DecryptAppStoreSignInHint()
                                DecryptOwnedStoreAppsSection()
                                DecryptDeviceAppsSection()
                                DecryptPickIPACard { pickingIPA = true }
                            }
                            if !c.history.isEmpty {
                                historySection
                            }
                        }
                    } else {
                        Text("Sign in under Store Access to search free or purchased apps — same flow as iPadn, FairPlay stays on this iPhone.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                        DecryptStoreGateCard { AppNav.shared.go(AppTab.settings.rawValue) }
                        DecryptAppStoreSignInHint()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 120)
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
        .onAppear {
            recentSearches = DecryptSearchHistory.load()
            IPadnOptional.registerDefaults()
            consumePendingQuery()
            Task { await warmStoreSessionForNiche() }
        }
        .onChange(of: c.pendingQuery) { _ in consumePendingQuery() }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        DecryptSearchHistory.remember(q)
        recentSearches = DecryptSearchHistory.load()
        Task { await c.search(q) }
    }

    /// Soft-check + warm anisette/SAP so free/purchased fetch isn't a cold edge surprise.
    private func warmStoreSessionForNiche() async {
        guard store.isSignedIn else { return }
        if await store.reinforceStoreConnection() == nil, store.storeNeedsVerification {
            // reinforce already kept any usable prior token; only surface the wall when none.
        }
    }

    private func consumePendingQuery() {
        guard let name = c.pendingQuery else { return }
        c.pendingQuery = nil
        if !c.busy { c.clearSelection() }
        query = name
        runSearch()
    }

    private func handlePickedIPAs(_ urls: [URL]) {
        guard let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.deletingPathExtension().lastPathComponent
        let dest = AppPaths.dir("inbox").appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            pickMessage = error.localizedDescription
            return
        }
        // Build/sign/install the separate companion IPA — console UI opens there.
        pickMessage = "Building Tetherless Decrypt companion…"
        c.phase = .running
        c.message = "Building Tetherless Decrypt companion…"
        Task {
            do {
                _ = try await DecryptCompanionInstaller.installAndOpen(
                    embedding: dest,
                    displayName: name
                ) { msg in
                    Task { @MainActor in
                        c.message = msg
                        pickMessage = msg
                    }
                }
                await MainActor.run {
                    c.phase = .handedOff
                    c.message =
                        "Open Tetherless Decrypt — Trust your Apple ID under Settings › General › VPN & Device Management if iOS asks."
                    c.error = nil
                    pickMessage = "Companion installed — open Tetherless Decrypt."
                }
            } catch {
                await MainActor.run {
                    c.phase = .failed
                    c.error = error.localizedDescription
                    pickMessage = "Companion failed (\(error.localizedDescription)). Encrypted IPA kept in Files."
                }
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

    private var decryptJobStatusLabel: String {
        switch c.phase {
        case .downloading:
            return c.message.isEmpty ? "Downloading…" : c.message
        case .done:
            return "Decrypted"
        case .handedOff:
            return "Companion ready"
        case .failed:
            return "Failed"
        case .queued:
            return "Queued"
        case .running:
            return "Decrypting…"
        case .idle:
            return c.message.isEmpty ? "Ready" : c.message
        }
    }

    /// Yellow-wall / store 2FA failures — show inline code entry instead of only a tip.
    private static func needsStoreVerification(_ error: String?) -> Bool {
        guard let error, !error.isEmpty else { return false }
        let e = error.lowercased()
        // Portal cert errors (7460) are not store 2FA — don't stack the SMS entry on them.
        if isPortalCertError(error) { return false }
        return e.contains("verification code")
            || e.contains("two-factor")
            || e.contains("2fa")
            || e.contains("submit code")
            || e.contains("password token")
            || e.contains("resend text message")
    }

    private static func isPortalCertError(_ error: String?) -> Bool {
        guard let error, !error.isEmpty else { return false }
        let e = error.lowercased()
        return e.contains("7460")
            || e.contains("developer portal")
            || e.contains("development certificate")
            || e.contains("pending certificate request")
    }

    /// Only show the one-time App Store key hint when FairPlay/keys look like the failure mode.
    private static func shouldShowAppStoreKeyHint(_ error: String?) -> Bool {
        guard let error, !error.isEmpty else { return false }
        let e = error.lowercased()
        // Network / store protocol failures are not missing FairPlay keys.
        if e.contains("non-plist") || e.contains("http 204") || e.contains("http 404")
            || e.contains("http 403") || e.contains("http 500") || e.contains("http 502")
            || e.contains("http 503") || e.contains("store request failed")
            || e.contains("cdn download") || e.contains("client identity")
            || e.contains("app store download failed") {
            return false
        }
        if e.contains("pair") || e.contains("on-disk path") || e.contains("timed out") { return false }
        if e.contains("sign in under") || e.contains("store access") { return false }
        if e.contains("token") || e.contains("password") || e.contains("2fa") || e.contains("verification") {
            return false
        }
        return e.contains("fairplay")
            || e.contains("cryptid")
            || e.contains("encrypted")
            || e.contains("decryption key")
            || e.contains("sc_info")
            || e.contains("license")
            || e.contains("decrypt failed")
    }

    // MARK: Cards

    private func decryptJobCard(for app: DecryptApp) -> some View {
        GlassCard(corner: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    iconView(app.icon, size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name.isEmpty ? c.finishedName : app.name)
                            .font(.headline.weight(.semibold)).foregroundStyle(.white)
                        Text(app.dev).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        Text(decryptJobStatusLabel)
                            .font(.caption).foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    if c.phase == .done || c.phase == .handedOff {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if c.phase == .failed {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if c.phase == .downloading {
                        SlimProgress(value: percent).frame(width: 64)
                    } else if c.phase == .running || c.phase == .queued {
                        ProgressView().tint(TetherlessPalette.accent).scaleEffect(0.85)
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
                            Text(c.message.isEmpty ? "Starting…" : c.message)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                }

                if c.phase == .handedOff {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(c.message.isEmpty
                             ? "Open Tetherless Decrypt to finish FairPlay."
                             : c.message)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Dismiss") { c.reset() }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }

                if c.phase == .done, let file = c.finished {
                    VStack(spacing: 10) {
                        Text("Signs with your free Apple ID 7-day certificate and installs on this iPhone.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.7))
                        Button {
                            DecryptPipeline.shared.runFinishedIPA(file, name: c.finishedName.isEmpty ? app.name : c.finishedName)
                        } label: {
                            Text(DecryptPipeline.shared.busy ? "Pipeline…" : "Decrypt → Sign → Install")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(TetherlessPalette.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(DecryptPipeline.shared.busy)
                        Button {
                            SignQueue.shared.enqueueForAppleIDInstall(file)
                        } label: {
                            Text("Sign only")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.7))
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
                        .fixedSize(horizontal: false, vertical: true)
                    if !Self.isPortalCertError(c.error),
                       Self.needsStoreVerification(c.error) || AppleIDStore.shared.storeNeedsVerification {
                        DecryptStoreTrustHint(retryApp: app)
                    }
                    FailurePlaybookCard(errorText: c.error)
                    if Self.shouldShowAppStoreKeyHint(c.error) {
                        DecryptAppStoreSignInHint(compact: true)
                    }
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

// MARK: - Store trust piggyback (Decrypt tab)

/// Store unlocks with the first Sign In Allow/code — no second Store OTP.
private struct DecryptStoreTrustHint: View {
    let retryApp: DecryptApp
    @ObservedObject private var store = AppleIDStore.shared
    @State private var busy = false
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Store piggybacks the Allow / verification code from Sign In — it should not ask for a second text. Retry unlock, or Sign Out → Sign In once under Settings › Store Access.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task {
                    busy = true
                    localError = nil
                    defer { busy = false }
                    await store.requestStoreVerificationPrompt()
                    if store.storefrontSession()?.isUsable == true {
                        DecryptClient.shared.reset()
                        DeviceDecryptService.shared.decryptFromSearch(retryApp)
                    } else {
                        localError = store.statusMessage ?? store.lastError
                            ?? "Sign Out, then Sign In once so Store can use the first trust."
                    }
                }
            } label: {
                Text(busy ? "Retrying…" : "Retry Store unlock")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(busy || store.isBusy || store.storeConnecting)
            if let localError, !localError.isEmpty {
                Text(localError)
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Versions sheet

private struct DecryptVersionsSheet: View {
    let app: DecryptApp
    @ObservedObject private var c = DecryptClient.shared
    @Environment(\.dismiss) private var dismiss

    private var deviceIOS: String {
        UIDevice.current.systemVersion
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground().ignoresSafeArea()
                List {
                    if c.loadingVersions && c.versions.isEmpty {
                        Section {
                            HStack {
                                Spacer()
                                VStack(spacing: 12) {
                                    ProgressView().tint(.white)
                                    Text("Checking available versions…")
                                        .font(.subheadline)
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                                .padding(.vertical, 24)
                                Spacer()
                            }
                            .listRowBackground(Color.clear)
                        }
                        ForEach(0..<12, id: \.self) { idx in
                            HStack(spacing: 10) {
                                ProgressView().tint(.white.opacity(0.55)).scaleEffect(0.75)
                                Text("Resolving…")
                                    .foregroundStyle(.white.opacity(0.45))
                                Spacer()
                                if idx == 0 {
                                    Text("Latest").font(.subheadline).foregroundStyle(.white.opacity(0.35))
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.04))
                        }
                    } else if let err = c.error, c.versions.isEmpty {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(c.versions) { v in
                            let spoof = StoreDeviceSpoof.current
                            let fitsSpoof = !spoof.enabled || spoof.acceptsMinimumOS(v.minOS)
                            let fitsDevice = {
                                guard let min = v.minOS, !min.isEmpty else { return true }
                                return StoreDeviceSpoof.compareVersions(min, deviceIOS) != .orderedDescending
                            }()
                            Button {
                                if DecryptChannel.current == .telegram {
                                    c.start(url: app.url, version: v.v, display: app.name)
                                } else {
                                    DeviceDecryptService.shared.decryptFromSearch(
                                        app,
                                        version: v.v,
                                        externalVersionId: v.externalId
                                    )
                                }
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(v.v).foregroundStyle(.white)
                                        HStack(spacing: 6) {
                                            if let min = v.minOS, !min.isEmpty {
                                                Text("iOS \(min)+")
                                                    .font(.caption2)
                                                    .foregroundStyle(fitsSpoof ? .white.opacity(0.45) : .orange.opacity(0.85))
                                            }
                                            if spoof.enabled, fitsSpoof {
                                                Text("spoof OK")
                                                    .font(.caption2)
                                                    .foregroundStyle(TetherlessPalette.accent.opacity(0.8))
                                            }
                                        }
                                    }
                                    Spacer()
                                    if v.current {
                                        Text("Latest").font(.subheadline).foregroundStyle(.white.opacity(0.45))
                                    } else if !fitsDevice {
                                        Text("Device").font(.caption).foregroundStyle(.orange.opacity(0.7))
                                    }
                                }
                            }
                            .listRowBackground(Color.white.opacity(0.06))
                        }

                        // Placeholder rows while more history is still resolving (reference UI).
                        if c.loadingVersions {
                            ForEach(0..<8, id: \.self) { idx in
                                HStack(spacing: 10) {
                                    ProgressView().tint(.white.opacity(0.55)).scaleEffect(0.75)
                                    Text("Resolving…")
                                        .foregroundStyle(.white.opacity(0.45))
                                    Spacer()
                                    if idx == 0, c.versions.isEmpty {
                                        Text("Latest").font(.subheadline).foregroundStyle(.white.opacity(0.35))
                                    }
                                }
                                .listRowBackground(Color.white.opacity(0.04))
                            }
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
        .task {
            c.select(app)
            await c.loadVersions(page: 1)
        }
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
