//
// Brand: Tetherless · https://tetherless.dev
//  IPadnLoginView.swift
//  English Login + Verification UI from mengangs/ipadn AccountsView (GPL-2.0).
//  Calls AppleIDStore.signInViaIPadnStore — MZFinance first (same as iPadn).
//

import SwiftUI

// MARK: - Code field

struct IPadnVerificationCodeField: View {
    @Binding var code: String
    var length = 6
    var disabled = false
    var onComplete: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .disabled(disabled)
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(width: 1, height: 1)
                .opacity(0.02)
                .onChange(of: code) { value in
                    let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(length))
                    if digits != value { code = digits; return }
                    if digits.count == length { onComplete(digits) }
                }
            HStack(spacing: 10) {
                ForEach(0..<length, id: \.self) { index in
                    let characters = Array(code)
                    let current = index == characters.count && focused
                    Text(index < characters.count ? String(characters[index]) : "")
                        .font(.title.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 56)
                        .background(Color.white.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(current ? TetherlessPalette.accent : Color.white.opacity(0.18),
                                        lineWidth: current ? 2 : 1)
                        )
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Verification code, \(code.count) digits entered")
        }
        .onAppear { if !disabled { focused = true } }
        .onChange(of: disabled) { value in if !value { focused = true } }
    }
}

// MARK: - Two-factor step

struct IPadnVerificationStep: View {
    let account: String
    @Binding var code: String
    let busy: Bool
    let issue: String?
    var submitTitle = "Verify & Sign In"
    var sent = true
    /// e.g. "Step 1 of 2 · Apple ID" — explains why Allow may appear twice.
    var stepLabel: String? = nil
    var footnote: String? = nil
    var resend: (() -> Void)? = nil
    let submit: () -> Void
    var changeAccount: (() -> Void)? = nil
    @State private var showingHelp = false
    @State private var resendAvailableAt = Date().addingTimeInterval(30)

    /// Avoid `for ""` when the sheet was re-presented without local email state.
    private var accountLabel: String {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "your Apple Account" : trimmed
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(TetherlessPalette.accent)
                .padding(.top, 12)
                .accessibilityHidden(true)
            if let stepLabel, !stepLabel.isEmpty {
                Text(stepLabel.uppercased())
                    .font(.caption.weight(.semibold))
                    .kerning(0.8)
                    .foregroundStyle(TetherlessPalette.accent)
            }
            Text("Two-Factor Authentication")
                .font(.title.weight(.bold))
                .foregroundStyle(.white)
            Text(sent
                 ? "Apple sent a sign-in request to trusted devices for “\(accountLabel)”. Tap Allow, then enter the 6-digit code."
                 : "Asking Apple to send a verification code to trusted devices for “\(accountLabel)”…")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            IPadnVerificationCodeField(code: $code, disabled: busy) { _ in submit() }
                .padding(.vertical, 6)
            if busy {
                HStack(spacing: 8) {
                    ProgressView().tint(TetherlessPalette.accent)
                    Text("Verifying…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                }
            } else if let issue {
                Text(issue)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: submit) {
                Text(submitTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(TetherlessPalette.accent.opacity(busy || code.count != 6 ? 0.45 : 1), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busy || code.count != 6)

            if let resend {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let wait = Int(resendAvailableAt.timeIntervalSince(context.date).rounded(.up))
                    Button(wait > 0 ? "Resend Code (\(wait)s)" : "Resend Code") {
                        resendAvailableAt = Date().addingTimeInterval(30)
                        resend()
                    }
                    .font(.subheadline)
                    .foregroundStyle(TetherlessPalette.accent)
                    .disabled(busy || !sent || wait > 0)
                }
            }
            Button("Didn’t get a code?") { showingHelp = true }
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.55))
            if let changeAccount {
                Button("Change account or password", action: changeAccount)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .disabled(busy)
            }
        }
        .alert("Get a verification code", isPresented: $showingHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Codes go to iPhone, iPad, or Mac devices signed into this Apple Account — not SMS by default.\n1. Tap Allow on the Apple Account sign-in prompt.\n2. Or open Settings › [your name] › Sign-In & Security › Get Verification Code on a trusted device.\n3. If nothing arrives, tap Resend Code. Apple may throttle frequent requests.")
        }
    }
}

// MARK: - Login (iPadn LoginView English)

struct IPadnLoginView: View {
    let initialAccountID: String?
    let onSignedIn: (() -> Void)?
    var embedsNavigation: Bool = true

