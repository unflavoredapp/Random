import SwiftUI
import UniformTypeIdentifiers

// MARK: - Store Access (multi-account)

struct SettingsAppleIDCard: View {
    @ObservedObject private var store = AppleIDStore.shared
    @State private var email = ""
    @State private var password = ""
    @State private var twoFACode = ""
    @State private var showPassword = false
    @State private var showManage = false
    @State private var showAddAccount = false
    @State private var accountPendingDelete: AppleIDAccount?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Store Access")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                if store.hasAnyAccount {
                    Button("Manage") { showManage = true }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TetherlessPalette.accent)
                        .buttonStyle(.plain)
                }
            }

            Text("Add multiple Apple IDs for free App Store installs and decrypt. Switch accounts per download. For decrypt, each Apple ID must also have signed in to this iPhone’s App Store at least once so iOS has its decryption keys.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            Button { AppStoreDecryptGuide.openAppStore() } label: {
                Label("Open App Store to sign in once", systemImage: "bag.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
            }
            .buttonStyle(.plain)

            if store.accounts.isEmpty {
                emptySignIn
            } else {
                accountList
                Button {
                    showAddAccount = true
                } label: {
                    Label("Add Apple ID", systemImage: "plus.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TetherlessPalette.accent)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

            if let err = store.lastError, !err.isEmpty {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .tetherlessGlassCard(cornerRadius: 22)
        .sheet(isPresented: $showManage) {
            NavigationStack {
                AppleIDManageView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showManage = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showAddAccount) {
            NavigationStack {
                addAccountForm
                    .padding(20)
                    .navigationTitle("Add Apple ID")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showAddAccount = false; store.cancelTwoFactor() }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .confirmationDialog(
            "Remove Apple ID?",
            isPresented: Binding(
                get: { accountPendingDelete != nil },
                set: { if !$0 { accountPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let a = accountPendingDelete { store.removeAccount(id: a.id) }
                accountPendingDelete = nil
            }
            Button("Cancel", role: .cancel) { accountPendingDelete = nil }
        } message: {
            if let a = accountPendingDelete {
                Text("Remove \(a.email) from Store Access on this device.")
            }
        }
    }

    private var emptySignIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            glassField("Apple ID", text: $email, secure: false)
            HStack(spacing: 10) {
                glassField(showPassword ? "Password" : "Password", text: $password, secure: !showPassword)
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 44, height: 44)
                        .background(Color.black.opacity(0.28), in: Circle())
                }
                .buttonStyle(.plain)
            }
            if store.authPhase == .awaitingTwoFactor {
                twoFactorBlock
            } else {
                primaryButton(store.isBusy ? "Signing In…" : "Sign In") {
                    Task { await store.signIn(email: email, password: password) }
                }
                .disabled(store.isBusy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                .opacity(store.isBusy ? 0.7 : 1)
            }
        }
    }

    private var addAccountForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Sign in with another Apple ID. Each account can install and decrypt apps independently.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.6))
            glassField("Apple ID", text: $email, secure: false)
            glassField("Password", text: $password, secure: true)
            if store.authPhase == .awaitingTwoFactor {
                twoFactorBlock
            } else {
                primaryButton(store.isBusy ? "Signing In…" : "Add Account") {
                    Task {
                        await store.signIn(email: email, password: password)
                        if store.authPhase == .idle, store.lastError == nil {
                            showAddAccount = false
                            email = ""; password = ""; twoFACode = ""
                        }
                    }
                }
                .disabled(store.isBusy || email.isEmpty || password.isEmpty)
            }
            Spacer()
        }
    }

    private var twoFactorBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Enter the verification code from a trusted device.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.65))
            TextField("6-digit code", text: $twoFACode)
                .keyboardType(.numberPad)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(Color.black.opacity(0.28), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
            HStack(spacing: 10) {
                primaryButton(store.isBusy ? "Verifying…" : "Verify") {
                    Task {
                        await store.submitTwoFactor(code: twoFACode)
                        if store.authPhase == .idle, store.lastError == nil {
                            showAddAccount = false
                            email = ""; password = ""; twoFACode = ""
                        }
                    }
                }
                .disabled(store.isBusy || twoFACode.count < 4)
                secondaryButton("Cancel", busy: false) {
                    store.cancelTwoFactor()
                    twoFACode = ""
                }
            }
        }
    }

    private var accountList: some View {
        VStack(spacing: 10) {
            ForEach(store.accounts) { account in
                HStack(spacing: 12) {
                    Button {
                        store.selectAccount(id: account.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: store.activeAccountID == account.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(store.activeAccountID == account.id ? TetherlessPalette.accent : .white.opacity(0.35))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.email)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(account.statusLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                            Spacer(minLength: 4)
                        }
                    }
                    .buttonStyle(.plain)

                    Menu {
                        Button("Set Active") { store.selectAccount(id: account.id) }
                        Button("Manage") {
                            store.selectAccount(id: account.id)
                            showManage = true
                        }
                        Button("Remove", role: .destructive) { accountPendingDelete = account }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            store.activeAccountID == account.id ? TetherlessPalette.accent.opacity(0.55) : .white.opacity(0.08),
                            lineWidth: 1
                        )
                )
            }
        }
    }

    private func glassField(_ placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure {
                SecureField(placeholder, text: text)
            } else {
                TextField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Color.black.opacity(0.28), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(TetherlessPalette.accent, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(_ title: String, busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if busy {
                ProgressView().tint(.white)
            } else {
                Text(title).font(.body.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(.white.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }
}


@MainActor
final class AppUpdateChecker: ObservableObject {
    static let shared = AppUpdateChecker()

    @Published private(set) var remoteVersion: String?
    @Published private(set) var downloadURL: URL?
    @Published private(set) var checking = false
    @Published private(set) var message: String?

    var localVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? Theme.appVersion
    }

    var updateAvailable: Bool {
        guard let remote = remoteVersion else { return false }
        return VersionCompare.isNewer(remote: remote, than: localVersion)
    }

    func refresh() async {
        checking = true
        defer { checking = false }
        do {
            guard let url = URL(string: "https://api.github.com/repos/unflavoredapp/Random/releases/latest") else { return }
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            // GitHub requires a User-Agent; without it the API returns 403 and we show "Couldn't check".
            req.setValue("TetherLess/\(localVersion)", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                message = status == 403 || status == 429
                    ? "Update check rate-limited. Try again shortly."
                    : "Couldn't check for updates."
                return
            }
            let tag = ((obj["tag_name"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            remoteVersion = tag.isEmpty ? nil : tag
            if let html = obj["html_url"] as? String { downloadURL = URL(string: html) }
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }
}

struct SettingsSoftwareUpdateCard: View {
    @ObservedObject private var checker = AppUpdateChecker.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        GlassCard(corner: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(Color.green.opacity(0.9))
                        Image(systemName: "arrow.down")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Software Update")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                        if checker.updateAvailable, let remote = checker.remoteVersion {
                            Text("Version \(remote) is available. You're on \(checker.localVersion).")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                        } else if checker.checking {
                            Text("Checking for updates…")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                        } else {
                            Text("You're on the latest version (\(checker.localVersion)).")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }

                if checker.updateAvailable, let remote = checker.remoteVersion {
                    Button {
                        if let u = checker.downloadURL { openURL(u) }
                    } label: {
                        Text("Download \(remote)")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(TetherlessPalette.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        Task { await checker.refresh() }
                    } label: {
                        if checker.checking {
                            ProgressView().tint(.white)
                        } else {
                            Text("Check for Updates")
                                .font(.body.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    .disabled(checker.checking)
                }

                if let message = checker.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .task { await checker.refresh() }
    }
}

// MARK: - Glass nav row + toggles

struct SettingsGlassNavRow: View {
    let systemImage: String
    var tint: Color = TetherlessPalette.accent
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassCard(corner: 22) {
                HStack(spacing: 14) {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.headline.weight(.semibold)).foregroundStyle(.white)
                        Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.55)).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct SettingsToggleCard: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        GlassCard(corner: 22) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline.weight(.semibold)).foregroundStyle(.white)
                    Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $isOn)
                    .labelsHidden()
                    .tint(TetherlessPalette.accent)
            }
        }
    }
}

struct SettingsDisableNotificationsRow: View {
    @AppStorage("msign.installReadyNotifications") private var installReadyNotifications = true

    private var disabledBinding: Binding<Bool> {
        Binding(
            get: { !installReadyNotifications },
            set: { newValue in
                installReadyNotifications = !newValue
                LocalSourceUpdateWatcher.shared.setNotificationsEnabled(!newValue)
            }
        )
    }

    var body: some View {
        SettingsToggleCard(
            title: "Disable Notifications",
            subtitle: "Turns off every notification this app sends, including the pairing PIN.",
            isOn: disabledBinding
        )
    }
}

struct SettingsBackgroundSideloadingRow: View {
    @AppStorage(BackgroundKeepAlive.enabledKey) private var continueWhenBackgrounded = true

    var body: some View {
        SettingsToggleCard(
            title: "Continue Sideloading when Backgrounded",
            subtitle: "Allow sideloading to continue after you leave TetherLess.",
            isOn: $continueWhenBackgrounded
        )
    }
}


struct SettingsKeepAppsAliveCard: View {
    @ObservedObject private var updater = AppAutoUpdater.shared
    @AppStorage(BackgroundKeepAlive.enabledKey) private var keepAlive = true

    var body: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title2)
                        .foregroundStyle(TetherlessPalette.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Keep Apps Alive")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Re-sign tracked apps with your active or free Apple ID certificate, even while backgrounded.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Button {
                    AppleIDStore.shared.activatePreferredSigningCertificate()
                    updater.refreshAll()
                } label: {
                    HStack {
                        if updater.busy {
                            ProgressView().tint(.white)
                        } else {
                            Text("Refresh All")
                                .font(.title3.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(TetherlessPalette.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(updater.busy)
                .opacity(updater.busy ? 0.7 : 1)

                if !updater.status.isEmpty {
                    Text(updater.status)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }

                Text(keepAlive
                     ? "Background keep-alive is on — installs and Refresh All can finish after you leave TetherLess. Add the “Refresh All” Shortcut from the Shortcuts app for one-tap resign."
                     : "Turn on Continue Sideloading when Backgrounded so Refresh All can finish while your iPhone is locked.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
