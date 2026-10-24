//
//  SettingsView.swift
//  AirShare-style settings: sectioned rows (icon tile · title · subtitle · open
//  glyph). Tapping a row pushes a dedicated screen. Rows have a fixed height
//  so the list stays compact and never fights the keyboard.
//

import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Root list

private enum Screen: Identifiable, Hashable {
    case github, account, localZSignAPI
    case signingRequestCertificate
    case about, repo, token
    case dylibTemplate, ipaTemplate
    case certificates, otaDomain, certInspector, transparency, recoverData
    case tutorials, extras, tableView, nativeInstall
    var id: String {
        switch self {
        case .github: return "github"; case .account: return "account"; case .localZSignAPI: return "local-zsign-api"
        case .signingRequestCertificate: return "signing-request-certificate"
        case .about: return "about"; case .repo: return "repo"; case .token: return "token"
        case .dylibTemplate: return "tpl-dylib"; case .ipaTemplate: return "tpl-ipa"
        case .certificates: return "certs"; case .otaDomain: return "ota"; case .certInspector: return "inspect"; case .transparency: return "transparency"; case .recoverData: return "recover"
        case .tutorials: return "tutorials"
        case .extras: return "extras"
        case .tableView: return "table-view"
        case .nativeInstall: return "native-install"
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read accent live (auto-cycle) without rebuilding
    @EnvironmentObject var config: Config
    @EnvironmentObject var session: Session
    @ObservedObject private var certs = CertificateStore.shared
    @ObservedObject private var staff = StaffGate.shared
    @ObservedObject private var account = ZefvAccount.shared
    @State private var screen: Screen?

    var body: some View {
        ZStack {
                Theme.bg.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {

                        SettingsSection("General") {
                            SettingsRow(icon: "info.circle.fill", title: "About", subtitle: "App information and version") { screen = .about }
                        }

                        SettingsSection("Account") {
                            SettingsRow(icon: account.isLoggedIn ? "person.crop.circle.fill" : "person.crop.circle.badge.plus",
                                        title: "User Settings",
                                        subtitle: account.isLoggedIn ? "\(account.username ?? "") · account and device settings" : "Sign in or register") { screen = .account }
                            SettingsRow(icon: "plus.app.fill", title: "Request Certificate",
                                        subtitle: "Submit or review your certificate requests") { screen = .signingRequestCertificate }
                        }

                        SettingsSection("Signing") {
                            SettingsRow(icon: "checkmark.seal.fill", title: "Certificates",
                                        subtitle: certs.active?.name ?? "No signing certificate") { screen = .certificates }
                            SettingsRow(icon: "gearshape.fill", title: "Settings",
                                        subtitle: "Local ZSign API · AirShare Domain") { screen = .tableView }
                            // The "dev" group specifically — not admin, not the developer role. Being an admin
                            // or having elevated role doesn't put the GitHub repo tools in front of you.
                            if account.style.badges.contains("dev") {
                                SettingsRow(icon: "chevron.left.forwardslash.chevron.right", title: "GitHub",
                                            subtitle: githubSubtitle) { screen = .github }
                            }
                        }

                        SettingsSection("Install") {
                            SettingsRow(icon: "arrow.down.app.fill", title: "Install Method",
                                        subtitle: NativeInstaller.isSelected ? "Native · built-in VPN · auto-updates" : "OTA · itms-services over AirShare domain") { screen = .nativeInstall }
                        }

                        SettingsSection("Support") {
                            SettingsLink(icon: "globe", imageName: "airshare_logo", title: "AirShare",
                                         subtitle: "airshare.lol | Official site",
                                         url: URL(string: "https://airshare.lol")!)
                            SettingsLink(icon: "network", imageName: "delvek_logo", imageURL: URL(string: "https://delvek.net/img/delvek4.png"), title: "Delvek.net",
                                         subtitle: "delvek.net | Repo and support",
                                         url: URL(string: "https://delvek.net")!)
                        }

                        StatusFooter()
                            .padding(.top, 26)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 20)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                TabTitleBar(title: "Settings") {
                    Text("\(Theme.appName.uppercased()) \(Theme.appVersion)").font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                }
            }
            .task { await StaffGate.shared.refresh(); await ZefvAccount.shared.refreshProfile() }
            .onReceive(AppNav.shared.$openAccountScreen) { if $0 { AppNav.shared.openAccountScreen = false; screen = .account } }
        }
        .fullScreenCover(item: $screen) { s in
            Group {
                switch s {
                case .github: GitHubSettingsScreen()
                case .account: AccountScreen()
                case .localZSignAPI: LocalZSignAPISettingsView()
                case .signingRequestCertificate: CertificateRequestView()
                case .about: AboutScreen()
                case .repo:  RepoScreen()
                case .token: TokenScreen()
                case .certificates:  CertificatesScreen()
                case .otaDomain:     OTADomainScreen()
                case .certInspector: CertInspectorScreen()
                case .transparency:  TransparencyScreen()
                case .recoverData:   McryptedRecoverView()
                case .dylibTemplate: DylibTemplateScreen()
                case .ipaTemplate:   IPATemplateScreen()
                case .tutorials: TutorialsListScreen()
                case .extras: ExtrasScreen()
                case .tableView: TableViewSettingsScreen()
                case .nativeInstall: NativeInstallScreen()
                }
            }
            .environmentObject(config)
            .environmentObject(session)
            .preferredColorScheme(.dark)
        }
    }

    private var githubSubtitle: String {
        guard !config.owner.isEmpty, !config.repo.isEmpty else { return "Import · Push · Build · Templates · Tutorials" }
        return "\(config.owner)/\(config.repo) · Import · Push · Build"
    }
}

// MARK: - GitHub hub (everything repo/dev related lives here, off the main list)

private struct GitHubSettingsScreen: View {
    @EnvironmentObject var config: Config
    @EnvironmentObject var session: Session
    @ObservedObject private var staff = StaffGate.shared
    @Environment(\.dismiss) private var dismiss
    @State private var screen: Screen?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {

                    SettingsSection("GitHub") {
                        SettingsRow(icon: "tray.and.arrow.down.fill", title: "Import zip",
                                    subtitle: "Extract a zip into the workspace") { GitHubHub.shared.open(0) }
                        SettingsRow(icon: "folder.fill", title: "Contents",
                                    subtitle: session.root == nil ? "Workspace is empty" : "\(session.fileCount) files · \(session.archiveName ?? "")") { GitHubHub.shared.open(1) }
                        SettingsRow(icon: "arrow.up.circle.fill", title: "Push",
                                    subtitle: "Commit the workspace to \(config.owner.isEmpty ? "a repo" : "\(config.owner)/\(config.repo)")") { GitHubHub.shared.open(2) }
                        SettingsRow(icon: "hammer.fill", title: "Build",
                                    subtitle: "Actions runs, steps, artifacts") { GitHubHub.shared.open(3) }
                    }

                    SettingsSection("Target") {
                        SettingsRow(icon: "point.3.connected.trianglepath.dotted",
                                    title: "Repository",
                                    subtitle: repoSubtitle) { screen = .repo }
                    }

                    SettingsSection("Security") {
                        SettingsRow(icon: "key.fill",
                                    title: "Access token",
                                    subtitle: config.hasToken ? "GitHub PAT stored in Keychain" : "No token set") { screen = .token }
                        if staff.isStaff {
                            SettingsRow(icon: "lock.doc.fill",
                                        title: "Recover hidden data",
                                        subtitle: "Decrypt an Mcrypted payload from any signed IPA") { screen = .recoverData }
                        }
                    }

                    SettingsSection("Transparency") {
                        SettingsRow(icon: "doc.text.magnifyingglass", title: "Certificate inspector",
                                    subtitle: "Every cert the app can serve, field by field") { screen = .certInspector }
                        SettingsRow(icon: "eye.trianglebadge.exclamationmark", title: "What leaves this device",
                                    subtitle: "Endpoints, what's sent, and live self-checks") { screen = .transparency }
                    }

                    SettingsSection("Templates") {
                        SettingsRow(icon: "puzzlepiece.extension.fill", title: "Dylib project",
                                    subtitle: "Theos · runtime swizzle · Actions build") { screen = .dylibTemplate }
                        SettingsRow(icon: "app.badge.fill", title: "IPA app project",
                                    subtitle: "SwiftUI · XcodeGen · unsigned Actions build") { screen = .ipaTemplate }
                    }

                    SettingsSection("Learn") {
                        SettingsRow(icon: "book.fill", title: "Tutorials",
                                    subtitle: "\(TutorialLibrary.all.count) guides · phone-only workflow, FLEX, hooking, certs") { screen = .tutorials }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 30)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                ZStack {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(Theme.accent)
                        Text("GITHUB").font(.system(size: 15, weight: .heavy, design: .rounded)).kerning(1).foregroundStyle(Theme.text)
                        Spacer()
                    }
                    Text(config.repo.isEmpty ? "Setup" : "\(config.owner)/\(config.repo)")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.subtle)
                        .frame(maxWidth: .infinity).padding(.horizontal, 120).lineLimit(1).truncationMode(.middle)
                    HStack {
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                                .frame(width: 34, height: 34).background(Theme.accent.opacity(0.14)).clipShape(Circle())
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .floatingGlassBar(edge: .top)
            }
        }
        .fullScreenCover(item: $screen) { s in
            Group {
                switch s {
                case .github, .account, .localZSignAPI, .about, .certificates, .otaDomain, .extras, .tableView, .nativeInstall:
                    EmptyView()
                case .signingRequestCertificate: CertificateRequestView()
                case .repo:  RepoScreen()
                case .token: TokenScreen()
                case .certInspector: CertInspectorScreen()
                case .transparency:  TransparencyScreen()
                case .recoverData:   McryptedRecoverView()
                case .dylibTemplate: DylibTemplateScreen()
                case .ipaTemplate:   IPATemplateScreen()
                case .tutorials:     TutorialsListScreen()
                }
            }
            .environmentObject(config)
            .environmentObject(session)
            .preferredColorScheme(AppTheme.shared.colorScheme)
        }
    }

    private var repoSubtitle: String {
        guard !config.owner.isEmpty, !config.repo.isEmpty else { return "Set owner, repo and branch" }
        return "\(config.owner)/\(config.repo) @ \(config.branch.isEmpty ? "main" : config.branch)"
    }
}

// MARK: - Section

private struct SettingsSection<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder var content: Content

    init(_ title: String, trailing: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.trailing = trailing; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .semibold)).kerning(1.1)
                    .foregroundStyle(Theme.subtle)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.subtle.opacity(0.8))
                }
            }
            .padding(.top, 18).padding(.bottom, 6)

            VStack(spacing: 0) { content }
        }
    }
}

// MARK: - Rows

private let rowHeight: CGFloat = 64

private struct RowBody: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    let icon: String
    var imageName: String? = nil
    var imageURL: URL? = nil
    let title: String
    let subtitle: String
    var trailingIcon: String = "arrow.up.forward.square"

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
                if let imageName, let ui = UIImage(named: imageName) {
                    Image(uiImage: ui)
                        .resizable().scaledToFill()
                        .frame(width: 38, height: 38)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else if let imageURL {
                    AsyncImage(url: imageURL) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        } else {
                            Image(systemName: icon)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.subtle).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: trailingIcon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .frame(height: rowHeight)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 0.5).padding(.leading, 52)
        }
    }
}

