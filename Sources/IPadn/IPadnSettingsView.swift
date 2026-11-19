//
// Brand: Tetherless · https://tetherless.dev
//  IPadnSettingsView.swift
//  English Settings — structure from mengangs/ipadn SettingsView (GPL-2.0).
//  Account embeds the root sections inline; subpages still push from there.
//

import SwiftUI
import UIKit
import UserNotifications

struct IPadnSettingsView: View {
    enum Page: Hashable {
        case root, downloads, fairplay, follow, appearance, lock, sources, maintenance

        var title: String {
            switch self {
            case .root: return "Settings"
            case .downloads: return "Downloads"
            case .fairplay: return "FairPlay Decrypt"
            case .follow: return "Following"
            case .appearance: return "Appearance & Icon"
            case .lock: return "App Lock"
            case .sources: return "Version Sources"
            case .maintenance: return "Backup & Maintenance"
            }
        }
    }

    var page: Page = .root

    @AppStorage("ipadn.settings.maxConcurrentDownloads") private var maxConcurrentDownloads = 3
    @AppStorage("ipadn.settings.notifications") private var notifications = true
    @AppStorage("ipadn.settings.updateNotifications") private var updateNotifications = true
    @AppStorage("ipadn.settings.wifiOnlyDownloads") private var wifiOnlyDownloads = false
    @AppStorage("ipadn.settings.autoInstall") private var autoInstall = false
    @AppStorage("ipadn.settings.downloadLiveActivity") private var downloadLiveActivity = true
    @AppStorage("ipadn.settings.showHistoryIcons") private var showHistoryIcons = true
    @AppStorage("ipadn.settings.prioritizeDelistedSearchResults") private var prioritizeDelisted = false
    @AppStorage("ipadn.settings.compatibleDownloadMode") private var compatibleDownloadMode = false
    @AppStorage("ipadn.settings.watchNotifications") private var watchNotifications = true
    @AppStorage("ipadn.settings.targetPrices") private var targetPrices = true
    @AppStorage("ipadn.settings.appLock") private var appLock = false
    @AppStorage("ipadn.settings.appLockDelay") private var appLockDelay = 0
    @AppStorage("ipadn.settings.searchLimit") private var searchLimit = 50
    @AppStorage("ipadn.settings.showDiscover") private var showDiscover = true
    @AppStorage("ipadn.settings.appearance") private var appearance = "system"
    @AppStorage("ipadn.settings.proMode") private var proMode = false
    @AppStorage("ipadn.settings.appUpdateCheck") private var appUpdateCheck = true
    @AppStorage("ipadn.settings.useSignerCache") private var useSignerCache = true
    @AppStorage(IPadnOptional.countryKey) private var country = "US"
    @AppStorage(IPadnOptional.platformKey) private var platform = IPadnPlatform.iOS.rawValue

    @State private var resetSettings = false
    @State private var clearCache = false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            if page == .root {
                IPadnSettingsRootSections(statusMessage: $statusMessage)
            }

            if page == .fairplay {
                FairPlayAdvancedSettingsSection()
            }

