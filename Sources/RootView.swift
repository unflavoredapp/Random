//
// Brand: Tetherless · https://tetherless.dev
//  RootView.swift
//  TetherLess glass shell — iPadn tab IA (English): Search · Downloads ·
//  Purchased · Account. Pair / Files / Library live under Account.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var signQueue = SignQueue.shared
    @ObservedObject private var hub = GitHubHub.shared
    @ObservedObject private var theme = AppTheme.shared
    @ObservedObject private var account = ZefvAccount.shared
    @ObservedObject private var nav = AppNav.shared
    @ObservedObject private var signed = SignedStore.shared
    @ObservedObject private var decrypt = DecryptClient.shared
    @ObservedObject private var deviceDecrypt = DeviceDecryptService.shared
    @ObservedObject private var downloads = IPadnDownloadManager.shared
    /// Unsigned launches land on Account so Store login is the first thing they see.
    @State private var tab: AppTab = AppleIDStore.shared.isSignedIn ? .search : .account
    @State private var signItem: SignItem?
    @State private var signError: String?

    private var downloadBadge: Int {
        let live = downloads.activeCount
        if live > 0 { return live }
        return (decrypt.busy || deviceDecrypt.busy
            || decrypt.phase == .running || decrypt.phase == .downloading || decrypt.phase == .queued) ? 1 : 0
    }

    /// An IPA handed to the shell for signing — goes straight into SigningSheet.
    private struct SignItem: Identifiable {
        let url: URL
        let meta: IPAMeta
        var pending: PendingIPADownload? = nil
        var id: String { url.path }
    }

    var body: some View {
        ZStack {
            AppBackground()

            Group {
                switch tab {
                case .search:
                    DecryptView()
                case .downloads:
                    DownloadsHomeView()
                case .purchased:
                    PurchasedHomeView()
                case .account:
                    AccountHomeView()
                }
            }
            .id(theme.revision)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .simultaneousGesture(                                 // finger drives the particle layer when enabled
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { ParticleTouch.point = $0.location }
                .onEnded { v in
                    ParticleTouch.point = nil
                    if abs(v.translation.width) < 8 && abs(v.translation.height) < 8 {
                        ParticleTouch.pulse = (v.location, Date.timeIntervalSinceReferenceDate)
                    }
                }
        )
        .overlay { if theme.background != .none { ThemeBackgroundLayer() } }
        .overlay { dropdownLayer }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: theme.panelShown)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: account.panelShown)

        .task {
            theme.startCycleIfNeeded()
            // Full FairPlay / Purchases / Downloads need Apple ID — nudge unsigned users to Account.
            AppNav.shared.nudgeAccountLoginIfNeeded()
            Task.detached(priority: .utility) { try? await Task.sleep(nanoseconds: 8_000_000_000); await StorageCleaner.run() }
            Task { _ = await LibraryCache.shared.refresh() }
            await SourceStore.shared.warmUpAtLaunch()
            _ = InstallAutopilot.apply()
            SideloadSurvival.refreshExpiryLoop()
            WidgetDataManager.shared.refresh()
            _ = await PortalStorage.cleanupStaleTemporaryFiles()
            await LocalSourceUpdateWatcher.shared.scanAllSources(reason: "launch")
        }
        .onChange(of: signed.entries) { _ in
            WidgetDataManager.shared.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await LocalSourceUpdateWatcher.shared.scanAllSources(reason: "foreground") }
        }
        .onChange(of: nav.requestedTab) { t in
            guard let t, let mapped = AppTab(rawValue: t) else { return }
            nav.requestedTab = nil
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { tab = mapped }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingTabBar(selection: $tab, downloadBadge: downloadBadge)
        }
        .tint(TetherlessPalette.accent)
        .preferredColorScheme(.dark)
        .onChange(of: signQueue.requestedTab) { t in
            // Signing is a flow, not a tab: open SigningSheet directly over whatever's showing.
            guard t != nil else { return }
            signQueue.requestedTab = nil
            if let d = signQueue.pendingDownload {
                signQueue.pendingDownload = nil
                d.start()
                signItem = SignItem(url: d.url, meta: d.meta, pending: d)
            } else if let url = signQueue.pending { openSigningSheet(url) }
        }
        .fullScreenCover(item: $signItem) { it in
            SigningSheet(ipaURL: it.url, meta: it.meta, pending: it.pending) { _ in }
                .preferredColorScheme(theme.colorScheme)
        }
        .fullScreenCover(isPresented: $hub.isPresented) {
            GitHubHubScreen()
                .environmentObject(session)
                .preferredColorScheme(theme.colorScheme)
        }
        .sheet(isPresented: Binding(
            get: { nav.presentFairPlayKeysCapture },
            set: { nav.presentFairPlayKeysCapture = $0 }
        )) {
            FairPlayKeysCaptureSheet()
                .preferredColorScheme(theme.colorScheme)
        }
        .onOpenURL { url in
            handleAirShareDeepLink(url)
        }
        .onReceive(NotificationCenter.default.publisher(for: .airshareOpenDeepLink)) { note in
            guard let url = note.object as? URL else { return }
            handleAirShareDeepLink(url)
        }
        .alert("Couldn't read IPA", isPresented: Binding(get: { signError != nil }, set: { if !$0 { signError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(signError ?? "") }
    }

    /// Theme palette (top-left button) and account dropdown (username chip) — tap outside to close.
    @ViewBuilder private var dropdownLayer: some View {
        if theme.panelShown || account.panelShown {
            GeometryReader { g in
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.35).ignoresSafeArea()
                        .onTapGesture { theme.panelShown = false; account.panelShown = false }
                    if theme.panelShown {
                        ThemePanel()
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.accent.opacity(0.3), lineWidth: 1))
                            .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                            .padding(.leading, 12).padding(.top, g.safeAreaInsets.top + 54)
                            .transition(.scale(scale: 0.94, anchor: .topLeading).combined(with: .opacity))
                    }
                    if account.panelShown {
                        AccountDropdown()
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                            .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.trailing, 12).padding(.top, g.safeAreaInsets.top + 100)
                            .transition(.scale(scale: 0.94, anchor: .topTrailing).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .ignoresSafeArea()
        }
    }

    private func handleAirShareDeepLink(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        // Companion console is a separate IPA (`fastdecryptbot://`). Host only owns
        // `tetherless://` — bounce decrypt-companion deep links to Search, or Account
        // when unsigned so they can sign in for FairPlay / Purchases.
        if scheme == "tetherless"
            && (url.host?.lowercased() == "decrypt-companion" || url.host?.lowercased() == "companion") {
            if AppleIDStore.shared.isSignedIn {
                nav.goSearch()
            } else {
                nav.goStoreLogin()
            }
            return
        }
        // Companion finished FairPlay — import clear IPA from App Group into inbox / DecryptClient.
        if scheme == "tetherless",
           ["decrypt-export", "decrypt-import", "export"].contains(url.host?.lowercased() ?? "") {
            _ = DecryptCompanionHandoff.consumePendingClearIPAExport()
            nav.goSearch()
            return
        }
        // Companion hit ENOMEM / hard FairPlay fail — finish via Decrypt site URL (Mac / tetherless.dev).
        if scheme == "tetherless",
           ["decrypt-server", "server-decrypt", "server"].contains(url.host?.lowercased() ?? "") {
            _ = DecryptCompanionHandoff.consumePendingServerFallback()
            nav.goSearch()
            return
        }
        guard ["airshare", "msign", "tetherless", "sideloader"].contains(scheme) else { return }
        switch url.host?.lowercased() {
        case "activity", "signed":
            nav.goDownloads()
        case "updates", "pair":
            nav.goPair()
        case "import", "turbo", "files":
            nav.goFiles()
        case "library":
            nav.goLibrary()
        case "decrypt", "search":
            nav.goSearch()
        case "purchased":
            nav.goPurchased()
        case "downloads":
            nav.goDownloads()
        case "settings", "account":
            nav.goSettings()
        case "install":
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let id = components.queryItems?.first(where: { $0.name == "signedID" })?.value,
                  let entry = signed.entries.first(where: { $0.id == id }) else {
                signError = "The signed app from this notification is no longer available."
                return
            }
            Task {
                do {
                    LocalZSignAPI.shared.startIfNeeded()
                    try await Task.sleep(nanoseconds: 150_000_000)
                    try await OTAInstaller.shared.install(entry)
                } catch {
                    signError = error.localizedDescription
                }
            }
        default:
            break
        }
    }

    private func openSigningSheet(_ url: URL) {
        Task {
            do {
                let m = try await Task.detached { try IPAMeta.read(url) }.value
                signQueue.pending = nil
                signItem = SignItem(url: url, meta: m)
            } catch {
                signQueue.pending = nil
                signError = error.localizedDescription
            }
        }
    }
}