private struct SettingsRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RowBody(icon: icon, title: title, subtitle: subtitle)
        }
        .buttonStyle(RowPressStyle())
    }
}

private struct SettingsLink: View {
    let icon: String
    var imageName: String? = nil
    var imageURL: URL? = nil
    let title: String
    let subtitle: String
    let url: URL
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button { openURL(url) } label: {
            RowBody(icon: icon, imageName: imageName, imageURL: imageURL, title: title, subtitle: subtitle, trailingIcon: "safari")
        }
        .buttonStyle(RowPressStyle())
    }
}

private struct SourceUpdateControls: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @ObservedObject private var watcher = LocalSourceUpdateWatcher.shared
    @ObservedObject private var certs = CertificateStore.shared

    private func toggle(_ icon: String, _ title: String, _ subtitle: String, _ get: @escaping () -> Bool, _ set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.14))
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.subtle).lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: get, set: set)).labelsHidden().tint(Theme.accent)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    var body: some View {
        VStack(spacing: 0) {
            toggle("eye.fill", "Monitor Added Sources", "Scan every source saved in Browse",
                   { watcher.enabled }, { watcher.setEnabled($0) })
            Divider().overlay(Theme.stroke)
            toggle("signature", "Automatic Local Signing", certs.active.map { "Signs with \($0.name)" } ?? "Needs an active certificate",
                   { watcher.automaticSigning }, { watcher.setAutomaticSigning($0) })
            Divider().overlay(Theme.stroke)
            toggle("bell.badge.fill", "Update Notifications", "Notify when a new version is found or signing fails",
                   { watcher.notificationsEnabled }, { watcher.setNotificationsEnabled($0) })
            Divider().overlay(Theme.stroke)
            Button { Task { await watcher.scanAllSources(reason: "manual") } } label: {
                RowBody(icon: watcher.scanning ? "arrow.triangle.2.circlepath" : "arrow.clockwise",
                        title: watcher.scanning ? "Scanning…" : "Scan All Sources",
                        subtitle: watcher.lastScan.map { "Last scan \($0.formatted(date: .abbreviated, time: .shortened)) · \(watcher.updatesFound) update(s)" } ?? watcher.lastMessage,
                        trailingIcon: "chevron.right")
            }
            .buttonStyle(RowPressStyle())
        }
    }
}

private struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color.white.opacity(0.05) : .clear)
    }
}

// MARK: - Footer (AirShare-style identity + status pill)

private struct StatusFooter: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @EnvironmentObject var config: Config
    @ObservedObject private var staff = StaffGate.shared
    @ObservedObject private var account = ZefvAccount.shared
    @State private var checking = false
    @State private var showAccount = false

    private var role: UserRole { staff.isStaff ? staff.role : account.role }

    var body: some View {
        VStack(spacing: 8) {
            if account.isLoggedIn {
                // Signed-in: signature · username, then ADID and role inline.
                HStack(spacing: 8) {
                    Image(systemName: "signature").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                    StyledUsername(name: account.username ?? "", style: account.style, base: 15)
                    refreshButton
                }
                HStack(spacing: 8) {
                    mdidPill
                    rolePill
                }
            } else {
                // Guest: create-account CTA, then role + ADID underneath
                Button { showAccount = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 16, weight: .semibold))
                        Text("Create an AirShare account").font(.system(size: 15, weight: .bold)).underline()
                    }
                    .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                HStack(spacing: 8) {
                    mdidPill
                    rolePill
                    refreshButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
        .sheet(isPresented: $showAccount) { ZefvAccountScreen(mode: .register) }
    }

    private var rolePill: some View {
        Text(role.badgeText)
            .font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(role.color.opacity(0.18)).foregroundStyle(role.color)
            .overlay(Capsule().stroke(role.color.opacity(0.5), lineWidth: 1)).clipShape(Capsule())
    }

    private var refreshButton: some View {
        Button {
            guard !checking else { return }
            checking = true
            Task { await staff.refresh(); checking = false }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.subtle)
                .rotationEffect(.degrees(checking ? 360 : 0))
                .animation(checking ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default, value: checking)
        }
        .buttonStyle(.plain)
    }

    private var mdidPill: some View {
        HStack(spacing: 4) {
            Text("ADID")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.subtle)
            Text(staff.mdid)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.white.opacity(0.04))
        .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
        .clipShape(Capsule())
        .onTapGesture {
            UIPasteboard.general.string = staff.mdid
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }
}

// MARK: - Signing Settings (signing tools)

private struct TableViewSettingsScreen: View {
    @EnvironmentObject var config: Config
    @EnvironmentObject var session: Session
    @State private var showAPI = false
    @State private var showDomain = false

    var body: some View {
        DetailScreen(title: "Settings") {
            VStack(alignment: .leading, spacing: 0) {
                SettingsSection("Signing tools") {
                    SettingsRow(icon: "bolt.horizontal.circle.fill", title: "Local ZSign API",
                                subtitle: "127.0.0.1:\(LocalZSignAPI.shared.port) · loopback signing control") { showAPI = true }
                    SettingsRow(icon: "network", title: "AirShare Domain",
                                subtitle: "\(ServerConfig.installHost) · certbot via Actions") { showDomain = true }
                }
            }
        }
        .fullScreenCover(isPresented: $showAPI) {
            LocalZSignAPISettingsView().environmentObject(config).environmentObject(session).preferredColorScheme(.dark)
        }
        .fullScreenCover(isPresented: $showDomain) {
            OTADomainScreen().environmentObject(config).environmentObject(session).preferredColorScheme(.dark)
        }
    }
}

// MARK: - Extras (auto-update signing)

private struct ExtrasScreen: View {
    var body: some View {
        DetailScreen(title: "Extras") {
            VStack(alignment: .leading, spacing: 0) {
                SettingsSection("Auto-Update Signing") {
                    SourceUpdateControls()
                }
            }
        }
    }
}

// MARK: - Detail screen shell

private struct DetailScreen<Content: View>: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read accent live (auto-cycle) without rebuilding
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) { content }
                .padding(16)
        }
        // Floating glass header — content scrolls underneath it.
        .safeAreaInset(edge: .top, spacing: 0) {
            ZStack {
                HStack(spacing: 8) {
                    Image(systemName: "archivebox.fill").foregroundStyle(Theme.accent)
                    Text("AIRSHARE")
                        .font(.system(size: 15, weight: .heavy, design: .rounded))
                        .kerning(1).foregroundStyle(Theme.text)
                    Spacer()
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.subtle)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 140)
                    .lineLimit(1)
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 34, height: 34)
                            .background(Theme.accent.opacity(0.14))
                            .clipShape(Circle())
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .floatingGlassBar(edge: .top)
        }
        .background(Theme.bg.ignoresSafeArea())
        .scrollDismissesKeyboard(.interactively)
    }
}

private struct Field: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    var secure = false
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(Theme.subtle)
            Group {
                if secure { SecureField(placeholder, text: $text) }
                else { TextField(placeholder, text: $text) }
            }
            .keyboardType(keyboard)
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            .padding(12).background(Theme.bg).foregroundStyle(Theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
        }
    }
}

// MARK: - About

private func statusLine(_ name: String, _ ok: Bool) -> some View {
    HStack(spacing: 8) {
        Circle().fill(ok ? Color.green : Color.red).frame(width: 8, height: 8)
        Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
        Spacer()
        Text(ok ? "OK" : "DOWN").font(.system(size: 10, weight: .heavy, design: .monospaced)).kerning(1).foregroundStyle(ok ? .green : .red)
    }
}

private struct AboutScreen: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @Environment(\.openURL) private var openURL

    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? Theme.appVersion
    }
    private var iosVersion: String { UIDevice.current.systemVersion }

    private struct Credit: Identifiable {
        let id = UUID()
        let name: String, blurb: String, asset: String, symbol: String, url: String
    }
    private let credits: [Credit] = [
        Credit(name: "MRZefv", blurb: "Built AirShare. Sign anything, keep it local.", asset: "airshare_mark", symbol: "person.fill", url: "https://airshare.lol"),
        Credit(name: "DELvEK", blurb: "Trusted partner. Respected, protected apps updated daily with screenshots.", asset: "delvek_logo", symbol: "pawprint.fill", url: "https://delvek.net"),
    ]
    private let sponsors: [(String, Color)] = [
        ("MYKALL", Color(red: 0.42, green: 0.85, blue: 0.45)),
        ("JIMEDUDE.", Color(red: 0.40, green: 0.72, blue: 0.95)),
        ("DELvEK", Color(red: 0.74, green: 0.35, blue: 0.88)),
    ]

    var body: some View {
        DetailScreen(title: "About") {
            VStack(spacing: 0) {
                // App icon · name · version | iOS
                // AirCore logo: transparent, no tile behind it — it just floats with a soft glow.
                Image("aircore_logo")
                    .resizable().scaledToFit()
                    .frame(width: 130, height: 130)
                    .shadow(color: Theme.accent.opacity(0.55), radius: 18)
                    .padding(.top, 18)

                Text(Theme.appName).font(.system(size: 34, weight: .bold)).foregroundStyle(Theme.text).padding(.top, 18)
                HStack(spacing: 10) {
                    Text("Version \(version)")
                    Text("|").foregroundStyle(Theme.subtle)
                    Text("iOS \(iosVersion)")
                }
                .font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text.opacity(0.9)).padding(.top, 8)

                // Credits
                sectionLabel("CREDITS").padding(.top, 54)
                Rectangle().fill(Theme.stroke).frame(height: 0.5)
                ForEach(Array(credits.enumerated()), id: \.element.id) { idx, c in
                    Button { if let u = URL(string: c.url) { openURL(u) } } label: {
                        HStack(spacing: 14) {
                            Group {
                                if UIImage(named: c.asset) != nil { Image(c.asset).resizable().scaledToFill() }
                                else { ZStack { Color.white.opacity(0.08); Image(systemName: c.symbol).foregroundStyle(Theme.subtle) } }
                            }
                            .frame(width: 46, height: 46).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(c.name).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text)
                                Text(c.blurb).font(.system(size: 14)).foregroundStyle(Theme.subtle).lineLimit(2).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 6)
                            Image(systemName: "arrow.up.right.square").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent)
                        }
                        .padding(.vertical, 14).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if idx < credits.count - 1 { Rectangle().fill(Theme.stroke).frame(height: 0.5).padding(.leading, 60) }
                }
                Rectangle().fill(Theme.stroke).frame(height: 0.5).padding(.leading, 60)

                // Sponsors
                sectionLabel("SPONSORS").padding(.top, 34)
                HStack(spacing: 0) {
                    ForEach(Array(sponsors.enumerated()), id: \.offset) { i, sp in
                        Text(sp.0).font(.system(size: 22, weight: .semibold)).foregroundStyle(sp.1)
                        if i < sponsors.count - 1 { Text(", ").font(.system(size: 22)).foregroundStyle(Theme.subtle) }
                    }
                    Spacer(minLength: 0)
                }
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.top, 14).padding(.horizontal, 4)

                HStack(spacing: 14) {
                    Rectangle().fill(Theme.stroke).frame(height: 1)
                    Image(systemName: "cylinder.fill").font(.system(size: 22)).foregroundStyle(Theme.subtle)
                    Rectangle().fill(Theme.stroke).frame(height: 1)
                }
                .padding(.top, 36)

                Text("It puts the lotion on the dirty skin or the sponsor gets it again!")
                    .font(.system(size: 14, design: .monospaced)).foregroundStyle(Theme.subtle)
                    .multilineTextAlignment(.center).padding(.top, 26).padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func sectionLabel(_ t: String) -> some View {
        HStack { Text(t).font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.subtle).padding(.leading, 4); Spacer() }
            .padding(.bottom, 12)
    }
}

