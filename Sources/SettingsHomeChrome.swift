import SwiftUI
import UniformTypeIdentifiers

// MARK: - Apple Account status (login lives on Account / iPadn only)

/// Status + deep-link to the Account tab. No second login sheet, Manage Apple ID,
/// GrandSlam 2FA block, or Developer Portal chrome — those are not from iPadn.
struct SettingsAppleIDCard: View {
    @ObservedObject private var store = AppleIDStore.shared

    var body: some View {
        GlassCard(corner: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(TetherlessPalette.accent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Apple Account")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Sign in and manage accounts on the Account tab (iPadn Store login).")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                if store.hasAnyAccount {
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

                    Button {
                        store.signOutActive()
                    } label: {
                        Text("Sign Out")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.white.opacity(0.10), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        AppNav.shared.goStoreLogin()
                    } label: {
                        Text("Open Account")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(TetherlessPalette.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
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
                Text("Account sign-in needs a reachable v3 anisette host (SideStore / jkcoxson). If Sign In fails with a TLS error, pick another server here first — you don’t need to be signed in.")
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
            ? "Using \(url.host ?? server) — open Account if downloads fail."
            : "Using \(url.host ?? server) — try Sign In again under Account."
        if AppleIDStore.shared.hasAnyAccount {
            await AppleIDStore.shared.requestStoreVerificationPrompt()
        }
    }

    private func rotate() async {
        let next = await AnisetteClient.shared.rotateServer()
        current = next.absoluteString
        status = AppleIDStore.shared.hasAnyAccount
            ? "Rotated to \(next.host ?? next.absoluteString) — open Account if downloads fail."
            : "Rotated to \(next.host ?? next.absoluteString) — try Sign In again under Account."
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
