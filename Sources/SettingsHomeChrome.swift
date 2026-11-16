import SwiftUI
import UniformTypeIdentifiers

// MARK: - Apple ID (signing)

struct SettingsAppleIDCard: View {
    @ObservedObject private var store = AppleIDStore.shared
    @State private var email = ""
    @State private var password = ""
    @State private var twoFACode = ""
    @State private var showPassword = false
    @State private var showManageAccounts = false
    @State private var showPortalManage = false
    @State private var showAddAccount = false
    @State private var showIPadnLogin = false
    @State private var accountPendingDelete: AppleIDAccount?

    private var isPreparing: Bool {
        store.authPhase == .preparing || store.authPhase == .authenticating || store.authPhase == .verifying
    }

    var body: some View {
        GlassCard(corner: 24) {
            VStack(alignment: .leading, spacing: 14) {
                // Apple ID signing only — store login is on Account (iPadn).
                appleIDHeader

                if store.hasAnyAccount {
                    signedInAppleBlock
                                    } else if store.authPhase == .awaitingTwoFactor {
                    // Legacy GSA fallback still needs the inline code field.
                    twoFactorBlock
                } else if isPreparing {
                    HStack(spacing: 10) {
                        ProgressView().tint(TetherlessPalette.accent)
                        Text("Signing in…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                } else {
                    emptySignIn
                }

                if let err = store.lastError, !err.isEmpty,
                   store.storefrontSession()?.isUsable != true {
                    // Don't paint red under a green Store session (stale 404 / Owned soft fails).
                    Text(err)
                        .font(.footnote)
                        .foregroundStyle(.red.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(isPresented: $showManageAccounts) {
            NavigationStack {
                manageStoreAccountsSheet
                    .navigationTitle("Apple Accounts")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showManageAccounts = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showPortalManage) {
            NavigationStack {
                AppleIDManageView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showPortalManage = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showIPadnLogin) {
            IPadnLoginView {
                showIPadnLogin = false
            }
        }
        .sheet(isPresented: $showAddAccount) {
            IPadnLoginView {
                showAddAccount = false
                email = ""; password = ""; twoFACode = ""
            }
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
                Text("Remove \(a.email) from Apple Accounts on this device.")
            }
        }
    }

    private var appleIDHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(TetherlessPalette.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("Apple ID")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Signs your apps with your free Apple ID.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
    }

    private var signedInAppleBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(Color.green.opacity(0.95))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Signed in")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(store.email)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Button { showPortalManage = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "rosette")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(TetherlessPalette.accent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Developer Account")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("View your certificates, App IDs and devices — and free up a certificate slot.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)

            secondaryButton("Sign Out", busy: false) {
                store.signOutActive()
                email = ""; password = ""; twoFACode = ""
            }
        }
    }

    private var emptySignIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(TetherlessPalette.accent)
                Text("Not signed in")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Text("Uses iPadn’s Store login (MZFinance) so purchases and downloads unlock in one step — then optional Apple ID trust for signing.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            primaryButton("Sign In with Apple Account") {
                showIPadnLogin = true
            }
        }
    }

    private var manageStoreAccountsSheet: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                GlassCard(corner: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Store accounts")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Text("\(store.accounts.count)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        Text("The active account is used for every download and decrypt. Switch any time; the Decrypt tab shows a quick switcher once you have two or more.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)

                        accountList
                    }
                }

                GlassCard(corner: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Image(systemName: "person.badge.plus")
                                .foregroundStyle(TetherlessPalette.accent)
                            Text("Add Account")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        Text("Sign in another Apple ID for Store downloads. It becomes the active one.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                        Button {
                            showManageAccounts = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                showAddAccount = true
                            }
                        } label: {
                            Text("Add Account")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(.white.opacity(0.10), in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }

                GlassCard(corner: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(TetherlessPalette.accent)
                            Text("About decrypt")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
                        }
                        Text("Decrypt works for an Apple ID only if it has signed into this iPhone's App Store at least once (ever). Downloads work for any added account.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                PhoneDecryptWorkerCard()
            }
            .padding(20)
            .padding(.bottom, 28)
        }
        .background(AppBackground().ignoresSafeArea())
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
        VStack(alignment: .leading, spacing: 12) {
            // Reference chrome: “Verification code needed” after GrandSlam trusted-device push.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "number")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Color.green.opacity(0.95))
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.isBusy ? "Verifying code…" : "Verification code needed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(twoFactorHelpText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if store.isBusy {
                    ProgressView().tint(TetherlessPalette.accent)
                }
            }

            TextField("123456", text: $twoFACode)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
                .disabled(store.isBusy)

            primaryButton(store.isBusy ? "Verifying code…" : "Submit Code") {
                Task {
                    await store.submitTwoFactor(code: twoFACode)
                    if store.authPhase == .idle, store.lastError == nil {
                        showAddAccount = false
                        email = ""; password = ""; twoFACode = ""
                    }
                }
            }
            .disabled(store.isBusy || twoFACode.filter(\.isNumber).count < 6)
            .opacity(store.isBusy ? 0.7 : 1)

            VStack(alignment: .leading, spacing: 10) {
                if !store.isSMSTwoFactor {
                    Button {
                        Task { await store.requestTrustedDevicePush() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "iphone.radiowaves.left.and.right")
                            Text("Send again to devices")
                                .font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(TetherlessPalette.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isBusy)
                }

                HStack(spacing: 16) {
                    Button {
                        Task { await store.requestSMSCode() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "message.fill")
                            Text(store.isSMSTwoFactor ? "Resend text message" : "Text me a code")
                                .font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(TetherlessPalette.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isBusy)

                    Spacer(minLength: 0)

                    Button {
                        store.cancelTwoFactor()
                        twoFACode = ""
                    } label: {
                        Text("Cancel")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isBusy)
                }
            }
        }
    }

    private var twoFactorHelpText: String {
        if store.isBusy {
            return store.statusMessage?.isEmpty == false
                ? store.statusMessage!
                : "Checking the code with Apple…"
        }
        if let status = store.statusMessage, !status.isEmpty {
            return status
        }
        if store.isSMSTwoFactor {
            if let hint = store.twoFactorPhoneHint, !hint.isEmpty {
                return "Enter the 6-digit code texted to \(hint)."
            }
            return "Enter the 6-digit code texted to your phone."
        }
        let device = AuthClientSpoof.current.displayName
        return "Watch for Apple’s Allow sheet (map · \(device)) and verification code on this iPhone — turn Focus off (moon) if they don’t appear. Enter that code below; Store unlocks from the same trust after Submit (no second text)."
    }

    private var accountList: some View {
        VStack(spacing: 10) {
            ForEach(store.accounts) { account in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Button {
                            store.selectAccount(id: account.id)
                        } label: {
                            HStack(spacing: 12) {
                                Text(account.email)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if store.activeAccountID == account.id {
                                    Text("Active")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.green.opacity(0.85), in: Capsule())
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    Button(role: .destructive) {
                        accountPendingDelete = account
                    } label: {
                        Label("Sign Out", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(.white.opacity(0.08), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            store.activeAccountID == account.id ? Color.green.opacity(0.45) : .white.opacity(0.08),
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
        .buttonStyle(.plain)
    }
}

/// Enable this iPhone as the FairPlay worker for the site / own Telegram bot queue.
struct PhoneDecryptWorkerCard: View {
    @ObservedObject private var worker = PhoneDecryptWorker.shared

    var body: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(
                    get: { worker.enabled },
                    set: { worker.applyEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Phone Worker")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Claim decrypt jobs from your site / Telegram bot and run FairPlay on this iPhone. Keep the app open while jobs run.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(TetherlessPalette.accent)

                SecureField("DECRYPT_WORKER_TOKEN", text: $worker.workerToken)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.28), in: Capsule())
                    .foregroundStyle(.white)
                    .disabled(!worker.enabled)
                    .opacity(worker.enabled ? 1 : 0.5)

                Text(worker.status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(worker.busy ? TetherlessPalette.accent : .white.opacity(0.55))
                if let err = worker.lastError, !err.isEmpty {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Spoof MacBook / iPhone AuthKit identity for Apple ID sign-in (HSA2 Allow + code sheets).
struct AuthClientSpoofCard: View {
    @State private var spoof = AuthClientSpoof.current
    private let profiles = AuthClientProfile.builtIn

    var body: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .foregroundStyle(TetherlessPalette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sign-in device identity")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Claims a MacBook or another iPhone when requesting Apple’s Allow + verification code sheets. MacBook usually overlays this phone; iPhone may push to other trusted devices.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text(spoof.summaryLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(profiles) { profile in
                            Button {
                                spoof.apply(profile)
                                persist()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.title)
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                    Text(profile.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.45))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(
                                    spoof.profileID == profile.id
                                        ? TetherlessPalette.accent.opacity(0.35)
                                        : Color.black.opacity(0.28),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(
                                            spoof.profileID == profile.id
                                                ? TetherlessPalette.accent.opacity(0.7)
                                                : .white.opacity(0.08),
                                            lineWidth: 1
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Text(spoof.clientInfo)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { spoof = AuthClientSpoof.current }
    }

    private func persist() {
        AuthClientSpoof.current = spoof
    }
}

/// SideStore-style anisette v3 server picker (backend list + built-in fallbacks).
struct AnisetteServerCard: View {
    @State private var current = ""
    @State private var servers: [String] = AnisetteClient.builtInServers
    @State private var status: String?

    var body: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Anisette server")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Sign In and Store Access need a reachable v3 anisette host (SideStore / jkcoxson). If Sign In fails with a TLS error, pick another server here first — you don’t need to be signed in.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)

                Text(current.isEmpty ? "Loading…" : current)
                    .font(.caption.monospaced())
                    .foregroundStyle(TetherlessPalette.accent)
                    .lineLimit(2)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(servers, id: \.self) { server in
                            let on = server.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                                == current.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
                            Button {
                                Task { await select(server) }
                            } label: {
                                Text(shortLabel(server))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(on ? .white : .white.opacity(0.7))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(on ? TetherlessPalette.accent : Color.white.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Button {
                    Task { await rotate() }
                } label: {
                    Text("Rotate anisette server")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.10), in: Capsule())
                }
                .buttonStyle(.plain)

                if let status {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .task { await reload() }
    }

    private func shortLabel(_ server: String) -> String {
        URL(string: server)?.host ?? server
    }

    private func reload() async {
        let url = await AnisetteClient.shared.serverURL
        current = url.absoluteString
        var list = AnisetteClient.builtInServers
        if let req = try? LocalDecryptBridge.request("api/store/anisette-servers"),
           let (_, json) = try? await LocalDecryptBridge.sendRaw(req),
           let rows = json["servers"] as? [String] {
            list = rows + list
        }
        var seen = Set<String>()
        servers = list.filter { seen.insert($0.lowercased()).inserted }
        if !servers.contains(where: { $0.caseInsensitiveCompare(current) == .orderedSame }) {
            servers.insert(current, at: 0)
        }
    }

    private func select(_ server: String) async {
        guard let url = URL(string: server) else { return }
        await AnisetteClient.shared.setServerURL(url)
        current = url.absoluteString
        status = AppleIDStore.shared.hasAnyAccount
            ? "Using \(url.host ?? server) — tap Retry Store unlock."
            : "Using \(url.host ?? server) — try Sign In again."
        if AppleIDStore.shared.hasAnyAccount {
            await AppleIDStore.shared.requestStoreVerificationPrompt()
        }
    }

    private func rotate() async {
        let next = await AnisetteClient.shared.rotateServer()
        current = next.absoluteString
        status = AppleIDStore.shared.hasAnyAccount
            ? "Rotated to \(next.host ?? next.absoluteString) — reminting Store…"
            : "Rotated to \(next.host ?? next.absoluteString) — try Sign In again."
        if AppleIDStore.shared.hasAnyAccount {
            await AppleIDStore.shared.requestStoreVerificationPrompt()
        }
        await reload()
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
            // No GitHub Releases yet → treat as up to date rather than an error.
            if status == 404 {
                remoteVersion = nil
                downloadURL = nil
                message = nil
                return
            }
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
                    Image(systemName: checker.updateAvailable ? "arrow.down.circle.fill" : "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(checker.updateAvailable ? TetherlessPalette.accent : .green)
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
                    SideloadSurvival.refreshAllWithKeepAlive()
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