// MARK: - Repository

private struct RepoScreen: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @EnvironmentObject var config: Config
    @State private var checking = false
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        DetailScreen(title: "Repository") {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Target repo", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline).foregroundStyle(Theme.text)
                    Field(label: "Owner", text: config.cleaned(\.owner), placeholder: "mrzefv")
                    Field(label: "Repo", text: config.cleaned(\.repo), placeholder: "my-repo")
                    Field(label: "Branch", text: config.cleaned(\.branch), placeholder: "main")
                    Field(label: "Subpath (optional)", text: config.cleaned(\.subpath), placeholder: "e.g. incoming")
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Connection", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.headline).foregroundStyle(Theme.text)
                    Text("Checks the repo and branch are reachable with the saved token.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                    Button { Task { await check() } } label: {
                        HStack {
                            if checking { ProgressView().tint(.black) }
                            else { Image(systemName: "checkmark.shield.fill") }
                            Text(checking ? "Checking…" : "Test connection").fontWeight(.semibold)
                            Spacer()
                        }
                        .padding(.vertical, 12).padding(.horizontal, 14)
                        .background(canCheck ? Theme.accent : Theme.subtle)
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(!canCheck || checking)
                    if let result {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(ok ? .green : .red)
                            Text(result).font(.caption).foregroundStyle(Theme.text)
                        }
                    }
                }
            }
        }
    }

    private var canCheck: Bool { config.hasToken && !config.owner.isEmpty && !config.repo.isEmpty }

    private func check() async {
        checking = true; result = nil
        let client = GitHubClient(owner: config.owner, repo: config.repo,
                                  branch: config.branch.isEmpty ? "main" : config.branch, token: config.token)
        do {
            let v = try await client.verify()
            ok = true
            result = "\(v.fullName) · branch \(v.branch) · \(v.permission)"
        } catch {
            ok = false
            result = error.localizedDescription
        }
        checking = false
    }
}

// MARK: - Token

private struct TokenScreen: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @EnvironmentObject var config: Config
    @State private var show = false

    var body: some View {
        DetailScreen(title: "Access token") {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Label("GitHub PAT", systemImage: "key.fill").font(.headline).foregroundStyle(Theme.text)
                    Text("Fine-grained or classic PAT with Contents: read & write on the target repo. Stored in the Keychain, never leaves the device except to api.github.com.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                    HStack(spacing: 10) {
                        Field(label: "Token", text: config.cleaned(\.token), placeholder: "github_pat_… / ghp_…", secure: !show)
                        Button { show.toggle() } label: {
                            Image(systemName: show ? "eye.slash" : "eye")
                                .font(.system(size: 17)).foregroundStyle(Theme.subtle)
                                .frame(width: 40, height: 40)
                        }
                        .padding(.top, 18)
                    }
                    if config.hasToken {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text("Saved · \(config.token.prefix(11))…")
                                .font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                        }
                        Button(role: .destructive) { config.token = "" } label: {
                            Label("Clear token", systemImage: "trash").font(.caption)
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Required scope").font(.headline).foregroundStyle(Theme.text)
                    Text("Fine-grained: Repository permissions → Contents: Read and write, Actions: Read and write (Build tab), Workflows: Read and write (if the drop has .github/workflows).\nClassic: repo + workflow.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                    Link("Create a token on GitHub", destination: URL(string: "https://github.com/settings/tokens")!)
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                }
            }
        }
    }
}


// MARK: - Templates

private struct DylibTemplateScreen: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var name = "MRvEKTweak"
    @State private var target = ""
    @State private var author = "MRzefv"

    var body: some View {
        DetailScreen(title: "Dylib project") {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Theos dylib, no Substrate", systemImage: "puzzlepiece.extension.fill")
                        .font(.headline).foregroundStyle(Theme.text)
                    Text("Makefile + Tweak.xm with a runtime-swizzle helper and an example overlay hook, bundle-filter plist, control, and a GitHub Actions workflow that installs Theos and uploads the .dylib as an artifact. Works sideloaded via AirShare or on a jailbreak.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                    Field(label: "Tweak name", text: $name, placeholder: "MRvEKTweak")
                    Field(label: "Target bundle id", text: $target, placeholder: "com.audiomack.iphone")
                    Field(label: "Author handle", text: $author, placeholder: "MRzefv")
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Files").font(.headline).foregroundStyle(Theme.text)
                    ForEach(["Makefile", "Tweak.xm", "<name>.plist", "control", ".github/workflows/build.yml", "README.md"], id: \.self) {
                        Text("· " + $0).font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                    }
                }
            }
            generate("Generate dylib project") {
                ProjectTemplate.dylib(name: name, target: target, author: author.isEmpty ? "MRzefv" : author)
            }
            Text("Then: Push → Build tab → download <name>-dylib → inject with AirShare. See Tutorials for the FLEX walkthrough.")
                .font(.caption2).foregroundStyle(Theme.subtle)
        }
    }

    private func generate(_ title: String, _ make: @escaping () -> [(path: String, content: String)]) -> some View {
        Button {
            session.loadGenerated(name: name.isEmpty ? "MRvEKTweak" : name, files: make())
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } label: {
            HStack { Image(systemName: "wand.and.stars"); Text(title).fontWeight(.semibold); Spacer() }
                .padding(.vertical, 12).padding(.horizontal, 14)
                .background(Theme.accent).foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct IPATemplateScreen: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @EnvironmentObject var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var name = "MRvEKApp"
    @State private var bundle = ""
    @State private var author = "MRzefv"

    var body: some View {
        DetailScreen(title: "IPA app project") {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Label("SwiftUI app, unsigned IPA", systemImage: "app.badge.fill")
                        .font(.headline).foregroundStyle(Theme.text)
                    Text("project.yml (XcodeGen) so there's no pbxproj to maintain by hand, a custom-shell RootView with the same header/tab-bar pattern as this app, launch screen set so it's full-screen, and a workflow that generates the project, builds unsigned and uploads <name>.ipa. Sign with AirShare to install.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                    Field(label: "App name", text: $name, placeholder: "MRvEKApp")
                    Field(label: "Bundle id", text: $bundle, placeholder: "party.mrvek.app")
                    Field(label: "Author handle", text: $author, placeholder: "MRzefv")
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Files").font(.headline).foregroundStyle(Theme.text)
                    ForEach(["project.yml", "Sources/<name>App.swift", "Sources/Theme.swift", "Sources/RootView.swift", "Assets.xcassets/…", ".github/workflows/build.yml", "README.md"], id: \.self) {
                        Text("· " + $0).font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                    }
                }
            }
            Button {
                session.loadGenerated(name: name.isEmpty ? "MRvEKApp" : name,
                                      files: ProjectTemplate.ipaApp(name: name, bundleID: bundle, author: author.isEmpty ? "MRzefv" : author))
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
            } label: {
                HStack { Image(systemName: "wand.and.stars"); Text("Generate IPA project").fontWeight(.semibold); Spacer() }
                    .padding(.vertical, 12).padding(.horizontal, 14)
                    .background(Theme.accent).foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text("Then: Push → Build tab → download <name>-ipa → sign in AirShare.")
                .font(.caption2).foregroundStyle(Theme.subtle)
        }
    }
}


// MARK: - Table plumbing shared by the AirShare screens

/// Inset-grouped table screen with the app's dark chrome. Root screens get a
/// chevron-down dismiss; pushed screens get the system back button.
private struct TableScreen<Content: View>: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    let title: String
    var root = false
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List { content }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if root {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.down").font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Theme.accent).frame(width: 34, height: 34)
                                .background(Theme.accent.opacity(0.14)).clipShape(Circle())
                        }
                    }
                }
            }
    }
}

private struct TRow: View {          // label · value
    let k: String; let v: String
    var tint: Color = Theme.text
    var body: some View {
        HStack {
            Text(k).foregroundStyle(Theme.subtle)
            Spacer(minLength: 12)
            Text(v).font(.system(size: 15, design: .monospaced)).foregroundStyle(tint)
                .lineLimit(1).truncationMode(.middle).multilineTextAlignment(.trailing)
        }
        .listRowBackground(Theme.card)
    }
}

private struct TStatusRow: View {    // icon · text (green/orange)
    let ok: Bool; let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.shield.fill" : "exclamationmark.shield.fill").foregroundStyle(ok ? .green : .orange)
            Text(text).font(.subheadline).foregroundStyle(ok ? .green : .orange)
        }
        .listRowBackground(Theme.card)
    }
}

private struct TNav<Dest: View>: View {   // icon · title · subtitle › pushes Dest
    let icon: String; let title: String; var subtitle: String = ""
    @ViewBuilder var dest: Dest
    var body: some View {
        NavigationLink {
            dest
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(Theme.text)
                    if !subtitle.isEmpty { Text(subtitle).font(.caption).foregroundStyle(Theme.subtle).lineLimit(2) }
                }
            }
        }
        .listRowBackground(Theme.card)
    }
}

private struct TButton: View {       // full-width action row
    let title: String; let icon: String
    var role: ButtonRole? = nil
    var busy = false
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                if busy { ProgressView().tint(Theme.accent) } else { Image(systemName: icon) }
                Text(title).fontWeight(.semibold)
                Spacer()
            }
            .foregroundStyle(role == .destructive ? .red : (enabled ? Theme.accent : Theme.subtle))
        }
        .disabled(busy || !enabled)
        .listRowBackground(Theme.card)
    }
}

private struct TField: View {        // label · text field on one row
    let label: String
    @Binding var text: String
    var placeholder = ""
    var keyboard: UIKeyboardType = .default
    var body: some View {
        HStack {
            Text(label).foregroundStyle(Theme.subtle)
            Spacer(minLength: 12)
            TextField(placeholder, text: $text)
                .keyboardType(keyboard).textInputAutocapitalization(.never).autocorrectionDisabled()
                .multilineTextAlignment(.trailing).foregroundStyle(Theme.text)
                .font(.system(size: 15, design: .monospaced))
        }
        .listRowBackground(Theme.card)
    }
}

private struct TNote: View {         // footer-ish explanatory row
    let text: String
    var tint: Color = Theme.subtle
    var body: some View {
        Text(text).font(.caption).foregroundStyle(tint).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 6, trailing: 4))
    }
}

private func certPill(_ exp: Date?) -> some View {
    let days = exp.map { Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0 } ?? -1
    let color: Color = exp == nil ? .orange : (days < 0 ? .red : (days < ServerConfig.refreshBufferDays ? .orange : .green))
    let text = exp == nil ? "MISSING" : (days < 0 ? "EXPIRED" : (days < ServerConfig.refreshBufferDays ? "\(days)D LEFT" : "READY"))
    return Text(text).font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(color.opacity(0.18)).foregroundStyle(color).clipShape(Capsule())
}

/// Shared, observable snapshot of the AirShare cert state so every pushed screen
/// re-renders the root when it changes something.
@MainActor
private final class OTAState: ObservableObject {
    @Published var mode = ServerConfig.certMode
    @Published var host = ServerConfig.installHost
    @Published var domain = ServerConfig.certDomain
    @Published var sans: [String] = []
    @Published var expires: Date?
    @Published var rootTrusted = false
    @Published var hasRoot = false
    @Published var hasLeaf = false
    @Published var hasCustom = false
    @Published var cached = false
    @Published var fetchedAt: Date?
    @Published var files: [URL] = []

