//
// Brand: Tetherless · https://tetherless.dev
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
    @State private var showSearch = false

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
        for job in manager.jobs {
            guard let adam = job.adamId else { continue }
            if badges[adam] != nil { continue }
            switch job.status {
            case .queued, .running, .pausing:
                badges[adam] = ("Downloading…", TetherlessPalette.accent)
            case .processing:
                badges[adam] = ("Companion…", TetherlessPalette.accent)
            case .completed:
                badges[adam] = (
                    job.version.isEmpty ? "Decrypted" : "Decrypted \(job.version)",
                    TetherlessPalette.success
                )
            case .failed:
                badges[adam] = ("Failed", .orange)
            case .paused:
                badges[adam] = ("Paused", .white.opacity(0.5))
            }
        }
        return badges
    }

    var body: some View {
        NavigationStack(path: $path) {
            IPadnBlurNavScroll(title: "Purchased") {
                purchasedTrailing
            } content: {
                if store.isSignedIn {
                    if showSearch {
                        IPadnCapsuleSearch(
                            text: $term,
                            placeholder: "Search purchases or App ID",
                            onSubmit: {},
                            onClear: {
                                term = ""
                                query = ""
                            }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Picker("Purchase window", selection: $months) {
                        Text("All").tag(0)
                        Text("1 mo").tag(1)
                        Text("6 mo").tag(6)
                        Text("1 yr").tag(12)
                    }
                    .pickerStyle(.segmented)

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

    private var purchasedTrailing: some View {
        HStack(spacing: 8) {
            if store.isSignedIn {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSearch.toggle()
                        if !showSearch {
                            term = ""
                            query = ""
                        }
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(showSearch ? TetherlessPalette.accent : .white)
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(showSearch ? 0.18 : 0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showSearch ? "Hide search" : "Search purchases")
            }

            Menu {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                Button {
                    AppNav.shared.goAccount()
                } label: {
                    Label("Account", systemImage: "person.crop.circle")
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
            CachedIcon(url: app.iconURL, side: 56, fallback: app.name)

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
                    IPadnDecryptPipeline.getOwned(app)
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
                IPadnDecryptPipeline.getOwned(app, openDownloads: false)
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

private enum AccountAuthSheet: String, Identifiable {
    case appleID
    case storeUnlock
    var id: String { rawValue }
}

/// Always-on FairPlay keys row for Account — status + live install path stamp.
private struct AccountFairPlayKeysSection: View {
    @ObservedObject private var store = AppleIDStore.shared
    @ObservedObject private var keys = FairPlayKeysFetcher.shared
    @State private var probedLivePath: (path: String, bundleID: String)?
    @State private var probingLive = false
    @State private var livePathHint =
        "Live install path: (none yet — stamp appears after Get, or tap Probe)"

    private var email: String {
        store.email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var statusLine: String {
        if !store.isSignedIn { return "Sign in under Sign-in first" }
        if case .grabbed(_, let at, let readiness) = keys.phase {
            let when = at.formatted(date: .abbreviated, time: .shortened)
            return "Keys ready · \(readiness.storeApps) app(s) · \(readiness.scInfoHits) SC_Info · \(when)"
        }
        if AppStoreDecryptGuide.isAcknowledged(email: email), !email.isEmpty {
            return "Keys acknowledged for \(email)"
        }
        if case .confirmSignIn = keys.phase { return "Confirm keys after Media & Purchases…" }
        if keys.isWaiting { return "Capturing FairPlay keys…" }
        return "Capture FairPlay keys for companion decrypt"
    }

    var body: some View {
        Section {
            Button {
                FairPlayKeysFetcher.shared.presentCaptureSheet()
            } label: {
                Label("FairPlay keys…", systemImage: "key.fill")
            }
            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let live = DecryptCompanionHandoff.readLiveInstallPath() {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live install path (stamped)")
                        .font(.caption.weight(.semibold))
                    Text(live.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if !live.bundleID.isEmpty {
                        Text(live.bundleID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            } else if let probed = probedLivePath {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Live install path (probed)")
                        .font(.caption.weight(.semibold))
                    Text(probed.path)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if !probed.bundleID.isEmpty {
                        Text(probed.bundleID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            } else {
                Text(livePathHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Probe live install path…") {
                Task { await probeLiveInstallPath() }
            }
            .font(.caption.weight(.semibold))
            .disabled(probingLive)
        } header: {
            Text("FairPlay keys")
        } footer: {
            Text("Keys stay on this iPhone. The stamp appears after a successful Get. If the app is installed but path stays empty, Pair Native and refresh Installed — LaunchServices alone often can’t see Store containers on free/dev certs.")
        }
        .onAppear {
            keys.refreshFromAck()
            Task { await probeLiveInstallPath() }
        }
        .onChange(of: store.email) { _ in keys.refreshFromAck() }
    }

    private func probeLiveInstallPath() async {
        probingLive = true
        defer { probingLive = false }
        // Prefer selected Search/Downloads target, then last stamped bid, then first library DRM app.
        let selectedBid = (DecryptClient.shared.selected?.bundle ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stampedBid = (DecryptCompanionHandoff.readLiveInstallPath()?.bundleID
            ?? DecryptCompanionHandoff.readEncryptedIPAPath()?.bundleID
            ?? DecryptCompanionHandoff.readTargetStamp()?.bundleID
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let libraryBid = DeviceLibrary.shared.apps.first {
            $0.isDecryptTarget(includeTestFlight: FairPlayAdvancedOptions.includeTestFlightApps)
        }?.bundleID ?? ""
        let bid = [selectedBid, stampedBid, libraryBid].first { !$0.isEmpty } ?? ""
        guard !bid.isEmpty else {
            probedLivePath = nil
            livePathHint = "Live install path: (none — pick an app on Search/Get, or Pair + refresh Installed)"
            return
        }
        if let live = await FairPlayKeyGate.resolveLiveInstallURL(bundleID: bid) {
            probedLivePath = (live.path, bid)
            DecryptCompanionHandoff.publishLiveInstallPath(live.path, bundleID: bid)
            livePathHint = "Live install path found for \(bid)"
        } else {
            probedLivePath = nil
            let paired = DevicePairingStore.hasSavedPairing
            livePathHint = paired
                ? "Live install path: (none for \(bid) — install from App Store if missing, then refresh Installed)"
                : "Live install path: (none for \(bid) — Pair Native so installd Path is visible)"
        }
    }
}

struct AccountHomeView: View {
    @ObservedObject private var store = AppleIDStore.shared
    @ObservedObject private var nav = AppNav.shared
    @State private var path = NavigationPath()
    /// One sheet at a time — never stack Apple ID + Store (iOS double-sheet).
    @State private var authSheet: AccountAuthSheet?
    /// Tracks which sheet just closed so Store handoff only follows Apple ID.
    @State private var lastAuthSheet: AccountAuthSheet?
    @State private var appleIDExpanded = true
    @State private var settingsStatus: String?

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    profileCard
                }

                Section {
                    DisclosureGroup(isExpanded: $appleIDExpanded) {
                        accountRows
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.fill")
                                .font(.title3)
                                .foregroundStyle(TetherlessPalette.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apple ID")
                                    .font(.body.weight(.semibold))
                                if store.isSignedIn {
                                    Text(store.email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                } else {
                                    Text("Sign in to sync purchases")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                // Sole Sign-in UI — Apple ID sheet + Store sheet only (nothing else).
                Section {
                    Button {
                        AppNav.shared.goAppleIDLogin()
                    } label: {
                        Label(
                            store.authPhase == .awaitingTwoFactor
                                ? "Continue Apple ID verification…"
                                : "Apple ID login…",
                            systemImage: "person.badge.key.fill"
                        )
                    }
                    Button {
                        AppNav.shared.goStoreUnlock()
                    } label: {
                        Label("Show Store login…", systemImage: "lock.open.fill")
                    }
                    .disabled(!store.isSignedIn && store.authPhase != .awaitingTwoFactor)
                    if let status = store.statusMessage, !status.isEmpty {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Sign-in")
                } footer: {
                    Text("Apple ID and Store each open their own sheet. FairPlay keys cannot be exported into FastDecryptBot — enroll Media & Purchases on this iPhone, then Confirm keys.")
                }

                // Always-visible FairPlay keys status (not buried under FairPlay advanced).
                AccountFairPlayKeysSection()

                // Settings root (was LIBRARY / DEVICE → Settings push).
                IPadnSettingsRootSections(statusMessage: $settingsStatus)

                if store.isSignedIn {
                    Section {
                        Button(role: .destructive) {
                            store.signOut()
                        } label: {
                            Text("Sign Out")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.large)
            // Keep Form rows above the floating tab bar.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: 100)
            }
            .alert("Settings", isPresented: Binding(
                get: { settingsStatus != nil },
                set: { if !$0 { settingsStatus = nil } }
            )) {
                Button("OK", role: .cancel) { settingsStatus = nil }
            } message: {
                Text(settingsStatus ?? "")
            }
            .navigationDestination(for: AppAccountPush.self) { dest in
                accountDestination(dest)
            }
            .sheet(item: $authSheet, onDismiss: {
                nav.presentIPadnLogin = false
                nav.presentStoreUnlock = false
                let closed = lastAuthSheet
                lastAuthSheet = nil
                // Only chain Store after Apple ID — never re-open Store on its own dismiss.
                if closed == .appleID {
                    scheduleStoreUnlockIfNeeded()
                }
            }) { sheet in
                switch sheet {
                case .appleID:
                    IPadnLoginView(
                        initialAccountID: store.authPhase == .awaitingTwoFactor
                            ? loginSeedAccountID
                            : nil
                    ) {
                        authSheet = nil
                    }
                case .storeUnlock:
                    IPadnStoreUnlockSheet {
                        authSheet = nil
                    }
                }
            }
            .onAppear {
                consumePendingAccountNav()
            }
            .onChange(of: nav.accountPush) { _ in consumePendingAccountNav() }
            .onChange(of: nav.openAccountScreen) { _ in consumePendingAccountNav() }
            .onChange(of: nav.presentIPadnLogin) { open in
                if open { presentAuthSheet(.appleID) }
            }
            .onChange(of: nav.presentStoreUnlock) { open in
                if open { presentAuthSheet(.storeUnlock) }
            }
        }
    }

    /// Prefer draft / active email so a re-opened 2FA sheet is not blank (`for ""`).
    private var loginSeedAccountID: String? {
        let candidates = [store.draftEmail, store.email]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return candidates.first
    }

    /// Exclusive presenter — replaces any open auth sheet; clears AppNav request flags.
    private func presentAuthSheet(_ sheet: AccountAuthSheet) {
        nav.presentIPadnLogin = false
        nav.presentStoreUnlock = false
        lastAuthSheet = sheet
        authSheet = sheet
    }

    /// After Step 1 dismisses, open Step 2 only if Store still needs its own Allow+code.
    private func scheduleStoreUnlockIfNeeded() {
        guard store.isSignedIn, store.storeNeedsVerification else { return }
        guard authSheet == nil else { return }
        Task { @MainActor in
            // Let the Step 1 sheet finish dismissing so the second Allow cannot stack.
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard store.isSignedIn, store.storeNeedsVerification else { return }
            guard authSheet == nil else { return }
            lastAuthSheet = .storeUnlock
            authSheet = .storeUnlock
        }
    }

    private func consumePendingAccountNav() {
        if let dest = nav.accountPush {
            // Settings live on Account root now — pop to root instead of pushing a duplicate.
            if dest == .settings {
                path = NavigationPath()
            } else {
                path.append(dest)
            }
            nav.accountPush = nil
        }
        if nav.openAccountScreen {
            nav.openAccountScreen = false
            path = NavigationPath()
        }
        if nav.presentIPadnLogin {
            presentAuthSheet(.appleID)
        } else if nav.presentStoreUnlock {
            presentAuthSheet(.storeUnlock)
        }
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.primary.opacity(0.22), Color.primary.opacity(0.08)],
                        startPoint: .top, endPoint: .bottom))
                if store.isSignedIn {
                    Text(String(store.email.prefix(1)).uppercased())
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                } else {
                    Image(systemName: "person.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 3) {
                Text(store.isSignedIn ? "Apple Account" : "Sign in to your Apple Account")
                    .font(.title3.weight(.semibold))
                Text("Sync purchases and download apps you’re licensed to use")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var accountRows: some View {
        if store.accounts.isEmpty {
            Button {
                presentAuthSheet(.appleID)
            } label: {
                Label("Sign in to Apple Account", systemImage: "plus")
            }
        } else {
            ForEach(store.accounts) { account in
                Button {
                    store.selectAccount(id: account.id)
                } label: {
                    HStack(spacing: 12) {
                        Text(String(account.email.prefix(1)).uppercased())
                            .font(.caption.weight(.bold))
                            .frame(width: 36, height: 36)
                            .background(Color.primary.opacity(0.08), in: Circle())
                        Text(account.email)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Spacer()
                        if account.id == store.activeAccountID {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(TetherlessPalette.accent)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text("Tap to switch the download account.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                presentAuthSheet(.appleID)
            } label: {
                Label("Add account", systemImage: "plus")
            }
        }
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
            // Settings are inline on Account; keep destination for older deep links.
            IPadnSettingsView()
        case .installation:
            IPadnInstallationSettingsView()
        }
    }
}