            if page == .downloads {
                Section {
                    Stepper("Concurrent downloads: \(maxConcurrentDownloads)", value: $maxConcurrentDownloads, in: 1...6)
                    Text("Stack as many Gets as you want — they download and decrypt only. Signing happens later when you Install.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle("Download finished notifications", isOn: $notifications)
                    Toggle("New version alerts", isOn: $updateNotifications)
                        .onChange(of: updateNotifications) { on in
                            if on {
                                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                            }
                        }
                    Toggle("Wi‑Fi only downloads", isOn: $wifiOnlyDownloads)
                    Toggle(isOn: $autoInstall) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Install when download finishes")
                            Text("Native Install can finish in the background; other methods ask you to confirm when the app is open.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Live Activity download progress", isOn: $downloadLiveActivity)
                    Toggle("Show history version icons", isOn: $showHistoryIcons)
                    Toggle("Prioritize delisted apps in search", isOn: $prioritizeDelisted)
                    Toggle("Compatible download mode", isOn: $compatibleDownloadMode)
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Wi‑Fi only pauses cellular downloads until you’re back on Wi‑Fi. Compatible mode keeps downloads in the foreground when background transfer fails under some resignatures.")
                }

                Section {
                    Toggle("Speed up repeat downloads", isOn: $useSignerCache)
                    Button("Clear cache") {
                        statusMessage = "Cache cleared for this session."
                    }
                } header: {
                    Text("Performance")
                } footer: {
                    Text("Cache lasts only for this run.")
                }
            }

            if page == .follow {
                Section {
                    Toggle("Following alerts", isOn: $watchNotifications)
                        .onChange(of: watchNotifications) { on in
                            if on {
                                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                            }
                        }
                    Toggle("Target price alerts", isOn: $targetPrices)
                } header: {
                    Text("Following")
                } footer: {
                    Text("Get notified when followed apps update, drop in price, go free, or leave the store. Checks also run when you open the app.")
                }
            }

            if page == .lock {
                Section {
                    Toggle(isOn: $appLock) {
                        Text("Require authentication")
                    }
                    if appLock {
                        Picker("Require after", selection: $appLockDelay) {
                            Text("Immediately").tag(0)
                            Text("1 minute").tag(60)
                            Text("5 minutes").tag(300)
                            Text("15 minutes").tag(900)
                        }
                    }
                } footer: {
                    Text("When locked, opening the app or returning after a break requires Face ID, Touch ID, or your passcode. Downloads keep running in the background.")
                }
            }

            if page == .appearance {
                Section("Search & appearance") {
                    Picker("Search result count", selection: $searchLimit) {
                        ForEach([10, 30, 50, 100, 200], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Toggle("Show Discover on Search", isOn: $showDiscover.animation())
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    Picker("Default storefront", selection: $country) {
                        ForEach(IPadnBrowserModel.countries, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Default platform", selection: $platform) {
                        ForEach(IPadnPlatform.allCases.filter { $0 == .iOS || $0 == .iPadOS }) { p in
                            Text(p.title).tag(p.rawValue)
                        }
                    }
                }
            }

            if page == .sources {
                Section {
                    ForEach(IPadnVersionSource.defaults, id: \.name) { source in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.name).font(.body.weight(.semibold))
                            Text(source.urlTemplate)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(source.enabled ? "Enabled" : "Disabled")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Version history sources")
                } footer: {
                    Text("Used to look up older versions (Timbrd, Bilin, iosdump). Public version feeds used by Tetherless Store search.")
                }
            }

            if page == .maintenance {
                Section {
                    Button("Export settings & following") {
                        statusMessage = "Export uses the Tetherless backup format when available on this build."
                    }
                    Button("Import settings & following") {
                        statusMessage = "Import a JSON backup exported from Tetherless Account settings."
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Includes settings, version sources, followed apps, and recent searches — not Apple Accounts or downloaded packages.")
                }

                Section("Maintenance") {
                    Button("Clear version history cache") { clearCache = true }
                        .confirmationDialog("Clear version history cache?", isPresented: $clearCache, titleVisibility: .visible) {
                            Button("Clear cache", role: .destructive) {
                                statusMessage = "Version history cache cleared."
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                    if let url = URL(string: "https://github.com/unflavoredapp/Random/issues") {
                        Link("Report an issue", destination: url)
                    }
                    Button("Reset to defaults", role: .destructive) { resetSettings = true }
                }
            }
        }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        // Keep Form rows (About card, links) above the floating tab bar.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 100)
        }
        .onAppear { applyDownloadPrefs() }
        .onChange(of: maxConcurrentDownloads) { _ in applyDownloadPrefs() }
        .onChange(of: wifiOnlyDownloads) { _ in applyDownloadPrefs() }
        .onChange(of: compatibleDownloadMode) { _ in applyDownloadPrefs() }
        .confirmationDialog("Reset settings to defaults?", isPresented: $resetSettings, titleVisibility: .visible) {
            Button("Reset settings", role: .destructive) { resetToDefaults() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Apple Accounts, downloads, and purchased history are not affected.")
        }
        .alert("Settings", isPresented: Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )) {
            Button("OK", role: .cancel) { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
    }

    private func applyDownloadPrefs() {
        IPadnDownloadManager.shared.applySettings(
            maxConcurrent: maxConcurrentDownloads,
            wifiOnly: wifiOnlyDownloads,
            compatibleMode: compatibleDownloadMode
        )
    }

    private func resetToDefaults() {
        maxConcurrentDownloads = 3
        notifications = true
        updateNotifications = true
        wifiOnlyDownloads = false
        autoInstall = false
        downloadLiveActivity = true
        showHistoryIcons = true
        prioritizeDelisted = false
        compatibleDownloadMode = false
        watchNotifications = true
        targetPrices = true
        appLock = false
        appLockDelay = 0
        searchLimit = 50
        showDiscover = true
        appearance = "system"
        proMode = false
        appUpdateCheck = true
        useSignerCache = true
        FairPlayAdvancedOptions.resetToDefaults()
        applyDownloadPrefs()
        statusMessage = "Settings restored to defaults."
    }
}

/// Compact Phone Worker controls — opt-in only when DECRYPT_BACKENDS includes phone.
private struct PhoneDecryptWorkerInline: View {
    @ObservedObject private var worker = PhoneDecryptWorker.shared

    var body: some View {
        Toggle(isOn: Binding(
            get: { worker.enabled },
            set: { worker.applyEnabled($0) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Phone Worker (opt-in)")
                Text(worker.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        SecureField("DECRYPT_WORKER_TOKEN", text: $worker.workerToken)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.footnote.monospaced())
            .disabled(!worker.enabled)
        if let err = worker.lastError, !err.isEmpty {
            Text(err)
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }
}

/// Override `as_site_base` so Store/Telegram/companion jobs hit the Mac HTTPS API
/// (`mac-https-api.js` behind cloudflared — not tetherless.dev).
private struct FairPlayDecryptHostField: View {
    @AppStorage("as_site_base") private var siteBase = ""
    @AppStorage("tetherless.decrypt.macOnly") private var macOnly = true
    @State private var draft = ""
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Mac decrypt only (skip on-device companion FairPlay)", isOn: $macOnly)
                .font(.footnote)
            TextField("Mac API URL (https://….trycloudflare.com/)", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .font(.footnote.monospaced())
                .onAppear {
                    draft = siteBase
                    if Self.isDeadLookingHost(siteBase) {
                        note = "Previous Mac tunnel may be dead — Refresh clears it, then paste a new Mac API URL."
                    }
                }
            HStack {
                Button("Save Mac API") {
                    saveMacAPI(draft)
                }
                .buttonStyle(.borderedProminent)
                Button("Paste") {
                    if let clip = UIPasteboard.general.string?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !clip.isEmpty {
                        draft = Self.normalizeMacAPIURL(clip)
                        saveMacAPI(draft)
                    } else {
                        note = "Clipboard is empty — copy the URL from mac-ssh.sh api / status first."
                    }
                }
                .buttonStyle(.bordered)
            }
            HStack {
                Button("Clear dead host") {
                    clearHost(reason: "Cleared. Run: zsh ~/tetherless/server/mac-ssh.sh api — then Paste the printed Mac API URL.")
                }
                .buttonStyle(.bordered)
                Button("Use tetherless.dev") {
                    clearHost(reason: "Using tetherless.dev (not MacDuty unfairplay).")
                }
                .buttonStyle(.bordered)
            }
            Text(
                siteBase.isEmpty
                    ? "No Mac API set — Mac decrypt needs the live trycloudflare URL from mac-ssh.sh api."
                    : "Mac API: \(siteBase)"
            )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func saveMacAPI(_ raw: String) {
        let normalized = Self.normalizeMacAPIURL(raw)
        guard !normalized.isEmpty else {
            note = "Paste the Mac API URL from: zsh ~/tetherless/server/mac-ssh.sh api"
            return
        }
        siteBase = normalized
        draft = normalized
        note = "Saved Mac API. Tap Refresh backend status."
        NotificationCenter.default.post(name: .tetherlessMacAPIHostDidChange, object: normalized)
    }

    private func clearHost(reason: String) {
        siteBase = ""
        draft = ""
        note = reason
        NotificationCenter.default.post(name: .tetherlessMacAPIHostDidChange, object: "")
    }

    static func normalizeMacAPIURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        if !s.hasPrefix("http://"), !s.hasPrefix("https://") {
            s = "https://" + s
        }
        // Prefer HTTPS for App Transport; trycloudflare is always https.
        if s.hasPrefix("http://"), s.lowercased().contains("trycloudflare.com") {
            s = "https://" + s.dropFirst("http://".count)
        }
        if !s.hasSuffix("/") { s += "/" }
        return s
    }

    static func isDeadLookingHost(_ raw: String) -> Bool {
        let lower = raw.lowercased()
        return lower.contains("trycloudflare.com")
    }
}

extension Notification.Name {
    static let tetherlessMacAPIHostDidChange = Notification.Name("tetherless.macAPIHostDidChange")
}

/// Shows which FairPlay backends the Mac API / site reports as configured.
private struct DecryptBackendsStatusRow: View {
    @AppStorage("as_site_base") private var siteBase = ""
    @State private var lines: [String] = ["Tap Refresh"]
    @State private var busy = false

    var body: some View {
        ForEach(lines, id: \.self) { line in
            Text(line)
                .font(.caption.monospaced())
                .foregroundStyle(lineHasError(line) ? Color.orange : Color.secondary)
                .textSelection(.enabled)
        }
        Button(busy ? "Refreshing…" : "Refresh backend status") {
            Task { await refresh() }
        }
        .disabled(busy)
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .tetherlessMacAPIHostDidChange)) { _ in
            Task { await refresh() }
        }
    }

    private func lineHasError(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.contains("could not be found")
            || l.contains("dead")
            || l.contains("failed")
            || l.contains("timed out")
            || l.hasPrefix("http ")
    }

    private func refresh() async {
        busy = true
        defer { busy = false }
        let configured = siteBase.trimmingCharacters(in: .whitespacesAndNewlines)
        if configured.isEmpty {
            lines = [
                "No Mac API URL — run on the Mac:",
                "zsh ~/tetherless/server/mac-ssh.sh api",
                "Then Paste the printed https://….trycloudflare.com/ URL.",
            ]
            return
        }
        do {
            let base = DecryptClient.siteBase
            guard !base.isEmpty, let url = URL(string: base + "api/decrypt/backends") else {
                lines = ["Bad Mac API URL"]
                return
            }
            let (data, resp) = try await URLSession.shared.data(from: url)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 400,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                lines = ["Mac API HTTP \(code) — is mac-https-api running?"]
                return
            }
            let order = (json["backends"] as? [String]) ?? []
            var out: [String] = ["Mac API OK · Order: " + (order.isEmpty ? "(none)" : order.joined(separator: " → "))]
            if let macApi = (json["macApiUrl"] as? String) ?? (json["publicBase"] as? String), !macApi.isEmpty {
                out.append("Public: \(macApi)")
            }
            if let status = json["status"] as? [String: Any] {
                if let host = status["host"] as? String, !host.isEmpty {
                    out.append("Host: \(host)" + ((status["macHost"] as? Bool) == true ? " (enroll+decrypt here)" : ""))
                } else if (status["linuxOnly"] as? Bool) == true {
                    out.append("Linux-only (no JB / TrollStore / phone)")
                }
                if let cred = status["credential"] as? [String: Any] {
                    let ready = (cred["ready"] as? Bool) == true
                    if ready {
                        out.append("✓ credential.bin (16 bytes)")
                    } else {
                        out.append("✗ credential.bin — \((cred["error"] as? String) ?? "missing")")
                    }
                }
                if let model = status["enrollmentModel"] as? [String: Any] {
                    let ready = (model["ready"] as? Bool) == true
                    out.append(ready ? "✓ enrollment model" : "· enrollment model")
                }
                if let ipa = status["ipatool"] as? [String: Any] {
                    let ready = (ipa["ready"] as? Bool) == true
                    let email = (ipa["email"] as? String) ?? ""
                    let note = (ipa["note"] as? String) ?? (ipa["error"] as? String) ?? ""
                    if ready {
                        out.append("✓ ipatool" + (email.isEmpty ? "" : " · \(email)"))
                    } else {
                        out.append("✗ ipatool — \(note.isEmpty ? "not logged in" : note)")
                    }
                }
                for key in ["fairplay-decrypt", "unfairplay", "ipadecrypt", "ipa-decrypter", "unfaird", "phone"] {
                    guard let row = status[key] as? [String: Any] else { continue }
                    let ready = (row["ready"] as? Bool) == true
                    out.append("\(ready ? "✓" : "·") \(key)")
                }
            }
            lines = out
        } catch {
            let msg = error.localizedDescription
            // Dead trycloudflare tunnels show "hostname could not be found" — clear so Mac API can be set fresh.
            if isUnreachableHostError(msg), FairPlayDecryptHostField.isDeadLookingHost(configured) {
                siteBase = ""
                lines = [
                    "Dead Mac tunnel cleared (hostname not found).",
                    "On the Mac: zsh ~/tetherless/server/mac-ssh.sh api",
                    "Copy the new https://….trycloudflare.com/ → Paste → Save Mac API.",
                ]
                NotificationCenter.default.post(name: .tetherlessMacAPIHostDidChange, object: "")
            } else {
                lines = [msg]
            }
        }
    }

    private func isUnreachableHostError(_ msg: String) -> Bool {
        let l = msg.lowercased()
        return l.contains("hostname could not be found")
            || l.contains("nodename nor servname")
            || l.contains("could not resolve")
            || l.contains("a server with the specified hostname")
            || l.contains("not known")
    }
}

/// Advanced FairPlay decrypt controls — source path, verbose console, retries, IPA retention.
private struct FairPlayAdvancedSettingsSection: View {
    @AppStorage(FairPlayAdvancedOptions.sourceModeKey) private var sourceModeRaw =
        FairPlayAdvancedOptions.SourceMode.automatic.rawValue
    @AppStorage(FairPlayAdvancedOptions.verboseKey) private var verboseConsole = false
    @AppStorage(FairPlayAdvancedOptions.keepEncryptedIPAKey) private var keepEncryptedIPA = true
    @AppStorage(FairPlayAdvancedOptions.retryRoundsKey) private var retryRounds =
        FairPlayAdvancedOptions.defaultRetryRounds
    @AppStorage(FairPlayAdvancedOptions.pathDiagnosticsKey) private var pathDiagnostics = false
    @AppStorage(FairPlayAdvancedOptions.requireAllFrameworksKey) private var requireAllFrameworks = false
    @AppStorage(FairPlayAdvancedOptions.includeTestFlightKey) private var includeTestFlight = true

    private var sourceMode: FairPlayAdvancedOptions.SourceMode {
        FairPlayAdvancedOptions.SourceMode(rawValue: sourceModeRaw) ?? .automatic
    }

    var body: some View {
        Section {
            DecryptBackendsStatusRow()
            FairPlayDecryptHostField()
        } header: {
            Text("Server · FairPlay host")
        } footer: {
            Text("MacDuty: zsh ~/tetherless/server/mac-ssh.sh api → paste the printed Mac API URL here (Save Mac API). Dead trycloudflare hosts are cleared on Refresh. Leave empty only if you want tetherless.dev instead of Mac unfairplay. No jailbreak or TrollStore.")
        }

        Section {
            PhoneDecryptWorkerInline()
        } header: {
            Text("Optional · Phone Worker")
        } footer: {
            Text("Not needed for Mac/Linux offline decrypt. Only used when DECRYPT_BACKENDS explicitly includes phone.")
        }

        Section {
            Picker("Decrypt source", selection: $sourceModeRaw) {
                ForEach(FairPlayAdvancedOptions.SourceMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            Text(sourceMode.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("Source")
        } footer: {
            Text("Automatic is best for most apps. Live install only helps when EmbeddedPayload hits FairPlay EPERM (e.g. Roblox).")
        }

        Section {
            Toggle("Include TestFlight apps", isOn: $includeTestFlight)
        } header: {
            Text("Installed apps")
        } footer: {
            Text("When on, TestFlight betas (Beta Distribution signing) appear in Decrypt and FairPlay keys readiness alongside App Store installs.")
        }

        Section {
            Stepper("Targeted retries: \(max(3, min(8, retryRounds == 0 ? 5 : retryRounds)))", value: $retryRounds, in: 3...8)
            Toggle("Verbose FairPlay console", isOn: $verboseConsole)
            Toggle("Show path diagnostics", isOn: $pathDiagnostics)
            Toggle("Require all frameworks", isOn: $requireAllFrameworks)
        } header: {
            Text("Decrypt engine")
        } footer: {
            Text("Encrypted IPA Get already fail-closes on every iPhone Mach-O (no fake PARTIAL). Require all frameworks also applies that to live-install triage. Verbose logs retries and SINF staging.")
        }

        Section {
            Toggle("Keep encrypted IPA after decrypt", isOn: $keepEncryptedIPA)
            if let stamped = DecryptCompanionHandoff.readEncryptedIPAPath() {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stamped encrypted IPA")
                        .font(.subheadline.weight(.semibold))
                    Text(stamped.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
                Button("Clear stamped IPA path", role: .destructive) {
                    DecryptCompanionHandoff.purgeRetainedEncryptedIPA()
                }
            } else {
                Text("No stamped encrypted IPA yet — run Get on an App Store app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let live = DecryptCompanionHandoff.readLiveInstallPath() {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stamped live install")
                        .font(.subheadline.weight(.semibold))
                    Text(live.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Temp paths")
        } footer: {
            Text("Free Apple ID certs usually strip App Groups, so stamps under Documents stay host-only. Get always embeds EncryptedSource.ipa inside Tetherless Decrypt for FairPlay. Delete the old companion before Get. Turn Keep off to delete the stamped file after a successful clear export.")
        }

        Section {
            Button("Reset FairPlay advanced defaults") {
                FairPlayAdvancedOptions.resetToDefaults()
                sourceModeRaw = FairPlayAdvancedOptions.SourceMode.automatic.rawValue
                verboseConsole = false
                keepEncryptedIPA = true
                retryRounds = FairPlayAdvancedOptions.defaultRetryRounds
                pathDiagnostics = false
                requireAllFrameworks = false
                includeTestFlight = true
            }
        }
    }
}

/// Root Settings rows shared by Account (inline) and the pushed Settings page.
struct IPadnSettingsRootSections: View {
    @Binding var statusMessage: String?

    @AppStorage("ipadn.settings.proMode") private var proMode = false
    @AppStorage("ipadn.settings.appUpdateCheck") private var appUpdateCheck = true

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? Theme.appVersion
    }

    var body: some View {
        Section {
            pageLink(.downloads, "arrow.down.circle")
            pageLink(.fairplay, "lock.open")
            pageLink(.follow, "bell")
            pageLink(.appearance, "paintbrush")
            pageLink(.lock, "lock")
            pageLink(.sources, "clock.arrow.circlepath")
            NavigationLink {
                IPadnInstallationSettingsView()
            } label: {
                Label("Installation settings", systemImage: "arrow.down.app")
            }
            pageLink(.maintenance, "wrench.and.screwdriver")
        }

        Section {
            Toggle("Pro mode", isOn: $proMode.animation())
        } footer: {
            Text(proMode
                 ? "Package contents and device identifiers are available in download task details."
                 : "Turn on to browse package contents and inspect device identifiers.")
        }

        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    TetherlessAppIconView(size: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(TetherlessBrand.name).font(.headline)
                            Text(appVersion).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("Search, download, sign, and install — branded at tetherless.dev.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(TetherlessBrand.ascii)
                    .font(.system(size: 6.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(TetherlessPalette.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Link(TetherlessBrand.siteDisplay, destination: TetherlessBrand.siteURL)
                    .font(.caption.weight(.semibold))
            }
            .padding(.vertical, 2)

            Button {
                statusMessage = "You're on the latest build available for this install (\(appVersion))."
            } label: {
                Text("Check for Updates")
            }

            Toggle("Check for updates automatically", isOn: $appUpdateCheck)

            Link("tetherless.dev", destination: TetherlessBrand.siteURL)
            if let url = URL(string: "https://github.com/mengangs/ipadn") {
                Link("Open-source Store login (GPL-2.0)", destination: url)
            }
        }
    }

    private func pageLink(_ page: IPadnSettingsView.Page, _ symbol: String) -> some View {
        NavigationLink {
            IPadnSettingsView(page: page)
        } label: {
            Label(page.title, systemImage: symbol)
        }
    }
}