    func reload() {
        LocalCAManager.rehydrateIfNeeded()
        mode = ServerConfig.certMode; host = ServerConfig.installHost; domain = ServerConfig.certDomain
        hasRoot = LocalCAManager.hasRoot; hasLeaf = LocalCAManager.hasLeaf; hasCustom = ZefvCert.hasCustom
        rootTrusted = LocalCAManager.isRootTrusted()
        cached = ZefvCert.hasCached; fetchedAt = ZefvCert.meta?.fetchedAt
        switch mode {
        case "local":  sans = LocalCAManager.leafSANs(); expires = LocalCAManager.leafExpiry
        case "custom": sans = ZefvCert.customSANs;       expires = ZefvCert.customNotAfter
        default:       sans = ZefvCert.effectiveSANs;    expires = ZefvCert.effectiveNotAfter
        }
        files = OTAFiles.list()
    }

    var have: Bool { mode == "local" ? hasLeaf : (mode == "custom" ? hasCustom : ZefvCert.isAvailable) }
    var coversHost: Bool { mode == "local" ? LocalCAManager.covers(host) : ZefvCert.covers(host, sans: sans) }
    var ready: Bool { have && coversHost && (mode != "local" || rootTrusted) }
    var modeName: String { mode == "local" ? "Local CA" : (mode == "custom" ? "Own cert" : "airshare.lol") }
    var statusText: String { ready ? "READY" : (have ? (coversHost ? "NOT TRUSTED" : "MISMATCH") : "MISSING") }
}

// MARK: - AirShare (root table)

struct OTADomainScreen: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @EnvironmentObject var config: Config
    @StateObject private var st = OTAState()

    var body: some View {
        NavigationStack {
            TableScreen(title: "AirShare", root: true) {

                Section {
                    Picker(selection: Binding(get: { st.mode }, set: { m in
                        ServerConfig.setCertMode(m)
                        if m == "public" {
                            ServerConfig.setCertDomain(ServerConfig.defaultDomain)
                            if !ServerConfig.installHost.hasSuffix("." + ServerConfig.defaultDomain) { ServerConfig.setInstallHost(ServerConfig.defaultInstallHost) }
                        }
                        st.reload()
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    })) {
                        Label("airshare.lol · VPS auto-renew", systemImage: "globe").tag("public")
                        Label("Own TLS cert",             systemImage: "doc.badge.plus").tag("custom")
                        Label("Local root CA",            systemImage: "iphone").tag("local")
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.rotation").foregroundStyle(Theme.accent).frame(width: 26)
                            Text("Certificate mode").foregroundStyle(Theme.text)
                        }
                    }
                    .pickerStyle(.menu).tint(Theme.accent)
                    .listRowBackground(Theme.card)
                } footer: {
                    Text(st.mode == "public"
                         ? "Real Let's Encrypt wildcard for *.airshare.lol, renewed on the VPS (certbot + Cloudflare) and pulled here. Trusted by iOS out of the box."
                         : st.mode == "custom"
                         ? "Your own TLS cert for your own domain. Import fullchain + key; point the host at 127.0.0.1."
                         : "Your own root CA — offline, no DNS provider. iOS trusts it once the root profile is installed and enabled.")
                    .foregroundStyle(Theme.subtle)
                }

                Section {
                    HStack {
                        Label("Active cert", systemImage: "checkmark.seal").foregroundStyle(Theme.text)
                        Spacer()
                        Text(st.statusText).font(.system(size: 10, weight: .heavy, design: .monospaced)).kerning(0.5)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background((st.ready ? Color.green : Color.orange).opacity(0.18))
                            .foregroundStyle(st.ready ? .green : .orange).clipShape(Capsule())
                    }
                    .listRowBackground(Theme.card)
                    TRow(k: "Mode", v: st.modeName)
                    TRow(k: "Install host", v: st.host)
                    TRow(k: "Covers", v: st.sans.isEmpty ? "—" : st.sans.joined(separator: ", "))
                    TRow(k: "Expires", v: st.expires.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                    if st.mode == "local" {
                        TStatusRow(ok: st.rootTrusted, text: st.rootTrusted ? "Root CA installed & trusted on this device" : "Root CA not trusted yet — install the profile, then enable it in Settings › General › About › Certificate Trust Settings")
                    }
                    if st.have && !st.coversHost {
                        TStatusRow(ok: false, text: "The cert doesn't cover \(st.host).")
                    }
                }

                Section {
                    if st.mode != "local" {
                        TNav(icon: "network", title: "Install host & DNS", subtitle: st.host) { OTAHostScreen(st: st) }
                    }
                    switch st.mode {
                    case "local":
                        TNav(icon: "iphone", title: "Local CA", subtitle: st.hasRoot ? "Root ready · leaf \(st.hasLeaf ? "issued for \(LocalCAManager.meta?.host ?? st.host)" : "not issued")" : "Create root + leaf, install the trust profile") { LocalCAScreen(st: st) }
                    case "custom":
                        TNav(icon: "doc.badge.plus", title: "Own certificate", subtitle: st.hasCustom ? "Imported · \(st.sans.joined(separator: ", "))" : "Import fullchain + key (PEM)") { OwnCertScreen(st: st) }
                    default:
                        TNav(icon: "arrow.triangle.2.circlepath.circle", title: "airshare.lol certificate", subtitle: st.cached ? "Pulled from VPS · \(st.fetchedAt?.formatted(date: .abbreviated, time: .shortened) ?? "")" : "Bundled in IPA · pull from VPS to refresh") { VPSCertScreen(st: st) }
                    }
                } header: {
                    Text("Setup")
                }

                Section {
                    TNav(icon: "folder", title: "Exported files", subtitle: st.files.isEmpty ? "Nothing exported yet" : "\(st.files.count) file\(st.files.count == 1 ? "" : "s") · Files › On My iPhone › AirShare › AirShare Certs") { OTAFilesScreen(st: st) }
                } footer: {
                    Text("Certs, chains and the trust profile are copied into a folder the Files app can see whenever you issue or install. Private keys never leave the Keychain.").foregroundStyle(Theme.subtle)
                }
            }
        }
        .onAppear { st.reload() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in st.reload() }
    }
}

// MARK: - Install host & DNS

private struct OTAHostScreen: View {
    @ObservedObject var st: OTAState
    @State private var domain = ServerConfig.certDomain
    @State private var host = ServerConfig.installHost
    @State private var dnsLoopback: Bool?
    @State private var checking = false
    @State private var saved = false

    private var cleanDomain: String {
        domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "*.", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/."))
    }
    private var cleanHost: String {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return h.isEmpty ? (cleanDomain == ServerConfig.defaultDomain ? ServerConfig.defaultInstallHost : "mr.\(cleanDomain)") : h
    }
    private var domainOK: Bool { cleanDomain.contains(".") && !cleanDomain.contains(" ") }
    private var hostOK: Bool { domainOK && (cleanHost.hasSuffix("." + cleanDomain) || cleanHost == cleanDomain) }

    var body: some View {
        TableScreen(title: "Install host & DNS") {
            Section {
                if st.mode != "public" { TField(label: "Domain", text: $domain, placeholder: "example.com", keyboard: .URL) }
                TField(label: "Install host", text: $host, placeholder: ServerConfig.defaultInstallHost, keyboard: .URL)
            } footer: {
                Text(st.mode == "public"
                     ? "On Cloudflare, *.airshare.lol points at the VPS, so the AirShare host is the dedicated ota.airshare.lol A record → 127.0.0.1 (DNS only). One label under the wildcard, so the *.airshare.lol cert covers it."
                     : "The install host must resolve to 127.0.0.1 via an A record — iOS silently drops the install prompt otherwise. The cert must cover it (wildcard *.<domain> covers any single label).")
                .foregroundStyle(Theme.subtle)
            }

            Section {
                HStack(spacing: 10) {
                    Image(systemName: checking ? "hourglass" : (dnsLoopback == true ? "checkmark.circle.fill" : (dnsLoopback == false ? "xmark.octagon.fill" : "questionmark.circle")))
                        .foregroundStyle(dnsLoopback == true ? .green : (dnsLoopback == false ? .red : Theme.subtle))
                    Text(checking ? "Resolving \(cleanHost)…"
                         : dnsLoopback == true ? "\(cleanHost) → 127.0.0.1"
                         : dnsLoopback == false ? "\(cleanHost) does not resolve to 127.0.0.1"
                         : "Not checked").font(.subheadline).foregroundStyle(Theme.text)
                    Spacer()
                }
                .listRowBackground(Theme.card)
                TButton(title: "Check DNS", icon: "arrow.clockwise", busy: checking, enabled: domainOK) { Task { await check() } }
            } header: {
                Text("DNS")
            }

            Section {
                if !domainOK { TStatusRow(ok: false, text: "Enter a domain like example.com") }
                else if !hostOK { TStatusRow(ok: false, text: "Host must be under \(cleanDomain).") }
                else if !st.sans.isEmpty, !ZefvCert.covers(cleanHost, sans: st.sans) { TStatusRow(ok: false, text: "Cert covers \(st.sans.joined(separator: ", ")) — not \(cleanHost).") }
                TButton(title: saved ? "Saved" : "Save", icon: saved ? "checkmark.circle.fill" : "square.and.arrow.down", enabled: hostOK) {
                    ServerConfig.setCertDomain(cleanDomain); ServerConfig.setInstallHost(cleanHost)
                    domain = ServerConfig.certDomain; host = ServerConfig.installHost; saved = true
                    st.reload(); UINotificationFeedbackGenerator().notificationOccurred(.success)
                    Task { await check() }
                }
            }
        }
        .onChange(of: host) { _ in saved = false; dnsLoopback = nil }
        .onChange(of: domain) { _ in saved = false; dnsLoopback = nil }
        .task { await check() }
    }

    private func check() async {
        guard domainOK else { return }
        checking = true; dnsLoopback = await ZefvCert.resolvesToLoopback(cleanHost); checking = false
    }
}

// MARK: - airshare.lol certificate (VPS)

private struct VPSCertScreen: View {
    @ObservedObject var st: OTAState
    @State private var refreshing = false
    @State private var error: String?
    @State private var note: String?

