//
//  SettingsHomeChrome.swift
//  Glass Settings home cards matching the TetherLess reference (Apple ID,
//  Software Update, Custom Certificate, notification toggle).
//

import SwiftUI

// MARK: - Apple ID (free signing credentials; wires into SigningSheet method)

@MainActor
final class AppleIDStore: ObservableObject {
    static let shared = AppleIDStore()
    private static let emailKey = "tetherless.appleid.email"
    private static let passwordKey = "tetherless.appleid.password"

    @Published private(set) var email: String = ""
    @Published var draftEmail = ""
    @Published var draftPassword = ""
    @Published var statusMessage: String?
    @Published var isBusy = false

    var isSignedIn: Bool { !email.isEmpty }

    private init() {
        email = Keychain.get(Self.emailKey) ?? ""
        draftEmail = email
    }

    func signIn() {
        let e = draftEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = draftPassword
        guard e.contains("@"), e.contains("."), !p.isEmpty else {
            statusMessage = "Enter a valid Apple ID email and password."
            return
        }
        isBusy = true
        statusMessage = nil
        _ = Keychain.set(Self.emailKey, e)
        _ = Keychain.setSecret(Self.passwordKey, p)
        email = e
        draftPassword = ""
        UserDefaults.standard.set("appleid", forKey: "uzd_signing_method")
        isBusy = false
        statusMessage = "Signed in. Free Apple ID certificates last 7 days."
    }

    func signOut() {
        _ = Keychain.set(Self.emailKey, "")
        Keychain.deleteSecret(Self.passwordKey)
        email = ""
        draftEmail = ""
        draftPassword = ""
        statusMessage = nil
        if UserDefaults.standard.string(forKey: "uzd_signing_method") == "appleid" {
            UserDefaults.standard.set("saved", forKey: "uzd_signing_method")
        }
    }
}

struct SettingsAppleIDCard: View {
    @ObservedObject private var store = AppleIDStore.shared

    var body: some View {
        GlassCard(corner: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(TetherlessPalette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("Apple ID")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
                            Image(systemName: "info.circle")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(TetherlessPalette.accent)
                        }
                        Text(store.isSignedIn ? store.email : "Not signed in.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Text("Signs your apps with your free Apple ID. One sign-in covers both app signing and Store downloads.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }

                if store.isSignedIn {
                    Button("Sign Out", role: .destructive, action: store.signOut)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                } else {
                    glassField("Apple ID email", text: $store.draftEmail, secure: false)
                    glassField("Password", text: $store.draftPassword, secure: true)
                    Button(action: store.signIn) {
                        if store.isBusy {
                            ProgressView().tint(.white)
                        } else {
                            Text("Sign In")
                                .font(.body.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                    .disabled(store.isBusy)
                }

                if let msg = store.statusMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
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
                            Text("You're on \(checker.localVersion)\(checker.remoteVersion.map { " · latest \($0)" } ?? "").")
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

// MARK: - Glass nav row + toggle

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
        HStack {
            Text("Disable Notifications")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: disabledBinding)
                .labelsHidden()
                .tint(.white.opacity(0.35))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
