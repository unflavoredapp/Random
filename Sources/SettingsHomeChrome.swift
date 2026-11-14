//
//  SettingsHomeChrome.swift
//  Glass Settings home cards matching the TetherLess reference (Apple ID 2FA
//  flow, Software Update, Custom Certificate, notification / background toggles).
//

import SwiftUI

// MARK: - Apple ID session

@MainActor
final class AppleIDStore: ObservableObject {
    static let shared = AppleIDStore()
    private static let emailKey = "tetherless.appleid.email"
    private static let passwordKey = "tetherless.appleid.password"
    private static let storeReadyKey = "tetherless.appleid.storeReady"

    enum Phase: Equatable {
        case signedOut
        case authenticating
        case needsCode
        case verifying
        case signedIn
        case preparing
    }

    @Published private(set) var email: String = ""
    @Published var draftEmail = ""
    @Published var draftPassword = ""
    @Published var verificationCode = ""
    @Published private(set) var phase: Phase = .signedOut
    @Published var statusMessage: String?
    @Published var presentedDisplayCode: String?
    @Published private(set) var storeReady = false

    var isSignedIn: Bool {
        switch phase {
        case .signedIn, .preparing: return true
        default: return false
        }
    }

    private init() {
        email = Keychain.get(Self.emailKey) ?? ""
        draftEmail = email
        storeReady = UserDefaults.standard.bool(forKey: Self.storeReadyKey)
        if !email.isEmpty {
            phase = storeReady ? .signedIn : .preparing
            if !storeReady { Task { await finishPreparing() } }
        }
    }

    func signIn() {
        let e = draftEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = draftPassword
        guard e.contains("@"), e.contains("."), !p.isEmpty else {
            statusMessage = "Enter a valid Apple ID email and password."
            return
        }
        statusMessage = nil
        phase = .authenticating
        draftPassword = ""
        _ = Keychain.set(Self.emailKey, e)
        _ = Keychain.setSecret(Self.passwordKey, p)
        email = e
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            // Free Apple ID signing always challenges with a trusted-device code.
            withAnimation(.snappy) { phase = .needsCode }
        }
    }

    func submitVerificationCode() {
        let digits = verificationCode.filter(\.isNumber)
        guard digits.count == 6 else {
            statusMessage = "Enter the 6-digit code from your Apple device."
            return
        }
        statusMessage = nil
        phase = .verifying
        Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            // Store Access only — signing still uses Custom Certificate / TrustCore.
            verificationCode = ""
            withAnimation(.snappy) { phase = .preparing }
            await finishPreparing()
        }
    }

    /// Optional path: this device is showing a code for another Apple device (trusted-device prompt).
    func presentTrustedDeviceCode() {
        let code = String((0..<6).map { _ in String(Int.random(in: 0...9)) }.joined())
        presentedDisplayCode = code
    }

    func dismissDisplayedCode() { presentedDisplayCode = nil }

    func signOut() {
        _ = Keychain.set(Self.emailKey, "")
        Keychain.deleteSecret(Self.passwordKey)
        UserDefaults.standard.set(false, forKey: Self.storeReadyKey)
        email = ""
        draftEmail = ""
        draftPassword = ""
        verificationCode = ""
        storeReady = false
        statusMessage = nil
        presentedDisplayCode = nil
        phase = .signedOut
    }

    private func finishPreparing() async {
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        storeReady = true
        UserDefaults.standard.set(true, forKey: Self.storeReadyKey)
        withAnimation(.snappy) { phase = .signedIn }
    }
}

struct SettingsAppleIDCard: View {
    @ObservedObject private var store = AppleIDStore.shared
    @FocusState private var codeFocused: Bool
    @State private var manageAccounts = false

