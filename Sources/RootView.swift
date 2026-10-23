//
//  RootView.swift
//  App shell. The app is a signer first: Browse (repo.json sources → apps →
//  IPA), Library (sign + install), Decrypt (lock — App Store IPAs via the AirShare backend), Signed (history), Settings. Handing an IPA to
//  SignQueue opens SigningSheet directly — there is no intermediate Sign screen. The GitHub
//  tools (Import · Contents · Push · Build · Repos) live behind Settings ›
//  GitHub as a full-screen hub.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject var session: Session
    @ObservedObject private var signQueue = SignQueue.shared
    @ObservedObject private var hub = GitHubHub.shared
    @ObservedObject private var theme = AppTheme.shared
    @ObservedObject private var account = ZefvAccount.shared
    @ObservedObject private var nav = AppNav.shared
    @ObservedObject private var onboarding = Onboarding.shared
    @ObservedObject private var signed = SignedStore.shared
    @State private var tab = 0
    @State private var signItem: SignItem?
    @State private var signError: String?

    /// An IPA handed to the shell for signing — goes straight into SigningSheet.
    private struct SignItem: Identifiable {
        let url: URL
        let meta: IPAMeta
        var id: String { url.path }
    }

    var body: some View {
        ZStack {
            switch tab {
            case 0: SourcesView()
            case 1: LibraryView()
            case 2: DecryptView()
            case 3: SignedView()
            default: SettingsView()
            }
        }
        .id(theme.revision)                                   // re-skin every tab on a theme change
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .simultaneousGesture(                                 // finger drives the particle layer (grab / repulse / attract + tap burst)
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { ParticleTouch.point = $0.location }
                .onEnded { v in
                    ParticleTouch.point = nil
                    if abs(v.translation.width) < 8 && abs(v.translation.height) < 8 {
                        ParticleTouch.pulse = (v.location, Date.timeIntervalSinceReferenceDate)
                    }
                }
        )
        .overlay(ThemeBackgroundLayer())                      // particle/grid network floats over the tab content
        .overlay { dropdownLayer }                            // palette + account dropdowns
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: theme.panelShown)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: account.panelShown)

        .task {
            theme.startCycleIfNeeded()
            Task.detached(priority: .utility) { try? await Task.sleep(nanoseconds: 8_000_000_000); await StorageCleaner.run() }
            Task { _ = await LibraryCache.shared.refresh() }   // Library is ready before you open it
            await SourceStore.shared.warmUpAtLaunch()
            WidgetDataManager.shared.refresh()
            _ = await PortalStorage.cleanupStaleTemporaryFiles()
            await LocalSourceUpdateWatcher.shared.scanAllSources(reason: "launch")
        }
        .onChange(of: signed.entries) { _ in
            WidgetDataManager.shared.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await LocalSourceUpdateWatcher.shared.scanAllSources(reason: "foreground") }
        }   // repos parsed from disk instantly, refreshed in background
        .onChange(of: nav.requestedTab) { t in
            guard let t else { return }
            nav.requestedTab = nil
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { tab = t }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            TabBar(selected: $tab)
        }
        .background(Theme.bg.ignoresSafeArea())
        .tint(Theme.accent)
        .preferredColorScheme(theme.colorScheme)
        .onChange(of: signQueue.requestedTab) { t in
            // Signing is a flow, not a tab: open SigningSheet directly over whatever's showing.
            guard t != nil else { return }
            signQueue.requestedTab = nil
            if let url = signQueue.pending { openSigningSheet(url) }
        }
        .fullScreenCover(item: $signItem) { it in
            SigningSheet(ipaURL: it.url, meta: it.meta) { _ in }
                .preferredColorScheme(theme.colorScheme)
        }
        .fullScreenCover(isPresented: $hub.isPresented) {
            GitHubHubScreen()
                .environmentObject(session)
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
        .fullScreenCover(isPresented: $onboarding.needsOnboarding) {
            OnboardingView { onboarding.complete() }
        }
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
        guard ["airshare", "msign"].contains(url.scheme?.lowercased() ?? "") else { return }
        switch url.host?.lowercased() {
        case "activity":
            nav.go(3)
        case "updates":
            nav.go(0)
        case "import", "turbo":
            nav.go(1)
        case "decrypt":
            nav.go(2)
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

// MARK: - Tab bar

private struct TabBar: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @Binding var selected: Int
    private let tabs: [(label: String, icon: String)] = [
        ("Browse",   "square.grid.3x3.fill"),
        ("Library",  "square.grid.2x2.fill"),
        ("Decrypt",  "lock.fill"),
        ("Signed",   "signature"),
        ("Settings", "gearshape"),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { i, t in
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selected = i }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: t.icon).font(.system(size: 21, weight: .regular))
                            .frame(height: 25)
                        Text(t.label).font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(selected == i ? Theme.accent : Theme.subtle)
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .floatingGlassBar(edge: .bottom, cornerRadius: 30)
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
                    Text("UNZIP DROP").font(.system(size: 15, weight: .heavy, design: .rounded)).kerning(1).foregroundStyle(Theme.text)
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