    init(
        initialAccountID: String? = nil,
        embedsNavigation: Bool = true,
        onSignedIn: (() -> Void)? = nil
    ) {
        self.initialAccountID = initialAccountID
        self.embedsNavigation = embedsNavigation
        self.onSignedIn = onSignedIn
        _email = State(initialValue: initialAccountID ?? "")
    }

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AppleIDStore.shared
    @State private var email = ""
    @State private var password = ""
    @State private var code = ""
    @State private var busy = false
    @State private var verifying = false
    @State private var failure: String?
    @State private var loginTask: Task<Void, Never>?
    @FocusState private var focus: Field?
    private enum Field { case email, password }

    private var canSubmit: Bool {
        let hasEmail = !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !store.draftEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !store.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPassword = !password.isEmpty || store.pendingSignInPassword() != nil
        if verifying {
            // Code step can use Keychain / active-account secret when @State was wiped.
            return !busy && hasEmail && hasPassword && code.count == 6
        }
        return !busy && hasEmail && !password.isEmpty
    }

    var body: some View {
        Group {
            if embedsNavigation {
                NavigationStack { content }
            } else {
                content
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 22) {
                if verifying {
                    IPadnVerificationStep(
                        account: email.trimmingCharacters(in: .whitespacesAndNewlines),
                        code: $code,
                        busy: busy,
                        issue: failure,
                        submitTitle: "Verify & Sign In",
                        stepLabel: "Step 1 of 2 · Apple ID",
                        footnote: "If Store downloads still need access after this, you’ll get a second Allow sheet — that’s step 2, not a failed login.",
                        resend: resendCode,
                        submit: submit,
                        changeAccount: {
                            verifying = false
                            code = ""
                            failure = nil
                            focus = .password
                        }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    credentials
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: verifying)
            .frame(maxWidth: 460)
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(busy)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    loginTask?.cancel()
                    if store.authPhase == .awaitingTwoFactor {
                        // Explicit cancel leaves 2FA — clear so Account can reopen cleanly.
                        store.clearPendingTwoFactorUI()
                    }
                    dismiss()
                }
                .disabled(busy && !verifying)
            }
            if busy {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { loginTask?.cancel() }
                }
            }
        }
        // Do NOT cancel on disappear while awaiting a code — leaving for Allow used to
        // wipe the sheet and leave the user stuck with no place to type digits.
        .onDisappear {
            if !verifying && store.authPhase != .awaitingTwoFactor {
                loginTask?.cancel()
            }
        }
        .onAppear {
            restorePendingIdentityIfNeeded()
            if store.authPhase == .awaitingTwoFactor {
                verifying = true
            }
        }
        .onChange(of: store.authPhase) { phase in
            if phase == .awaitingTwoFactor {
                restorePendingIdentityIfNeeded()
                verifying = true
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Sheet re-presentation after Allow / portal 2FA starts with empty `@State` — pull
    /// email (and password when still pending) from the store so Verify & Sign In works.
    private func restorePendingIdentityIfNeeded() {
        if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let restored = [
                store.draftEmail,
                store.email,
                UserDefaults.standard.string(forKey: "tetherless.appleid.activeEmailCache") ?? ""
            ]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
            if !restored.isEmpty { email = restored }
        }
        if password.isEmpty, let pending = store.pendingSignInPassword(), !pending.isEmpty {
            password = pending
        }
    }

    private var credentials: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(TetherlessPalette.accent)
                    .accessibilityHidden(true)
                Text(initialAccountID == nil ? "Sign in to Apple Account" : "Sign In Again")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                Text(initialAccountID == nil
                     ? "Sync purchases and download apps you’re licensed to use with your Apple Account."
                     : "This session expired. Enter the current password for this account.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                Text("Sign-in is two steps: Apple ID Allow (1), then Store downloads Allow (2) if needed.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 12)

            VStack(spacing: 0) {
                TextField("Email or Phone Number", text: $email)
                    .textContentType(.username)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focus = .password }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    .foregroundStyle(.white)
                Divider().overlay(.white.opacity(0.12)).padding(.leading, 16)
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focus, equals: .password)
                    .submitLabel(.go)
                    .onSubmit { if canSubmit { submit() } }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 50)
                    .foregroundStyle(.white)
            }
            .disabled(busy)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let failure {
                Label(failure, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: submit) {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(.white) }
                    Text(busy ? "Signing In…" : "Continue")
                        .font(.title3.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(TetherlessPalette.accent.opacity(canSubmit ? 1 : 0.45), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)

            Label("Your account details stay on this device.", systemImage: "lock.fill")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .onAppear {
            if email.isEmpty { focus = .email }
            else if password.isEmpty { focus = .password }
        }
    }

    /// Ask Apple for a fresh Allow push. Do not re-run password login — that can leave
    /// an old Allow on screen while a new push invalidates its code.
    private func resendCode() {
        guard !busy else { return }
        restorePendingIdentityIfNeeded()
        busy = true
        failure = nil
        code = ""
        loginTask = Task {
            defer { busy = false; loginTask = nil }
            await store.requestTrustedDevicePush(force: true)
            verifying = true
            if let err = store.lastError, !err.isEmpty {
                failure = err
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focus = nil
        busy = true
        failure = nil
        loginTask = Task {
            defer { busy = false; loginTask = nil }
            // Code step: use store.submitTwoFactor so re-presented sheets still have
            // draftEmail + Keychain / account password (local @State may be empty).
            if verifying {
                restorePendingIdentityIfNeeded()
                await store.submitTwoFactor(code: code)
                if store.authPhase == .idle, store.isSignedIn, store.lastError == nil {
                    password = ""
                    code = ""
                    onSignedIn?()
                    dismiss()
                } else if store.authPhase == .awaitingTwoFactor {
                    verifying = true
                    failure = store.lastError
                    code = ""
                } else if let err = store.lastError, !err.isEmpty {
                    failure = err
                    code = ""
                }
                return
            }
            do {
                try await store.signInViaIPadnStore(
                    email: email,
                    password: password,
                    code: ""
                )
                password = ""
                code = ""
                onSignedIn?()
                dismiss()
            } catch AppStoreClientError.needsTwoFactor {
                verifying = true
                code = ""
                failure = nil
            } catch is CancellationError {
                // Leaving the app to tap Allow cancels the network task — keep the sheet.
                if verifying || store.authPhase == .awaitingTwoFactor {
                    verifying = true
                    failure = nil
                } else {
                    failure = "Sign-in cancelled — try again."
                }
            } catch {
                failure = error.localizedDescription
                code = ""
            }
        }
    }
}

// MARK: - Second-step Store unlock (after Apple ID 2FA)

/// Shown when Apple ID is signed in but MZFinance still needs its own Allow push + code.
/// Restores the Store Access trusted-device flow removed with the iPadn Settings migration (#111).
struct IPadnStoreUnlockSheet: View {
    var onUnlocked: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = AppleIDStore.shared
    @State private var code = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var didRequestPush = false

    private var accountLabel: String {
        let email = store.email.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? "your Apple Account" : email
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    IPadnVerificationStep(
                        account: accountLabel,
                        code: $code,
                        busy: busy,
                        issue: failure ?? store.lastError,
                        submitTitle: "Unlock Store",
                        sent: true,
                        stepLabel: "Step 2 of 2 · Store downloads",
                        footnote: "Apple ID is already signed in. This second Allow unlocks purchases and silent downloads — separate from step 1.",
                        resend: { Task { await sendAllowPush(force: true) } },
                        submit: { submit() },
                        changeAccount: {
                            store.clearPendingTwoFactorUI()
                            dismiss()
                        }
                    )

                    if let status = store.statusMessage, !status.isEmpty {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                    }

                    Button {
                        Task { await sendAllowPush(force: true) }
                    } label: {
                        Label("Send Allow to devices again", systemImage: "iphone.radiowaves.left.and.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(TetherlessPalette.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || store.isBusy || store.storeConnecting)
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Unlock Store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                guard !didRequestPush else { return }
                didRequestPush = true
                // force:false — keep an Allow already in flight; a second push burns its code.
                await sendAllowPush(force: false)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func sendAllowPush(force: Bool) async {
        busy = true
        failure = nil
        defer { busy = false }
        await store.requestTrustedDevicePush(forStoreUnlock: true, force: force)
        if let err = store.lastError, !err.isEmpty {
            failure = err
        }
    }

    private func submit() {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return }
        busy = true
        failure = nil
        Task {
            defer { busy = false }
            do {
                _ = try await store.submitStoreVerificationCode(digits)
                code = ""
                onUnlocked?()
                dismiss()
            } catch {
                failure = store.lastError ?? error.localizedDescription
                code = ""
            }
        }
    }
}