// MARK: - View Extensions

extension View {
    @ViewBuilder
    func then<Content: View>(@ViewBuilder _ transform: (Self) -> Content) -> Content {
        transform(self)
    }
}

// MARK: - GitHub hub (Import · Contents · Push · Build) presented from Settings

@MainActor
final class GitHubHub: ObservableObject {
    static let shared = GitHubHub()
    @Published var isPresented = false
    @Published var page = 0
    private init() {}

    func open(_ page: Int) { self.page = page; isPresented = true }
}

struct GitHubHubScreen: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @ObservedObject private var hub = GitHubHub.shared
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss

    private let pages: [(label: String, icon: String)] = [
        ("Import",   "tray.and.arrow.down.fill"),
        ("Contents", "folder.fill"),
        ("Push",     "arrow.up.circle.fill"),
        ("Build",    "hammer.fill"),
        ("Repos",    "book.closed.fill"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox.fill").foregroundStyle(Theme.accent)
                    Text("TETHERLESS").font(.system(size: 15, weight: .heavy, design: .rounded)).kerning(1).foregroundStyle(Theme.text)
                    Spacer()
                }
                Text("GitHub").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.subtle)
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 34).background(Theme.accent.opacity(0.14)).clipShape(Circle())
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .floatingGlassBar(edge: .top)

            // Segmented pages
            HStack(spacing: 6) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                    Button { hub.page = i } label: {
                        HStack(spacing: 4) {
                            Image(systemName: p.icon).font(.system(size: 11, weight: .semibold))
                            Text(p.label).font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.vertical, 8).frame(maxWidth: .infinity)
                        .background(hub.page == i ? Theme.accent.opacity(0.16) : Theme.card)
                        .foregroundStyle(hub.page == i ? Theme.accent : Theme.subtle)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(hub.page == i ? Theme.accent.opacity(0.5) : Theme.stroke, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.bg)

            ZStack {
                switch hub.page {
                case 0: ImportView()
                case 1: ContentsView()
                case 2: PushView()
                case 3: BuildView()
                default: RepoBrowseView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg.ignoresSafeArea())
        .onChange(of: session.lastEventID) { _ in hub.page = 1 }   // after an import/generate, show Contents
    }
}