    var body: some View {
        TableScreen(title: "airshare.lol certificate") {
            Section {
                HStack { Text("Status").foregroundStyle(Theme.subtle); Spacer(); certPill(ZefvCert.effectiveNotAfter) }.listRowBackground(Theme.card)
                TRow(k: "In use", v: st.cached ? "Pulled from VPS" : "Bundled in IPA")
                TRow(k: "Covers", v: ZefvCert.effectiveSANs.isEmpty ? "—" : ZefvCert.effectiveSANs.joined(separator: ", "))
                TRow(k: "Expires", v: ZefvCert.effectiveNotAfter.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                TRow(k: "Last pull", v: st.fetchedAt?.formatted(date: .abbreviated, time: .shortened) ?? "never")
            }

            Section {
                TButton(title: refreshing ? "Fetching…" : "Pull latest from VPS", icon: "arrow.down.circle", busy: refreshing) { Task { await refresh() } }
                if st.cached { TButton(title: "Forget pulled copy (use bundled)", icon: "trash", role: .destructive) { ZefvCert.clearCache(); st.reload() } }
                if let error { TStatusRow(ok: false, text: error) }
                if let note { TStatusRow(ok: true, text: note) }
            } footer: {
                Text("certbot on the VPS renews *.airshare.lol through the Cloudflare DNS API; the app auto-pulls on install when within \(ServerConfig.refreshBufferDays) days of expiry. Pull latest forces it now.").foregroundStyle(Theme.subtle)
            }
        }
    }

    private func refresh() async {
        refreshing = true; error = nil; note = nil
        do {
            _ = try await ZefvCert.fetch()
            OTAFiles.exportPublicChain(); st.reload()
            note = "Certificate pulled from AirShare"
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { self.error = error.localizedDescription }
        refreshing = false
    }
}

// MARK: - Own certificate

private struct OwnCertScreen: View {
    @ObservedObject var st: OTAState
    @State private var showPicker = false
    @State private var error: String?
    @State private var note: String?

    var body: some View {
        TableScreen(title: "Own certificate") {
            Section {
                HStack { Text("Status").foregroundStyle(Theme.subtle); Spacer(); if st.hasCustom { certPill(ZefvCert.customNotAfter) } else { Text("MISSING").font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(.orange) } }.listRowBackground(Theme.card)
                if st.hasCustom {
                    TRow(k: "Covers", v: ZefvCert.customSANs.joined(separator: ", "))
                    TRow(k: "Expires", v: ZefvCert.customNotAfter.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                    if !ZefvCert.covers(st.host, sans: ZefvCert.customSANs) { TStatusRow(ok: false, text: "Doesn't cover \(st.host) — change the install host or import a cert for it.") }
                }
            } footer: {
                Text("Bring the cert you already have for your domain — Let's Encrypt, ZeroSSL, Cloudflare Origin, anything iOS trusts. Pick the fullchain (.pem/.crt) and the private key (.pem/.key), or one combined PEM. The key must be unencrypted PEM; it stays on this device.").foregroundStyle(Theme.subtle)
            }
            Section {
                TButton(title: st.hasCustom ? "Replace cert + key" : "Import cert + key", icon: "square.and.arrow.down") { error = nil; note = nil; showPicker = true }
                if st.hasCustom { TButton(title: "Remove imported cert", icon: "trash", role: .destructive) { ZefvCert.clearCustom(); st.reload() } }
                if let error { TStatusRow(ok: false, text: error) }
                if let note { TStatusRow(ok: true, text: note) }
            } footer: {
                Text("Nothing renews automatically in this mode — when the cert expires, import the renewed pair.").foregroundStyle(Theme.subtle)
            }
        }
        .sheet(isPresented: $showPicker) {
            DocPicker(types: [.item]) { urls in
                guard !urls.isEmpty else { return }
                do {
                    try ZefvCert.importCustom(files: urls)
                    OTAFiles.exportPublicChain()
                    note = "Imported \(urls.count) file\(urls.count == 1 ? "" : "s")."
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } catch { self.error = error.localizedDescription }
                st.reload()
            }
        }
    }
}

// MARK: - Exported files

private struct OTAFilesScreen: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @ObservedObject var st: OTAState
    @Environment(\.openURL) private var openURL
    @State private var share: URLItem?

    var body: some View {
        TableScreen(title: "Exported files") {
            Section {
                TRow(k: "Folder", v: "Files › On My iPhone › AirShare › AirShare Certs")
                if let u = OTAFiles.filesAppURL {
                    TButton(title: "Open in Files", icon: "folder") { openURL(u) }
                }
                TButton(title: "Export again", icon: "arrow.triangle.2.circlepath") {
                    if st.mode == "local" { OTAFiles.exportLocalCA() } else { OTAFiles.exportPublicChain() }
                    st.reload(); UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
            Section {
                if st.files.isEmpty {
                    Text("Nothing exported yet.").foregroundStyle(Theme.subtle).listRowBackground(Theme.card)
                }
                ForEach(st.files, id: \.path) { u in
                    Button { share = URLItem(url: u) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: u.pathExtension == "mobileconfig" ? "doc.badge.gearshape" : (u.pathExtension == "txt" ? "doc.text" : "doc.badge.ellipsis"))
                                .foregroundStyle(Theme.accent).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(u.lastPathComponent).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                                Text(sizeString(u)).font(.caption).foregroundStyle(Theme.subtle)
                            }
                            Spacer()
                            Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.subtle)
                        }
                    }
                    .listRowBackground(Theme.card)
                }
            } header: {
                Text("Files")
            }
            if !st.files.isEmpty {
                Section { TButton(title: "Clear folder", icon: "trash", role: .destructive) { OTAFiles.clear(); st.reload() } }
            }
        }
        .sheet(item: $share) { ShareSheet(items: [$0.url]) }
    }

    private func sizeString(_ u: URL) -> String {
        let n = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

// MARK: - Local CA

private struct LocalCAScreen: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @ObservedObject var st: OTAState
    @State private var host = ServerConfig.installHost
    @State private var working = false
    @State private var error: String?
    @State private var note: String?
    @State private var showProfileText = false
    @State private var share: URLItem?
    @State private var dnsLoopback: Bool?
    @State private var dnsChecking = false
    @State private var confirmDelete = false

    private var cleanHost: String {
        Config.clean(host).replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "*.", with: "").lowercased()
    }

    var body: some View {
        TableScreen(title: "Local CA") {
            Section {
                TRow(k: "Root CA", v: st.hasRoot ? "ready" : "not created", tint: st.hasRoot ? .green : .orange)
                TRow(k: "Leaf", v: st.hasLeaf ? "issued for \(LocalCAManager.meta?.host ?? "—")" : "not issued", tint: st.hasLeaf ? .green : .orange)
                TStatusRow(ok: st.rootTrusted, text: st.rootTrusted ? "Root profile installed & trusted on this device" : "Root profile not trusted on this device yet")
                TButton(title: "Re-check trust", icon: "arrow.clockwise") { st.reload() }
            } footer: {
                Text("Generates a root CA on this device (OpenSSL), signs a leaf for your AirShare host, and serves installs with it. Private keys stay in the Keychain (ThisDeviceOnly) — public certs are mirrored to iCloud Keychain so a reinstall keeps the same root.").foregroundStyle(Theme.subtle)
            }

            Section {
                TField(label: "AirShare host", text: $host, placeholder: ServerConfig.defaultInstallHost, keyboard: .URL)
                HStack(spacing: 10) {
                    Image(systemName: dnsChecking ? "hourglass" : (dnsLoopback == true ? "checkmark.circle.fill" : (dnsLoopback == false ? "xmark.octagon.fill" : "questionmark.circle")))
                        .foregroundStyle(dnsLoopback == true ? .green : (dnsLoopback == false ? .red : Theme.subtle))
                    Text(dnsChecking ? "Resolving…" : dnsLoopback == true ? "\(cleanHost) → 127.0.0.1" : dnsLoopback == false ? "\(cleanHost) does not resolve to 127.0.0.1" : "DNS not checked")
                        .font(.subheadline).foregroundStyle(Theme.text)
                    Spacer()
                    Button("Check") { Task { await checkDNS() } }.font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                }
                .listRowBackground(Theme.card)
                TButton(title: working ? "Working…" : (st.hasLeaf ? "Re-issue leaf for host" : "Create CA & issue leaf"), icon: "checkmark.seal.fill", busy: working) { Task { await issue() } }
            } header: {
                Text("1 · Host & leaf")
            } footer: {
                Text("The leaf covers this host and *.<host>. The host must ALSO resolve to 127.0.0.1 (A record, or a free name like 127-0-0-1.nip.io) or the install prompt never appears.").foregroundStyle(Theme.subtle)
            }

            if st.hasRoot {
                Section {
                    TButton(title: "Install trust profile", icon: "square.and.arrow.down") {
                        OTAFiles.exportLocalCA()
                        if let u = LocalCAManager.writeMobileConfig() { share = URLItem(url: u) } else { error = "Couldn't build the profile." }
                        st.reload()
                    }
                    TButton(title: "View profile contents", icon: "doc.text.magnifyingglass") { showProfileText = true }
                } header: {
                    Text("2 · Trust profile")
                } footer: {
                    Text("One payload: the root cert as a trusted-root payload. Unsigned, plain text. After installing, enable it in Settings › General › About › Certificate Trust Settings — the status above flips green on its own.").foregroundStyle(Theme.subtle)
                }

                Section {
                    TRow(k: "Subject", v: "MRvEK Local Root CA")
                    TRow(k: "Fingerprint", v: fingerprint)
                    if let m = LocalCAManager.meta {
                        TRow(k: "Created", v: m.rootCreated.formatted(date: .abbreviated, time: .shortened))
                        TRow(k: "Leaf issued", v: m.leafIssued.formatted(date: .abbreviated, time: .shortened))
                    }
                    TRow(k: "Leaf expires", v: LocalCAManager.leafExpiry.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "—")
                    TRow(k: "Key storage", v: "Keychain · ThisDeviceOnly")
                } header: {
                    Text("Root details")
                }

                Section {
                    TButton(title: "Delete local CA", icon: "trash", role: .destructive) { confirmDelete = true }
                }
            }

            if let error { Section { TStatusRow(ok: false, text: error) } }
            if let note { Section { TStatusRow(ok: true, text: note) } }
        }
        .sheet(item: $share) { ShareSheet(items: [$0.url]) }
        .sheet(isPresented: $showProfileText) { ProfileInspector(text: profileXML) }
        .confirmationDialog("Delete the local CA?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete root + leaf", role: .destructive) { LocalCAManager.reset(); OTAFiles.clear(); st.reload(); note = "Local CA deleted." }
        } message: { Text("Installs signed by this root stop being trusted. Remove the profile from Settings afterwards.") }
        .task { await checkDNS() }
    }

    private var profileXML: String {
        LocalCAManager.mobileConfig().flatMap { String(data: $0, encoding: .utf8) } ?? "(no profile — create the CA first)"
    }
    private var fingerprint: String {
        guard let der = LocalCAManager.rootDER() else { return "—" }
        return SHA256.hash(data: der).prefix(8).map { String(format: "%02X", $0) }.joined(separator: ":") + "…"
    }

    private func checkDNS() async {
        dnsChecking = true; dnsLoopback = await ZefvCert.resolvesToLoopback(cleanHost); dnsChecking = false
    }

    private func issue() async {
        working = true; error = nil; note = nil
        let h = cleanHost
        guard h.contains(".") else { error = "Enter a host like \(ServerConfig.defaultInstallHost)"; working = false; return }
        do {
            try LocalCAManager.issueLeaf(host: h)
            ServerConfig.setInstallHost(h)
            ServerConfig.setCertMode("local")
            OTAFiles.exportLocalCA()
            st.reload()
            await checkDNS()
            note = dnsLoopback == false
                ? "Root + leaf ready for \(h) and exported to Files — but \(h) does NOT resolve to 127.0.0.1, so the install sheet won't appear until it does."
                : "Root + leaf ready for \(h) and exported to Files. Install the trust profile next."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch { self.error = error.localizedDescription }
        working = false
    }
}

// Plain-text profile viewer.
private struct ProfileInspector: View {
    let text: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle(".mobileconfig").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Certificate inspector (public vs local, same fields)

private struct CertInspectorScreen: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @State private var publicChain: [CertFacts] = []
    @State private var localLeaf: [CertFacts] = []
    @State private var localRoot: [CertFacts] = []

