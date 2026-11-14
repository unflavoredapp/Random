import SwiftUI
import UniformTypeIdentifiers

// MARK: - Store Access (multi-account)

struct SettingsAppleIDCard: View {
    @ObservedObject private var store = AppleIDStore.shared
    @State private var email = ""
    @State private var password = ""
    @State private var twoFACode = ""
    @State private var showPassword = false
    @State private var showManageAccounts = false
    @State private var showPortalManage = false
    @State private var showAddAccount = false
    @State private var accountPendingDelete: AppleIDAccount?

    private var isPreparing: Bool {
        store.authPhase == .preparing || store.authPhase == .authenticating || store.authPhase == .verifying
    }

    var body: some View {
        GlassCard(corner: 24) {
            VStack(alignment: .leading, spacing: 14) {
                // Reference chrome: Apple ID (signing) + Store Access in one card.
                appleIDHeader

                if store.hasAnyAccount {
                    signedInAppleBlock
                    storeAccessSection
                } else if store.authPhase == .awaitingTwoFactor {
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

                if let err = store.lastError, !err.isEmpty {
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
                    .navigationTitle("Store Access")
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
        .sheet(isPresented: $showAddAccount) {
            NavigationStack {
                addAccountForm
                    .padding(20)
                    .navigationTitle("Add Apple ID")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                showAddAccount = false
                                store.cancelTwoFactor()
                                email = ""; password = ""; twoFACode = ""
                            }
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

    @ViewBuilder
    private var storeAccessSection: some View {
        Divider().overlay(.white.opacity(0.12))

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bag.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(TetherlessPalette.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text("Store Access")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Used by Decrypt to buy/download apps.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }

        // Target chrome: green “Signed in for Store access” with the same Apple ID email
        // once the shared passwordToken session exists — never hide that behind a spinner.
        if store.storefrontSession()?.isUsable == true {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(Color.green.opacity(0.95))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Signed in for Store access")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(store.email)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Text("Ready to fetch free apps and anything this Apple ID already purchased.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)

            Button { showManageAccounts = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.2.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(TetherlessPalette.accent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Manage Store Accounts")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Add another Apple ID for downloads, or switch accounts.")
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
        } else if store.storeConnecting || isPreparing {
            HStack(spacing: 10) {
                ProgressView().tint(TetherlessPalette.accent)
                Text("Signing in for Store access…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
        } else if store.storeNeedsVerification {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Store download needs a code")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Tap Resend text message, enter that SMS code below, then Submit. Stay signed in — don’t use an older code from a previous prompt.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            SettingsStoreCodeEntry()
        } else {
            // Portal signed in; store session not loaded yet — reconnect with the same password.
            HStack(spacing: 10) {
                ProgressView().tint(TetherlessPalette.accent)
                Text("Signing in for Store access…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .task {
                await store.reconnectStoreSessionIfNeeded()
                // Don't spin forever if reconnect no-ops or store still needs a code.
                if store.storefrontSession()?.isUsable != true, !store.storeConnecting {
                    store.noteStoreNeedsVerification()
                }
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
            Text("One sign-in covers both app signing and Store downloads with the same session.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)

            glassField("Apple ID email", text: $email, secure: false)
            HStack(spacing: 10) {
                glassField("Password", text: $password, secure: !showPassword)
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
            primaryButton(store.isBusy ? "Signing In…" : "Sign In") {
                Task { await store.signIn(email: email, password: password) }
            }
            .disabled(store.isBusy || email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            .opacity(store.isBusy ? 0.7 : 1)
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

                AuthClientSpoofCard()
                StoreDeviceSpoofCard()
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
        return "Watch for Apple’s Allow sheet (map · \(device)) and verification code on this iPhone — turn Focus off if they don’t appear. Then enter the code below."
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

/// Inline MZFinance 6-digit code on Settings (keeps Apple ID signed in).
private struct SettingsStoreCodeEntry: View {
    @ObservedObject private var store = AppleIDStore.shared
    @State private var code = ""
    @State private var busy = false
    @State private var localError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.body.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.28), in: Capsule())
                    .foregroundStyle(.white)
                Button {
                    Task { await submit() }
                } label: {
                    if busy {
                        ProgressView().tint(.white).frame(width: 44, height: 36)
                    } else {
                        Text("Submit")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(TetherlessPalette.accent, in: Capsule())
                    }
                }
                .buttonStyle(.plain)
                .disabled(busy || code.filter(\.isNumber).count < 6)
            }
            Button {
                Task {
                    await store.requestStoreVerificationPrompt()
                    // Prefer success/status copy; fall back to lastError when SMS failed.
                    if let err = store.lastError, !(store.statusMessage?.localizedCaseInsensitiveContains("sent") == true) {
                        localError = err
                    } else {
                        localError = store.statusMessage
                    }
                }
            } label: {
                Label(
                    store.isSMSTwoFactor ? "Resend text message" : "Text me a code",
                    systemImage: "message.fill"
                )
                .font(.footnote.weight(.semibold))
                .foregroundStyle(TetherlessPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(busy || store.isBusy)
            if let localError, !localError.isEmpty {
                Text(localError)
                    .font(.caption2)
                    .foregroundStyle(
                        localError.localizedCaseInsensitiveContains("sent") ? Color.green.opacity(0.9) : .orange
                    )
            }
        }
    }

    private func submit() async {
        busy = true
        localError = nil
        defer { busy = false }
        do {
            _ = try await store.submitStoreVerificationCode(code)
            code = ""
        } catch {
            localError = error.localizedDescription
        }
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

/// Spoof claimed iOS / device model on App Store download requests (variant selection).
struct StoreDeviceSpoofCard: View {
    @State private var spoof = StoreDeviceSpoof.current
    private let profiles = StoreSpoofProfile.builtIn(realModel: StoreDeviceSpoof.realModelIdentifier())

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { spoof.enabled },
                set: { spoof.enabled = $0; persist() }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spoof Store iOS / device")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Claims another iOS/device on store requests (Configurator+iOS UA, Client-Info, headers). Auto-selects a compatible app build when you don’t pin a version. Does not change this iPhone’s real OS.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(TetherlessPalette.accent)

            Text(spoof.summaryLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(spoof.enabled ? TetherlessPalette.accent : .white.opacity(0.45))

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
                                isSelected(profile)
                                    ? TetherlessPalette.accent.opacity(0.35)
                                    : Color.black.opacity(0.28),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(
                                        isSelected(profile) ? TetherlessPalette.accent.opacity(0.7) : .white.opacity(0.08),
                                        lineWidth: 1
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if spoof.enabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text("iOS version")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(StoreDeviceSpoof.iosVersionPresets, id: \.self) { ver in
                                Button {
                                    spoof.iosVersion = ver
                                    spoof.build = StoreDeviceSpoof.defaultBuild(forIOS: ver) ?? spoof.build
                                    persist()
                                } label: {
                                    Text(ver)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(
                                            spoof.iosVersion == ver
                                                ? TetherlessPalette.accent.opacity(0.4)
                                                : Color.black.opacity(0.28),
                                            in: Capsule()
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        TextField("iOS version", text: Binding(
                            get: { spoof.iosVersion },
                            set: {
                                spoof.iosVersion = $0
                                if spoof.build.isEmpty {
                                    spoof.build = StoreDeviceSpoof.defaultBuild(forIOS: $0) ?? ""
                                }
                                persist()
                            }
                        ))
                        .keyboardType(.decimalPad)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.28), in: Capsule())

                        TextField("Build", text: Binding(
                            get: { spoof.build },
                            set: { spoof.build = $0; persist() }
                        ))
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.28), in: Capsule())
                    }

                    Menu {
                        ForEach(StoreDeviceSpoof.modelPresets, id: \.model) { preset in
                            Button(preset.label) {
                                spoof.deviceModel = preset.model
                                spoof.hardwarePlatform = StoreDeviceSpoof.hardwarePlatform(forModel: preset.model) ?? ""
                                persist()
                            }
                        }
                    } label: {
                        HStack {
                            Text(modelMenuLabel)
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.28), in: Capsule())
                    }

                    Toggle(isOn: Binding(
                        get: { spoof.autoSelectCompatibleVersion },
                        set: { spoof.autoSelectCompatibleVersion = $0; persist() }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Auto-pick compatible app version")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("Walks store version IDs and pins the newest build whose min iOS fits the spoofed OS.")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(TetherlessPalette.accent)

                    Toggle(isOn: Binding(
                        get: { spoof.rewriteClientInfo },
                        set: { spoof.rewriteClientInfo = $0; persist() }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Rewrite Client-Info (advanced)")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("Off by default. Turning this on can cause HTTP 204/404 from Apple when anisette MID doesn’t match.")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(TetherlessPalette.accent)

                    Menu {
                        ForEach(StoreUserAgentStyle.allCases, id: \.self) { style in
                            Button(style.label) {
                                spoof.style = style
                                persist()
                            }
                        }
                    } label: {
                        HStack {
                            Text("UA style · \(spoof.style.label)")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.28), in: Capsule())
                    }

                    Text("Real device: iOS \(UIDevice.current.systemVersion) · \(StoreDeviceSpoof.realModelIdentifier())")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                    Text(spoof.storeUserAgent(fallbackConfigurator: "Configurator/2.15 (Macintosh; OS X 11.0.0; 16A5288f) AppleWebKit/0605.2.7.5"))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, 4)
        .onAppear { spoof = StoreDeviceSpoof.current }
    }

    private var modelMenuLabel: String {
        if let match = StoreDeviceSpoof.modelPresets.first(where: { $0.model == spoof.deviceModel }) {
            return "\(match.label) · \(match.model)"
        }
        return spoof.deviceModel.isEmpty ? "Device model" : spoof.deviceModel
    }

    private func isSelected(_ profile: StoreSpoofProfile) -> Bool {
        if profile.id == "device" { return !spoof.enabled }
        if profile.id == "newest" {
            return spoof.enabled && spoof.preferLatestPackage
        }
        return spoof.enabled
            && !spoof.preferLatestPackage
            && spoof.iosVersion == profile.iosVersion
            && (profile.deviceModel == nil || spoof.deviceModel == profile.deviceModel)
    }

    private func persist() {
        StoreDeviceSpoof.current = spoof
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
