//
// Brand: Tetherless · https://tetherless.dev
//  IPadnSettingsView.swift
//  English Settings — structure from mengangs/ipadn SettingsView (GPL-2.0).
//  Account › Settings uses this only; the legacy TetherLess Settings chrome is not shown.
//

import SwiftUI
import UserNotifications

struct IPadnSettingsView: View {
    enum Page: Hashable {
        case root, downloads, follow, appearance, lock, sources, maintenance

        var title: String {
            switch self {
            case .root: return "Settings"
            case .downloads: return "Downloads"
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
    @AppStorage("ipadn.settings.maxQueuedDownloads") private var maxQueuedDownloads = 40
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

    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? Theme.appVersion
    }

    var body: some View {
        Form {
            if page == .root {
                Section {
                    pageLink(.downloads, "arrow.down.circle")
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

            if page == .downloads {
                Section {
                    Stepper("Concurrent downloads: \(maxConcurrentDownloads)", value: $maxConcurrentDownloads, in: 1...6)
                    Stepper("Queued download limit: \(maxQueuedDownloads)", value: $maxQueuedDownloads, in: 1...100)
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
        .onChange(of: maxQueuedDownloads) { _ in applyDownloadPrefs() }
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

    private func pageLink(_ page: Page, _ symbol: String) -> some View {
        NavigationLink {
            IPadnSettingsView(page: page)
        } label: {
            Label(page.title, systemImage: symbol)
        }
    }

    private func applyDownloadPrefs() {
        IPadnDownloadManager.shared.applySettings(
            maxConcurrent: maxConcurrentDownloads,
            wifiOnly: wifiOnlyDownloads,
            maxQueued: maxQueuedDownloads,
            compatibleMode: compatibleDownloadMode
        )
    }

    private func resetToDefaults() {
        maxConcurrentDownloads = 3
        maxQueuedDownloads = 40
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
        applyDownloadPrefs()
        statusMessage = "Settings restored to defaults."
    }
}