    var body: some View {
        DetailScreen(title: "Certificate inspector") {
            Card {
                Text("Same parser, same fields, for every certificate this app can present to iOS. Compare what a public CA issued against what this phone issued. Active mode: \(ServerConfig.certMode == "local" ? "Fully local" : (ServerConfig.certMode == "custom" ? "Own TLS cert" : "airshare.lol (VPS)")).")
                    .font(.caption).foregroundStyle(Theme.subtle)
            }
            chainSection("PUBLIC (ACME) CERT", publicChain, empty: "No public cert loaded.")
            chainSection("LOCAL CA — LEAF", localLeaf, empty: "No local leaf issued.")
            chainSection("LOCAL CA — ROOT", localRoot, empty: "No local root created.")
        }
        .onAppear(perform: load)
    }

    private func load() {
        if let u = ZefvCert.crtURL { publicChain = CertInspector.inspect(fileURL: u) }
        localLeaf = CertInspector.inspect(fileURL: LocalCAManager.leafCertURL)
        localRoot = CertInspector.inspect(fileURL: LocalCAManager.rootCertURL)
    }

    @ViewBuilder
    private func chainSection(_ title: String, _ chain: [CertFacts], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .semibold)).kerning(1.1).foregroundStyle(Theme.subtle)
            if chain.isEmpty {
                Card { Text(empty).font(.caption).foregroundStyle(Theme.subtle) }
            } else {
                ForEach(chain) { certCard($0) }
            }
        }
    }

    private func certCard(_ c: CertFacts) -> some View {
        let days = c.daysLeft ?? -1
        let color: Color = days < 0 ? .red : (days < 21 ? .orange : .green)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(c.label).font(.headline).foregroundStyle(Theme.text)
                    if c.isCA { tag("CA", Theme.accent) }
                    if c.selfSigned { tag("SELF-SIGNED", .orange) }
                    Spacer()
                    tag(days < 0 ? "EXPIRED" : "\(days)D LEFT", color)
                }
                row("Subject", c.subjectCN + (c.subjectO.isEmpty ? "" : " · \(c.subjectO)"))
                row("Issuer", c.issuerCN + (c.issuerO.isEmpty ? "" : " · \(c.issuerO)"))
                row("Covers", c.sans.isEmpty ? "— (no SANs)" : c.sans.joined(separator: ", "))
                row("Valid", "\(fmt(c.notBefore)) → \(fmt(c.notAfter))")
                row("Key", c.keyType)
                row("Serial", c.serialHex)
                row("SHA-256", c.sha256)
            }
        }
    }

    private func fmt(_ d: Date?) -> String { d?.formatted(date: .abbreviated, time: .omitted) ?? "—" }
    private func tag(_ s: String, _ c: Color) -> some View {
        Text(s).font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(0.5)
            .padding(.horizontal, 6).padding(.vertical, 3).background(c.opacity(0.18)).foregroundStyle(c).clipShape(Capsule())
    }
    private func row(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.caption).foregroundStyle(Theme.subtle)
            Text(v).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).textSelection(.enabled)
        }
    }
}

// MARK: - What leaves this device

private struct TransparencyScreen: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @State private var checks: [TransparencyReport.Check] = []
    @State private var running = false

    var body: some View {
        DetailScreen(title: "What leaves this device") {
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Self-check", systemImage: "checkmark.shield").font(.headline).foregroundStyle(Theme.text)
                    Text("The app verifies its own privacy claims at runtime instead of asserting them. Run it any time.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                    ForEach(checks) { c in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: c.pass ? "checkmark.circle.fill" : "xmark.octagon.fill").foregroundStyle(c.pass ? .green : .red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                Text(c.detail).font(.caption2).foregroundStyle(Theme.subtle)
                            }
                        }
                    }
                    Button { run() } label: {
                        HStack { if running { ProgressView().tint(.black) } else { Image(systemName: "arrow.clockwise") }; Text("Run self-check").fontWeight(.semibold); Spacer() }
                            .padding(.vertical, 12).padding(.horizontal, 14)
                            .background(Theme.accent).foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(running)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("NEVER SENT ANYWHERE").font(.system(size: 12, weight: .semibold)).kerning(1.1).foregroundStyle(Theme.subtle)
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(TransparencyReport.neverSent, id: \.self) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "lock.fill").font(.caption).foregroundStyle(.green)
                                Text(line).font(.caption).foregroundStyle(Theme.text)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("EVERY ENDPOINT THIS APP CAN CONTACT").font(.system(size: 12, weight: .semibold)).kerning(1.1).foregroundStyle(Theme.subtle)
                ForEach(TransparencyReport.endpoints) { e in
                    Card {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(e.host).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent)
                            Text(e.purpose).font(.subheadline).foregroundStyle(Theme.text)
                            kv("Sends", e.sends)
                            kv("When", e.when)
                        }
                    }
                }
                Text("This list is declared in source (TransparencyReport.endpoints) and shipped with the app — if the app talked to anything not on it, that would be a bug you could diff.")
                    .font(.caption2).foregroundStyle(Theme.subtle)
            }
        }
        .onAppear(perform: run)
    }

    private func run() {
        running = true
        let r = TransparencyReport.selfCheck()
        checks = r
        running = false
    }

    private func kv(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.caption2.weight(.semibold)).foregroundStyle(Theme.subtle)
            Text(v).font(.caption).foregroundStyle(Theme.text)
        }
    }
}

// MARK: - Install method (OTA vs native device install)