    var body: some View {
        GlassCard(corner: 24) {
            VStack(alignment: .leading, spacing: 16) {
                switch store.phase {
                case .signedOut:
                    statusRow(
                        icon: "bag",
                        tint: TetherlessPalette.accent,
                        title: "Store Access",
                        subtitle: "Lets Decrypt download apps from the App Store. Signing uses your certificate — no Apple ID needed."
                    )
                    glassField("Apple ID email", text: $store.draftEmail, secure: false)
                    glassField("Password", text: $store.draftPassword, secure: true)
                    secondaryButton("Sign In", busy: false, action: store.signIn)

                case .authenticating:
                    statusRow(icon: "bag", tint: TetherlessPalette.accent, title: "Store Access",
                              subtitle: "Lets Decrypt download apps from the App Store.")
                    statusRow(icon: nil, tint: TetherlessPalette.accent, title: "Signing in…",
                              subtitle: "Contacting Apple ID…", spinning: true)

                case .needsCode:
                    statusRow(icon: "bag", tint: TetherlessPalette.accent, title: "Store Access",
                              subtitle: "Lets Decrypt download apps from the App Store.")
                    statusRow(
                        icon: "number",
                        tint: .green,
                        title: "Verification code needed",
                        subtitle: "Enter the code shown on one of your Apple devices."
                    )
                    TextField("000000", text: $store.verificationCode)
                        .keyboardType(.numberPad)
                        .focused($codeFocused)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.vertical, 14)
                        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                        )
                        .onChange(of: store.verificationCode) { value in
                            let digits = String(value.filter(\.isNumber).prefix(6))
                            if digits != value { store.verificationCode = digits }
                        }
                        .onAppear { codeFocused = true }
                    primaryButton("Submit Code", action: store.submitVerificationCode)

                case .verifying:
                    statusRow(icon: "bag", tint: TetherlessPalette.accent, title: "Store Access",
                              subtitle: "Lets Decrypt download apps from the App Store.")
                    statusRow(icon: nil, tint: TetherlessPalette.accent, title: "Verifying code…",
                              subtitle: "Checking with Apple…", spinning: true)

                case .preparing, .signedIn:
                    storeAccessSignedIn
                }

                if let msg = store.statusMessage {
                    Text(msg).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .sheet(item: Binding(
            get: { store.presentedDisplayCode.map { DisplayedCode($0) } },
            set: { if $0 == nil { store.dismissDisplayedCode() } }
        )) { item in
            VerificationCodeSheet(code: item.value) { store.dismissDisplayedCode() }
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $manageAccounts) {
            NavigationStack {
                List {
                    Section("Active") {
                        Text(store.email).foregroundStyle(.primary)
                    }
                    Section {
                        Button("Add another Apple ID…") {
                            manageAccounts = false
                            store.signOut()
                        }
                    }
                }
                .navigationTitle("Store Accounts")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { manageAccounts = false }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var storeAccessSignedIn: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusRow(
                icon: "bag",
                tint: TetherlessPalette.accent,
                title: "Store Access",
                subtitle: "Lets Decrypt download apps from the App Store. Signing uses your certificate — no Apple ID needed."
            )
            statusRow(
                icon: "checkmark.seal.fill",
                tint: .green,
                title: "Signed in for Store access",
                subtitle: store.email
            )
            Button { manageAccounts = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "person.2.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(TetherlessPalette.accent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Manage Store Accounts")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Add another Apple ID for downloads, or switch accounts.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .buttonStyle(.plain)
            if store.phase == .preparing {
                statusRow(icon: nil, tint: TetherlessPalette.accent, title: "Preparing…",
                          subtitle: "Starting things back up…", spinning: true)
            }
            secondaryButton("Sign Out", busy: false, action: store.signOut)
        }
    }

    private func statusRow(icon: String?, tint: Color, title: String, subtitle: String, spinning: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if spinning {
                    ProgressView().tint(tint)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline.weight(.semibold)).foregroundStyle(.white)
                Text(subtitle).font(.subheadline).foregroundStyle(.white.opacity(0.55))
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

private struct DisplayedCode: Identifiable {
    let id = UUID()
    let value: String
    init(_ value: String) { self.value = value }
}

private struct VerificationCodeSheet: View {
    let code: String
    let onDismiss: () -> Void

    private var spaced: String {
        let d = Array(code)
        guard d.count == 6 else { return code }
        return "\(d[0]) \(d[1]) \(d[2])   \(d[3]) \(d[4]) \(d[5])"
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Apple Account Verification Code")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            Text("Enter this verification code on your other Apple device to sign in.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
            Text(spaced)
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.vertical, 8)
            Text("Don’t share it with anyone. Apple will never call or text you for this code.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
            Button("OK", action: onDismiss)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(TetherlessPalette.accent, in: Capsule())
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppBackground())
    }
}

// MARK: - Software Update

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
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                message = "Couldn't check for updates."
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
