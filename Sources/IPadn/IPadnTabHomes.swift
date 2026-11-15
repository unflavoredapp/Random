//
//  IPadnTabHomes.swift
//  English Downloads / Purchased / Account tab roots modeled on mengangs/ipadn
//  DownloadsView, PurchasedView, AccountsView (GPL-2.0).
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Downloads

struct DownloadsHomeView: View {
    @ObservedObject private var decrypt = DecryptClient.shared
    @ObservedObject private var device = DeviceDecryptService.shared
    @ObservedObject private var signed = SignedStore.shared
    @State private var filter: DownloadFilterChip = .all
    @State private var term = ""
    @State private var pickingIPA = false

    private enum DownloadFilterChip: String, CaseIterable, Identifiable {
        case all, active, done, failed
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .active: return "Active"
            case .done: return "Completed"
            case .failed: return "Failed"
            }
        }
        var symbol: String {
            switch self {
            case .all: return "line.3.horizontal.decrease.circle"
            case .active: return "arrow.down.circle"
            case .done: return "checkmark.circle"
            case .failed: return "exclamationmark.triangle"
            }
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                IPadnPageHeader(title: "Downloads") {
                    Button {
                        pickingIPA = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.12), in: Circle())
                    }
                    .accessibilityLabel("Add IPA")
                }

                IPadnCapsuleSearch(
                    text: $term,
                    placeholder: "Filter downloads",
                    onSubmit: {}
                )

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(DownloadFilterChip.allCases) { chip in
                            Button {
                                filter = chip
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: chip.symbol).font(.caption.weight(.semibold))
                                    Text(chip.title).font(.subheadline.weight(.medium))
                                }
                                .foregroundStyle(filter == chip ? .white : .white.opacity(0.7))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 32)
                                .background(
                                    filter == chip ? TetherlessPalette.accent.opacity(0.9) : Color.white.opacity(0.10),
                                    in: Capsule()
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if showsActive {
                    activeJobCard
                }

                if !decrypt.history.isEmpty, filter == .all || filter == .done {
                    Text("Recent decrypts")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                    ForEach(filteredHistory) { item in
                        historyRow(item)
                        Divider().overlay(.white.opacity(0.08))
                    }
                }

                if !signed.entries.isEmpty, filter == .all || filter == .done {
                    Text("Signed installs")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.top, 8)
                    ForEach(filteredSigned.prefix(20)) { entry in
                        signedRow(entry)
                        Divider().overlay(.white.opacity(0.08))
                    }
                }

                if !showsActive && filteredHistory.isEmpty && filteredSigned.isEmpty {
                    emptyDownloads
                }

                Button {
                    AppNav.shared.goFiles()
                } label: {
                    Label("Open Files", systemImage: "folder.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TetherlessPalette.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: $pickingIPA) {
            DocPicker(types: [UTType(filenameExtension: "ipa") ?? .data]) { urls in
                guard let url = urls.first else { return }
                AppNav.shared.goSearch()
                DecryptClient.shared.pendingQuery = url.deletingPathExtension().lastPathComponent
            }
        }
    }

    private var showsActive: Bool {
        guard filter == .all || filter == .active || filter == .failed else { return false }
        if filter == .failed { return decrypt.phase == .failed }
        return decrypt.phase != .idle || decrypt.busy || device.busy
    }

    private var filteredHistory: [DecryptHistoryItem] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        return decrypt.history.filter {
            q.isEmpty
                || $0.name.localizedCaseInsensitiveContains(q)
                || $0.bundle.localizedCaseInsensitiveContains(q)
                || $0.version.localizedCaseInsensitiveContains(q)
        }
    }

    private var filteredSigned: [SignedEntry] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        return signed.entries.filter {
            q.isEmpty
                || $0.name.localizedCaseInsensitiveContains(q)
                || $0.bundleID.localizedCaseInsensitiveContains(q)
        }
    }

    @ViewBuilder private var activeJobCard: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(decrypt.phase == .failed ? "Failed" : "In progress")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if decrypt.phase != .failed, decrypt.phase != .done, decrypt.phase != .handedOff {
                        ProgressView().tint(TetherlessPalette.accent)
                    }
                }
                Text(decrypt.finishedName.isEmpty ? (decrypt.selected?.name ?? "Decrypt job") : decrypt.finishedName)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                Text(decrypt.message.isEmpty ? (decrypt.error ?? phaseLabel(decrypt.phase)) : decrypt.message)
                    .font(.caption)
                    .foregroundStyle(decrypt.phase == .failed ? .orange : .white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
                if decrypt.phase == .failed || decrypt.phase == .done || decrypt.phase == .handedOff {
                    Button("Dismiss") { decrypt.reset() }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    private func historyRow(_ item: DecryptHistoryItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.open.fill")
                .foregroundStyle(TetherlessPalette.accent)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.body.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                Text([item.version.isEmpty ? nil : "v\(item.version)", item.bundle]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer()
            IPadnGetCapsule(title: "Retry") {
                DecryptClient.shared.pendingQuery = item.name
                AppNav.shared.goSearch()
            }
        }
        .padding(.vertical, 4)
    }

    private func signedRow(_ entry: SignedEntry) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(TetherlessPalette.success)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name).font(.body.weight(.medium)).foregroundStyle(.white).lineLimit(1)
                Text(entry.bundleID)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer()
            Text("Signed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.vertical, 4)
    }

    private func phaseLabel(_ phase: DecryptClient.Phase) -> String {
        switch phase {
        case .idle: return "Idle"
        case .queued: return "Queued"
        case .running: return "Running"
        case .downloading: return "Downloading"
        case .done: return "Done"
        case .failed: return "Failed"
        case .handedOff: return "Handed off"
        }
    }

    private var emptyDownloads: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.35))
            Text("No downloads yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Search for a free or purchased app, or import an IPA. Progress and history show up here.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
            Button {
                AppNav.shared.goSearch()
            } label: {
                Text("Open Search")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(TetherlessPalette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

// MARK: - Purchased

struct PurchasedHomeView: View {
    @ObservedObject private var store = AppleIDStore.shared
    @ObservedObject private var decrypting = DeviceDecryptService.shared
    @State private var owned: [OwnedStoreApp] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var term = ""
    @State private var months = 0

    private var filtered: [OwnedStoreApp] {
        let q = term.trimmingCharacters(in: .whitespacesAndNewlines)
        return owned.filter {
            q.isEmpty
                || $0.name.localizedCaseInsensitiveContains(q)
                || $0.bundleId.localizedCaseInsensitiveContains(q)
                || "\($0.adamId)".contains(q)
        }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                IPadnPageHeader(title: "Purchased") {
                    Menu {
                        Button {
                            Task { await refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        Button {
                            AppNav.shared.goSettings()
                        } label: {
                            Label("Store Access", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.12), in: Circle())
                    }
                    .accessibilityLabel("More")
                }

                if store.isSignedIn {
                    IPadnCapsuleSearch(
                        text: $term,
                        placeholder: "Search purchases or App ID",
                        onSubmit: {}
                    )

                    Picker("Purchase window", selection: $months) {
                        Text("All").tag(0)
                        Text("1 mo").tag(1)
                        Text("6 mo").tag(6)
                        Text("1 yr").tag(12)
                    }
                    .pickerStyle(.segmented)

                    Text("Account: \(store.email)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))

                    if loading {
                        HStack {
                            ProgressView().tint(TetherlessPalette.accent)
                            Text("Loading purchase history…")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    } else if let loadError, !loadError.isEmpty {
                        Text(loadError)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Retry") { Task { await refresh() } }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(TetherlessPalette.accent)
                    } else if filtered.isEmpty {
                        emptyPurchased
                    } else {
                        Text("\(filtered.count) item\(filtered.count == 1 ? "" : "s")")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.white)
                        ForEach(filtered) { app in
                            IPadnDecryptAppRow(
                                app: app.asDecryptApp,
                                onGet: {
                                    DeviceDecryptService.shared.decryptFromSearch(app.asDecryptApp)
                                },
                                onVersions: {
                                    DecryptClient.shared.select(app.asDecryptApp)
                                    AppNav.shared.goSearch()
                                }
                            )
                            Divider().overlay(.white.opacity(0.08))
                        }
                    }
                } else {
                    Text("Sign in under Store Access to sync purchases and download apps you own.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.65))
                    Button {
                        AppNav.shared.goSettings()
                    } label: {
                        Text("Open Store Access")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(TetherlessPalette.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 120)
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await refresh() }
        .refreshable { await refresh() }
    }

    private var emptyPurchased: some View {
        VStack(spacing: 12) {
            Image(systemName: "bag")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.35))
            Text("No purchases listed")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Apple didn’t return items for this session, or the list is empty. Search still works for free and owned apps.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func refresh() async {
        // Purchase-window chips match iPadn UI; OwnedStoreApp has no date yet.
        _ = months
        guard store.isSignedIn else {
            owned = []
            return
        }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            owned = try await DeviceDecryptService.shared.ownedStoreApps()
        } catch {
            loadError = error.localizedDescription
            owned = []
        }
    }
}

// MARK: - Account (iPadn AccountsView English)

struct AccountHomeView: View {
    @ObservedObject private var store = AppleIDStore.shared
    @ObservedObject private var nav = AppNav.shared
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    IPadnPageHeader(title: "Account") {
                        EmptyView()
                    }

                    profileCard

                    sectionHeader("Apple ID")
                    accountRows

                    sectionHeader("Library")
                    navRow(.purchasedTab, title: "Purchased", symbol: "bag.fill")
                    navRow(.downloadsTab, title: "Downloads & install", symbol: "arrow.down.circle.fill")
                    pushRow(.library, title: "Installed & sources", symbol: "square.stack.3d.up.fill")
                    pushRow(.files, title: "Files", symbol: "folder.fill")

                    sectionHeader("Device")
                    pushRow(.pair, title: "Pair (native install)", symbol: "iphone.radiowaves.left.and.right")
                    pushRow(.settings, title: "Settings", symbol: "gearshape.fill")

                    if store.isSignedIn {
                        Button(role: .destructive) {
                            store.signOut()
                        } label: {
                            Text("Sign Out")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .foregroundStyle(.red)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 120)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationDestination(for: AppAccountPush.self) { dest in
                accountDestination(dest)
            }
            .onAppear { consumePendingAccountNav() }
            .onChange(of: nav.accountPush) { _ in consumePendingAccountNav() }
            .onChange(of: nav.openAccountScreen) { _ in consumePendingAccountNav() }
        }
    }

    private func consumePendingAccountNav() {
        if let dest = nav.accountPush {
            path.append(dest)
            nav.accountPush = nil
        }
        if nav.openAccountScreen {
            nav.openAccountScreen = false
            path.append(AppAccountPush.settings)
        }
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.white.opacity(0.35), Color.white.opacity(0.12)],
                        startPoint: .top, endPoint: .bottom))
                if store.isSignedIn {
                    Text(String(store.email.prefix(1)).uppercased())
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "person.fill")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 3) {
                if store.isSignedIn {
                    Text(store.email)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Store Access signed in")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    Text("Sign in with Apple ID")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Sync purchases and download apps you own")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder private var accountRows: some View {
        if store.accounts.isEmpty {
            Button {
                path.append(AppAccountPush.settings)
            } label: {
                Label("Add Apple ID — Store Access", systemImage: "plus")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
        } else {
            ForEach(store.accounts) { account in
                Button {
                    store.selectAccount(id: account.id)
                } label: {
                    HStack(spacing: 12) {
                        Text(String(account.email.prefix(1)).uppercased())
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.email)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        Spacer()
                        if account.id == store.activeAccountID {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(TetherlessPalette.accent)
                        }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button {
                path.append(AppAccountPush.settings)
            } label: {
                Label("Add account", systemImage: "plus")
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.vertical, 8)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white.opacity(0.4))
            .textCase(.uppercase)
            .padding(.top, 4)
    }

    private enum QuickLink { case purchasedTab, downloadsTab }

    private func navRow(_ link: QuickLink, title: String, symbol: String) -> some View {
        Button {
            switch link {
            case .purchasedTab: AppNav.shared.goPurchased()
            case .downloadsTab: AppNav.shared.goDownloads()
            }
        } label: {
            Label(title, systemImage: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }

    private func pushRow(_ dest: AppAccountPush, title: String, symbol: String) -> some View {
        Button {
            path.append(dest)
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func accountDestination(_ dest: AppAccountPush) -> some View {
        switch dest {
        case .pair:
            PairHomeView()
                .navigationTitle("Pair")
                .navigationBarTitleDisplayMode(.inline)
        case .files:
            FilesHomeView()
                .navigationTitle("Files")
                .navigationBarTitleDisplayMode(.inline)
        case .library:
            LibraryHomeView()
                .navigationTitle("Library")
                .navigationBarTitleDisplayMode(.inline)
        case .settings:
            SettingsView()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
