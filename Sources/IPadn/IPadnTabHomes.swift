//
//  IPadnTabHomes.swift
//  English Purchased + Account tab roots modeled on mengangs/ipadn
//  PurchasedView / AccountsView (GPL-2.0). Downloads live in IPadnDownloadsView.
//

import SwiftUI

// MARK: - Purchased

struct PurchasedHomeView: View {
    @ObservedObject private var store = AppleIDStore.shared
    @ObservedObject private var manager = IPadnDownloadManager.shared
    @State private var owned: [OwnedStoreApp] = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var term = ""
    @State private var query = ""
    @State private var months = 0
    @State private var selecting = false
    @State private var selection = Set<Int>()
    @State private var batchProgress: (done: Int, total: Int)?
    @State private var path = NavigationPath()

    private var filtered: [OwnedStoreApp] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? .distantPast
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return owned.filter {
            (months == 0 || ($0.purchaseDate ?? .distantPast) >= cutoff)
                && (q.isEmpty
                    || $0.name.localizedCaseInsensitiveContains(q)
                    || $0.bundleId.localizedCaseInsensitiveContains(q)
                    || "\($0.adamId)".contains(q))
        }
    }

    private var downloadBadges: [Int: (text: String, tint: Color)] {
        var badges: [Int: (text: String, tint: Color)] = [:]
        for job in manager.jobs where job.status == .completed {
            guard let adam = job.adamId else { continue }
            if badges[adam] == nil {
                badges[adam] = (
                    job.version.isEmpty ? "Downloaded" : "Downloaded \(job.version)",
                    TetherlessPalette.success
                )
            }
        }
        return badges
    }

    var body: some View {
        NavigationStack(path: $path) {
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

                        if loading && owned.isEmpty {
                            HStack {
                                ProgressView().tint(TetherlessPalette.accent)
                                Text("Syncing purchase history…")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        } else if let loadError, !loadError.isEmpty {
                            Text(loadError)
                                .font(.footnote)
                                .foregroundStyle(.orange)
                            Button("Retry") { Task { await refresh() } }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(TetherlessPalette.accent)
                        } else if filtered.isEmpty {
                            emptyPurchased
                        } else {
                            let badges = downloadBadges
                            HStack {
                                Text("\(filtered.count) item\(filtered.count == 1 ? "" : "s")")
                                    .font(.title3.weight(.bold))
                                    .foregroundStyle(.white)
                                Spacer()
                                Button(selecting ? "Done" : "Select") {
                                    withAnimation {
                                        selecting.toggle()
                                        selection.removeAll()
                                    }
                                }
                                .font(.body.weight(.semibold))
                                .foregroundStyle(TetherlessPalette.accent)
                                .disabled(batchProgress != nil)
                            }

                            ForEach(filtered) { app in
                                purchasedRow(app, badge: badges[app.adamId])
                                Divider().overlay(.white.opacity(0.08))
                            }
                        }
                    } else {
                        Text("Sign in with Apple Account to sync purchases and download apps you own.")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.65))
                        Button {
                            AppNav.shared.goStoreLogin()
                        } label: {
                            Text("Sign In")
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
            .navigationDestination(for: IPadnStoreApp.self) { app in
                IPadnAppDetailView(app: app)
            }
            .task { await refresh() }
            .refreshable { await refresh() }
            .task(id: term) {
                if !term.isEmpty { try? await Task.sleep(nanoseconds: 250_000_000) }
                guard !Task.isCancelled else { return }
                query = term
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    selectBar
                }
            }
        }
    }

    @ViewBuilder private func purchasedRow(_ app: OwnedStoreApp, badge: (text: String, tint: Color)?) -> some View {
        let subtitle = app.purchaseDate.map {
            "Purchased on \($0.formatted(.dateTime.year().month(.defaultDigits).day()))"
        }
        if selecting {
            Button {
                if selection.contains(app.adamId) { selection.remove(app.adamId) }
                else { selection.insert(app.adamId) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selection.contains(app.adamId) ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(selection.contains(app.adamId) ? TetherlessPalette.accent : .white.opacity(0.35))
                    purchasedContent(app, subtitle: subtitle, badge: badge, showCloud: false)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Button {
                path.append(app.asIPadnStoreApp)
            } label: {
                purchasedContent(app, subtitle: subtitle, badge: badge, showCloud: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func purchasedContent(
        _ app: OwnedStoreApp,
        subtitle: String?,
        badge: (text: String, tint: Color)?,
        showCloud: Bool
    ) -> some View {
        HStack(spacing: 14) {
            AsyncImage(url: app.iconURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay { Image(systemName: "app.fill").foregroundStyle(.white.opacity(0.35)) }
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                }
                if let badge {
                    Text(badge.text)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(badge.tint)
                }
            }
            Spacer(minLength: 0)
            if showCloud {
                Button {
                    try? manager.enqueueStore(owned: app)
                    AppNav.shared.goDownloads()
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.title2)
                        .foregroundStyle(TetherlessPalette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Download \(app.name)")
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.vertical, 4)
    }

    private var selectBar: some View {
        HStack(spacing: 12) {
            let visible = filtered
            let allSelected = !visible.isEmpty && visible.allSatisfy { selection.contains($0.adamId) }
            Button(allSelected ? "Deselect All" : "Select All") {
                if allSelected { selection.subtract(visible.map(\.adamId)) }
                else { selection.formUnion(visible.map(\.adamId)) }
            }
            .disabled(visible.isEmpty || batchProgress != nil)
            Spacer()
            if let batchProgress {
                ProgressView()
                Text("Adding \(batchProgress.done)/\(batchProgress.total)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                Button {
                    downloadSelected()
                } label: {
                    Text(selection.isEmpty ? "Download Selected" : "Download Selected (\(selection.count))")
                        .fontWeight(.semibold)
                }
                .disabled(selection.isEmpty)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
        .padding(.bottom, 56)
    }

    private var emptyPurchased: some View {
        VStack(spacing: 12) {
            Image(systemName: "bag")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.35))
            Text(term.isEmpty && months == 0 ? "No purchase history" : "No matching apps")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(term.isEmpty && months == 0
                 ? "After sync you can find and download apps you’ve acquired."
                 : "Try another keyword or purchase window.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
            if !term.isEmpty || months != 0 {
                Button("Clear Filters") { term = ""; query = ""; months = 0 }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
            } else {
                Button("Sync Now") { Task { await refresh() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func downloadSelected() {
        let apps = owned.filter { selection.contains($0.adamId) }
        guard !apps.isEmpty, batchProgress == nil else { return }
        batchProgress = (0, apps.count)
        Task {
            var done = 0
            for app in apps {
                try? manager.enqueueStore(owned: app)
                done += 1
                batchProgress = (done, apps.count)
            }
            batchProgress = nil
            selection.removeAll()
            selecting = false
            AppNav.shared.goDownloads()
        }
    }

    private func refresh() async {
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

// MARK: - Account

struct AccountHomeView: View {
    @ObservedObject private var store = AppleIDStore.shared
    @ObservedObject private var nav = AppNav.shared
    @State private var path = NavigationPath()
    @State private var showIPadnLogin = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    IPadnPageHeader(title: "Account") { EmptyView() }

                    profileCard

                    sectionHeader("Apple ID")
                    accountRows

                    sectionHeader("Library")
                    navRow(.purchasedTab, title: "Purchased", symbol: "bag.fill")
                    navRow(.downloadsTab, title: "Downloads & installation", symbol: "arrow.down.circle.fill")
                    pushRow(.library, title: "Apps on this device", symbol: "iphone")
                    pushRow(.files, title: "Files", symbol: "folder.fill")

                    sectionHeader("Device")
                    pushRow(.installation, title: "Installation settings", symbol: "wrench.and.screwdriver")
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
            .sheet(isPresented: $showIPadnLogin) {
                IPadnLoginView {
                    showIPadnLogin = false
                    nav.presentIPadnLogin = false
                }
            }
            .onAppear { consumePendingAccountNav() }
            .onChange(of: nav.accountPush) { _ in consumePendingAccountNav() }
            .onChange(of: nav.openAccountScreen) { _ in consumePendingAccountNav() }
            .onChange(of: nav.presentIPadnLogin) { open in
                if open { showIPadnLogin = true }
            }
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
        if nav.presentIPadnLogin {
            showIPadnLogin = true
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
                    Text("Sync purchases and download apps you’re licensed to use")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                } else {
                    Text("Sign in to your Apple Account")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Sync purchases and download apps you’re licensed to use")
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
                showIPadnLogin = true
            } label: {
                Label("Sign in to Apple Account", systemImage: "plus")
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
                        Text(account.email)
                            .foregroundStyle(.white)
                            .lineLimit(1)
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
            Text("Tap to switch the download account.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))
            Button {
                showIPadnLogin = true
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
                .navigationTitle("Apps on this device")
                .navigationBarTitleDisplayMode(.inline)
        case .settings:
            SettingsView()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
        case .installation:
            IPadnInstallationSettingsView()
        }
    }
}