private struct NativeInstallScreen: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @AppStorage(NativeInstaller.methodKey) private var method = "ota"
    @ObservedObject private var manager = DeviceInstallationManager.shared
    @ObservedObject private var pairing = DevicePairingService.shared
    @ObservedObject private var installer = NativeInstaller.shared
    @ObservedObject private var reconnect = VPNReconnectCoordinator.shared
    @AppStorage(VPNReconnectCoordinator.enabledKey) private var reconnectOn = false
    @AppStorage(VPNReconnectCoordinator.shortcutNameKey) private var shortcutName = VPNReconnectCoordinator.defaultShortcutName
    @AppStorage(VPNReconnectCoordinator.presentationKey) private var presentation = VPNReconnectPresentation.shareSheet.rawValue
    @ObservedObject private var appUpdater = AppAutoUpdater.shared
    @AppStorage(AppAutoUpdater.enabledKey) private var autoApps = false
    @AppStorage(AppAutoUpdater.wifiOnlyKey) private var wifiOnly = false
    @AppStorage(AppAutoUpdater.chargingOnlyKey) private var chargingOnly = false
    @AppStorage(AppAutoUpdater.certRefreshKey) private var certRefresh = false
    @AppStorage("AirShare.uploadChunkMB") private var chunkMB = 4
    @AppStorage(BackgroundKeepAlive.enabledKey) private var keepAlive = true
    @AppStorage(BackgroundKeepAlive.songTitleKey) private var songTitle = ""
    @ObservedObject private var keepAliveEngine = BackgroundKeepAlive.shared
    @State private var songError: String?
    @State private var confirmReset = false
    @State private var showNativeGuide = false
    @Environment(\.dismiss) private var dismiss

    private var busy: Bool { manager.isBusy || installer.isActive }
    /// Pairing can only be created on the phone from iOS 27, so older versions get a nudge to update.
    private static let onIOS27 = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))

    var body: some View {
        NavigationStack {
            dashboard
                .confirmationDialog("Forget this device's saved pairing?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Forget Pairing", role: .destructive) { Task { await manager.resetPairing() } }
                } message: {
                    Text("The next native install will ask you to pair again.")
                }
                .fullScreenCover(isPresented: $showNativeGuide) {
                    TutorialScreen(tutorial: TutorialLibrary.nativeInstall).preferredColorScheme(.dark)
                }
        }
    }

    /// Shown below the device card when this phone is older than iOS 27.
    private var upgradeCard: some View {
        panelBox(stroke: Theme.accent.opacity(0.6), glow: true) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.accent)
                    Text("Update to iOS 27 for native installs").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
                }
                Text("This phone is on iOS \(UIDevice.current.systemVersion). On iOS 27, AirShare installs apps straight to the phone with no install link or prompt, finishes in the background, and keeps your apps updated automatically.")
                    .font(.footnote).foregroundStyle(Theme.subtle).fixedSize(horizontal: false, vertical: true)
                Button { showNativeGuide = true } label: {
                    Text("See how to set it up").font(.system(size: 14, weight: .bold)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Connection Controller

    private var linked: Bool { manager.phase == .ready || manager.phase == .configured }
    private var deviceModel: String {
        var u = utsname(); _ = uname(&u)
        let id = withUnsafePointer(to: &u.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        let map = ["iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
                   "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
                   "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
                   "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
                   "iPhone17,5": "iPhone 16e", "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max", "iPhone18,3": "iPhone 17",
                   "iPhone18,4": "iPhone Air"]
        return map[id] ?? UIDevice.current.model
    }

    private func timing(_ label: String) -> String {
        guard let t = installer.timings.first(where: { $0.label == label }) else { return "—" }
        return String(format: "%.1f s", t.seconds)
    }
    private var totalTiming: String {
        installer.timings.isEmpty ? "—" : String(format: "%.1f s", installer.timings.reduce(0) { $0 + $1.seconds })
    }

    private var accent2: Color { Color(red: 1.0, green: 0.30, blue: 0.0) }
    private var accentGradient: LinearGradient {
        LinearGradient(colors: [Theme.accent, accent2], startPoint: .leading, endPoint: .trailing)
    }
    private let panel = Color(red: 0.063, green: 0.063, blue: 0.071)
    private let hairline = Color.white.opacity(0.08)

    private var dashboard: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                heroCard
                if !Self.onIOS27 { upgradeCard }
                if !linked || manager.setupNotice != nil || installer.job != nil { setupCard }
                methodCard
                chunkCard
                keepAliveCard
                songCard
                StorageCleanCard()
                actionGrid
                lastInstallCard
                tipCard
                footerCard
            }
            .padding(.horizontal, 16).padding(.bottom, 30).padding(.top, 6)
        }
        .background(
            ZStack {
                Color(red: 0.027, green: 0.031, blue: 0.039)
                RadialGradient(colors: [Theme.accent.opacity(0.33), .clear], center: .topTrailing, startRadius: 0, endRadius: 330)
                RadialGradient(colors: [Theme.accent.opacity(0.15), .clear], center: .bottomLeading, startRadius: 0, endRadius: 330)
            }.ignoresSafeArea()
        )
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { dismiss() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 17, weight: .bold))
                        Text("Settings").font(.system(size: 16, weight: .semibold))
                    }.foregroundStyle(Theme.accent).frame(minHeight: 44)
                }
                Spacer()
                Image("aircore_logo").resizable().scaledToFit().frame(width: 56, height: 56)
                    .shadow(color: Theme.accent.opacity(0.55), radius: 12)
            }
            Text("Connection\nController").font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.text).lineSpacing(-2)
            Text("Your local VPN, device pairing and the route native installs travel.")
                .font(.subheadline).foregroundStyle(Theme.subtle).frame(maxWidth: 290, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func panelBox<C: View>(radius: CGFloat = 22, stroke: Color? = nil, glow: Bool = false, pad: CGFloat = 16,
                                   @ViewBuilder _ c: () -> C) -> some View {
        c().padding(pad).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(panel))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(stroke ?? hairline, lineWidth: 1))
            .shadow(color: glow ? Theme.accent.opacity(0.18) : .clear, radius: 14)
    }

    private var heroCard: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                PhoneIcon(height: 92)
                    .shadow(color: Theme.accent.opacity(0.4), radius: 14, y: 6)
                    .frame(width: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(deviceModel).font(.system(size: 21, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                    Text("iOS \(UIDevice.current.systemVersion) · Developer Mode").font(.footnote).foregroundStyle(Theme.subtle)
                    HStack(spacing: 7) {
                        Circle().fill(linked ? Color.green : Color.orange).frame(width: 8, height: 8)
                            .overlay(Circle().stroke((linked ? Color.green : Color.orange).opacity(0.25), lineWidth: 4))
                        Text(linked ? "Connected" : "Not connected").font(.footnote.weight(.semibold))
                            .foregroundStyle(linked ? Color.green : Color.orange)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill((linked ? Color.green : Color.orange).opacity(0.12)))
                    .overlay(Capsule().stroke((linked ? Color.green : Color.orange).opacity(0.35), lineWidth: 1))
                    .padding(.top, 5)
                }
                Spacer(minLength: 0)
            }
            pipeline
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.09, green: 0.075, blue: 0.06), Color(red: 0.05, green: 0.05, blue: 0.06)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing)))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }

    private var pipeline: some View {
        ZStack(alignment: .top) {
            GeometryReader { g in
                let inset = g.size.width / 8
                Capsule().fill(accentGradient).frame(height: 3)
                    .padding(.horizontal, inset).offset(y: 21)
                    .opacity(linked ? 1 : 0.25)
            }
            .frame(height: 44)
            HStack(alignment: .top, spacing: 0) {
                node("link", "Pairing", linked ? "Active" : "None")
                node("shield.fill", "VPN", linked ? "Running" : "Stopped")
                node("wifi", "Tunnel", linked ? "Connected" : "Idle")
                node("iphone", "Device", linked ? "Reachable" : "Unknown")
            }
        }
    }

    private func node(_ icon: String, _ title: String, _ value: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(red: 0.078, green: 0.067, blue: 0.055)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(linked ? Theme.accent : Color.white.opacity(0.15), lineWidth: 1.5))
            VStack(spacing: 2) {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                Text(value).font(.system(size: 11.5)).foregroundStyle(linked ? Color.green : Color.orange).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Pairing code / progress / errors while setup is running or has failed.
    private var setupCard: some View {
        panelBox {
            VStack(alignment: .leading, spacing: 10) {
                switch manager.phase {
                case .pairing:
                    if let pin = pairing.pin {
                        Text("Pairing code").font(.caption).foregroundStyle(Theme.subtle)
                        Text(pin).font(.system(size: 34, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent)
                        Text("Enter it in Settings › Privacy & Security › Developer Mode › Pair with AirShare.")
                            .font(.footnote).foregroundStyle(Theme.subtle)
                    } else {
                        Text("Open Settings › Privacy & Security › Developer Mode and choose Pair with AirShare…")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    Button("Cancel Setup", role: .destructive) { manager.cancelSetup() }
                case .connecting:
                    HStack { ProgressView(); Text("Connecting to this device…").foregroundStyle(Theme.text) }
                    Text("Allow the VPN configuration if iOS asks.").font(.footnote).foregroundStyle(Theme.subtle)
                    Button("Cancel Setup", role: .destructive) { manager.cancelSetup() }
                case .failed(let message):
                    Text(message).font(.footnote).foregroundStyle(.red)
                    Button("Retry Setup") { Task { await manager.setUp() } }.disabled(busy)
                case .idle:
                    Text("Not set up yet. Tap Setup below.").font(.footnote).foregroundStyle(Theme.subtle)
                default: EmptyView()
                }
                if let notice = manager.setupNotice { Text(notice).font(.footnote).foregroundStyle(.orange) }
                if installer.job != nil {
                    Text("\(installer.job?.name ?? "Install") — \(installer.stage.label)").font(.footnote).foregroundStyle(Theme.text)
                }
            }
            .tint(Theme.accent)
        }
    }

    private var methodCard: some View {
        panelBox(stroke: Theme.accent.opacity(0.4), glow: true) {
            VStack(alignment: .leading, spacing: 12) {
                NavigationLink { connectionDetail } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Install method").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                            Text(manager.mode == .builtIn ? "Built-in connection & pairing" : "Manual setup")
                                .font(.footnote).foregroundStyle(Theme.subtle)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.subtle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HStack(spacing: 0) {
                    segment("Native", on: method == "native") { method = "native" }
                    segment("OTA", on: method != "native") { method = "ota" }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(red: 0.027, green: 0.031, blue: 0.039)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
                .disabled(busy)
                Text(method == "native"
                     ? (linked ? "Paired and ready — installs go straight to this device with no Apple prompt."
                               : "Pair this device to enable native installs with no Apple prompt.")
                     : "Serves the signed IPA over HTTPS and hands iOS an itms-services link.")
                    .font(.footnote).foregroundStyle(Theme.text.opacity(0.8))
            }
        }
    }

    private func segment(_ title: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .bold))
                .foregroundStyle(on ? Color(red: 0.1, green: 0.055, blue: 0.016) : Theme.subtle)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(on ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, accent2.opacity(0.9)], startPoint: .leading, endPoint: .trailing))
                             : AnyShapeStyle(Color.clear)))
        }
        .buttonStyle(.plain)
    }

    private func tile<C: View>(icon: String, title: String, subtitle: String, tint: Color = Theme.accent, titleTint: Color = Theme.text,
                               fill: Color? = nil, border: Color? = nil, @ViewBuilder badge: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.15)))
                Spacer(minLength: 0)
                badge()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(titleTint)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.subtle).lineLimit(1).minimumScaleFactor(0.85)
            }
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(fill ?? panel))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(border ?? hairline, lineWidth: 1))
        .contentShape(Rectangle())
    }

    private var actionGrid: some View {
        let cols = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: cols, spacing: 10) {
            Button { Task { await manager.setUp() } } label: {
                tile(icon: "bolt.fill", title: "Setup", subtitle: "Pair & configure VPN") { EmptyView() }
            }.buttonStyle(.plain).disabled(busy)

            NavigationLink { restoreDetail } label: {
                tile(icon: "arrow.triangle.2.circlepath", title: "Restore VPN", subtitle: "Quick reconnect") { EmptyView() }
            }.buttonStyle(.plain)

            NavigationLink { updatesDetail } label: {
                tile(icon: "arrow.down.circle", title: "App updates", subtitle: "Skip · roll back · re-sign") {
                    Text(autoApps ? "Auto on" : "Auto off").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(autoApps ? Color.green : Theme.subtle)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill((autoApps ? Color.green : Color.white).opacity(0.12)))
                }
            }.buttonStyle(.plain)

            NavigationLink { InstalledAppsScreen() } label: {
                tile(icon: "trash.square", title: "Installed apps", subtitle: "Uninstall from this device") { EmptyView() }
            }.buttonStyle(.plain)

            Button { confirmReset = true } label: {
                tile(icon: "trash", title: "Forget pairing", subtitle: "Remove record",
                     tint: Color(red: 1, green: 0.42, blue: 0.38), titleTint: Color(red: 1, green: 0.42, blue: 0.38),
                     fill: Color(red: 0.086, green: 0.043, blue: 0.043), border: Color.red.opacity(0.22)) { EmptyView() }
            }.buttonStyle(.plain).disabled(busy || manager.mode != .builtIn)
        }
    }

    private var lastInstallCard: some View {
        let t = installer.timings
        let total = t.reduce(0) { $0 + $1.seconds }
        let colors: [String: Color] = ["Pack": Color(red: 0.6, green: 0.85, blue: 1), "Connect": Color(red: 1, green: 0.82, blue: 0.37),
                                       "Upload": Theme.accent, "Install": Color(red: 1, green: 0.48, blue: 0.35)]
        return panelBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Last install").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(Theme.text)
                    Spacer()
                    if t.isEmpty {
                        Text("No installs yet").font(.footnote).foregroundStyle(Theme.subtle)
                    } else {
                        (Text(String(format: "%.1f", total)).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(Theme.accent)
                        + Text(" s").font(.footnote.weight(.semibold)).foregroundColor(Theme.subtle))
                    }
                }
                GeometryReader { g in
                    HStack(spacing: 3) {
                        ForEach(Array(t.enumerated()), id: \.offset) { _, item in
                            Capsule().fill(colors[item.label] ?? Theme.accent)
                                .frame(width: max(6, (g.size.width - CGFloat(max(t.count - 1, 0)) * 3) * CGFloat(item.seconds / max(total, 0.001))))
                        }
                        if t.isEmpty { Capsule().fill(Color.white.opacity(0.07)) }
                    }
                }
                .frame(height: 12)
                if !t.isEmpty {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(t.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Circle().fill(colors[item.label] ?? Theme.accent).frame(width: 8, height: 8)
                                    Text(item.label).font(.caption).foregroundStyle(Theme.subtle)
                                }
                                Text(String(format: "%.1f s", item.seconds)).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private var chunkCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.5)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Upload chunk size").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Bigger = fewer round trips, more memory").font(.system(size: 12)).foregroundStyle(Theme.subtle)
            }
            Spacer(minLength: 4)
            Picker("", selection: $chunkMB) {
                ForEach([1, 2, 4, 8, 16], id: \.self) { Text("\($0) MB").tag($0) }
            }
            .pickerStyle(.menu).tint(Theme.accent).disabled(busy)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(panel))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(hairline, lineWidth: 1))
    }

    private var songCard: some View {
        // The title can outlive the file (e.g. after an older build): only trust it when the file is really there.
        let hasSong = !songTitle.isEmpty && BackgroundKeepAlive.songURL != nil
        return HStack(spacing: 12) {
            Image(systemName: "music.note").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.5)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Install song").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text(songError ?? (!hasSong ? "Pick a song to play while apps install"
                                   : (keepAlive ? songTitle : "Turn on “Finish installs in background” to hear it")))
                    .font(.system(size: 12)).foregroundStyle(songError == nil ? Theme.subtle : Color.red).lineLimit(2)
            }
            Spacer(minLength: 4)
            if !hasSong {
                Button { chooseSong() } label: {
                    Text("Choose").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 7).background(Theme.accent).clipShape(Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    Button { keepAliveEngine.togglePreview() } label: {
                        Label(keepAliveEngine.isPreviewing ? "Stop preview" : "Preview", systemImage: keepAliveEngine.isPreviewing ? "stop.fill" : "play.fill")
                    }
                    .disabled(keepAliveEngine.isHolding)
                    Button { chooseSong() } label: { Label("Change song", systemImage: "arrow.triangle.2.circlepath") }
                    Button(role: .destructive) { keepAliveEngine.removeSong(); songError = nil } label: { Label("Remove", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle.fill").font(.system(size: 24)).foregroundStyle(Theme.accent)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(panel))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(hairline, lineWidth: 1))
    }

    private func chooseSong() {
        DocumentPickerPresenter.pickAudio { url in
            guard let url else { return }
            do { try BackgroundKeepAlive.shared.setSong(from: url); songError = nil }
            catch { songError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }

    private var keepAliveCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.stars.fill").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.5)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Finish installs in background").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                Text("Leave AirShare mid-install. Progress shows as a notification.").font(.system(size: 12)).foregroundStyle(Theme.subtle)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: $keepAlive).labelsHidden().tint(Theme.accent)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(panel))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(hairline, lineWidth: 1))
    }

    private var tipCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "lightbulb").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.5)))
            (Text("Keep it healthy. ").bold().foregroundColor(Theme.text)
             + Text("Re-pair if the device changes or Developer Mode resets.").foregroundColor(Theme.text.opacity(0.8)))
                .font(.system(size: 12.5))
            Spacer(minLength: 4)
            NavigationLink { guideDetail } label: {
                Text("Guide").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent).frame(minHeight: 44)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(LinearGradient(colors: [Theme.accent.opacity(0.2), panel], startPoint: .leading, endPoint: .trailing)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.accent.opacity(0.28), lineWidth: 1))
    }

    private var footerCard: some View {
        HStack(alignment: .top, spacing: 0) {
            footerItem(linked ? "Device online" : "Device offline", manager.mode == .builtIn ? "Built-in pairing" : "Manual pairing")
            Rectangle().fill(hairline).frame(width: 1).padding(.vertical, 2)
            footerItem(linked ? "VPN tunnel active" : "VPN tunnel idle", "Local · 127.0.0.1").padding(.leading, 16)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(red: 0.05, green: 0.05, blue: 0.057)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    private func footerItem(_ title: String, _ sub: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(linked ? Color.green : Color.orange).frame(width: 10, height: 10).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.text)
                Text(sub).font(.system(size: 12)).foregroundStyle(Theme.subtle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Detail pages

    private var connectionDetail: some View {
        TableScreen(title: "Connection") {
            Section {
                Picker(selection: $method) {
                    Label("OTA · itms-services", systemImage: "globe").tag("ota")
                    Label("Native · built-in VPN", systemImage: "iphone.and.arrow.forward").tag("native")
                } label: {
                    Label("Install method", systemImage: "arrow.down.app.fill").foregroundStyle(Theme.text)
                }
                .pickerStyle(.menu).listRowBackground(Theme.card).disabled(busy)
                TNote(text: method == "native"
                      ? "Installs straight to this device over a local VPN and a device pairing — no AirShare domain, TLS cert or itms-services prompt. Needs a build signed with a profile that allows Network Extensions (packet-tunnel-provider)."
                      : "Serves the signed IPA from the on-device HTTPS server and hands iOS an itms-services link.")
            }
            Section {
                Picker(selection: $manager.mode) {
                    ForEach(DeviceConnectionMode.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Connection", systemImage: "point.3.connected.trianglepath.dotted").foregroundStyle(Theme.text)
                }
                .pickerStyle(.menu).listRowBackground(Theme.card).disabled(busy)
                TNote(text: manager.mode == .builtIn
                      ? "Built-in manages a local VPN inside AirShare. Creating a pairing on-device needs iOS 27+, Developer Mode and Local Network access. The VPN may replace another active VPN."
                      : "Manual uses an imported pairingFile.plist in AirShare's Documents folder and your own local VPN.")
            }
            Section { statusRows }
        }
    }

    private var restoreDetail: some View {
        TableScreen(title: "Restore VPN") { reconnectSection }
    }

    private var updatesDetail: some View {
        TableScreen(title: "App Updates") { appUpdateSection }
    }

    private var guideDetail: some View {
        TableScreen(title: "Guide") {
            Section {
                TNote(text: "1. Turn on Developer Mode (Settings › Privacy & Security).\n2. Tap Setup Connection and allow the VPN configuration.\n3. Enter the pairing code shown here in Settings › Privacy & Security › Developer Mode › Pair with AirShare.\n4. Pick Native as the install method.\n\nRe-pair if you change devices, Developer Mode resets, or the tunnel stops responding (Forget Built-in Pairing, then Setup Connection).")
            }
        }
    }

    @ViewBuilder private var statusRows: some View {
        if let notice = manager.setupNotice { TNote(text: notice, tint: .orange) }
        switch manager.phase {
        case .pairing:
            if let pin = pairing.pin {
                TRow(k: "Pairing code", v: pin, tint: Theme.accent)
                TNote(text: "Enter this code in Settings › Privacy & Security › Developer Mode › Pair with AirShare.")
            } else {
                TStatusRow(ok: false, text: "Open Settings › Privacy & Security › Developer Mode and choose Pair with AirShare…")
            }
            TButton(title: "Cancel Setup", icon: "xmark.circle", role: .destructive) { manager.cancelSetup() }
        case .connecting:
            TButton(title: "Connecting to this device…", icon: "bolt.horizontal", busy: true) {}
            TNote(text: "Allow the VPN configuration if iOS asks.")
            TButton(title: "Cancel Setup", icon: "xmark.circle", role: .destructive) { manager.cancelSetup() }
        case .failed(let message):
            TStatusRow(ok: false, text: message)
            TButton(title: "Retry Setup", icon: "arrow.clockwise", enabled: !busy) { Task { await manager.setUp() } }
        case .ready:
            TStatusRow(ok: true, text: "Connected")
        case .configured:
            TStatusRow(ok: true, text: "Setup complete — AirShare reconnects automatically on install.")
        case .idle:
            TButton(title: "Set Up Connection", icon: "bolt.horizontal.circle.fill", enabled: !busy) { Task { await manager.setUp() } }
            TNote(text: "AirShare also connects automatically on the first native install.")
        }
        if installer.job != nil {
            TRow(k: installer.job?.name ?? "Install", v: installer.stage.label)
        }
    }

    @ViewBuilder private var reconnectSection: some View {
        Section {
            Toggle(isOn: $reconnectOn) {
                Label("Reconnect VPN after install", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(Theme.text)
            }
            .tint(Theme.accent).listRowBackground(Theme.card)
            .onChange(of: reconnectOn) { on in
                if on { Task { await reconnect.requestNotificationPermission() } } else { reconnect.disable() }
            }
            if reconnectOn {
                Picker(selection: $presentation) {
                    ForEach(VPNReconnectPresentation.allCases) { Text($0.title).tag($0.rawValue) }
                } label: { Text("Method").foregroundStyle(Theme.text) }
                .pickerStyle(.menu).listRowBackground(Theme.card)
                TField(label: "Shortcut", text: $shortcutName, placeholder: VPNReconnectCoordinator.defaultShortcutName)
                TButton(title: presentation == VPNReconnectPresentation.shareSheet.rawValue ? "Test Share Sheet" : "Test Shortcut",
                        icon: "play.circle", enabled: manager.canReconnectVPN && !installer.isActive &&
                        !shortcutName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    Task { await manager.testVPNReconnectShortcut() }
                }
                if reconnect.pendingShortcutName != nil {
                    TButton(title: "Reconnect VPN", icon: "network", enabled: manager.canReconnectVPN && !installer.isActive) {
                        Task { await reconnect.runPendingShortcut() }
                    }
                }
                if let notice = reconnect.notice { TNote(text: notice) }
            }
            TNote(text: "Create a shortcut (default name “Restore Tailscale”) with your VPN's Connect action, enable Show in Share Sheet and allow Text input. AirShare offers it after all device work ends and its local VPN disconnects.")
        } header: {
            Text("Restore your VPN").font(.caption.weight(.semibold)).foregroundStyle(Theme.subtle)
        }
    }

    // MARK: App updates

    private var activeCertLine: String? {
        guard let c = CertificateStore.shared.active, let d = try? Data(contentsOf: c.provisionURL),
              let exp = CertificateStore.profileInfo(d).expires else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Date(), to: exp).day ?? 0
        return days >= 0 ? "\(c.name) · expires in \(days) day\(days == 1 ? "" : "s")" : "\(c.name) · expired"
    }

    @ViewBuilder private var appUpdateSection: some View {
        Section {
            Toggle(isOn: $autoApps) {
                Label("Auto-update my apps", systemImage: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(Theme.text)
            }
            .tint(Theme.accent).listRowBackground(Theme.card)
            Toggle(isOn: $wifiOnly) {
                Label("Wi-Fi only", systemImage: "wifi").foregroundStyle(Theme.text)
            }
            .tint(Theme.accent).listRowBackground(Theme.card)
            Toggle(isOn: $chargingOnly) {
                Label("Only while charging", systemImage: "bolt.fill").foregroundStyle(Theme.text)
            }
            .tint(Theme.accent).listRowBackground(Theme.card)
            Toggle(isOn: $certRefresh) {
                Label("Re-sign when certificate changes", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.text)
            }
            .tint(Theme.accent).listRowBackground(Theme.card)
            TButton(title: "Check for Updates", icon: "magnifyingglass", busy: appUpdater.busy,
                    enabled: !appUpdater.busy && !installer.isActive) { appUpdater.checkOnly() }
            TButton(title: "Update Apps Now", icon: "arrow.down.app", busy: appUpdater.busy,
                    enabled: !appUpdater.busy && !installer.isActive) { appUpdater.updateNow() }
            TButton(title: "Re-sign Apps With Active Certificate", icon: "arrow.triangle.2.circlepath", busy: appUpdater.busy,
                    enabled: !appUpdater.busy && !installer.isActive) { appUpdater.refreshCertificates() }
            TButton(title: "Track Apps I've Signed", icon: "plus.circle", enabled: !appUpdater.busy) { appUpdater.trackSignedApps() }
            if let line = activeCertLine { TNote(text: "Active certificate: " + line) }
            if !appUpdater.status.isEmpty { TNote(text: appUpdater.status) }
            ForEach(appUpdater.tracked) { app in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).foregroundStyle(Theme.text).lineLimit(1)
                            Text("v\(app.version) · \(app.bundleID)").font(.caption.monospaced()).foregroundStyle(Theme.subtle).lineLimit(1)
                            if let v = appUpdater.available[app.bundleID] {
                                Text(app.skipped == v ? "v\(v) skipped" : "v\(v) available")
                                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                            }
                        }
                        Spacer()
                        Button { appUpdater.untrack(app) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                    HStack(spacing: 14) {
                        Toggle("Auto", isOn: Binding(get: { app.isAuto }, set: { appUpdater.setAuto($0, for: app) }))
                            .toggleStyle(.switch).tint(Theme.accent).labelsHidden()
                        Text("Auto").font(.caption).foregroundStyle(Theme.subtle)
                        Spacer()
                        if appUpdater.available[app.bundleID] != nil {
                            Button("Update") { appUpdater.update(app) }.disabled(appUpdater.busy || installer.isActive)
                            if app.skipped != appUpdater.available[app.bundleID] {
                                Button("Skip") { appUpdater.skip(app) }.disabled(appUpdater.busy)
                            }
                        }
                        if let prev = appUpdater.rollbackTarget(for: app) {
                            Button("Roll back to v\(prev.version)") { appUpdater.rollBack(app) }
                                .disabled(appUpdater.busy || installer.isActive)
                        }
                    }
                    .font(.caption.weight(.semibold)).buttonStyle(.borderless).tint(Theme.accent)
                }
                .listRowBackground(Theme.card)
            }
            TNote(text: appUpdater.tracked.isEmpty
                  ? "No tracked apps yet. Apps you install with Native are added automatically."
                  : "Automatic checks run when you open AirShare (at most every 30 minutes) and only for apps with Auto on. Wi-Fi / charging limits apply to automatic checks only. Several updates share one VPN session. Rolling back skips the newer version.")
        } header: {
            Text("App updates").font(.caption.weight(.semibold)).foregroundStyle(Theme.subtle)
        }
    }
}

