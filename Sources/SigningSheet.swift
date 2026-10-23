//
//  SigningSheet.swift
//  Full-screen signing sheet in the AirShare layout: signing method (active cert),
//  app icon replace, name/bundle/version, build-option groups (General, Strip
//  Content, Entitlement/Info tweaks), dylib injection with @executable/@rpath +
//  folder pickers, a "Changes to be applied" summary, and a Sign IPA bar.
//  Everything is applied on-device by SignEngine.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers
import ZIPFoundation

private final class SigningLogSink: @unchecked Sendable {
    private let onLine: (String) -> Void
    init(onLine: @escaping (String) -> Void) { self.onLine = onLine }
    func append(_ line: String) {
        DispatchQueue.main.async { [onLine] in
            onLine(line)
        }
    }
}

struct SigningSheet: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read accent live (auto-cycle) without rebuilding
    let ipaURL: URL
    let meta: IPAMeta
    var onSigned: (SignedEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var certs = CertificateStore.shared
    @ObservedObject private var staff = StaffGate.shared
    @ObservedObject private var account = ZefvAccount.shared
    @ObservedObject private var ota = OTAInstaller.shared

    /// Dev/ADV tools (CFG viewer, patching, AVX512, etc) are for people who BUILD the
    /// app's tooling — Admin, Co-Admin, and Developer — not for plain Staff, who monitor
    /// reports/signings/accounts instead. A server "staff" role alone (StaffGate.isStaff /
    /// UserRole.developer fallback) no longer qualifies on its own; it takes an actual
    /// admin/co_admin/dev badge or the admin role.
    private var canAccessDeveloperTools: Bool {
        if account.role == .admin || staff.role == .admin { return true }
        let badges = Set(account.style.badges.map { $0.lowercased() })
        return badges.contains("admin") || badges.contains("co_admin") || badges.contains("dev")
    }

    // identity
    @State private var name: String
    @State private var bundle: String
    @State private var version: String
    @State private var iconPNG: Data?
    @State private var showIconPicker = false

    // dylibs
    @State private var injectPath = "@executable_path"
    @State private var injectFolder = "/"
    @State private var dylibs: [DylibItem] = []
    @State private var removeDylibs: Set<String> = []
    @State private var machoDylibs: [String] = []
    @State private var showDylibPicker = false
    @State private var showAVX512DylibPicker = false

    // toggles
    @State private var o = ExtraToggles()
    @State private var expanded: Set<String> = ["general"]

    // AirShare-style signing method selector (Saved / Enterprise / Apple ID).
    // "saved" is fully wired; the others are UI placeholders to plug in later.
    @AppStorage("uzd_signing_method") private var method = "saved"   // saved | enterprise | appleid
    @State private var enterpriseName = ""
    @State private var appleIDEmail = ""
    @State private var showBundleInfo = false
    @State private var bundleInfoMode: BundleInfoEditorSheet.Mode = .entitlements
    @State private var entitlementValues: [String: String] = [:]
    @State private var entitlementTypeHints: [String: String] = [:]
    @State private var plistSetValues: [String: String] = [:]
    @State private var showDeveloperTool = false
    @State private var showProtectionAnalysis = false
    @State private var developerToolMode: DeveloperToolSheet.Mode = .strings
    @State private var developerStrings: [DeveloperStringEntry] = []
    @State private var binaryPatches: [BinaryPatch] = []
    @State private var injectDataBlob: Data? = nil
    @State private var injectDataName: String = ""

    // binary analysis
    @State private var macho: MachOReport?
    @State private var machoError: String?
    @State private var parallelSigningPayloadSize: Int64?

    // signing
    @State private var signing = false
    @State private var showTerminal = false
    @State private var settingsJump: SettingsJump?
    private enum SettingsJump: String, Identifiable { case ota, certs; var id: String { rawValue } }
    @State private var log: [String] = []
    @State private var lastEntitlements: [String: String] = [:]
    @State private var lastSizeBytes: Int64 = 0
    @State private var showInstallPrompt = false
    @State private var sentToHome = false
    @State private var error: String?
    @State private var result: SignedEntry?
    @State private var avx512DylibURL: URL?
    @State private var installing = false
    @State private var showBulkSigning = false

    private var blue: Color { Theme.accent }
    private var accent: Color { Theme.accent }
    private var accentSoft: Color { Theme.accent.opacity(0.8) }
    private var accentTint: Color { Theme.accent.opacity(0.14) }
    private let surface = Color(red: 0.06, green: 0.06, blue: 0.07)
    private let surfaceRaised = Color(red: 0.09, green: 0.09, blue: 0.10)
    private let success = Color(red: 0.45, green: 0.79, blue: 0.34)

    struct DylibItem: Identifiable, Equatable { let id = UUID(); let url: URL; var weak = false }
    struct ExtraToggles {
        var removeExistingLibraries = false, thinToArm64Only = false, randomizeBundleID = false, disableATS = false
        var weakDylibReferences = false, sha256Only = false, forceResign = false, surgicalMode = false, parallelSigning = false
        var forceMinIOS12 = false, disableFileSharing = false, forcePortrait = false, skipIPad = false
        var stripSCInfo = false, stripPrivacy = false, stripWatch = false, stripExtensions = false, removeURLSchemes = false
        var stripBitcode = false, stripDebugSymbols = false
        var autoFixEntitlements = false, disablePush = false, disableAppGroups = false
        var disableiCloud = false, disableSiri = false, disableBackgroundModes = false
        var replaceIcon = true
    }

    init(ipaURL: URL, meta: IPAMeta, onSigned: @escaping (SignedEntry) -> Void) {
        self.ipaURL = ipaURL; self.meta = meta; self.onSigned = onSigned
        _name = State(initialValue: meta.name)
        _bundle = State(initialValue: meta.bundleID)
        _version = State(initialValue: meta.version)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16.5) {
                    signingMethodCard        // AirShare: Saved / Enterprise / Apple ID
                    appIcon
                    identity                 // App metadata: name / bundle / version
                    buildOptions             // 4 collapsible categories
                    bundleInfoCard           // Entitlements · Info.plist (view)
                    if canAccessDeveloperTools { developerCard }   // dev + ADV tools: admin / co-admin / dev only
                    if canAccessDeveloperTools {
                        AVX512ExperimentalSection(
                            ipaURL: ipaURL,
                            appName: name,
                            bundleID: bundle,
                            dylibURL: $avx512DylibURL,
                            showPicker: $showAVX512DylibPicker
                        )
                    }
                    dylibInjection
                    changesSummary
                    if let error { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal, 3) }
                    if ota.tracing { tracingCard }
                    if let rep = ota.lastReport { reportCard(rep) }
                    Spacer(minLength: 15)
                }
                .padding(12)
            }
            .safeAreaInset(edge: .top, spacing: 0) { titleBar }
            .safeAreaInset(edge: .bottom, spacing: 0) { signBar.floatingGlassBar(edge: .bottom) }
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showBulkSigning) {
            TurboBulkSigningView(defaultOptions: buildOptionsValue())
        }
        .sheet(isPresented: $showProtectionAnalysis) {
            ProtectionAnalysisSheet(ipaURL: ipaURL)
        }
        .fullScreenCover(isPresented: $showTerminal) {
            SigningTerminalView(
                appName: name, bundle: bundle, icon: iconPNG ?? meta.iconPNG,
                lines: $log, done: Binding(get: { !signing && (result != nil || error != nil) }, set: { _ in }),
                result: result, error: error,
                certName: certs.active?.name ?? "", sizeBefore: sourceSizeBytes, sizeAfter: lastSizeBytes,
                onInstall: { _ in showInstallPrompt = true },
                onExit: { showTerminal = false }
            )
            .preferredColorScheme(.dark)
            .overlay {
                if sentToHome {
                    SentToHomeOverlay(name: name, icon: iconPNG ?? meta.iconPNG, host: ServerConfig.installHost)
                        .transition(.opacity)
                }
            }
            .overlay {
                if showInstallPrompt, let r = result {
                    InstallPromptOverlay(
                        name: r.name, bundle: r.bundleID, version: r.version,
                        sizeBytes: lastSizeBytes, icon: iconPNG ?? meta.iconPNG,
                        source: sourceLabel,
                        mdid: CertificateStore.knownUDID(certName: certs.active?.name) ?? "",
                        cert: certs.active?.name ?? "",
                        entitlements: lastEntitlements,
                        onInstall: { showInstallPrompt = false; Task { await install(r) } },
                        onCancel: { showInstallPrompt = false },
                        onTrollStore: OTAInstaller.trollStoreAvailable ? { showInstallPrompt = false; Task { await installTrollStore(r) } } : nil
                    )
                }
            }
        }
        .task {
            await StaffGate.shared.refresh()
            parallelSigningPayloadSize = await loadParallelSigningPayloadSize()
            machoDylibs = await currentDylibs()
            await analyzeBinary()
            developerStrings = await loadDeveloperStrings()
            avx512DylibURL = AVX512DylibStore.storedURL
            if canAccessDeveloperTools, AVX512AirShareBridge.shared.enabled, let avx512DylibURL {
                attachAVX512DylibIfNeeded(avx512DylibURL)
            }
        }
        .sheet(isPresented: $showDylibPicker) {
            DocPicker(types: [UTType(filenameExtension: "dylib") ?? .item, UTType(filenameExtension: "framework") ?? .item, UTType(filenameExtension: "deb") ?? .item]) { urls in
                for u in urls { dylibs.append(DylibItem(url: u)) }
            }
        }
        .sheet(isPresented: $showAVX512DylibPicker) {
            DocPicker(types: [UTType(filenameExtension: "dylib") ?? .item]) { urls in
                guard let u = urls.first else { return }
                do {
                    let stored = try AVX512DylibStore.install(from: u)
                    avx512DylibURL = stored
                    attachAVX512DylibIfNeeded(stored)
                } catch {
                    self.error = "AVX512 dylib: \(error.localizedDescription)"
                }
            }
        }
        .sheet(isPresented: $showBundleInfo) {
            BundleInfoEditorSheet(
                mode: bundleInfoMode,
                entitlements: $entitlementValues,
                infoPlistSet: $plistSetValues
            ) { removedKey in
                entitlementTypeHints.removeValue(forKey: removedKey)
            }
        }
        // CFG mode brings its own full-screen UIKit nav bar (UCDisasmViewController)
        // with no SwiftUI chrome around it — presenting that through `.sheet` left
        // this screen's own nav bar peeking above it and clipped its trailing
        // buttons, same issue as the inner CFG-related sheets fixed elsewhere.
        // `.fullScreenCover` for that one mode only; every other mode keeps its
        // normal dismissible card via `.sheet`.
        .fullScreenCover(isPresented: Binding(
            get: { showDeveloperTool && developerToolMode == .cfgViewer },
            set: { if !$0 { showDeveloperTool = false } }
        )) {
            DeveloperToolSheet(
                mode: developerToolMode,
                ipaURL: ipaURL,
                appName: meta.name,
                appBundleID: meta.bundleID,
                macho: macho,
                machoError: machoError,
                patches: $binaryPatches,
                injectBlob: $injectDataBlob,
                injectName: $injectDataName,
                stageDylib: { url in dylibs.append(DylibItem(url: url)); showDeveloperTool = false }
            )
        }
        .sheet(isPresented: Binding(
            get: { showDeveloperTool && developerToolMode != .cfgViewer },
            set: { if !$0 { showDeveloperTool = false } }
        )) {
            DeveloperToolSheet(
                mode: developerToolMode,
                ipaURL: ipaURL,
                appName: meta.name,
                appBundleID: meta.bundleID,
                macho: macho,
                machoError: machoError,
                patches: $binaryPatches,
                injectBlob: $injectDataBlob,
                injectName: $injectDataName,
                stageDylib: { url in dylibs.append(DylibItem(url: url)); showDeveloperTool = false }
            )
        }
        .fullScreenCover(item: $settingsJump) { j in
            Group {
                switch j {
                case .ota:   OTADomainScreen()
                case .certs: CertificatesScreen()
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showIconPicker) {
            DocPicker(types: [.png, .jpeg, .image]) { urls in
                if let u = urls.first, let d = try? Data(contentsOf: u), let img = UIImage(data: d) {
                    iconPNG = img.pngData()
                }
            }
        }
    }

    // MARK: Title

    private var titleBar: some View {
        HStack(spacing: 12) {
            titleBarButton("chevron.left")
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                iconThumb(iconPNG ?? meta.iconPNG, side: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 16, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                    Text(bundle).font(.system(size: 12)).foregroundStyle(accent).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            titleBarButton("xmark")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        // Floating Liquid Glass header — the sheet scrolls underneath it.
        .floatingGlassBar(edge: .top, cornerRadius: 30)
    }

    private func titleBarButton(_ icon: String) -> some View {
        Button { dismiss() } label: {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.12))
                .clipShape(Circle())
        }
    }

    // MARK: Bundle info (AirShare: Entitlements · Info.plist)

    private var bundleInfoCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("BUNDLE INFO")
            VStack(spacing: 0) {
                bundleRow("Entitlements", "key.fill", entitlementValues.isEmpty ? "View" : "\(entitlementValues.count)") {
                    if entitlementValues.isEmpty { loadEntitlementsFromActiveProfile() }
                    bundleInfoMode = .entitlements
                    showBundleInfo = true
                }
                Divider().overlay(Theme.stroke).padding(.leading, 39)
                bundleRow("Info.plist", "doc.text.fill", plistSetValues.isEmpty ? "View" : "\(plistSetValues.count)") {
                    bundleInfoMode = .infoPlist
                    showBundleInfo = true
                }
            }
            .background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func bundleRow(_ title: String, _ icon: String, _ trailing: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                ZStack { RoundedRectangle(cornerRadius: 7).fill(blue.opacity(0.15)).frame(width: 19, height: 25.5); Image(systemName: icon).foregroundStyle(blue).font(.system(size: 10.5)) }
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                Spacer()
                Text(trailing).font(.caption.weight(.semibold)).foregroundStyle(Theme.subtle)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.subtle)
            }
            .padding(10.5)
        }
        .buttonStyle(.plain)
    }

    // MARK: Developer options

    private var developerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("DEVELOPER")
            VStack(spacing: 0) {
                // "Search / Edit Strings" and "Disassemble ARM64" moved into the
                // CFG Viewer's own toolbar (Edit Strings; Find + the More menu's
                // Disassembler Browser/Pseudocode/Analysis Center cover exactly
                // what the old Disassemble ARM64 grid did) — not duplicated here.
                bundleRow("Patch Functions", "scissors", "View") {
                    developerToolMode = .patchFunctions
                    showDeveloperTool = true
                }
                Divider().overlay(Theme.stroke).padding(.leading, 39)
                bundleRow("Mach-O Dependencies", "point.3.connected.trianglepath.dotted", macho.map { "\($0.arm64?.dylibs.count ?? 0)" } ?? "0") {
                    developerToolMode = .dependencies
                    showDeveloperTool = true
                }
                Divider().overlay(Theme.stroke).padding(.leading, 39)
                bundleRow("Real Binary Analysis", "waveform.path.ecg", "Open") {
                    developerToolMode = .analysis
                    showDeveloperTool = true
                }
                Divider().overlay(Theme.stroke).padding(.leading, 39)
                bundleRow("Protection Analysis", "shield.lefthalf.filled", "Scan") {
                    showProtectionAnalysis = true
                }
                Divider().overlay(Theme.stroke).padding(.leading, 39)
                bundleRow("CFG Viewer", "point.3.connected.trianglepath.dotted", "Capstone") {
                    developerToolMode = .cfgViewer
                    showDeveloperTool = true
                }
                Divider().overlay(Theme.stroke).padding(.leading, 39)
                bundleRow("Inject Data", "lock.doc.fill", injectDataBlob == nil ? "Hide" : "Ready") {
                    developerToolMode = .injectData
                    showDeveloperTool = true
                }
            }
            .background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 12))

        }
    }

    // MARK: Binary analysis (hand-rolled Mach-O reader)

    private var binaryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("BINARY")
            if let r = macho {
                VStack(alignment: .leading, spacing: 7.5) {
                    HStack(spacing: 6) {
                        Image(systemName: r.encrypted ? "lock.fill" : "lock.open.fill").foregroundStyle(r.encrypted ? .red : .green)
                        Text(r.encrypted ? "FairPlay ENCRYPTED — will not run after re-sign" : "Decrypted — safe to re-sign")
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(r.encrypted ? .red : .green)
                        Spacer()
                        Text(r.isFat ? "FAT" : "THIN").font(.system(size: 7, weight: .heavy, design: .monospaced)).kerning(0.5)
                            .padding(.horizontal, 4.5).padding(.vertical, 2).background(Color(white: 0.16)).foregroundStyle(Theme.subtle).clipShape(Capsule())
                    }
                    ForEach(r.slices) { sl in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(sl.arch).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(blue)
                                Text(sl.fileType).font(.caption).foregroundStyle(Theme.subtle)
                                if sl.pie { tagSmall("PIE") }
                                if sl.hasCodeSignature { tagSmall("SIGNED \(ByteCountFormatter.string(fromByteCount: Int64(sl.codeSignatureSize), countStyle: .file))") }
                                Spacer()
                            }
                            kvSmall("Min OS", (sl.platform ?? "") + " " + (sl.minOS ?? "—") + (sl.sdk.map { " · SDK \($0)" } ?? ""))
                            kvSmall("Encryption", sl.encrypted ? "cryptid=\(sl.cryptID) (ENCRYPTED)" : "cryptid=0 (clear)")
                            kvSmall("Links", "\(sl.dylibs.count) dylibs · \(sl.weakDylibs.count) weak · \(sl.rpaths.count) rpaths")
                            if !sl.dylibs.isEmpty {
                                DisclosureGroup {
                                    ForEach(sl.dylibs + sl.weakDylibs.map { "(weak) " + $0 }, id: \.self) { d in
                                        Text(d).font(.system(size: 7.5, design: .monospaced)).foregroundStyle(Theme.subtle).lineLimit(1).truncationMode(.middle)
                                    }
                                } label: { Text("Show load commands").font(.caption).foregroundStyle(blue) }
                                .tint(blue)
                            }
                        }
                        .padding(7.5).background(Color(white: 0.06)).clipShape(RoundedRectangle(cornerRadius: 7.5))
                    }
                    ForEach(r.warnings, id: \.self) { w in
                        HStack(alignment: .top, spacing: 4.5) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                            Text(w).font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .padding(10.5).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(r.encrypted ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1))
            } else if let e = machoError {
                Text(e).font(.caption).foregroundStyle(.orange).padding(10.5).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                HStack(spacing: 7.5) { ProgressView().tint(blue); Text("Reading Mach-O headers…").font(.caption).foregroundStyle(Theme.subtle) }
                    .padding(10.5).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func tagSmall(_ s: String) -> some View {
        Text(s).font(.system(size: 7, weight: .heavy, design: .monospaced)).kerning(0.5)
            .padding(.horizontal, 4.5).padding(.vertical, 2).background(blue.opacity(0.15)).foregroundStyle(blue).clipShape(Capsule())
    }
    private func kvSmall(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 4.5) {
            Text(k).font(.caption2).foregroundStyle(Theme.subtle).frame(width: 39.5, alignment: .leading)
            Text(v).font(.system(size: 8, design: .monospaced)).foregroundStyle(.white)
        }
    }

    private func analyzeBinary() async {
        let url = ipaURL
        // Return only Sendable values across the detached boundary (Result<_, Error>
        // is not Sendable under strict concurrency).
        let outcome: (report: MachOReport?, error: String?) = await Task.detached {
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("macho-" + UUID().uuidString, isDirectory: true)
            defer { try? fm.removeItem(at: work) }
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                try fm.unzipItem(at: url, to: work)
                let payload = work.appendingPathComponent("Payload", isDirectory: true)
                guard let app = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else {
                    return (nil, "No .app inside the IPA.")
                }
                return (try MachOInspector.inspect(appBundle: app), nil)
            } catch {
                return (nil, "Couldn't analyze binary: \(error.localizedDescription)")
            }
        }.value
        if let r = outcome.report { macho = r } else { machoError = outcome.error }
    }

    // MARK: Signing method

    // AirShare-style signing method: a selector (Saved / Enterprise / Apple ID)
    // over a body whose accent + content changes with the choice.
    private var signingMethodCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("SIGNING METHOD")
            savedBody
        }
    }

    private var sourceLabel: String { ServerConfig.installHost }

    @ViewBuilder private var savedBody: some View {
        if let c = certs.active {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(accentTint)
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(accentSoft).font(.system(size: 18, weight: .bold))
                    }
                    .frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("USING YOUR SAVED CERTIFICATE").font(.system(size: 8.5, weight: .heavy)).kerning(1.1).foregroundStyle(accentSoft)
                        Text(c.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                        Text(certSubtitle(c)).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.subtle).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(.horizontal, 6)
                HiddenWhenNative {
                HStack(alignment: .top, spacing: 0) {
                    Button { settingsJump = .ota } label: {
                        detailTile(
                            icon: "globe",
                            iconColor: blue,
                            iconBackground: blue.opacity(0.16),
                            title: "DISTRIBUTED IDENTITY",
                            titleColor: blue,
                            primary: ServerConfig.installHost,
                            secondary: "https://\(ServerConfig.installHost)",
                            tertiary: "This is the public URL where your app will be available."
                        )
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(Theme.stroke).frame(width: 1).padding(.vertical, 18)
                    Button { settingsJump = .certs } label: {
                        detailTile(
                            icon: "signature.zh",
                            iconColor: success,
                            iconBackground: success.opacity(0.16),
                            title: "CERTIFICATE",
                            titleColor: success,
                            primary: ServerConfig.certMode == "local" ? "Local CA" : (ServerConfig.certMode == "custom" ? "Own cert" : "Let's Encrypt"),
                            secondary: certStatusTitle,
                            tertiary: certStatusSubtitle
                        )
                    }
                    .buttonStyle(.plain)
                }
                .background(surface)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
            .padding(12)
            .background(surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(accent.opacity(0.45), lineWidth: 1.2))
        } else {
            HStack(spacing: 7.5) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text("No certificate — import one in Settings › Certificates.").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Icon

    private var certDaysLeft: Int? {
        if ServerConfig.certMode == "local" { return LocalCAManager.leafDaysLeft }
        return ZefvCert.effectiveNotAfter.map { Calendar.current.dateComponents([.day], from: Date(), to: $0).day ?? 0 }
    }

    private func certSubtitle(_ c: Certificate) -> String {
        let info = (try? Data(contentsOf: c.provisionURL)).map(CertificateStore.profileInfo) ?? ProfileInfo()
        var parts: [String] = []
        if let t = info.team { parts.append("Team \(t)") }
        if let e = info.expires { parts.append("Expires " + e.formatted(date: .abbreviated, time: .omitted)) }
        return parts.isEmpty ? "On-device certificate" : parts.joined(separator: " · ")
    }

    private var certStatusTitle: String {
        guard let d = certDaysLeft else { return "Unknown" }
        return d < 0 ? "Expired" : "Valid"
    }

    private var certStatusSubtitle: String {
        guard let d = certDaysLeft else { return "Expiry unavailable" }
        let label = d == 1 ? "day" : "days"
        if let date = ZefvCert.effectiveNotAfter {
            return d < 0 ? "Expired \(date.formatted(date: .abbreviated, time: .omitted))" : "Expires in \(d) \(label) (\(date.formatted(date: .abbreviated, time: .omitted)))"
        }
        return d < 0 ? "Expired" : "Expires in \(d) \(label)"
    }

    private func detailTile(icon: String, iconColor: Color, iconBackground: Color, title: String, titleColor: Color, primary: String, secondary: String, tertiary: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous).fill(iconBackground)
                    Image(systemName: icon).foregroundStyle(iconColor).font(.system(size: 18, weight: .semibold))
                }
                .frame(width: 44, height: 44)
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 8.5, weight: .heavy)).kerning(1.1).foregroundStyle(titleColor)
                Text(primary).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                Text(secondary).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(titleColor)
                Divider().overlay(Theme.stroke)
                Text(tertiary).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.subtle)
            }
            HStack {
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.subtle)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var appIcon: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("APP ICON")
            Button { showIconPicker = true } label: {
                HStack(spacing: 12) {
                    iconThumb(iconPNG ?? meta.iconPNG, side: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(iconPNG == nil ? "Replace app icon" : "Icon replaced").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                        Text("PNG/JPEG — auto-resized to required sizes").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.subtle)
                    }
                    Spacer()
                    if iconPNG != nil {
                        Button { iconPNG = nil } label: {
                            Image(systemName: "arrow.uturn.backward").foregroundStyle(accentSoft).font(.system(size: 16, weight: .bold))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Image(systemName: "chevron.right").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.subtle)
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(surfaceRaised)
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [6])))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Identity

    private var identity: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("APP NAME · BUNDLE ID · VERSION")
            VStack(spacing: 0) {
                identRow("Aa", "Name", $name)
                divider
                identRow("shippingbox.fill", "Bundle ID", $bundle, mono: true)
                divider
                identRow("number", "Version", $version, mono: true)
            }
            .background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func identRow(_ icon: String, _ label: String, _ text: Binding<String>, mono: Bool = false) -> some View {
        HStack(spacing: 10.5) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accentTint).frame(width: 32, height: 32)
                if icon == "Aa" { Text("Aa").font(.system(size: 13, weight: .bold)).foregroundStyle(accentSoft) }
                else { Image(systemName: icon).foregroundStyle(accentSoft) }
            }
            VStack(alignment: .leading, spacing: 1.5) {
                Text(label).font(.system(size: 11, weight: .bold)).foregroundStyle(.white.opacity(0.88))
                TextField(label, text: text)
                    .font(.system(size: 12, weight: .medium, design: mono ? .monospaced : .default)).foregroundStyle(.white)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            }
        }
        .padding(12)
    }

    // MARK: Build options (collapsible groups)

    private var buildOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("BUILD OPTIONS")
            group("general", "slider.horizontal.3", "General", badge: generalCount > 0 ? "\(generalCount) active" : nil) {
                toggle("Remove existing libraries", $o.removeExistingLibraries, note: "Strip pre-existing dylibs and frameworks before injection")
                toggle("Thin to arm64 only", $o.thinToArm64Only, note: "Drop other architectures — ~30% smaller, A8+ devices")
                toggle("Randomize bundle ID", $o.randomizeBundleID, note: "Append a random suffix so it can coexist with the original app")
                toggle("Disable ATS (HTTP allowed)", $o.disableATS, note: "Adds NSAllowsArbitraryLoads to Info.plist for legacy HTTP endpoints")
                toggle("Weak dylib references", $o.weakDylibReferences, note: "Use LC_LOAD_WEAK_DYLIB — survives missing libs at launch")
                toggle("Remove Watch apps", $o.stripWatch, note: "Strip the embedded watchOS bundle for smaller IPAs")
                toggle("SHA256 only", $o.sha256Only, note: "Skip SHA1 hashes — modern iOS verifies faster, ~5% smaller CodeResources")
                toggle("Force re-sign", $o.forceResign, note: "Override existing signatures even on already-signed IPAs")
                toggle("Surgical mode", $o.surgicalMode, note: "Use the faster signing prep path when possible")
                toggle("Parallel signing", $o.parallelSigning, note: parallelSigningNote)
            }
            group("strip", "scissors", "Strip Content", badge: "\(stripCount)") {
                toggle("Strip PlugIns", $o.stripExtensions, note: "Remove app extensions (Today widget, share sheet) — required for some sideloads")
                toggle("Strip SC_Info", $o.stripSCInfo, note: "Remove App Store DRM metadata — basic anti-traceback")
                toggle("Strip privacy declarations", $o.stripPrivacy, note: "Remove PrivacyInfo.xcprivacy files — avoids privacy manifest disclosure")
                toggle("Strip Bitcode", $o.stripBitcode, note: "Remove __LLVM segment — legacy, ignored by iOS 14+")
                toggle("Strip debug symbols", $o.stripDebugSymbols, note: "Drop dSYM/symbol tables — smaller binary")
            }
            group("scrub", "key.fill", "Entitlement Scrubbers", badge: "\(scrubCount)") {
                toggle("Auto-fix entitlements", $o.autoFixEntitlements, note: "Strip ents that don't match your cert team — fixes \"Profile doesn't include\" errors")
                toggle("Disable Push Notifications", $o.disablePush, note: "Strip aps-environment — required if your cert isn't push-enabled")
                toggle("Disable App Groups", $o.disableAppGroups, note: "Strip com.apple.security.application-groups — required for free certs")
                toggle("Disable iCloud", $o.disableiCloud, note: "Strip iCloud container & ubiquity entitlements")
                toggle("Disable Siri", $o.disableSiri, note: "Strip com.apple.developer.siri")
                toggle("Disable Background Modes", $o.disableBackgroundModes, note: "Strip UIBackgroundModes — kills VoIP/audio background")
            }
            group("plist", "doc.text.fill", "Info.plist Tweaks", badge: "\(plistCount)") {
                toggle("Force min iOS 12.0", $o.forceMinIOS12, note: "Override MinimumOSVersion so older devices can install")
                toggle("Hide URL schemes", $o.removeURLSchemes, note: "Strip CFBundleURLTypes — kills custom URL handlers")
                toggle("Disable file sharing", $o.disableFileSharing, note: "Force UIFileSharingEnabled = false")
                toggle("Force portrait", $o.forcePortrait, note: "Lock UISupportedInterfaceOrientations to portrait only")
                toggle("Skip iPad", $o.skipIPad, note: "Restrict UIDeviceFamily to iPhone only — smaller install footprint")
            }
        }
    }

    private var generalCount: Int {
        [o.removeExistingLibraries, o.thinToArm64Only, o.randomizeBundleID, o.disableATS,
         o.weakDylibReferences, o.stripWatch, o.sha256Only, o.forceResign, o.surgicalMode, o.parallelSigning].filter { $0 }.count
    }
    private var stripCount: Int { [o.stripExtensions, o.stripSCInfo, o.stripPrivacy, o.stripBitcode, o.stripDebugSymbols].filter { $0 }.count }
    private var scrubCount: Int { [o.autoFixEntitlements, o.disablePush, o.disableAppGroups, o.disableiCloud, o.disableSiri, o.disableBackgroundModes].filter { $0 }.count }
    private var plistCount: Int { [o.forceMinIOS12, o.removeURLSchemes, o.disableFileSharing, o.forcePortrait, o.skipIPad].filter { $0 }.count }

    @ViewBuilder
    private func group<C: View>(_ key: String, _ icon: String, _ title: String, badge: String?, @ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 0) {
            Button { withAnimation { if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) } } } label: {
                HStack(spacing: 10.5) {
                    ZStack { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(accentTint).frame(width: 32, height: 32); Image(systemName: icon).foregroundStyle(accentSoft) }
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white)
                    Spacer()
                    if let b = badge {
                        Text(b).font(.system(size: 10, weight: .bold)).foregroundStyle(b.contains("active") ? accentSoft : Theme.subtle)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.white.opacity(0.06)).clipShape(Capsule())
                    }
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.subtle)
                        .rotationEffect(.degrees(expanded.contains(key) ? 180 : 0))
                }
                .padding(10.5)
            }
            .buttonStyle(.plain)
            if expanded.contains(key) {
                VStack(spacing: 0) { content() }.padding(.bottom, 4.5)
            }
        }
        .background(surfaceRaised).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func toggle(_ label: String, _ b: Binding<Bool>, disabled: Bool = false, note: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1.5) {
                Text(label).font(.system(size: 11)).foregroundStyle(disabled ? Theme.subtle : .white)
                if let n = note { Text(n).font(.caption2).foregroundStyle(Theme.subtle) }
            }
            Spacer()
            Toggle("", isOn: b).labelsHidden().tint(accent).disabled(disabled)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    // MARK: Dylib injection

    private var dylibInjection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("DYLIB INJECTION")
            VStack(alignment: .leading, spacing: 10.5) {
                segRow("Inject Path", ["@executable_path": "@executable", "@rpath": "@rpath"], $injectPath)
                segRow("Inject Folder", ["/": "/", "Frameworks/": "Frameworks/"], $injectFolder)

                Text("\(injectPath)/\(injectFolder == "/" ? "" : "Frameworks/")xxx.dylib")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.subtle)
                    .padding(9).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(white: 0.06)).clipShape(RoundedRectangle(cornerRadius: 7.5))

                ForEach($dylibs) { $d in
                    HStack(spacing: 9) {
                        Button { dylibs.removeAll { $0.id == d.id } } label: {
                            Image(systemName: "minus.circle.fill").font(.system(size: 19.5)).foregroundStyle(.red)
                        }
                        Text(d.url.lastPathComponent).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white).lineLimit(1)
                        Spacer()
                        Toggle("weak", isOn: $d.weak).labelsHidden().tint(blue)
                    }
                    .padding(9).background(Color(white: 0.10)).clipShape(RoundedRectangle(cornerRadius: 9))
                }

                if !machoDylibs.isEmpty {
                    DisclosureGroup {
                        ForEach(machoDylibs, id: \.self) { d in
                            HStack {
                                Image(systemName: removeDylibs.contains(d) ? "checkmark.square.fill" : "square").foregroundStyle(removeDylibs.contains(d) ? .red : Theme.subtle)
                                Text(d).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.subtle).lineLimit(1).truncationMode(.middle)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { if removeDylibs.contains(d) { removeDylibs.remove(d) } else { removeDylibs.insert(d) } }
                            .padding(.vertical, 3)
                        }
                    } label: {
                        Text("Existing load commands (\(machoDylibs.count)) — tap to strip").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.subtle)
                    }
                    .tint(blue)
                    .padding(9).background(Color(white: 0.06)).clipShape(RoundedRectangle(cornerRadius: 9))
                }

                Button { showDylibPicker = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 19.5, weight: .bold)).foregroundStyle(Theme.subtle)
                        Text("Add library (.dylib, .framework)").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        Text("Includes GitHub Actions-built dylibs").font(.system(size: 9)).foregroundStyle(Theme.subtle)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 19.5)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.stroke, style: StrokeStyle(lineWidth: 1, dash: [6])))
                }
                .buttonStyle(.plain)
                Text("Workflow: export the generated template ZIP → push its files to your GitHub repository → download GeneratedSwizzle-ios-arm64 from Actions → return here and add the .dylib. AirCore stages it for this signing session; it does not download artifacts from GitHub automatically.")
                    .font(.system(size: 9)).foregroundStyle(Theme.subtle).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 13.5))
        }
    }

    private func segRow(_ label: String, _ opts: [String: String], _ sel: Binding<String>) -> some View {
        HStack(spacing: 7.5) {
            Text(label).font(.system(size: 12)).foregroundStyle(.white).frame(width: 61, alignment: .leading)
            ForEach(opts.sorted(by: { $0.key < $1.key }), id: \.key) { k, title in
                Button { sel.wrappedValue = k } label: {
                    Text(title).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .padding(.vertical, 7.5).frame(maxWidth: .infinity)
                        .background(sel.wrappedValue == k ? blue.opacity(0.18) : Color(white: 0.1))
                        .foregroundStyle(sel.wrappedValue == k ? blue : Theme.subtle)
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(sel.wrappedValue == k ? blue : Theme.stroke, lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Changes summary

    private var changesSummary: some View {
        let ident = [name != meta.name ? "Name → \(name)" : nil,
                     bundle != meta.bundleID ? "Bundle → \(bundle)" : nil,
                     version != meta.version ? "Version → \(version)" : nil,
                     iconPNG != nil ? "Replace icon" : nil].compactMap { $0 }
        let dy = dylibs.map { "Inject \($0.url.lastPathComponent)" } + removeDylibs.map { "Remove \(($0 as NSString).lastPathComponent)" }
        let build = strip + plistList + generalSummary
        return Group {
            if ident.isEmpty && dy.isEmpty && build.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel("CHANGES TO BE APPLIED")
                    VStack(alignment: .leading, spacing: 9) {
                        if !ident.isEmpty { summaryBlock("square.on.square", "Identity", ident) }
                        if !dy.isEmpty { summaryBlock("syringe", "Dylibs", dy) }
                        if !build.isEmpty { summaryBlock("slider.horizontal.3", "Build options", build) }
                    }
                    .padding(12).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 13.5))
                }
            }
        }
    }

    private var strip: [String] {
        [o.stripExtensions ? "Strip PlugIns" : nil, o.stripSCInfo ? "Strip SC_Info" : nil,
         o.stripPrivacy ? "Strip privacy declarations" : nil, o.stripBitcode ? "Strip Bitcode" : nil,
         o.stripDebugSymbols ? "Strip debug symbols" : nil,
         o.autoFixEntitlements ? "Auto-fix entitlements" : nil, o.disablePush ? "Disable Push" : nil,
         o.disableAppGroups ? "Disable App Groups" : nil, o.disableiCloud ? "Disable iCloud" : nil,
         o.disableSiri ? "Disable Siri" : nil, o.disableBackgroundModes ? "Disable Background Modes" : nil].compactMap { $0 }
    }
    private var generalSummary: [String] {
        let parallelDecision = currentParallelSigningDecision
        return [o.removeExistingLibraries ? "Remove existing libraries" : nil,
                o.randomizeBundleID ? "Randomize bundle ID" : nil,
                o.disableATS ? "Disable ATS" : nil,
                o.weakDylibReferences ? "Weak dylib references" : nil,
                o.stripWatch ? "Remove Watch apps" : nil,
                o.thinToArm64Only ? "Thin to arm64" : nil, o.sha256Only ? "SHA256 only" : nil,
                o.surgicalMode ? "Surgical mode" : nil,
                o.parallelSigning ? parallelDecision.statusText : nil].compactMap { $0 }
    }
    private var currentParallelSigningDecision: Signer.ParallelSigningDecision {
        var preview = SignOptions()
        preview.surgicalMode = o.surgicalMode
        preview.parallelSigning = o.parallelSigning
        preview.injectDylibs = dylibs.map { ($0.url, o.weakDylibReferences ? true : $0.weak) }
        return Signer.parallelSigningDecision(options: preview, payloadSizeBytes: parallelSigningPayloadSize)
    }
    private var effectiveParallelSigning: Bool { currentParallelSigningDecision.isEnabled }
    private var parallelSigningNote: String { currentParallelSigningDecision.noteText }
    private var plistList: [String] {
        [o.forceMinIOS12 ? "MinimumOSVersion 12.0" : nil, o.removeURLSchemes ? "Hide URL schemes" : nil,
         o.disableFileSharing ? "Disable file sharing" : nil,
         o.forcePortrait ? "Force portrait" : nil, o.skipIPad ? "iPhone only" : nil].compactMap { $0 }
        + plistSetValues.sorted(by: { $0.key < $1.key }).map { "Info.plist: \($0.key)=\($0.value)" }
    }

    private func summaryBlock(_ icon: String, _ title: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Image(systemName: icon).foregroundStyle(blue); Text(title).font(.system(size: 12, weight: .bold)).foregroundStyle(.white); Spacer(); Text("\(items.count)").foregroundStyle(Theme.subtle) }
            ForEach(items, id: \.self) { Text("· \($0)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.subtle) }
        }
    }

    // MARK: Log + signed

    private var tracingCard: some View {
        HStack(spacing: 7.5) {
            ProgressView().tint(blue)
            Text("Watching installd… tap Install in the iOS sheet. Report in ~25s.").font(.caption).foregroundStyle(Theme.subtle)
        }
        .padding(10.5).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 10.5))
    }

    private func reportCard(_ r: OTAInstaller.Report) -> some View {
        VStack(alignment: .leading, spacing: 7.5) {
            HStack {
                Label("Install trace", systemImage: "waveform.path.ecg").font(.headline).foregroundStyle(.white)
                Spacer()
                Text(r.delivered ? "IPA DELIVERED" : "NOT DELIVERED")
                    .font(.system(size: 7, weight: .heavy, design: .monospaced)).kerning(0.5)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background((r.delivered ? Color.green : Color.orange).opacity(0.18))
                    .foregroundStyle(r.delivered ? .green : .orange).clipShape(Capsule())
            }
            if r.requests.isEmpty {
                Text("installd made no requests.").font(.caption).foregroundStyle(.orange)
            } else {
                ForEach(r.requests) { e in
                    HStack(spacing: 6) {
                        Image(systemName: e.status == 200 ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(e.status == 200 ? .green : .orange).font(.caption)
                        Text(e.path).font(.system(size: 8, design: .monospaced)).foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: e.bytes, countStyle: .file)).font(.caption2.monospaced()).foregroundStyle(Theme.subtle)
                    }
                }
            }
            Text(r.diagnosis).font(.system(size: 10)).foregroundStyle(.white)
            if let p = r.profileNote {
                Text(p).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.subtle)
            }
        }
        .padding(10.5).background(Color(white: 0.08)).clipShape(RoundedRectangle(cornerRadius: 10.5))
    }

    // MARK: Sign bar

    private var signBar: some View {
        Button { Task { await sign() } } label: {
            HStack(spacing: 7.5) {
                if signing { ProgressView().tint(.white) } else { Image(systemName: "signature").font(.system(size: 13.5, weight: .bold)) }
                Text(signing ? "Signing…" : "Sign IPA").font(.system(size: 13.5, weight: .bold))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(certs.active == nil || macho?.encrypted == true ? Theme.subtle : accent).foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .disabled(signing || certs.active == nil || macho?.encrypted == true)
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 4.5)
    }

    // MARK: Helpers

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .bold)).kerning(2).foregroundStyle(.white.opacity(0.72))
    }
    private var divider: some View { Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 51) }

    private func iconThumb(_ data: Data?, side: CGFloat) -> some View {
        Group {
            if let data, let img = UIImage(data: data) { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: side * 0.22).fill(blue.opacity(0.15)).overlay(Image(systemName: "app.fill").foregroundStyle(blue)) }
        }
        .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
    }

    private func currentDylibs() async -> [String] {
        let url = ipaURL
        return await Task.detached { () -> [String] in
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("peek-" + UUID().uuidString, isDirectory: true)
            defer { try? fm.removeItem(at: work) }
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                try fm.unzipItem(at: url, to: work)
                let payload = work.appendingPathComponent("Payload", isDirectory: true)
                guard let app = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else { return [] }
                let bin = (NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))?["CFBundleExecutable"] as? String) ?? app.deletingPathExtension().lastPathComponent
                return ZsignSigner.listDylibs(inMachO: app.appendingPathComponent(bin).path)
                    .filter { !$0.hasPrefix("/System") && !$0.hasPrefix("/usr/lib") }
            } catch { return [] }
        }.value
    }

    private func loadParallelSigningPayloadSize() async -> Int64? {
        let url = ipaURL
        return await Task.detached {
            Signer.payloadSizeForParallelDecision(ipaURL: url)
        }.value
    }

    private func loadDeveloperStrings() async -> [DeveloperStringEntry] {
        let url = ipaURL
        return await Task.detached { () -> [DeveloperStringEntry] in
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("strings-" + UUID().uuidString, isDirectory: true)
            defer { try? fm.removeItem(at: work) }
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                try fm.unzipItem(at: url, to: work)
                let payload = work.appendingPathComponent("Payload", isDirectory: true)
                guard let app = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else { return [] }
                let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any]
                let bin = (info?["CFBundleExecutable"] as? String) ?? app.deletingPathExtension().lastPathComponent
                let binaryURL = app.appendingPathComponent(bin)

                var seen = Set<String>()
                var out: [DeveloperStringEntry] = []
                for value in flattenedPlistStrings(info) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard trimmed.count >= 4 else { continue }
                    if seen.insert("plist:\(trimmed)").inserted {
                        out.append(DeveloperStringEntry(source: "Info.plist", value: trimmed))
                    }
                }
                if let data = try? Data(contentsOf: binaryURL) {
                    for value in printableStrings(in: data).prefix(200) {
                        if seen.insert("bin:\(value)").inserted {
                            out.append(DeveloperStringEntry(source: bin, value: value))
                        }
                    }
                }
                return out
            } catch {
                return []
            }
        }.value
    }

    private func attachAVX512DylibIfNeeded(_ url: URL) {
        guard canAccessDeveloperTools, AVX512AirShareBridge.shared.enabled else { return }
        let path = url.standardizedFileURL.path
        guard !dylibs.contains(where: { $0.url.standardizedFileURL.path == path }) else { return }
        dylibs.append(DylibItem(url: url, weak: false))
    }

    private func buildOptionsValue() -> SignOptions {
        var s = SignOptions()
        s.name = name.isEmpty ? nil : name
        // Override only when the user changed it (AirShare passes the field through as-is
        // once it differs from the read value; unchanged → let the signer keep the app's own).
        let b = bundle.trimmingCharacters(in: .whitespaces)
        var bundleOut = (b.isEmpty || b == meta.bundleID) ? nil : b
        if o.randomizeBundleID {
            let base = (bundleOut ?? (b.isEmpty ? meta.bundleID : b)).trimmingCharacters(in: .whitespaces)
            if !base.isEmpty { bundleOut = base + "." + randomSuffix(6) }
        }
        s.bundleID = bundleOut
        s.version = version.isEmpty ? nil : version
        s.iconPNG = iconPNG
        s.injectDylibs = dylibs.map { ($0.url, o.weakDylibReferences ? true : $0.weak) }
        if canAccessDeveloperTools, AVX512AirShareBridge.shared.enabled {
            s.avx512BridgeManifest = AVX512AirShareBridge.shared.manifestData(bundleID: bundle, appName: name)
        }
        s.injectPath = injectPath; s.injectFolder = injectFolder
        s.removeDylibs = Array(Set((o.removeExistingLibraries ? machoDylibs : []) + Array(removeDylibs)))
        s.binaryPatches = binaryPatches
        s.injectDataBlob = injectDataBlob
        s.plistSet = plistSetValues
        s.forceMinIOS = o.forceMinIOS12 ? "12.0" : nil
        s.disableFileSharing = o.disableFileSharing
        s.forcePortrait = o.forcePortrait
        s.skipIPad = o.skipIPad
        s.disableATS = o.disableATS
        s.surgicalMode = o.surgicalMode
        s.parallelSigning = o.parallelSigning
        s.parallelSigningPayloadSizeBytes = parallelSigningPayloadSize
        s.stripSCInfo = o.stripSCInfo
        s.stripPrivacyManifests = o.stripPrivacy
        s.stripWatchApps = o.stripWatch
        s.stripExtensions = o.stripExtensions
        s.removeURLSchemes = o.removeURLSchemes
        s.stripBitcode = o.stripBitcode
        s.stripDebugSymbols = o.stripDebugSymbols
        s.autoFixEntitlements = o.autoFixEntitlements
        s.disablePush = o.disablePush
        s.disableAppGroups = o.disableAppGroups
        s.disableiCloud = o.disableiCloud
        s.disableSiri = o.disableSiri
        s.disableBackgroundModes = o.disableBackgroundModes
        s.entitlementsPlistData = encodedEntitlementsPlistData()
        return s
    }

    private func loadEntitlementsFromActiveProfile() {
        guard let material = try? certs.activeMaterial() else { return }
        let parsed = parseProvisionEntitlements(provision: material.provision)
        entitlementValues = parsed.values
        entitlementTypeHints = parsed.typeHints
    }

    private func parseProvisionEntitlements(provision: Data) -> (values: [String: String], typeHints: [String: String]) {
        guard let xml = xmlPlistData(fromMobileProvision: provision),
              let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let ent = plist["Entitlements"] as? [String: Any] else {
            return ([:], [:])
        }
        var values: [String: String] = [:]
        var hints: [String: String] = [:]
        for (k, v) in ent {
            values[k] = stringifyEntitlementValue(v)
            if v is Bool { hints[k] = "bool" }
            else if v is NSNumber { hints[k] = "number" }
            else if v is [Any] { hints[k] = "array" }
            else { hints[k] = "string" }
        }
        return (values, hints)
    }

    private func encodedEntitlementsPlistData() -> Data? {
        guard !entitlementValues.isEmpty else { return nil }
        var dict: [String: Any] = [:]
        for (k, raw) in entitlementValues {
            let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch entitlementTypeHints[k] {
            case "bool":
                dict[k] = (v.lowercased() == "true")
            case "number":
                if let i = Int(v) { dict[k] = i }
                else if let d = Double(v) { dict[k] = d }
                else { dict[k] = v }
            case "array":
                dict[k] = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            default:
                if v.lowercased() == "true" { dict[k] = true }
                else if v.lowercased() == "false" { dict[k] = false }
                else { dict[k] = v }
            }
        }
        return try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    private func stringifyEntitlementValue(_ value: Any) -> String {
        if let b = value as? Bool { return b ? "true" : "false" }
        if let s = value as? String { return s }
        if let arr = value as? [String] { return arr.joined(separator: ", ") }
        if let arr = value as? [Any] { return arr.map { "\($0)" }.joined(separator: ", ") }
        return "\(value)"
    }

    private func randomSuffix(_ count: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<count).compactMap { _ in chars.randomElement() })
    }

    private func sign() async {
        showTerminal = true
        if let r = macho, r.encrypted {
            error = "This IPA is still FairPlay-encrypted (cryptid ≠ 0). Signing it will produce an app that crashes at launch. Get a decrypted IPA first."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        guard let material = try? certs.activeMaterial() else { error = "No active certificate."; return }
        if canAccessDeveloperTools, AVX512AirShareBridge.shared.enabled {
            AVX512AirShareBridge.shared.publish(bundleID: bundle, appName: name, ipaURL: ipaURL)
        }
        signing = true; error = nil; result = nil
        log = [">>> Signing \(name) with \(material.name)"]
        log.append(contentsOf: preflightLines(material))
        log.append(contentsOf: warningLines())
        let url = ipaURL
        let options = buildOptionsValue()
        let logSink = SigningLogSink { line in log.append(line) }
        // Native: connect and upload the files signing won't touch while the signer is still running.
        NativeInstaller.shared.beginPrestage(original: url, bundleID: meta.bundleID, name: name)
        // Start the song/keep-alive the moment you tap Sign, not only once the upload begins.
        let holdID = "sign-\(UUID().uuidString)"
        if NativeInstaller.isSelected { BackgroundKeepAlive.shared.start(holdID) }
        var handedOff = false
        defer { if !handedOff { BackgroundKeepAlive.shared.stop(holdID) } }
        do {
            let outcome = try await Task.detached(priority: .userInitiated) {
                try await Signer.signDetached(
                    ipaURL: url,
                    material: material,
                    options: options,
                    onLog: { line in logSink.append(line) }
                )
            }.value
            lastEntitlements = outcome.entitlements
            lastSizeBytes = outcome.sizeBytes
            let entry = try SignedStore.shared.add(outcome: outcome, icon: iconPNG ?? meta.iconPNG, certName: material.name)
            NativeInstaller.registerOriginal(url, forSigned: entry.ipaURL)
            SignProfileStore.shared.save(options: options, signedBundleID: entry.bundleID,
                                         sourceBundleID: meta.bundleID, sourceVersion: meta.version)
            log.append(contentsOf: postSignLines(outcome.entitlements, entry: entry))
            result = entry
            onSigned(entry)
            ZefvAccount.shared.recordSign()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            // Native: start installing the moment signing finishes — no extra tap, no waiting.
            if NativeInstaller.isSelected {
                handedOff = true
                Task { await install(entry); BackgroundKeepAlive.shared.stop(holdID) }
            }
        } catch {
            NativeInstaller.shared.cancelPrestage()
            self.error = error.localizedDescription
            log.append("error: \(error.localizedDescription)")
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        signing = false
    }

    private var sourceSizeBytes: Int64 {
        (try? FileManager.default.attributesOfItem(atPath: ipaURL.path)[.size] as? Int64) ?? 0
    }

    /// Pre-flight step: cert/profile · MachO encryption · dylib injection list.
    private func preflightLines(_ material: CertMaterial) -> [String] {
        var out = ["§step|checkmark.shield|Pre-flight"]
        let info = CertificateStore.profileInfo(material.provision)
        var certLine = material.name
        if let e = info.expires {
            let days = Int(e.timeIntervalSinceNow / 86400)
            certLine += days < 0 ? " · EXPIRED" : " · \(days) days left"
        }
        if !info.udids.isEmpty { certLine += " · \(info.udids.count) device\(info.udids.count == 1 ? "" : "s")" }
        if let t = info.team, !t.isEmpty { certLine += " · \(t)" }
        out.append("§child|Cert: \(certLine)")
        if let m = macho {
            let arch = m.arm64?.arch ?? m.slices.first?.arch ?? "?"
            out.append("§child|MachO: \(m.encrypted ? "FairPlay encrypted (cryptid \(m.arm64?.cryptID ?? 1))" : "decrypted") · \(arch)\(m.isFat ? " · fat" : "")\(m.arm64?.minOS.map { " · iOS \($0)+" } ?? "")")
        } else if let machoError {
            out.append("§child|MachO: not inspected (\(machoError))")
        }
        if dylibs.isEmpty { out.append("§child|Inject: none") }
        else { for d in dylibs { out.append("§child|Inject: \(d.url.lastPathComponent)\(d.weak || o.weakDylibReferences ? " (weak)" : "")") } }
        if !machoDylibs.isEmpty { out.append("§child|Existing load commands: \(machoDylibs.count)") }
        out.append("§done|Pre-flight")
        return out
    }

    /// Warnings step: every destructive option that's switched on.
    private func warningLines() -> [String] {
        var w: [String] = []
        if o.stripExtensions { w.append("PlugIns stripped — app extensions removed") }
        if o.stripWatch { w.append("Watch app removed") }
        if o.stripSCInfo { w.append("SC_Info removed") }
        if o.stripPrivacy { w.append("Privacy manifests removed") }
        if o.stripBitcode { w.append("Bitcode stripped") }
        if o.stripDebugSymbols { w.append("Debug symbols stripped") }
        if o.removeExistingLibraries { w.append("Existing dylib load commands removed") }
        if o.thinToArm64Only { w.append("Thinned to arm64 only") }
        if o.randomizeBundleID { w.append("Bundle ID randomized — installs side-by-side") }
        if o.disableATS { w.append("ATS disabled — cleartext HTTP allowed") }
        if o.removeURLSchemes { w.append("URL schemes removed") }
        if o.forceResign { w.append("Force re-sign — existing signatures discarded") }
        return w.map { "§warn|" + $0 }
    }

    /// Post-sign steps: key entitlements + AirShare manifest readiness.
    private func postSignLines(_ ents: [String: String], entry: SignedEntry) -> [String] {
        var out = ["§step|checkmark.shield.fill|Inspect entitlements"]
        let keys = ["application-identifier", "com.apple.developer.team-identifier", "get-task-allow", "aps-environment",
                    "com.apple.security.application-groups", "keychain-access-groups", "com.apple.developer.associated-domains",
                    "platform-application", "com.apple.security.app-sandbox"]
        var n = 0
        for k in keys { if let v = ents[k] { out.append("§child|\(k.replacingOccurrences(of: "com.apple.developer.", with: "").replacingOccurrences(of: "com.apple.security.", with: "")) = \(v)"); n += 1 } }
        if n == 0 { out.append("§child|\(ents.count) entitlement\(ents.count == 1 ? "" : "s")") }
        out.append("§done|Inspect entitlements (\(ents.count))")
        out.append("§step|antenna.radiowaves.left.and.right|Generate AirShare manifest")
        out.append("§child|host \(ServerConfig.installHost) · \(entry.name).ipa")
        out.append("§child|\(entry.bundleID) · v\(entry.version)")
        out.append("§done|AirShare manifest ready")
        return out
    }

    private func install(_ r: SignedEntry) async {
        error = nil
        do {
            let native = NativeInstaller.isSelected
            let started = Date()
            try await OTAInstaller.shared.install(r)
            if native {
                log.append(String(format: "✓ Install triggered — installed natively over the built-in VPN in %.1fs", Date().timeIntervalSince(started)))
                let t = NativeInstaller.shared.timingSummary
                if !t.isEmpty { log.append("⏱ " + t) }
            } else {
                log.append("✓ Install triggered — confirm on your home screen")
            }
            // Native shows its own install tile; the popup is only for the OTA handoff.
            if !native {
                withAnimation { sentToHome = true }
                try? await Task.sleep(nanoseconds: 2_600_000_000)
                withAnimation { sentToHome = false }
            }
        } catch {
            self.error = error.localizedDescription
            log.append("error: install failed — \(error.localizedDescription)")
        }
    }

    private func installTrollStore(_ r: SignedEntry) async {
        error = nil
        do {
            try await OTAInstaller.shared.installWithTrollStore(r)
            log.append("✓ Handed off to TrollStore")
            withAnimation { sentToHome = true }
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation { sentToHome = false }
        } catch {
            self.error = error.localizedDescription
            log.append("error: TrollStore install failed — \(error.localizedDescription)")
        }
    }
}

nonisolated struct DeveloperStringEntry: Identifiable, Hashable, Sendable {
    let source: String
    let value: String
    var id: String { source + "::" + value }
}

private func printableStrings(in data: Data, minimumLength: Int = 4) -> [String] {
    var values: [String] = []
    var current: [UInt8] = []
    current.reserveCapacity(64)
    for byte in data {
        if (32...126).contains(byte) {
            current.append(byte)
        } else {
            if current.count >= minimumLength {
                values.append(String(decoding: current, as: UTF8.self))
            }
            current.removeAll(keepingCapacity: true)
        }
    }
    if current.count >= minimumLength {
        values.append(String(decoding: current, as: UTF8.self))
    }
    return Array(NSOrderedSet(array: values)) as? [String] ?? values
}

private func flattenedPlistStrings(_ value: Any?) -> [String] {
    switch value {
    case let dict as [String: Any]:
        return dict.flatMap { [String(describing: $0.key)] + flattenedPlistStrings($0.value) }
    case let array as [Any]:
        return array.flatMap(flattenedPlistStrings)
    case let string as String:
        return [string]
    case let number as NSNumber:
        return [number.stringValue]
    default:
        return []
    }
}

// MARK: - Document picker

struct BundleInfoEditorSheet: View {
    enum Mode { case entitlements, infoPlist }

    let mode: Mode
    @Binding var entitlements: [String: String]
    @Binding var infoPlistSet: [String: String]
    var onRemoveEntitlement: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if mode == .entitlements {
                    KeyValueEditorList(
                        title: "Entitlements",
                        values: $entitlements,
                        addLabel: "Add entitlement key",
                        onRemoveKey: onRemoveEntitlement
                    )
                } else {
                    KeyValueEditorList(
                        title: "Info.plist",
                        values: $infoPlistSet,
                        addLabel: "Add Info.plist key"
                    )
                }
            }
            .navigationTitle(mode == .entitlements ? "Entitlements (\(entitlements.count))" : "Info.plist (\(infoPlistSet.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct DeveloperToolSheet: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    enum Mode { case strings, patchFunctions, dependencies, disassemble, analysis, injectData, cfgViewer }

    let mode: Mode
    let ipaURL: URL
    let appName: String
    let appBundleID: String
    let macho: MachOReport?
    let machoError: String?
    @Binding var patches: [BinaryPatch]
    @Binding var injectBlob: Data?
    @Binding var injectName: String
    var stageDylib: (URL) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var loading = true
    @State private var hits: [AVXScanHit] = []
    @State private var query = ""
    @State private var editHit: AVXScanHit?
    @State private var disasm: [DecodedInsn] = []
    @State private var disasmVA = ""
    @State private var catFilter = "all"
    @State private var showCFGViewer = false
    @State private var showPseudocodeViewer = false
    @State private var showDisassemblerBrowser = false
    @State private var showAnalysisCenter = false
    @State private var cfgFunction: UCFunction?
    @State private var cfgStatus: String?
    @State private var showCFGFind = false
    @State private var cfgFindQuery = ""
    @State private var showFunctionList = false
    @State private var functionListLoadProgress: Double = 0
    @State private var manifestLoadProgress: Double = 0
    /// The CFG floating toolbar starts collapsed to a single button — none of
    /// its actions (Functions included) are reachable until this is tapped.
    @State private var cfgToolbarExpanded = false
    @State private var cfgPicked = false   // true once the user actually chose a function/address — guards the "nothing picked, close" check
    @State private var functionListQuery = ""
    @State private var functionIndex: [(address: UInt64, name: String)] = []
    @State private var functionIndexState: FunctionIndexState = .idle
    @State private var showFunctionInfo = false
    @State private var autoShowInfoOnLoad = false
    @State private var cfgCallers: [(address: UInt64, name: String)] = []
    @State private var cfgCallersState: FunctionIndexState = .idle
    @State private var cfgRefStrings: [String] = []
    @State private var cfgRefSelectors: [String] = []
    @State private var cfgRefClasses: [String] = []
    @State private var symbolTable: [UInt64: String] = [:]
    @State private var importMap: [UInt64: String] = [:]
    @State private var objcClassList: [MachOTools.ObjCClassInfo] = []
    @State private var showObjCBrowser = false
    @State private var showAIHookCatalog = false
    @State private var objcBrowserQuery = ""
    @State private var selectedTweakMethods: Set<UInt64> = []
    @State private var showStringIndex = false
    @State private var stringIndexQuery = ""
    /// "Search / Edit Strings" pulled into the CFG toolbar — same `hits`/
    /// `loading`/`runScan()` the standalone Developer-card tool uses, just
    /// reachable without leaving the viewer. `stringSearchLoaded` guards
    /// against re-running the scan every time the sheet is reopened.
    @State private var showStringSearchTool = false
    @State private var stringSearchLoaded = false
    @State private var stringIndex: [(address: UInt64, name: String, refs: [String])] = []
    @State private var stringIndexState: FunctionIndexState = .idle
    @State private var stringIndexProgress: Double = 0
    @State private var patchPreview: PatchPreview?
    @State private var showCallGraph = false
    @State private var callGraphRoot: CallGraphNode?
    @State private var showGateFinder = false
    @State private var gateFinderState: FunctionIndexState = .idle
    @State private var gateFinderProgress: Double = 0
    @State private var gateCandidates: [GateCandidate] = []
    @State private var batchPatchPreview: BatchPatchPreview?
    @State private var showManifest = false
    @State private var manifestState: FunctionIndexState = .idle
    @State private var infoPlist: [String: Any] = [:]
    @State private var entitlements: [String: Any] = [:]
    enum FunctionIndexState: Equatable { case idle, loading, ready, empty }

    /// What kind of edge a call-graph node was reached by — drives both its
    /// color and whether it can be expanded further. `.direct` is a resolved
    /// `bl` into another real function; `.external` is a real, non-zero branch
    /// target that isn't covered by this binary's own LC_FUNCTION_STARTS
    /// (typically an imported/stub symbol); `.indirect` is a `blr` through a
    /// register, which has no static target at all.
    enum CallGraphEdgeKind { case root, direct, imported, external, indirect }
    enum CallGraphDirection { case callees, callers }

    /// One node in the interactive call graph. A reference type (not a
    /// `@State` value) on purpose: nodes are lazily, asynchronously filled in
    /// as the user expands them, and a class lets each row own its own
    /// loaded/loading flags without the whole tree re-rendering from the root.
    final class CallGraphNode: ObservableObject, Identifiable {
        let id = UUID()
        let address: UInt64
        let name: String
        let kind: CallGraphEdgeKind
        let depth: Int
        @Published var callees: [CallGraphNode] = []
        @Published var callers: [CallGraphNode] = []
        @Published var calleesLoaded = false
        @Published var callersLoaded = false
        @Published var isLoadingCallees = false
        @Published var isLoadingCallers = false
        init(address: UInt64, name: String, kind: CallGraphEdgeKind, depth: Int) {
            self.address = address; self.name = name; self.kind = kind; self.depth = depth
        }
    }

    /// What a NOP/RET patch would actually do, shown before it's queued: the
    /// real original instruction (decoded fresh from the real bytes at that
    /// file offset, not assumed), the real replacement bytes, and the exact
    /// file offset being written. No patch reaches `patches` without passing
    /// through this.
    struct PatchPreview: Identifiable {
        let id = UUID()
        let va: UInt64
        let fileOffset: Int
        let ret: Bool
        let originalBytes: [UInt8]
        let originalText: String
        let newBytes: [UInt8]
        let newText: String
    }

    /// Several `PatchPreview`s reviewed and queued together — e.g. every real
    /// caller of a function, NOP'd in one pass. Still one preview per site
    /// with its own real original/replacement bytes; this is just the
    /// confirm-all wrapper around the same single-patch flow.
    struct BatchPatchPreview: Identifiable {
        let id = UUID()
        let title: String
        let items: [PatchPreview]
    }

    /// A structural, instruction-level pattern found by `buildGateCandidates`:
    /// a value loaded from a real global address (via the same adrp+ldr pair
    /// `references(for:...)` already decodes) immediately tested by a
    /// conditional branch. This is reported as exactly what it is — a shape
    /// in the real decoded instructions — never as a claim about what the
    /// global or branch actually mean. Flagging it as a candidate, not a
    /// verdict, is the whole point: a human still has to look at it.
    struct GateCandidate: Identifiable {
        let id = UUID()
        let functionAddress: UInt64
        let functionName: String
        let loadAddress: UInt64
        let loadText: String
        let branchAddress: UInt64
        let branchText: String
        let globalVA: UInt64
        let globalLabel: String   // a resolved string at that address, or just its hex VA
    }

    private var blue: Color { Theme.accent }

    private var filtered: [AVXScanHit] {
        var out = hits
        if catFilter != "all" { out = out.filter { catOf($0) == catFilter } }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { out = out.filter { $0.string.localizedCaseInsensitiveContains(q) || $0.address.localizedCaseInsensitiveContains(q) } }
        return out
    }
    /// Map raw scanner category → chip bucket.
    private func catOf(_ h: AVXScanHit) -> String {
        switch h.category { case "premium": return "paywall"; default: return h.category }
    }

    var body: some View {
        Group {
            if mode == .cfgViewer {
                // UCDisasmViewController brings its own UINavigationController with a title
                // bar + Done/Share buttons already, so this mode skips the SwiftUI nav chrome
                // entirely instead of stacking a second bar on top of it.
                cfgDirectView
            } else {
                NavigationStack {
                    Group {
                        switch mode {
                        case .strings:        stringsView
                        case .patchFunctions: patchView
                        case .dependencies:   dependenciesView
                        case .disassemble:    disassembleView
                        case .analysis:       BinaryAnalysisView(ipaURL: ipaURL)
                        case .injectData:     injectDataView
                        case .cfgViewer:      EmptyView()   // handled above
                        }
                    }
                    .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
                    .modifier(StringSearchable(mode: mode, text: $query))
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if mode == .cfgViewer {
                // Load the real function table first, then go straight into the
                // CFG for the first function — no "pick a function" screen in the
                // way. Loading the index *before* calling openLocalCFG (instead of
                // racing them, which is what used to send people to a 800+ block
                // "__text CFG" wall) means functionBounds(containing:) has real
                // data to work with immediately, so the very first CFG shown is
                // already bounded to one real function, not the whole section.
                await loadFunctionIndex()
                cfgPicked = true
                await openLocalCFG()
            } else {
                await runScan()
            }
        }
        .sheet(item: $editHit) { hit in
            StringEditSheet(hit: hit, blue: blue) { patch in
                patches.removeAll { $0.fileOffset == patch.fileOffset }
                patches.append(patch)
                editHit = nil
            }
            .presentationDetents([.height(300)])
            .preferredColorScheme(.dark)
        }
        // These four were `.sheet(...)`, which on iOS is a non-fullscreen card:
        // the presenting screen's own nav bar ("Search / Edit Strings", etc.)
        // stayed visible peeking above it, and the sheet's own trailing edge
        // clipped its nav-bar buttons. `.fullScreenCover` covers the whole
        // screen, so there's exactly one nav bar and nothing gets cut off.
        .fullScreenCover(isPresented: $showCFGViewer) {
            if let cfgFunction {
                CFGViewerController(function: cfgFunction)
                    .ignoresSafeArea()
            } else {
                Color.black
            }
        }
        .fullScreenCover(isPresented: $showPseudocodeViewer) {
            if let cfgFunction {
                PseudocodeViewerController(function: cfgFunction)
                    .ignoresSafeArea()
            } else {
                Color.black
            }
        }
        .fullScreenCover(isPresented: $showAnalysisCenter) {
            if let cfgFunction {
                AnalysisCenterController(function: cfgFunction).ignoresSafeArea()
            } else { Color.black }
        }
        .fullScreenCover(isPresented: $showDisassemblerBrowser) {
            if let cfgFunction {
                DisassemblerBrowserController(function: cfgFunction)
                    .ignoresSafeArea()
            } else {
                Color.black
            }
        }
        .sheet(item: $patchPreview) { _ in patchPreviewSheet }
    }

    private var title: String {
        switch mode {
        case .strings: return "Search / Edit Strings"
        case .patchFunctions: return "Patch Functions"
        case .dependencies: return "Mach-O Dependencies"
        case .disassemble: return "Disassemble ARM64"
        case .analysis: return "Real Binary Analysis"
        case .injectData: return "Inject Data"
        case .cfgViewer: return "CFG Viewer"
        }
    }

    // MARK: CFG Viewer (direct — Capstone + UCDisassembler, no extra UI around it)

    private var cfgDirectView: some View {
        Group {
            if let cfgFunction {
                ZStack(alignment: .bottomTrailing) {
                    CFGViewerController(function: cfgFunction).ignoresSafeArea()
                    cfgFloatingToolbar
                }
            } else {
                ZStack(alignment: .topTrailing) {
                    VStack(spacing: 10) {
                        // This only shows while the auto-load is still in flight (or
                        // if it genuinely failed) — it's not asking you to pick
                        // anything. The old copy here ("Pick a function to build its
                        // CFG") was left over from before CFG auto-loaded and made it
                        // look like a function picker even though nothing here opens
                        // one anymore.
                        AirShareWatermark(size: 96)
                        ProgressView(value: functionListLoadProgress).tint(blue).frame(width: 180)
                        Text(cfgStatus?.isEmpty == false ? cfgStatus! : "Loading control flow graph…")
                            .font(.subheadline).foregroundStyle(Theme.text)
                            .multilineTextAlignment(.center).padding(.horizontal, 24)
                        Button("Browse Functions Instead") { showFunctionList = true }
                            .buttonStyle(.bordered).tint(blue).padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)

                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white.opacity(0.75), Color.black.opacity(0.4))
                    }
                    .padding(16)
                }
                .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $showCFGFind) { cfgFindSheet }
        .sheet(isPresented: $showFunctionList) {
            functionListSheet
                .onDisappear { if !cfgPicked { dismiss() } }   // closed without picking anything → nothing to show, close the tool
        }
        .sheet(isPresented: $showFunctionInfo) { functionInfoSheet }
        .sheet(isPresented: $showStringIndex) { stringIndexSheet }
        .sheet(isPresented: $showStringSearchTool) { stringSearchToolSheet }
        .sheet(isPresented: $showCallGraph) { callGraphSheet }
        .sheet(isPresented: $showObjCBrowser) { objcBrowserSheet }
        .sheet(isPresented: $showAIHookCatalog) { AIHookCatalogView() }
        .sheet(isPresented: $showGateFinder) { gateFinderSheet }
        .sheet(item: $batchPatchPreview) { b in batchPatchPreviewSheet(b) }
        .sheet(isPresented: $showManifest) { manifestSheet }
    }

    /// Bottom-floating panel over the CFG graph: switch tools without leaving
    /// the viewer, and jump straight to an address or a resolved call target.
    /// Two slim rows of icon-over-label buttons, each evenly filling its row's
    /// width — not a single crowded icon-only pill — so nothing overlaps or
    /// gets squeezed off the edge on a phone-width screen.
    /// Collapsed to a single round button by default — none of its actions
    /// (Functions included) are reachable until that button is tapped. Once
    /// expanded, every action is a single column of pills stacked on top of
    /// each other running up from the toggle, hugging the right edge.
    private var cfgFloatingToolbar: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if cfgToolbarExpanded {
                VStack(alignment: .trailing, spacing: 8) {
                    Menu {
                        Button { showDisassemblerBrowser = true } label: {
                            Label("Disassembler Browser", systemImage: "list.bullet.rectangle")
                        }
                        Button { showPseudocodeViewer = true } label: {
                            Label("Pseudocode", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                        Button { showAnalysisCenter = true } label: {
                            Label("Analysis Center", systemImage: "square.grid.3x3")
                        }
                    } label: {
                        cfgToolbarPill("square.grid.2x2", "More")
                    }

                    cfgToolbarRow("list.bullet.indent", "Functions") {
                        showFunctionList = true
                        if functionIndexState == .idle { Task { await loadFunctionIndex() } }
                    }
                    cfgToolbarRow("curlybraces", "Classes") {
                        showObjCBrowser = true
                        if functionIndexState == .idle { Task { await loadFunctionIndex() } }
                    }
                    cfgToolbarRow("info.circle", "Info") {
                        showFunctionInfo = true
                        if cfgCallersState == .idle, let f = cfgFunction { Task { await loadCallers(of: f.startAddress) } }
                    }
                    cfgToolbarRow("point.3.connected.trianglepath.dotted", "Call Graph") { openCallGraph() }
                    cfgToolbarRow("magnifyingglass", "Find") { showCFGFind = true }
                    cfgToolbarRow("text.magnifyingglass", "Strings") {
                        showStringIndex = true
                        if stringIndexState == .idle { Task { await buildStringIndex() } }
                    }
                    cfgToolbarRow("pencil.and.magnifyingglass", "Edit Strings") {
                        showStringSearchTool = true
                        if !stringSearchLoaded { Task { await runScan(); stringSearchLoaded = true } }
                    }
                    cfgToolbarRow("flag.badge.ellipsis", "Gates") {
                        showGateFinder = true
                        if gateFinderState == .idle { Task { await buildGateCandidates() } }
                    }
                    cfgToolbarRow("lock.shield", "Manifest") {
                        showManifest = true
                        if manifestState == .idle { Task { await loadManifest() } }
                    }
                    cfgToolbarRow("xmark.circle", "Close Viewer") { dismiss() }
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .opacity
                ))
            }

            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                    cfgToolbarExpanded.toggle()
                }
            } label: {
                // Points left ("pull the menu out") when collapsed, right
                // ("push it back out of the way") once expanded — a tab, not
                // an icon-only button, so it reads as something that slides
                // rather than something that just opens a menu over the graph.
                Image(systemName: cfgToolbarExpanded ? "chevron.right" : "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(blue, in: Circle())
                    .overlay(Circle().stroke(.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            }
        }
        .padding(.trailing, 14)
        .padding(.bottom, 18)
    }

    /// One row in the expanded toolbar column: tapping it runs the action and
    /// collapses the menu back down, same as picking an item from any menu.
    private func cfgToolbarRow(_ systemImage: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                cfgToolbarExpanded = false
            }
        } label: {
            cfgToolbarPill(systemImage, label)
        }
    }

    /// The pill shape shared by every row and the "More" menu's own label —
    /// icon + text side by side, right-aligned so the column reads cleanly
    /// against the right edge of the screen.
    private func cfgToolbarPill(_ systemImage: String, _ label: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 13, weight: .semibold))
            Image(systemName: systemImage).font(.system(size: 15, weight: .semibold)).frame(width: 20)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
    }


    /// Resolved call targets in the current window (real Capstone bl/branch data,
    /// deduped by address) plus a raw "jump to address" fallback.
    private var cfgCallTargets: [(address: UInt64, label: String)] {
        guard let instrs = cfgFunction?.instructions else { return [] }
        var seen = Set<UInt64>()
        var out: [(UInt64, String)] = []
        for insn in instrs where insn.isCall && insn.branchTarget > 0 {
            guard seen.insert(insn.branchTarget).inserted else { continue }
            let label = insn.comment?.isEmpty == false ? insn.comment! : String(format: "0x%llx", insn.branchTarget)
            out.append((insn.branchTarget, label))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// Calls in the current window that resolve to a real imported API — via
    /// `importMap`, the LC_DYSYMTAB indirect-symbol-table lookup built once in
    /// `loadFunctionIndex()` — rather than another function in this binary.
    private var cfgImportedCalls: [(address: UInt64, name: String)] {
        guard let instrs = cfgFunction?.instructions else { return [] }
        var seen = Set<UInt64>()
        var out: [(UInt64, String)] = []
        for insn in instrs where insn.isCall && insn.branchTarget > 0 {
            guard let name = importMap[insn.branchTarget], seen.insert(insn.branchTarget).inserted else { continue }
            out.append((insn.branchTarget, name))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    private var cfgFindResults: [(address: UInt64, label: String)] {
        let q = cfgFindQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return cfgCallTargets }
        return cfgCallTargets.filter {
            $0.label.lowercased().contains(q) || String(format: "%llx", $0.address).contains(q)
        }
    }

    private var cfgFindSheet: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Address or symbol, e.g. 0x1000074a0", text: $cfgFindQuery)
                            .font(.system(size: 13, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Jump") { jumpToCFGFindEntry() }.foregroundStyle(blue)
                    }
                }.listRowBackground(Color(white: 0.08))
                Section {
                    if cfgFindResults.isEmpty {
                        Text("No resolved call targets match yet. Enter a VA above and tap Jump to re-center the CFG there.")
                            .font(.caption).foregroundStyle(Theme.subtle)
                    } else {
                        ForEach(cfgFindResults, id: \.address) { entry in
                            Button {
                                cfgFindQuery = String(format: "0x%llx", entry.address)
                                jumpToCFGFindEntry()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.label).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                                        Text(String(format: "0x%llx", entry.address)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.subtle)
                                    }
                                    Spacer()
                                    Image(systemName: "arrow.forward.circle").foregroundStyle(blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Call targets in this window (\(cfgCallTargets.count))")
                }.listRowBackground(Color(white: 0.08))
            }
            .scrollContentBackground(.hidden).background(Color.black)
            .navigationTitle("Find").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { showCFGFind = false } } }
        }
        .preferredColorScheme(.dark)
    }

    private func jumpToCFGFindEntry() {
        let raw = cfgFindQuery.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "0x", with: "")
        guard !raw.isEmpty, UInt64(raw, radix: 16) != nil else { return }
        disasmVA = "0x\(raw)"
        cfgPicked = true
        autoShowInfoOnLoad = true
        cfgCallers = []; cfgCallersState = .idle; cfgRefStrings = []; cfgRefSelectors = []; cfgRefClasses = []
        showCFGFind = false
        showFunctionList = false
        cfgFunction = nil
        Task { await openLocalCFG() }
    }

    // MARK: Function list (LC_FUNCTION_STARTS + LC_SYMTAB — every real function entry in the binary)

    /// Builds the index once per sheet session. LC_FUNCTION_STARTS gives the real
    /// address of every function the linker recorded (not a prologue guess);
    /// LC_SYMTAB gives real names wherever the binary wasn't stripped of them.
    private func loadFunctionIndex() async {
        functionIndexState = .loading
        functionListLoadProgress = 0.1
        guard let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil) else {
            functionIndexState = .empty
            return
        }
        functionListLoadProgress = 0.35
        let starts = MachOTools.functionStarts(in: ctx.thin).sorted()
        guard !starts.isEmpty else {
            functionIndexState = .empty
            return
        }
        functionListLoadProgress = 0.55
        let symbols = MachOTools.symbolMap(in: ctx.thin)
        symbolTable = symbols   // cached for class-name resolution (see `references(for:...)`) — not just function names
        functionListLoadProgress = 0.7
        importMap = MachOTools.importStubMap(in: ctx.thin)   // real stub/symbol-pointer → imported-API-name map (see `calleesOf`)
        functionListLoadProgress = 0.85
        objcClassList = MachOTools.objcClasses(in: ctx.thin, segments: ctx.segments, sections: ctx.sections)   // real __objc_classlist walk — works even when LC_SYMTAB is stripped
        functionIndex = starts.map { addr in
            (address: addr, name: Self.displayName(forSymbol: symbols[addr], fallback: String(format: "sub_%llx", addr)))
        }
        functionListLoadProgress = 1.0
        functionIndexState = .ready
    }

    /// A real LC_SYMTAB symbol, labeled honestly rather than left looking like
    /// readable text when it isn't. Swift's name mangling produces names like
    /// `$s4Core...` that are technically real symbols but unreadable without a
    /// full demangler (which needs the Swift runtime/toolchain — not available
    /// here). Rather than either showing raw mangled noise with no context or
    /// pretending to demangle it, this just flags it plainly as Swift so
    /// nobody mistakes `$s4Core...` for a meaningless/corrupt name.
    nonisolated private static func displayName(forSymbol symbol: String?, fallback: String) -> String {
        guard let symbol, !symbol.isEmpty else { return fallback }
        let swiftPrefixes = ["_$s", "$s", "_$S", "$S", "_T0", "$T0"]
        if swiftPrefixes.contains(where: symbol.hasPrefix) {
            return "Swift: \(symbol)"
        }
        return symbol
    }

    /// Which real function (per LC_FUNCTION_STARTS) an address falls inside, and
    /// where that function ends (the next function's start). Binary search over
    /// `functionIndex`, which `loadFunctionIndex` builds in ascending order.
    private func functionBounds(containing va: UInt64) -> (start: UInt64, end: UInt64, name: String)? {
        guard !functionIndex.isEmpty else { return nil }
        var lo = 0, hi = functionIndex.count - 1, idx = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if functionIndex[mid].address <= va { idx = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        guard idx >= 0 else { return nil }
        let start = functionIndex[idx].address
        let end = idx + 1 < functionIndex.count ? functionIndex[idx + 1].address : start + 64 * 1024
        guard va < end else { return nil }
        return (start, end, functionIndex[idx].name)
    }

    /// Real callers of `target` — found by scanning __TEXT,__text for ARM64 `BL`
    /// instructions (opcode bits [31:26] == 0b100101) and decoding each one's
    /// signed, word-scaled 26-bit branch immediate directly from the raw machine
    /// code. Not inferred from any single function's Capstone window — every hit
    /// here is an actual `bl` encoded in the binary that resolves to this address.
    /// Every real `bl` instruction's own address in __TEXT,__text whose
    /// signed, word-scaled 26-bit branch immediate resolves to `target` —
    /// decoded directly from the raw machine code (opcode bits [31:26] ==
    /// 0b100101). These are exact call-SITE addresses, not the functions
    /// they sit inside — needed as-is for batch-patching every real caller,
    /// and aggregated by containing function for the Function Info /
    /// Call Graph "called from" views (see `scanCallers`).
    private func scanCallerSites(of target: UInt64) async -> [UInt64] {
        guard let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil),
              let text = MachOTools.textSection(ctx.sections, in: ctx.thin) else { return [] }
        let data = text.data
        let base = text.vmaddr
        var hitAddrs: [UInt64] = []
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let count = raw.count / 4
            for i in 0..<count {
                let word = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                guard (word & 0xFC00_0000) == 0x9400_0000 else { continue }   // BL <imm26>
                let raw26 = word & 0x03FF_FFFF
                let signBit: UInt32 = 0x0200_0000
                let imm26 = Int32(bitPattern: (raw26 ^ signBit) &- signBit)   // sign-extend the 26-bit field
                let instrAddr = base + UInt64(i * 4)
                let target64 = Int64(bitPattern: instrAddr) + Int64(imm26) * 4
                guard target64 >= 0, UInt64(target64) == target else { continue }
                hitAddrs.append(instrAddr)
            }
        }
        return hitAddrs.sorted()
    }

    /// Real callers of `target`, grouped by the real function each call site
    /// sits inside (see `scanCallerSites` for the exact per-site addresses).
    /// Pulled out as a pure function (no state writes) so both the Function
    /// Info screen and the per-node Call Graph lookups can share it.
    private func scanCallers(of target: UInt64) async -> [(address: UInt64, name: String, count: Int)] {
        let hitAddrs = await scanCallerSites(of: target)
        var byFunction: [UInt64: (name: String, count: Int)] = [:]
        for addr in hitAddrs {
            guard let b = functionBounds(containing: addr) else { continue }
            let prior = byFunction[b.start] ?? (b.name, 0)
            byFunction[b.start] = (prior.name, prior.count + 1)
        }
        return byFunction.map { start, v in (address: start, name: v.name, count: v.count) }.sorted { $0.address < $1.address }
    }

    private func loadCallers(of target: UInt64) async {
        cfgCallersState = .loading
        let results = await scanCallers(of: target)
        cfgCallers = results.map { (address: $0.address, name: $0.count > 1 ? "\($0.name) (\($0.count)×)" : $0.name) }
        cfgCallersState = cfgCallers.isEmpty ? .empty : .ready
    }

    /// Real direct callees of the function starting at (or containing) `addr` —
    /// found the same way the CFG viewer decodes any function: a bounded
    /// Capstone decode of that function's own real LC_FUNCTION_STARTS window.
    /// Each call instruction is classified by what its target actually is:
    /// `.direct` when the branch target lands exactly on another known
    /// function's real start address; `.external` when it's a real, non-zero
    /// branch target that doesn't match any LC_FUNCTION_STARTS entry (typically
    /// a stub/trampoline for a symbol imported from outside this binary); and
    /// `.indirect` when there's no static target at all (`blr` through a
    /// register) — nothing about that target is guessed, it's just reported as
    /// unresolvable, which is the honest answer.
    private func calleesOf(_ addr: UInt64) async -> [(address: UInt64, name: String, kind: CallGraphEdgeKind)] {
        guard let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil),
              let text = MachOTools.textSection(ctx.sections, in: ctx.thin),
              let bounds = functionBounds(containing: addr) else { return [] }
        let delta = Int(bounds.start - text.vmaddr)
        guard delta >= 0, delta < text.data.count else { return [] }
        let cap = min(Int(bounds.end - bounds.start), max(0, text.data.count - delta))
        guard cap >= 4 else { return [] }
        let window = text.data.subdata(in: delta ..< delta + cap)
        guard let result = UCDisassembler.sharedInstance().disassembleData(window, baseAddress: bounds.start) else { return [] }
        var seenDirect = Set<UInt64>()
        var out: [(UInt64, String, CallGraphEdgeKind)] = []
        for insn in result.instructions where insn.isCall {
            if insn.branchTarget == 0 {
                out.append((insn.address, "indirect call (\(insn.mnemonic)) @ 0x\(String(insn.address, radix: 16))", .indirect))
                continue
            }
            guard seenDirect.insert(insn.branchTarget).inserted else { continue }
            if let b = functionBounds(containing: insn.branchTarget), b.start == insn.branchTarget {
                out.append((insn.branchTarget, b.name, .direct))
            } else if let imported = importMap[insn.branchTarget] {
                // A real imported API, resolved via LC_DYSYMTAB's indirect
                // symbol table (see `MachOTools.importStubMap`) — not a guess,
                // the same lookup `otool -I` does.
                out.append((insn.branchTarget, imported, .imported))
            } else {
                out.append((insn.branchTarget, String(format: "sub_%llx (unresolved target)", insn.branchTarget), .external))
            }
        }
        return out
    }

    // MARK: Interactive call graph
    //
    // Reuses `scanCallers`/`calleesOf` — both already real, already-built data
    // sources — to let the user expand outward from any function, in either
    // direction, up to 3 levels deep. Tapping a resolved node's row jumps the
    // CFG viewer straight to it; the expand chevron (separate gesture target)
    // lazily loads that node's own callers/callees on first open, so nothing
    // beyond the root is scanned until the user actually asks to see it.

    private func loadCallees(for node: CallGraphNode) async {
        guard !node.calleesLoaded, node.depth < 3, node.kind == .direct || node.kind == .root else { return }
        node.isLoadingCallees = true
        let items = await calleesOf(node.address)
        node.callees = items.map { CallGraphNode(address: $0.address, name: $0.name, kind: $0.kind, depth: node.depth + 1) }
        node.calleesLoaded = true
        node.isLoadingCallees = false
    }

    private func loadCallers(for node: CallGraphNode) async {
        guard !node.callersLoaded, node.depth < 3, node.kind == .direct || node.kind == .root else { return }
        node.isLoadingCallers = true
        let items = await scanCallers(of: node.address)
        node.callers = items.map {
            CallGraphNode(address: $0.address, name: $0.count > 1 ? "\($0.name) (\($0.count)×)" : $0.name, kind: .direct, depth: node.depth + 1)
        }
        node.callersLoaded = true
        node.isLoadingCallers = false
    }

    private func openCallGraph() {
        guard let fn = cfgFunction else { return }
        let node = CallGraphNode(address: fn.startAddress, name: fn.name, kind: .root, depth: 0)
        callGraphRoot = node
        showCallGraph = true
        Task {
            await loadCallees(for: node)
            await loadCallers(for: node)
        }
    }

    /// Jumps the CFG viewer to a call-graph node the user tapped. Only
    /// `.direct`/`.root` nodes carry a real function address to jump to —
    /// `.external`/`.indirect` nodes are reported honestly as having nothing
    /// to open rather than guessing a destination.
    private func jumpCallGraph(to addr: UInt64, kind: CallGraphEdgeKind) {
        guard kind == .direct || kind == .root else {
            switch kind {
            case .indirect:
                cfgStatus = "This is an indirect call through a register — there's no static target to open."
            case .imported:
                cfgStatus = "This resolves to a real imported API, but its implementation lives outside this binary — there's no local function body to open."
            default:
                cfgStatus = "This branch target isn't covered by this binary's LC_FUNCTION_STARTS, so there's no known function to open."
            }
            return
        }
        disasmVA = String(format: "0x%llx", addr)
        cfgPicked = true
        autoShowInfoOnLoad = false
        showCallGraph = false
        cfgCallers = []; cfgCallersState = .idle; cfgRefStrings = []; cfgRefSelectors = []; cfgRefClasses = []
        Task { await openLocalCFG() }
    }

    // MARK: Static reference resolution (strings + ObjC selectors)
    //
    // The disassembler's OWN `findStringReference:`/`findObjcClassRef:` only
    // resolve when the target binary is actually mapped live into THIS app's
    // process (they call `vm_read_overwrite(mach_task_self(), …)`), which is
    // never true for a foreign decrypted IPA just sitting on disk — so reading
    // `insn.comment` for those here would silently show nothing, every time.
    // This re-implements the same adrp+ldr/add address-computation pattern —
    // faithfully, same instruction shapes, same lookahead — but reads the
    // decoded operands Capstone already gave us (no live memory needed) and
    // resolves the final address from the real on-disk bytes via MachOTools.

    /// Every `adrp` in `instrs` paired with the `ldr`/`add` that completes its
    /// address computation, resolved to the real target address each pair
    /// computes. Pure instruction-stream analysis — no I/O.
    nonisolated private static func adrpTargets(in instrs: [UCDisasmInstruction]) -> [UInt64] {
        var out: [UInt64] = []
        for i in 0..<instrs.count {
            let insn = instrs[i]
            guard insn.mnemonic.lowercased() == "adrp",
                  insn.operandList.count >= 2,
                  insn.operandList[0].type == .register,
                  insn.operandList[1].type == .immediate else { continue }
            let destReg = insn.operandList[0].registerName
            let pageBase = (insn.address & ~UInt64(0xFFF)) &+ insn.operandList[1].immediateValue
            let upper = min(i + 11, instrs.count)
            for j in (i + 1)..<upper {
                let next = instrs[j]
                let m = next.mnemonic.lowercased()
                if m == "ldr", next.operandList.count >= 2,
                   next.operandList[1].type == .memory,
                   next.operandList[1].memoryBaseReg == destReg {
                    out.append(pageBase &+ UInt64(bitPattern: next.operandList[1].memoryOffset))
                    break
                }
                if m == "add", next.operandList.count >= 3,
                   next.operandList[1].type == .register, next.operandList[1].registerName == destReg,
                   next.operandList[2].type == .immediate {
                    out.append(pageBase &+ next.operandList[2].immediateValue)
                    break
                }
            }
        }
        return out
    }

    /// Every `adrp`+`ldr` pair that loads an actual VALUE from a global
    /// address into a register (as opposed to `adrp`+`add`, which just
    /// computes an address) — returning the instruction index of that load,
    /// which register now holds the loaded value, and the real global
    /// address it was loaded from. Pure instruction-stream analysis, same
    /// lookahead window as `adrpTargets`; used by `buildGateCandidates` to
    /// find a load immediately followed by a test of that same register.
    nonisolated private static func globalLoadTargets(in instrs: [UCDisasmInstruction]) -> [(loadIndex: Int, reg: String, globalVA: UInt64)] {
        var out: [(Int, String, UInt64)] = []
        for i in 0..<instrs.count {
            let insn = instrs[i]
            guard insn.mnemonic.lowercased() == "adrp",
                  insn.operandList.count >= 2,
                  insn.operandList[0].type == .register,
                  insn.operandList[1].type == .immediate else { continue }
            let destReg = insn.operandList[0].registerName
            let pageBase = (insn.address & ~UInt64(0xFFF)) &+ insn.operandList[1].immediateValue
            let upper = min(i + 11, instrs.count)
            for j in (i + 1)..<upper {
                let next = instrs[j]
                guard next.mnemonic.lowercased() == "ldr",
                      next.operandList.count >= 2,
                      next.operandList[0].type == .register,
                      next.operandList[1].type == .memory,
                      next.operandList[1].memoryBaseReg == destReg else { continue }
                let globalVA = pageBase &+ UInt64(bitPattern: next.operandList[1].memoryOffset)
                out.append((j, next.operandList[0].registerName, globalVA))
                break
            }
        }
        return out
    }

    /// Resolves a computed address to real text: tries it directly as a
    /// printable C string first (the common case for literal strings), then
    /// falls back to one pointer dereference through the file (the common
    /// case for a GOT-style slot like an ObjC selref) and tries that address
    /// too. Either path only returns something when real, validated bytes are
    /// actually there — no ObjC runtime struct layout is assumed or guessed.
    private func resolveReference(at va: UInt64, thin: Data, segments: [MachOTools.Segment]) -> String? {
        if let s = MachOTools.cString(in: thin, segments: segments, at: va) { return s }
        if let ptr = MachOTools.pointer(in: thin, segments: segments, at: va),
           let s = MachOTools.cString(in: thin, segments: segments, at: ptr) { return s }
        return nil
    }

    /// Resolves an `__objc_classrefs` slot to the real class name it points
    /// to, with zero struct-layout guessing: a classref slot holds a pointer
    /// to a `class_t` struct, and for any class actually DEFINED in this
    /// binary, LC_SYMTAB already exports a `_OBJC_CLASS_$_<Name>` (or
    /// `_OBJC_METACLASS_$_<Name>`) symbol whose address is exactly that same
    /// `class_t` pointer — so one pointer dereference plus a lookup in the
    /// already-built `symbolTable` gives the real name, straight from the
    /// linker's own symbol table. Classes imported from elsewhere (not
    /// defined here) have no such local symbol and are left unresolved
    /// rather than guessed at.
    private func resolveClassRef(at va: UInt64, thin: Data, segments: [MachOTools.Segment]) -> String? {
        guard let classT = MachOTools.pointer(in: thin, segments: segments, at: va),
              let sym = symbolTable[classT] else { return nil }
        if sym.hasPrefix("_OBJC_METACLASS_$_") { return sym.replacingOccurrences(of: "_OBJC_METACLASS_$_", with: "") + " (metaclass)" }
        if sym.hasPrefix("_OBJC_CLASS_$_") { return sym.replacingOccurrences(of: "_OBJC_CLASS_$_", with: "") }
        return nil
    }

    /// Splits resolved references into plain strings, ObjC selectors, and ObjC
    /// class names, using the real section the computed address falls in:
    /// `__objc_selrefs` entries are ABI-guaranteed to point straight at a
    /// selector name, so a resolved hit there is labeled a selector;
    /// `__objc_classrefs` entries are resolved via `resolveClassRef`; anything
    /// else that resolves to printable text is a string.
    private func references(for instrs: [UCDisasmInstruction], thin: Data, sections: [MachOTools.Section], segments: [MachOTools.Segment]) -> (strings: [String], selectors: [String], classes: [String]) {
        var strings: [String] = [], selectors: [String] = [], classes: [String] = []
        var seenS = Set<String>(), seenSel = Set<String>(), seenC = Set<String>()
        for va in Self.adrpTargets(in: instrs) {
            let inSelRefs = sections.contains { $0.name == "__objc_selrefs" && va >= $0.addr && va < $0.addr + $0.size }
            let inClassRefs = sections.contains { $0.name == "__objc_classrefs" && va >= $0.addr && va < $0.addr + $0.size }
            if inClassRefs {
                if let cls = resolveClassRef(at: va, thin: thin, segments: segments), seenC.insert(cls).inserted {
                    classes.append(cls)
                }
                continue
            }
            guard let resolved = resolveReference(at: va, thin: thin, segments: segments) else { continue }
            if inSelRefs {
                if seenSel.insert(resolved).inserted { selectors.append(resolved) }
            } else {
                if seenS.insert(resolved).inserted { strings.append(resolved) }
            }
            if strings.count + selectors.count + classes.count >= 24 { break }
        }
        return (strings, selectors, classes)
    }

    // MARK: String/selector search across every real function

    /// Decodes every function in `functionIndex` (bounded to its own real size,
    /// same as the CFG viewer) just far enough to pull its real references —
    /// building a searchable "which function touches X" index. Real work, not
    /// a shortcut: every entry here comes from an actual Capstone decode of
    /// that function's own bytes, same as opening it in the CFG viewer would.
    private func buildStringIndex() async {
        guard stringIndexState != .loading else { return }
        stringIndexState = .loading
        stringIndexProgress = 0
        if functionIndex.isEmpty { await loadFunctionIndex() }
        guard let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil),
              let text = MachOTools.textSection(ctx.sections, in: ctx.thin),
              !functionIndex.isEmpty else {
            stringIndexState = .empty
            return
        }
        var out: [(address: UInt64, name: String, refs: [String])] = []
        let total = functionIndex.count
        for (i, fn) in functionIndex.enumerated() {
            guard fn.address >= text.vmaddr, fn.address < text.vmaddr + UInt64(text.data.count) else { continue }
            let end = i + 1 < functionIndex.count ? functionIndex[i + 1].address : fn.address + 4096
            let delta = Int(fn.address - text.vmaddr)
            let cap = min(Int(end - fn.address), max(0, text.data.count - delta))
            if cap >= 4 {
                let window = text.data.subdata(in: delta ..< delta + cap)
                if let result = UCDisassembler.sharedInstance().disassembleData(window, baseAddress: fn.address) {
                    let refs = references(for: result.instructions, thin: ctx.thin, sections: ctx.sections, segments: ctx.segments)
                    let all = refs.strings + refs.selectors.map { "@selector(\($0))" } + refs.classes.map { "class \($0)" }
                    if !all.isEmpty { out.append((fn.address, fn.name, all)) }
                }
            }
            if i % 20 == 0 {
                stringIndexProgress = Double(i) / Double(max(total, 1))
                await Task.yield()
            }
        }
        stringIndex = out
        stringIndexProgress = 1
        stringIndexState = stringIndex.isEmpty ? .empty : .ready
    }

    // MARK: Candidate gate-check finder
    //
    // Scans every real function for one specific, mechanical instruction
    // shape: a value loaded from a global address, tested by a conditional
    // branch within a few instructions. That shape is common for feature
    // flags and premium/paywall checks, but it's also just... an if
    // statement reading a global — this reports the structural match only,
    // never a claim about what the global or the branch mean. It's a list
    // of places to go look, not a verdict.

    /// Looks for a conditional test of the exact register a global load just
    /// filled, within a short window after the load — either a direct
    /// `cbz`/`cbnz`/`tbz`/`tbnz` on that register, or a `cmp`/`tst` on it
    /// immediately followed by a conditional branch reading those flags.
    private func gateCandidatesInFunction(instrs: [UCDisasmInstruction], functionAddress: UInt64, functionName: String, thin: Data, segments: [MachOTools.Segment]) -> [GateCandidate] {
        var out: [GateCandidate] = []
        for (loadIndex, reg, globalVA) in Self.globalLoadTargets(in: instrs) {
            let loadInsn = instrs[loadIndex]
            let upper = min(loadIndex + 6, instrs.count)
            var matched = false
            for k in (loadIndex + 1)..<upper where !matched {
                let insn = instrs[k]
                let m = insn.mnemonic.lowercased()
                let testsReg = insn.operandList.first?.type == .register && insn.operandList.first?.registerName == reg
                if testsReg, m == "cbz" || m == "cbnz" || m == "tbz" || m == "tbnz" {
                    out.append(makeGateCandidate(functionAddress: functionAddress, functionName: functionName, load: loadInsn, branch: insn, globalVA: globalVA, thin: thin, segments: segments))
                    matched = true
                    break
                }
                if testsReg, m == "cmp" || m == "tst" {
                    let branchUpper = min(k + 3, instrs.count)
                    for k2 in (k + 1)..<branchUpper where instrs[k2].isConditionalBranch {
                        out.append(makeGateCandidate(functionAddress: functionAddress, functionName: functionName, load: loadInsn, branch: instrs[k2], globalVA: globalVA, thin: thin, segments: segments))
                        matched = true
                        break
                    }
                    break   // flags consumed by the first branch after the compare either way
                }
                // the loaded value stopped being live once something else wrote to the same register
                if testsReg { break }
            }
        }
        return out
    }

    private func makeGateCandidate(functionAddress: UInt64, functionName: String, load: UCDisasmInstruction, branch: UCDisasmInstruction, globalVA: UInt64, thin: Data, segments: [MachOTools.Segment]) -> GateCandidate {
        let label = resolveReference(at: globalVA, thin: thin, segments: segments).map { "\"\($0)\"" } ?? String(format: "0x%llx", globalVA)
        return GateCandidate(functionAddress: functionAddress, functionName: functionName, loadAddress: load.address, loadText: load.fullText, branchAddress: branch.address, branchText: branch.fullText, globalVA: globalVA, globalLabel: label)
    }

    private func buildGateCandidates() async {
        guard gateFinderState != .loading else { return }
        gateFinderState = .loading
        gateFinderProgress = 0
        if functionIndex.isEmpty { await loadFunctionIndex() }
        guard let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil),
              let text = MachOTools.textSection(ctx.sections, in: ctx.thin),
              !functionIndex.isEmpty else {
            gateFinderState = .empty
            return
        }
        var out: [GateCandidate] = []
        let total = functionIndex.count
        for (i, fn) in functionIndex.enumerated() {
            guard fn.address >= text.vmaddr, fn.address < text.vmaddr + UInt64(text.data.count) else { continue }
            let end = i + 1 < functionIndex.count ? functionIndex[i + 1].address : fn.address + 4096
            let delta = Int(fn.address - text.vmaddr)
            let cap = min(Int(end - fn.address), max(0, text.data.count - delta))
            if cap >= 4 {
                let window = text.data.subdata(in: delta ..< delta + cap)
                if let result = UCDisassembler.sharedInstance().disassembleData(window, baseAddress: fn.address) {
                    out.append(contentsOf: gateCandidatesInFunction(instrs: result.instructions, functionAddress: fn.address, functionName: fn.name, thin: ctx.thin, segments: ctx.segments))
                }
            }
            if i % 20 == 0 {
                gateFinderProgress = Double(i) / Double(max(total, 1))
                await Task.yield()
            }
        }
        gateCandidates = out
        gateFinderProgress = 1
        gateFinderState = gateCandidates.isEmpty ? .empty : .ready
    }

    private var stringIndexResults: [(address: UInt64, name: String, refs: [String])] {
        let q = stringIndexQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return stringIndex }
        return stringIndex.compactMap { entry in
            let matched = entry.refs.filter { $0.lowercased().contains(q) }
            if !matched.isEmpty { return (entry.address, entry.name, matched) }
            if entry.name.lowercased().contains(q) { return entry }
            return nil
        }
    }

    private var stringIndexSheet: some View {
        NavigationStack {
            Group {
                switch stringIndexState {
                case .idle, .loading:
                    VStack(spacing: 18) {
                        AirShareWatermark(size: 96)
                        VStack(spacing: 10) {
                            ProgressView(value: stringIndexProgress).tint(blue).frame(width: 180)
                            Text("Decoding every function for real string/selector refs… \(Int(stringIndexProgress * 100))%")
                                .font(.caption).foregroundStyle(Theme.subtle)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    VStack(spacing: 8) {
                        Image(systemName: "text.magnifyingglass").font(.largeTitle).foregroundStyle(Theme.subtle)
                        Text("No resolvable string or selector references found.").font(.subheadline).foregroundStyle(Theme.text)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    List {
                        Section {
                            ForEach(stringIndexResults, id: \.address) { entry in
                                HStack {
                                    Button {
                                        disasmVA = String(format: "0x%llx", entry.address)
                                        cfgPicked = true
                                        autoShowInfoOnLoad = true
                                        cfgCallers = []; cfgCallersState = .idle; cfgRefStrings = []; cfgRefSelectors = []; cfgRefClasses = []
                                        showStringIndex = false
                                        Task { await openLocalCFG() }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(entry.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                                            Text(entry.refs.prefix(3).map { "\"\($0)\"" }.joined(separator: "  "))
                                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.subtle).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    // Jump straight into the Call Graph centered on this function —
                                    // same real caller/callee scan Call Graph always uses, just
                                    // skipping the extra "open CFG, then open Call Graph" hop.
                                    Button {
                                        disasmVA = String(format: "0x%llx", entry.address)
                                        cfgPicked = true
                                        autoShowInfoOnLoad = false
                                        cfgCallers = []; cfgCallersState = .idle; cfgRefStrings = []; cfgRefSelectors = []; cfgRefClasses = []
                                        showStringIndex = false
                                        Task {
                                            await openLocalCFG()
                                            openCallGraph()
                                        }
                                    } label: {
                                        Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(blue)
                                    }.buttonStyle(.plain)
                                }
                            }
                        } header: {
                            Text("\(stringIndexResults.count) of \(stringIndex.count) functions with real references")
                        } footer: {
                            Text("Tap a row to open its CFG; tap the graph icon to jump straight into the Call Graph for that function instead.")
                        }.listRowBackground(Color(white: 0.08))
                    }
                    .scrollContentBackground(.hidden).background(Color.black)
                    .searchable(text: $stringIndexQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search strings or selectors")
                }
            }
            .background(Color.black)
            .navigationTitle("String Search").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { showStringIndex = false } } }
        }
        .preferredColorScheme(.dark)
    }

    /// The full editable-strings tool (category chips, search, tap-to-edit —
    /// the same `stringsView` the standalone "Search / Edit Strings"
    /// Developer-card entry uses) surfaced from inside the CFG toolbar, so
    /// it's reachable without closing the viewer first.
    private var stringSearchToolSheet: some View {
        NavigationStack {
            Group {
                if loading {
                    VStack(spacing: 18) {
                        AirShareWatermark(size: 96)
                        VStack(spacing: 10) {
                            ProgressView(value: 0.5).tint(blue).frame(width: 180)
                            Text("Scanning binary for editable strings…").font(.caption).foregroundStyle(Theme.subtle)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    stringsView
                }
            }
            .background(Color.black)
            .navigationTitle("Search / Edit Strings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { showStringSearchTool = false } } }
            .modifier(StringSearchable(mode: .strings, text: $query))
        }
        .preferredColorScheme(.dark)
    }

    private var gateFinderSheet: some View {
        NavigationStack {
            Group {
                switch gateFinderState {
                case .idle, .loading:
                    VStack(spacing: 18) {
                        AirShareWatermark(size: 96)
                        VStack(spacing: 10) {
                            ProgressView(value: gateFinderProgress).tint(blue).frame(width: 180)
                            Text("Scanning every function for load+test patterns… \(Int(gateFinderProgress * 100))%")
                                .font(.caption).foregroundStyle(Theme.subtle)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    VStack(spacing: 8) {
                        Image(systemName: "flag.slash").font(.largeTitle).foregroundStyle(Theme.subtle)
                        Text("No global-load-then-branch patterns found.").font(.subheadline).foregroundStyle(Theme.text)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    List {
                        Section {
                            ForEach(gateCandidates) { c in
                                Button {
                                    disasmVA = String(format: "0x%llx", c.functionAddress)
                                    cfgPicked = true
                                    autoShowInfoOnLoad = true
                                    cfgCallers = []; cfgCallersState = .idle; cfgRefStrings = []; cfgRefSelectors = []; cfgRefClasses = []
                                    showGateFinder = false
                                    Task { await openLocalCFG() }
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(c.functionName).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                                            Spacer()
                                            Image(systemName: "arrow.forward.circle").foregroundStyle(blue)
                                        }
                                        Text("load: \(c.loadText)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.subtle).lineLimit(1)
                                        Text("test: \(c.branchText)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.subtle).lineLimit(1)
                                        Text("global: \(c.globalLabel)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.orange).lineLimit(1)
                                    }
                                }
                            }
                        } header: {
                            Text("\(gateCandidates.count) candidates")
                        } footer: {
                            Text("Heuristic, not a verdict: every row is a real load from a global address immediately tested by a real conditional branch, decoded straight from Capstone. It does not know — and isn't claiming — what that global or branch actually controls. Review the real instructions shown before touching anything.")
                        }.listRowBackground(Color(white: 0.08))
                    }
                    .scrollContentBackground(.hidden).background(Color.black)
                }
            }
            .background(Color.black)
            .navigationTitle("Candidate Gate Checks").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { showGateFinder = false } } }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Info.plist & entitlements, with a real literal cross-reference
    //
    // Entitlements come straight from this binary's own LC_CODE_SIGNATURE
    // (see `MachOTools.entitlementsPlist`) — present on any signed IPA, not
    // just ones that still carry embedded.mobileprovision. Info.plist comes
    // from the real file inside Payload/*.app. There is no attempt here to
    // claim "this entitlement enables that API" — Apple doesn't publish a
    // machine-readable version of that mapping, and guessing one would be
    // exactly the kind of fake output this tool avoids. What IS real and
    // checkable: whether a plist/entitlement value also appears, verbatim,
    // as a string this binary's own code references — a literal match
    // against the already-built String Search index, nothing inferred.

    private func loadManifest() async {
        manifestState = .loading
        manifestLoadProgress = 0.12
        guard let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil) else {
            manifestState = .empty
            return
        }
        manifestLoadProgress = 0.55
        entitlements = MachOTools.entitlementsPlist(in: ctx.thin) ?? [:]
        if let plistData = await LocalBinaryScanner.bundleFile(named: "Info.plist", ipaURL: ipaURL),
           let plist = (try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)) as? [String: Any] {
            infoPlist = plist
        } else {
            infoPlist = [:]
        }
        manifestLoadProgress = 1.0
        manifestState = (infoPlist.isEmpty && entitlements.isEmpty) ? .empty : .ready
    }

    /// Flattens a plist dict/array into (key, value) rows for display —
    /// only leaf values are shown as their own row, nested dicts recurse
    /// with a dotted key path.
    private func flattenedManifestPairs(_ dict: [String: Any], prefix: String = "") -> [(key: String, value: String)] {
        var out: [(String, String)] = []
        for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
            let fullKey = prefix.isEmpty ? k : "\(prefix).\(k)"
            if let sub = v as? [String: Any] {
                out.append(contentsOf: flattenedManifestPairs(sub, prefix: fullKey))
            } else if let arr = v as? [Any] {
                for (i, item) in arr.enumerated() {
                    out.append(("\(fullKey)[\(i)]", (item as? String) ?? "\(item)"))
                }
            } else {
                out.append((fullKey, "\(v)"))
            }
        }
        return out
    }

    /// Real, literal string-match cross-reference: does this plist/entitlement
    /// value also show up, byte-for-byte, in a real function's resolved
    /// string/selector/class references (the index String Search already
    /// built)? No semantic mapping, no guessing — an exact match or nothing.
    private func manifestCrossRefs(for value: String) -> [(address: UInt64, name: String)] {
        guard value.count >= 3 else { return [] }
        return stringIndex.filter { $0.refs.contains(value) }.map { ($0.address, $0.name) }
    }

    private func manifestRow(_ pair: (key: String, value: String)) -> some View {
        let refs = manifestCrossRefs(for: pair.value)
        return VStack(alignment: .leading, spacing: 3) {
            Text(pair.key).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
            Text(pair.value).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.subtle).lineLimit(2)
            if !refs.isEmpty {
                Text("also referenced verbatim in: \(refs.map { $0.name }.joined(separator: ", "))")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }

    private var manifestSheet: some View {
        NavigationStack {
            Group {
                switch manifestState {
                case .idle, .loading:
                    VStack(spacing: 18) {
                        AirShareWatermark(size: 96)
                        VStack(spacing: 10) {
                            ProgressView(value: manifestLoadProgress).tint(blue).frame(width: 180)
                            Text("Reading Info.plist + LC_CODE_SIGNATURE entitlements…").font(.caption).foregroundStyle(Theme.subtle)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    VStack(spacing: 8) {
                        Image(systemName: "lock.slash").font(.largeTitle).foregroundStyle(Theme.subtle)
                        Text("No Info.plist or entitlements found.").font(.subheadline).foregroundStyle(Theme.text)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    List {
                        if stringIndexState != .ready {
                            Section {
                                Button {
                                    Task { await buildStringIndex() }
                                } label: {
                                    Label(
                                        stringIndexState == .loading ? "Building cross-reference index… \(Int(stringIndexProgress * 100))%" : "Build cross-reference index",
                                        systemImage: "arrow.triangle.2.circlepath"
                                    )
                                }.disabled(stringIndexState == .loading)
                            } footer: {
                                Text("Builds the same real per-function string index String Search uses, so rows below can show which function also references each value verbatim.")
                            }.listRowBackground(Color(white: 0.08))
                        }

                        if entitlements.isEmpty {
                            Section {
                                Text("No entitlements blob in this binary's code signature.").font(.caption).foregroundStyle(Theme.subtle)
                            }.listRowBackground(Color(white: 0.08))
                        } else {
                            Section {
                                ForEach(flattenedManifestPairs(entitlements), id: \.key) { pair in manifestRow(pair) }
                            } header: {
                                Text("Entitlements (\(entitlements.count))")
                            } footer: {
                                Text("Parsed from this binary's own LC_CODE_SIGNATURE entitlements blob — present on any signed IPA, ad-hoc or App Store, unlike embedded.mobileprovision, which Apple strips from Store downloads.")
                            }.listRowBackground(Color(white: 0.08))
                        }

                        if !infoPlist.isEmpty {
                            Section {
                                ForEach(flattenedManifestPairs(infoPlist), id: \.key) { pair in manifestRow(pair) }
                            } header: {
                                Text("Info.plist (\(infoPlist.count) top-level keys)")
                            } footer: {
                                Text("Orange rows show a real, literal match — the exact plist/entitlement value also appears as a string a function in this binary references. This is not a claim about what that entitlement unlocks, only that the same bytes appear in both places.")
                            }.listRowBackground(Color(white: 0.08))
                        }
                    }
                    .scrollContentBackground(.hidden).background(Color.black)
                }
            }
            .background(Color.black)
            .navigationTitle("Info.plist & Entitlements").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { showManifest = false } } }
        }
        .preferredColorScheme(.dark)
    }

    private var functionListResults: [(address: UInt64, name: String)] {
        let q = functionListQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return functionIndex }
        return functionIndex.filter {
            $0.name.lowercased().contains(q) || String(format: "%llx", $0.address).contains(q)
        }
    }

    private var functionListSheet: some View {
        NavigationStack {
            Group {
                switch functionIndexState {
                case .idle, .loading:
                    VStack(spacing: 18) {
                        AirShareWatermark(size: 96)
                        VStack(spacing: 10) {
                            ProgressView(value: functionListLoadProgress).tint(blue).frame(width: 180)
                            Text("Reading LC_FUNCTION_STARTS + LC_SYMTAB…").font(.caption).foregroundStyle(Theme.subtle)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    VStack(spacing: 10) {
                        Image(systemName: "function").font(.largeTitle).foregroundStyle(Theme.subtle)
                        Text("No LC_FUNCTION_STARTS in this binary.").font(.subheadline).foregroundStyle(Theme.text)
                        Text("Some strip passes remove it along with the symbol table. Enter a VA to decode a window starting there instead.")
                            .font(.caption).foregroundStyle(Theme.subtle).multilineTextAlignment(.center).padding(.horizontal, 30)
                        HStack {
                            TextField("0x100004000", text: $cfgFindQuery)
                                .font(.system(size: 13, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .padding(8).background(Color(white: 0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
                            Button("Jump") { jumpToCFGFindEntry() }.foregroundStyle(blue)
                        }
                        .padding(.horizontal, 30).padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready:
                    List {
                        Section {
                            ForEach(functionListResults, id: \.address) { fn in
                                Button {
                                    disasmVA = String(format: "0x%llx", fn.address)
                                    cfgPicked = true
                                    autoShowInfoOnLoad = true
                                    cfgCallers = []; cfgCallersState = .idle; cfgRefStrings = []; cfgRefSelectors = []; cfgRefClasses = []
                                    showFunctionList = false
                                    Task { await openLocalCFG() }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(fn.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                                            Text(String(format: "0x%llx", fn.address)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.subtle)
                                        }
                                        Spacer()
                                        Image(systemName: "arrow.forward.circle").foregroundStyle(blue)
                                    }
                                }
                            }
                        } header: {
                            Text("\(functionListResults.count) of \(functionIndex.count) functions — real LC_FUNCTION_STARTS entries")
                        }.listRowBackground(Color(white: 0.08))
                    }
                    .scrollContentBackground(.hidden).background(Color.black)
                    .searchable(text: $functionListQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search name or address")
                }
            }
            .background(Color.black)
            .navigationTitle("Functions").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { showFunctionList = false } } }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Objective-C class & method browser
    //
    // Every entry here is a real -[Class selector:] / +[Class selector:]
    // symbol straight from LC_SYMTAB — the standard mangling clang emits for
    // every compiled method — cross-checked against LC_FUNCTION_STARTS so
    // only a symbol that's ALSO confirmed as a real function entry point
    // counts as "verified". No __objc_classlist / class_ro_t struct layout
    // is parsed or guessed at. Picking a method here feeds the exact same
    // pipeline as the Functions list or String Search: CFG, references,
    // and the Call Graph all key off the same real address.

    /// Primary source: real __objc_classlist → class_t → class_ro_t →
    /// method_list_t metadata (see `MachOTools.objcClasses`). This is what
    /// actually has data on a typical stripped release binary — the
    /// Objective-C runtime needs this metadata at launch regardless of
    /// LC_SYMTAB stripping. Supplemented (never overridden) by any
    /// "-[Class sel]"/"+[Class sel]" LC_SYMTAB strings the metadata pass
    /// didn't already cover, for the rarer binary that still has those.
    private var objcMethods: [(address: UInt64, cls: String, category: String?, isClassMethod: Bool, selector: String, typeEncoding: String?)] {
        var seen = Set<String>()
        var out: [(UInt64, String, String?, Bool, String, String?)] = []

        for cls in objcClassList {
            for m in cls.methods {
                let key = "\(m.isClassMethod)|\(cls.name)|\(m.selector)"
                guard seen.insert(key).inserted else { continue }
                out.append((m.impAddress, cls.name, nil, m.isClassMethod, m.selector, m.typeEncoding))
            }
        }

        guard !symbolTable.isEmpty else { return out }
        for (addr, name) in symbolTable {
            guard name.hasPrefix("-[") || name.hasPrefix("+[") , name.hasSuffix("]") else { continue }
            let isClassMethod = name.hasPrefix("+")
            let inner = name.dropFirst(2).dropLast()
            guard let spaceIdx = inner.firstIndex(of: " ") else { continue }
            let clsPart = String(inner[inner.startIndex..<spaceIdx])
            let selector = String(inner[inner.index(after: spaceIdx)...])
            guard !clsPart.isEmpty, !selector.isEmpty else { continue }
            var cls = clsPart
            var category: String? = nil
            if let parenOpen = clsPart.firstIndex(of: "("), clsPart.hasSuffix(")") {
                cls = String(clsPart[clsPart.startIndex..<parenOpen])
                category = String(clsPart[clsPart.index(after: parenOpen)..<clsPart.index(before: clsPart.endIndex)])
            }
            // "Verified" = LC_FUNCTION_STARTS independently confirms a real
            // function begins at this exact address, not just metadata.
            guard let b = functionBounds(containing: addr), b.start == addr else { continue }
            let key = "\(isClassMethod)|\(cls)|\(selector)"
            guard seen.insert(key).inserted else { continue }
            out.append((addr, cls, category, isClassMethod, selector, nil))
        }
        return out
    }

    private var objcClassGroups: [(cls: String, methods: [(address: UInt64, category: String?, isClassMethod: Bool, selector: String, typeEncoding: String?)])] {
        let q = objcBrowserQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var grouped: [String: [(address: UInt64, category: String?, isClassMethod: Bool, selector: String, typeEncoding: String?)]] = [:]
        for m in objcMethods {
            if !q.isEmpty {
                let display = "\(m.isClassMethod ? "+" : "-")[\(m.cls) \(m.selector)]".lowercased()
                guard m.cls.lowercased().contains(q) || m.selector.lowercased().contains(q) || display.contains(q) else { continue }
            }
            grouped[m.cls, default: []].append((m.address, m.category, m.isClassMethod, m.selector, m.typeEncoding))
        }
        return grouped.map { (cls: $0.key, methods: $0.value.sorted { $0.selector < $1.selector }) }.sorted { $0.cls < $1.cls }
    }

    private func pickObjCMethod(address: UInt64) {
        disasmVA = String(format: "0x%llx", address)
        cfgPicked = true
        autoShowInfoOnLoad = true
        cfgCallers = []; cfgCallersState = .idle; cfgRefStrings = []; cfgRefSelectors = []; cfgRefClasses = []
        showObjCBrowser = false
        Task { await openLocalCFG() }
    }

    private var objcBrowserSheet: some View {
        NavigationStack {
            Group {
                if functionIndexState == .idle || functionIndexState == .loading {
                    VStack(spacing: 18) {
                        AirShareWatermark(size: 96)
                        VStack(spacing: 10) {
                            ProgressView(value: functionListLoadProgress).tint(blue).frame(width: 180)
                            Text("Reading __objc_classlist + LC_FUNCTION_STARTS + LC_SYMTAB…").font(.caption).foregroundStyle(Theme.subtle)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if objcMethods.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "curlybraces").font(.largeTitle).foregroundStyle(Theme.subtle)
                        Text("No Objective-C methods found.").font(.subheadline).foregroundStyle(Theme.text)
                        Text("Checked both this binary's __objc_classlist runtime metadata and its LC_SYMTAB -[Class selector:] entries — neither turned up anything, so this is most likely pure Swift/C with no Objective-C classes at all.")
                            .font(.caption).foregroundStyle(Theme.subtle).multilineTextAlignment(.center).padding(.horizontal, 30)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            Button { showAIHookCatalog = true } label: {
                                Label("AI Hook Catalog · Scan TXT / Markdown", systemImage: "brain.head.profile")
                            }
                            .font(.caption.weight(.semibold)).buttonStyle(.borderedProminent).tint(blue)
                            Button { exportClassHeaders() } label: {
                                Label("Export all class headers (.h)", systemImage: "doc.text")
                            }
                            .font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(blue)
                        } footer: {
                            Text("One .h per class listing its real, verified methods (class names and method existence are real; argument/return types are flagged `id` placeholders — selectors carry no type info, so fill in real types from a class-dump before using as a compile-ready header).")
                        }.listRowBackground(Color(white: 0.08))

                        if !selectedTweakMethods.isEmpty {
                            Section {
                                Button { exportSwizzleDylib() } label: {
                                    Label("Generate swizzle dylib (\(selectedTweakMethods.count) selected)", systemImage: "hammer")
                                }
                                .font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(blue)
                                Button(role: .destructive) { selectedTweakMethods.removeAll() } label: {
                                    Label("Clear selection", systemImage: "xmark.circle")
                                }.font(.caption)
                            } footer: {
                                Text("Builds a clang-buildable .m/.dylib skeleton that swizzles each selected method via the Objective-C runtime (method_setImplementation) — the same pattern your other injected-dylib rebrand projects use, not a jailbreak/Theos tweak.")
                            }.listRowBackground(Color(white: 0.08))
                        }

                        Section {
                            ForEach(objcClassGroups, id: \.cls) { group in
                                DisclosureGroup {
                                    ForEach(group.methods, id: \.address) { m in
                                        HStack {
                                            Button {
                                                if selectedTweakMethods.contains(m.address) {
                                                    selectedTweakMethods.remove(m.address)
                                                } else {
                                                    selectedTweakMethods.insert(m.address)
                                                }
                                            } label: {
                                                Image(systemName: selectedTweakMethods.contains(m.address) ? "checkmark.circle.fill" : "circle")
                                                    .foregroundStyle(selectedTweakMethods.contains(m.address) ? blue : Theme.subtle)
                                            }
                                            .buttonStyle(.plain)

                                            Button { pickObjCMethod(address: m.address) } label: {
                                                HStack {
                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text("\(m.isClassMethod ? "+" : "-")\(m.category.map { "(\($0)) " } ?? "")\(m.selector)")
                                                            .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                                                        Text(String(format: "0x%llx", m.address)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.subtle)
                                                    }
                                                    Spacer()
                                                    Image(systemName: "arrow.forward.circle").foregroundStyle(blue).font(.caption)
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    Text(group.cls).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                                }
                            }
                        } header: {
                            Text("\(objcMethods.count) methods across \(objcClassGroups.count) classes")
                        } footer: {
                            Text("Each method comes from this binary's real __objc_classlist/class_ro_t/method_list_t runtime metadata — the same data the Objective-C runtime itself reads at launch, so this works even when LC_SYMTAB is stripped — supplemented by any -[Class selector:]/+[Class selector:] LC_SYMTAB symbols the metadata pass didn't already cover. Tap the circle to select for the swizzle dylib generator; tap the row itself to open its CFG.")
                        }.listRowBackground(Color(white: 0.08))
                    }
                    .scrollContentBackground(.hidden).background(Color.black)
                    .searchable(text: $objcBrowserQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search class or selector")
                }
            }
            .background(Color.black)
            .navigationTitle("Classes & Methods").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { showObjCBrowser = false } } }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Class header export
    //
    // One .h per class, listing its real, verified methods — reusing the
    // exact same `objcClassGroups` the browser above already built from
    // __objc_classlist runtime metadata (supplemented by LC_SYMTAB where
    // present). Class names, method existence, and instance-vs-class kind
    // are all real. Declared argument/return types in the signature itself
    // are still `id` placeholders — decoding a full Objective-C type-encoding
    // string into real C types isn't done here — but when the binary's
    // method_list_t carried a real type-encoding string (common even on
    // stripped release builds, since the runtime needs it for message
    // dispatch), the raw encoding is included verbatim as a trailing
    // comment, so you can read the real argument/return shape by eye
    // without this generator having to guess at it.

    private func classHeaderSource(for cls: String, methods: [(address: UInt64, category: String?, isClassMethod: Bool, selector: String, typeEncoding: String?)]) -> String {
        var decl = "@interface \(cls) : NSObject\n\n"
        for m in methods.sorted(by: { $0.selector < $1.selector }) {
            let argCount = m.selector.filter { $0 == ":" }.count
            let sig: String
            if argCount == 0 {
                sig = m.selector
            } else {
                let parts = m.selector.split(separator: ":").map(String.init)
                sig = parts.enumerated().map { i, part in "\(part):(id)arg\(i)" }.joined(separator: " ")
            }
            decl += "\(m.isClassMethod ? "+" : "-") (id)\(sig);"
            var comments: [String] = []
            if let cat = m.category { comments.append("category: \(cat)") }
            if let enc = m.typeEncoding, !enc.isEmpty { comments.append("encoding: \(enc)") }
            if !comments.isEmpty { decl += "  // \(comments.joined(separator: "  "))" }
            decl += "\n"
        }
        decl += "\n@end\n"
        return decl
    }

    private func exportClassHeaders() {
        guard !objcClassGroups.isEmpty else { return }
        var files: [(String, Data)] = []
        var combined = """
        // Auto-generated interface stubs — \(objcMethods.count) real
        // Objective-C methods across \(objcClassGroups.count) classes, from
        // the CFG Viewer's Classes & Methods browser.
        //
        // REAL: class names, which methods exist on each class, and
        // instance-vs-class kind — read directly from this binary's own
        // __objc_classlist/class_ro_t/method_list_t runtime metadata (the
        // same mechanism class-dump uses), which is why this still works on
        // a release build with LC_SYMTAB symbols stripped. Supplemented,
        // never overridden, by any "-[Class sel]"-style LC_SYMTAB entries
        // the metadata pass didn't already cover.
        // Where the binary's method_list_t carried a real type-encoding
        // string, it's included as a trailing `// encoding: ...` comment —
        // real, not guessed. The DECLARED signature below still uses `id`
        // for every argument/return type: decoding a type-encoding string
        // into real C types isn't done here, so treat this as a
        // method-existence stub, not a compile-ready header, until you
        // translate the encoding comments (or a class-dump) into real types.
        // Ivars are not included either — they weren't parsed in this pass.

        #import <Foundation/Foundation.h>


        """
        for group in objcClassGroups {
            let header = classHeaderSource(for: group.cls, methods: group.methods)
            combined += header + "\n"
            files.append(("\(group.cls).h", Data(header.utf8)))
        }
        files.append(("AllClasses.h", Data(combined.utf8)))
        do {
            let tmpDir = FileManager.default.temporaryDirectory
            let zipURL = tmpDir.appendingPathComponent("ClassHeaders.zip")
            try? FileManager.default.removeItem(at: zipURL)
            let archive = try Archive(url: zipURL, accessMode: .create)
            for (path, data) in files {
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                    data.subdata(in: Int(position) ..< Int(position) + size)
                }
            }
            UIActivityViewController.share(zipURL)
        } catch {
            cfgStatus = "Could not build the headers zip: \(error.localizedDescription)"
        }
    }

    // MARK: Swizzle dylib generator
    //
    // Builds a clang-buildable Objective-C runtime swizzle skeleton — a
    // constructor that overrides each selected method via the safe
    // class_addMethod/class_replaceMethod pattern (NSHipster/Mike Ash's
    // documented safe-swizzle shape), matching the same injected-rebrand-
    // dylib pattern already used elsewhere in this ecosystem, not a
    // jailbreak/Theos %hook tweak. Every real method picked here came from
    // the verified -[Class selector:] LC_SYMTAB browser above, so the
    // class/selector names are real. What's NOT real or knowable from a
    // selector alone is argument/return TYPES — every placeholder below is
    // `id`, loudly flagged, rather than guessed at. Everything else below
    // — correct class-vs-metaclass lookup, not stomping an inherited
    // superclass implementation, a no-op on re-entry, and a null-check for
    // a selector that doesn't resolve at all — is handled for real, not
    // just the method-body signatures.

    /// A valid, unique C identifier for one method's static storage.
    private func swizzleIdentifier(cls: String, selector: String, isClassMethod: Bool) -> String {
        let cleaned = (cls + "_" + selector).map { c -> Character in
            (c.isLetter || c.isNumber) ? c : "_"
        }
        return "\(isClassMethod ? "class" : "inst")_\(String(cleaned))"
    }

    private func swizzleSourceAndSelections() -> (source: String, count: Int)? {
        // Dedupe by (class, selector, isClassMethod): generating two swizzle
        // blocks for the exact same method in one constructor would make the
        // second block's class_addMethod fail against the first block's
        // just-added override, double-wrapping instead of cleanly failing —
        // so only the first selection of any given method is kept.
        var seenKeys = Set<String>()
        let selected = objcMethods
            .filter { selectedTweakMethods.contains($0.address) }
            .filter { seenKeys.insert("\($0.isClassMethod)|\($0.cls)|\($0.selector)").inserted }
        guard !selected.isEmpty else { return nil }
        let byClass = Dictionary(grouping: selected, by: { $0.cls })

        var body = ""
        for (cls, methods) in byClass.sorted(by: { $0.key < $1.key }) {
            body += "    // --- \(cls) ---\n"
            for m in methods.sorted(by: { $0.selector < $1.selector }) {
                let argCount = m.selector.filter { $0 == ":" }.count
                let ident = swizzleIdentifier(cls: cls, selector: m.selector, isClassMethod: m.isClassMethod)
                let blockArgs = (0..<argCount).map { "id arg\($0)" }.joined(separator: ", ")
                let blockSig = argCount == 0 ? "id self" : "id self, \(blockArgs)"
                let callArgs = (0..<argCount).map { ", arg\($0)" }.joined()
                let castArgTypes = (0..<argCount).map { _ in ", id" }.joined()
                // +methods live on the METACLASS, not the class — looking
                // them up and class_addMethod/class_replaceMethod'ing them
                // on `cls` itself (instead of object_getClass(cls)) would
                // silently do nothing. targetCls below is the class the
                // method actually needs to be added/replaced on.
                let lookupLine = m.isClassMethod
                    ? "Class targetCls = object_getClass(baseCls); // +methods live on the metaclass"
                    : "Class targetCls = baseCls;"
                body += """
                    {
                        Class baseCls = objc_getClass("\(cls)");
                        if (baseCls) {
                            \(lookupLine)
                            SEL sel_\(ident) = @selector(\(m.selector));
                            // class_getInstanceMethod walks the hierarchy, so this can
                            // return an INHERITED Method — that's fine, it's only read
                            // from here, never mutated directly.
                            Method originalMethod_\(ident) = class_getInstanceMethod(targetCls, sel_\(ident));
                            if (originalMethod_\(ident)) {
                                IMP originalImp_\(ident) = method_getImplementation(originalMethod_\(ident));
                                const char *typeEncoding_\(ident) = method_getTypeEncoding(originalMethod_\(ident));
                                IMP newImp_\(ident) = imp_implementationWithBlock(^id(\(blockSig)) {
                                    NSLog(@"[Swizzle] \(m.isClassMethod ? "+" : "-")[\(cls) \(m.selector)] called");
                                    return ((id (*)(id, SEL\(castArgTypes)))originalImp_\(ident))(self, sel_\(ident)\(callArgs));
                                });
                                // class_addMethod only succeeds if `targetCls` does NOT
                                // already implement this selector directly (an inherited
                                // method doesn't count as "already implements"). If it
                                // succeeds, the override now lives only on targetCls — the
                                // superclass's own implementation, and every OTHER
                                // subclass that inherits it, are untouched.
                                // originalImp_\(ident) above was captured before this call,
                                // so it's still the correct thing to chain to either way.
                                BOOL addedDirectly_\(ident) = class_addMethod(targetCls, sel_\(ident), newImp_\(ident), typeEncoding_\(ident));
                                if (!addedDirectly_\(ident)) {
                                    // targetCls already had its OWN implementation (not
                                    // inherited) — safe to replace it directly, since the
                                    // Method we read from is confirmed to belong to
                                    // targetCls itself, not a shared superclass.
                                    class_replaceMethod(targetCls, sel_\(ident), newImp_\(ident), typeEncoding_\(ident));
                                }
                            } else {
                                NSLog(@"[Swizzle] \(m.isClassMethod ? "+" : "-")[\(cls) \(m.selector)] not found at runtime — skipped (nothing was modified).");
                            }
                        }
                    }

                """
            }
        }

        let source = """
        #import <Foundation/Foundation.h>
        #import <objc/runtime.h>
        #import <objc/message.h>

        // Auto-generated Objective-C runtime swizzle skeleton — built from
        // \(selected.count) real, verified method symbols (each confirmed against
        // LC_FUNCTION_STARTS, picked from the CFG Viewer's Classes & Methods
        // browser). This is a plain clang dylib, NOT a Theos/jailbreak %hook
        // tweak — but note what's still true of ANY dylib like this:
        //
        // 1) This is not self-loading. A dylib's __attribute__((constructor))
        //    only runs once the dylib is actually LOADED into a running
        //    process by dyld. Nothing in this zip injects it — that's this
        //    app's own dylib-injection step (@executable_path/@rpath +
        //    folder picker), which adds the real LC_LOAD_DYLIB entry and
        //    re-signs the target so dyld is permitted to load it. Building
        //    this .dylib is necessary but not sufficient.
        // 2) Architecture must match the target slice exactly. Many modern
        //    App Store binaries are arm64e (pointer authentication); a
        //    plain arm64 dylib will not load into one. Check the target
        //    with `otool -hv <binary>` and set ARCH in the Makefile to
        //    match before building.
        // 3) The deployment target (-miphoneos-version-min) must be <= the
        //    target app's own minimum iOS version, or dyld can refuse to
        //    load this dylib into it.
        // 4) Linking: only Foundation/UIKit are linked by default. If the
        //    REAL types you fill in below need another framework, add it
        //    to the Makefile's -framework list — a missing framework is a
        //    link error, not a runtime crash, so you'll see it immediately.
        //
        // ============================ READ THIS ============================
        // Objective-C selector names do NOT encode argument or return types —
        // that information lives in each method's type-encoding string, which
        // this generator does not parse (it only had the verified symbol name
        // to go on). EVERY argument and return value below is typed `id` as a
        // placeholder. If the real method takes/returns a C primitive
        // (BOOL, int, CGFloat, a struct, …), this placeholder is a silent
        // ABI/calling-convention mismatch, not a compile error — fix the
        // types below from a real class-dump/header before shipping this.
        //
        // What IS handled correctly below, independent of the type fix:
        //   - class methods are looked up/overridden on the METACLASS
        //     (object_getClass(cls)), not the class — a +method swizzled on
        //     the class object itself would silently do nothing.
        //   - an inherited method is never mutated in place: class_addMethod
        //     is tried first, so if `targetCls` doesn't define the selector
        //     itself, the override lands only on targetCls, leaving the
        //     superclass (and every other subclass of it) untouched.
        //   - the whole constructor is a no-op if it somehow runs twice in
        //     one process (see generated_swizzle_did_run below) — swizzling
        //     the same method pair twice would otherwise double-wrap it.
        //   - a selector that doesn't resolve at runtime at all is logged
        //     and skipped, never force-unwrapped into a crash.
        // =====================================================================

        static BOOL generated_swizzle_did_run = NO;

        __attribute__((constructor))
        static void generated_swizzle_init(void) {
            // Guards against this constructor running more than once in the
            // same process — re-swizzling the same selector pair a second
            // time would wrap the already-wrapped IMP instead of cleanly
            // no-op'ing, so this is a hard stop, not a courtesy check.
            if (generated_swizzle_did_run) { return; }
            generated_swizzle_did_run = YES;

        \(body)}

        """
        return (source, selected.count)
    }

    private func exportSwizzleDylib() {
        guard let (source, count) = swizzleSourceAndSelections() else { return }
        let makefile = """
        # Plain clang dylib build — not Theos. These are NOT safe defaults to
        # build-and-ship blind; each one below must be checked against the
        # actual target binary first:
        #
        #   ARCH     — must match the target executable's slice exactly.
        #              Run `otool -hv TargetBinary` and look at the CPU
        #              subtype: arm64e (pointer authentication) and plain
        #              arm64 are NOT interchangeable — a mismatch fails to
        #              load, it does not silently "mostly work".
        #   IOS_MIN  — must be <= the target app's own deployment target,
        #              check with `otool -l TargetBinary | grep -A3 MIN_VERSION`.
        #
        # Override either at build time, e.g.: make ARCH=arm64e IOS_MIN=16.0

        ARCH     ?= arm64
        IOS_MIN  ?= 14.0
        SDK       = $(shell xcrun --sdk iphoneos --show-sdk-path)
        TARGET    = GeneratedSwizzle.dylib

        all:
        \tclang -dynamiclib \\
        \t\t-arch $(ARCH) \\
        \t\t-isysroot $(SDK) \\
        \t\t-miphoneos-version-min=$(IOS_MIN) \\
        \t\t-framework Foundation -framework UIKit \\
        \t\t-install_name @rpath/$(TARGET) \\
        \t\t-o $(TARGET) GeneratedSwizzle.m

        clean:
        \trm -f $(TARGET)
        """
        let readme = """
        # Generated Swizzle Dylib

        Built from \(count) real, verified Objective-C method(s) picked in the
        CFG Viewer's Classes & Methods browser — each one's class/selector name
        came straight from a real `-[Class selector:]` / `+[Class selector:]`
        LC_SYMTAB symbol, confirmed as a real function entry by LC_FUNCTION_STARTS.

        ## What's handled correctly already

        - **Class vs. instance lookup**: `+` methods are looked up and overridden
          on the metaclass (`object_getClass(cls)`), `-` methods on the class
          itself — swizzling a `+` method on the class object directly would
          silently do nothing.
        - **Inheritance**: uses the standard safe-swizzle pattern
          (`class_addMethod` first, `class_replaceMethod` only if that fails).
          If a selected class inherits the method rather than overriding it,
          the new implementation is added directly on that class only — the
          superclass, and any other subclass that also inherits it, are left
          completely untouched.
        - **Repeated swizzling**: the whole constructor is guarded by a
          `generated_swizzle_did_run` flag, so if the dylib's constructor
          somehow runs twice in one process, the second run is a no-op
          instead of double-wrapping every hook.
        - **Methods that don't resolve**: if a selector doesn't exist on the
          class at runtime at all, it's logged and skipped — nothing is
          force-unwrapped into a crash.

        ## What you still have to fix before this builds or runs correctly

        - **Types**: every argument/return type in `GeneratedSwizzle.m` is a
          placeholder `id`. Selector names carry no type information — pull
          the real types from a class-dump or header. A wrong type here is a
          silent ABI/calling-convention mismatch, not a compile error.
        - **Architecture**: the Makefile's `ARCH` must match the target
          binary's real slice (arm64 vs. arm64e) — check with `otool -hv`.
          A mismatch means dyld refuses to load this dylib at all.
        - **Deployment target**: `IOS_MIN` must be <= the target app's own
          minimum iOS version, or dyld can refuse to load this into it.
        - **Linking**: only Foundation/UIKit are linked. Once you fill in
          real types, add whatever framework those types actually need.
        - **Loading is not automatic**: a `__attribute__((constructor))` only
          runs once the OS has actually loaded this dylib into the target
          process. This zip only produces the `.dylib` — getting it into the
          target is this app's own dylib-injection step
          (`@executable_path`/`@rpath` + the folder picker), which adds the
          real load-command entry and re-signs the app so the OS permits
          loading an extra, non-Apple dylib into it. Skipping that step means
          this constructor never runs, no matter how correct the code is.
        - **GitHub Actions build**: the included `.github/workflows/build-dylib.yml`
          builds an arm64 iOS dylib and uploads it as `GeneratedSwizzle-ios-arm64`.
          Put these files in a GitHub repository, push to `main`/`master`, or run
          the workflow manually. Download the artifact from Actions.
        - **AirCore signing sheet**: use `Signing Sheet → Dylib Injection → Add
          library (.dylib, .framework)` and select the downloaded artifact's
          `GeneratedSwizzle.dylib`. AirCore then stages it in the existing
          injection list for your own test app.
        """
        do {
            let tmpDir = FileManager.default.temporaryDirectory
            let zipURL = tmpDir.appendingPathComponent("GeneratedSwizzleDylib.zip")
            try? FileManager.default.removeItem(at: zipURL)
            let archive = try Archive(url: zipURL, accessMode: .create)
            let workflow = """
            name: Build Generated Diagnostic Dylib

            on:
              workflow_dispatch:
              push:
                branches: [ main, master ]

            permissions:
              contents: read

            jobs:
              build-dylib:
                runs-on: macos-15
                timeout-minutes: 15
                steps:
                  - uses: actions/checkout@v4
                  - name: Build iOS arm64 dylib
                    shell: bash
                    run: |
                      set -euo pipefail
                      SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
                      clang -dynamiclib -arch arm64 -isysroot "$SDK" \
                        -miphoneos-version-min=14.0 \
                        -framework Foundation -framework UIKit \
                        -install_name @rpath/GeneratedSwizzle.dylib \
                        -o GeneratedSwizzle.dylib GeneratedSwizzle.m
                      file GeneratedSwizzle.dylib
                      xcrun --sdk iphoneos --find clang >/dev/null
                  - name: Upload dylib artifact
                    uses: actions/upload-artifact@v4
                    with:
                      name: GeneratedSwizzle-ios-arm64
                      path: GeneratedSwizzle.dylib
                      if-no-files-found: error
            """
            let files: [(String, Data)] = [
                ("GeneratedSwizzle.m", Data(source.utf8)),
                ("Makefile", Data(makefile.utf8)),
                ("README.md", Data(readme.utf8)),
                (".github/workflows/build-dylib.yml", Data(workflow.utf8)),
            ]
            for (path, data) in files {
                try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                    data.subdata(in: Int(position) ..< Int(position) + size)
                }
            }
            UIActivityViewController.share(zipURL)
        } catch {
            cfgStatus = "Could not build the dylib project zip: \(error.localizedDescription)"
        }
    }

    // MARK: Function Info — a plain-English index of what this function connects to.
    // Every line here comes from real, already-decoded data: Capstone's instruction
    // counts, its own resolved string/class xrefs, the real callees it dials out to,
    // and a real cross-reference scan for who calls it. Nothing is a semantic guess
    // about what the function "does" — just its honest connections, laid out for
    // someone who can't read the raw ARM64 above.

    private var functionInfoSheet: some View {
        NavigationStack {
            List {
                if let fn = cfgFunction {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(fn.name).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
                            Text(String(format: "0x%llx – 0x%llx · %lu bytes", fn.startAddress, fn.endAddress, fn.size))
                                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.subtle)
                            Text("\(fn.instructions.count) instructions · \(fn.basicBlockCount) basic blocks\(fn.boundaryIsBounded ? " · bounded by the next function" : "")")
                                .font(.caption).foregroundStyle(Theme.subtle)
                        }
                        HStack(spacing: 10) {
                            Button { Task { await preparePatchPreview(va: fn.startAddress, ret: false) } } label: {
                                Label("NOP entry", systemImage: "scissors")
                            }
                            Button { Task { await preparePatchPreview(va: fn.startAddress, ret: true) } } label: {
                                Label("RET entry", systemImage: "arrow.uturn.backward")
                            }
                        }
                        .font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(blue)
                        if patches.contains(where: { $0.label.hasSuffix(String(format: "0x%llx", fn.startAddress)) }) {
                            Label("Patch queued for this function — applies at sign time", systemImage: "checkmark.seal.fill")
                                .font(.caption2).foregroundStyle(.green)
                        }
                    }.listRowBackground(Color(white: 0.08))

                    Section {
                        let stats = functionComplexity(for: fn)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                            complexityTile("Basic blocks", "\(stats.nodeCount)")
                            complexityTile("Edges", "\(stats.edgeCount)")
                            complexityTile("Complexity", "\(stats.cyclomaticComplexity)")
                            complexityTile("Loops", "\(stats.loopCount)")
                            complexityTile("Branch blocks", "\(stats.branchBlockCount)")
                            complexityTile("Max out-degree", "\(stats.maxOutDegree)")
                        }
                        .padding(.vertical, 4)
                        Label(
                            stats.hasRecoveredName ? "Named — real symbol or recovered selector" : "Synthesized — no symbol found, named from its address",
                            systemImage: stats.hasRecoveredName ? "checkmark.seal" : "questionmark.circle"
                        )
                        .font(.caption).foregroundStyle(stats.hasRecoveredName ? .green : Theme.subtle)
                    } header: {
                        Text("Complexity")
                    } footer: {
                        Text("Cyclomatic complexity (E − N + 2) estimates how many independent paths run through this function — higher usually means more branching logic worth a closer look. Loops counts real back edges found by walking the same block graph the CFG viewer renders.")
                    }.listRowBackground(Color(white: 0.08))

                    Section {
                        if cfgRefStrings.isEmpty {
                            Text("No real string references resolved in this function.").font(.caption).foregroundStyle(Theme.subtle)
                        } else {
                            ForEach(cfgRefStrings, id: \.self) { s in
                                xrefRow(text: "\"\(s)\"") {
                                    stringIndexQuery = s
                                    showFunctionInfo = false
                                    showStringIndex = true
                                }
                            }
                        }
                    } header: {
                        Text("References — strings it touches")
                    } footer: {
                        Text("Resolved statically from the file's adrp+ldr/add pairs — not a live-process read, so this works on any IPA, not just AirShare's own code. Tap one to find every other function that references it.")
                    }.listRowBackground(Color(white: 0.08))

                    Section {
                        if cfgRefSelectors.isEmpty {
                            Text("No Objective-C selectors referenced in this function.").font(.caption).foregroundStyle(Theme.subtle)
                        } else {
                            ForEach(cfgRefSelectors, id: \.self) { s in
                                xrefRow(text: "@selector(\(s))") {
                                    stringIndexQuery = s
                                    showFunctionInfo = false
                                    showStringIndex = true
                                }
                            }
                        }
                    } header: {
                        Text("Objective-C messages sent")
                    } footer: {
                        Text("Every adrp+ldr pair whose slot lands in __objc_selrefs — the ABI guarantees that table only ever holds selector names, so this is real, not a guess at which bl is objc_msgSend. Tap one to find every other function sending it.")
                    }.listRowBackground(Color(white: 0.08))

                    Section {
                        if cfgRefClasses.isEmpty {
                            Text("No Objective-C classes resolved in this function.").font(.caption).foregroundStyle(Theme.subtle)
                        } else {
                            ForEach(cfgRefClasses, id: \.self) { c in
                                xrefRow(text: c, weight: .semibold) {
                                    objcBrowserQuery = c
                                    showFunctionInfo = false
                                    showObjCBrowser = true
                                }
                            }
                        }
                    } header: {
                        Text("Objective-C classes")
                    } footer: {
                        Text("From __objc_classrefs slots matched against this class's real _OBJC_CLASS_$_ symbol in LC_SYMTAB — only resolves classes actually defined in this binary, not ones it merely imports. Tap one to open it in the Classes & Methods browser.")
                    }.listRowBackground(Color(white: 0.08))

                    Section {
                        if cfgImportedCalls.isEmpty {
                            Text("No calls into an external/imported API resolved in this function.").font(.caption).foregroundStyle(Theme.subtle)
                        } else {
                            ForEach(cfgImportedCalls, id: \.address) { entry in
                                HStack {
                                    Circle().fill(.purple).frame(width: 7, height: 7)
                                    Text(entry.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                                }
                            }
                        }
                    } header: {
                        Text("Imported APIs called (\(cfgImportedCalls.count))")
                    } footer: {
                        Text("Resolved from LC_DYSYMTAB's indirect symbol table against each call's real branch target — the same mechanism otool -I uses, not a guess at what a stub does.")
                    }.listRowBackground(Color(white: 0.08))

                    Section {
                        if cfgCallTargets.isEmpty {
                            Text("Calls nothing outside itself in this window.").font(.caption).foregroundStyle(Theme.subtle)
                        } else {
                            ForEach(cfgCallTargets, id: \.address) { entry in
                                connectionRow(address: entry.address, name: entry.label)
                            }
                        }
                    } header: {
                        Text("Calls out to (\(cfgCallTargets.count))")
                    }.listRowBackground(Color(white: 0.08))

                    Section {
                        switch cfgCallersState {
                        case .idle, .loading:
                            HStack { ProgressView().tint(blue); Text("Scanning __text for real callers…").font(.caption).foregroundStyle(Theme.subtle) }
                        case .empty:
                            Text("No `bl` anywhere in __text resolves to this address — nothing in-module calls it directly (it may be an export, a callback target, or dead code).")
                                .font(.caption).foregroundStyle(Theme.subtle)
                        case .ready:
                            ForEach(cfgCallers, id: \.address) { entry in
                                connectionRow(address: entry.address, name: entry.name)
                            }
                        }
                    } header: {
                        Text("Called from (\(cfgCallers.count))")
                    } footer: {
                        Text("Found by scanning every real `bl` instruction in __text — not just this function's own window.")
                    }.listRowBackground(Color(white: 0.08))
                } else {
                    Text("No function loaded.").font(.caption).foregroundStyle(Theme.subtle)
                }
            }
            .scrollContentBackground(.hidden).background(Color.black)
            .navigationTitle("Function Info").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { showFunctionInfo = false } } }
        }
        .preferredColorScheme(.dark)
    }

    /// A tappable row in Function Info that jumps the CFG viewer to that address —
    /// lets you actually walk the real call graph in either direction.
    private func connectionRow(address: UInt64, name: String) -> some View {
        Button {
            disasmVA = String(format: "0x%llx", address)
            cfgPicked = true
            autoShowInfoOnLoad = true
            cfgCallers = []; cfgCallersState = .idle; cfgRefStrings = []; cfgRefSelectors = []; cfgRefClasses = []
            showFunctionInfo = false
            cfgFunction = nil
            Task { await openLocalCFG() }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(String(format: "0x%llx", address)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.subtle)
                }
                Spacer()
                Image(systemName: "arrow.forward.circle").foregroundStyle(blue)
            }
        }
    }

    /// A tappable row for a string/selector/class reference in Function Info
    /// that jumps to the real reverse-lookup for it — every other function
    /// that touches the same string, sends the same selector, or references
    /// the same class — instead of just listing it as inert text.
    private func xrefRow(text: String, weight: Font.Weight = .regular, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text).font(.system(size: 12, weight: weight, design: .monospaced)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer()
                Image(systemName: "arrow.forward.circle").foregroundStyle(blue).font(.caption)
            }
        }
    }

    /// Real, computed-not-guessed stats about a function's control flow —
    /// backs the "Complexity" section of Function Info. Everything here
    /// comes straight off the already-built basic-block graph (the same
    /// predecessor/successor data the CFG viewer renders), not a heuristic
    /// about what the function "looks like it does".
    private struct FunctionComplexity {
        var nodeCount: Int
        var edgeCount: Int
        /// McCabe cyclomatic complexity for a single-entry CFG: E - N + 2.
        var cyclomaticComplexity: Int
        var loopCount: Int
        var branchBlockCount: Int
        var maxOutDegree: Int
        var hasRecoveredName: Bool
    }

    private func functionComplexity(for fn: UCFunction) -> FunctionComplexity {
        let blocks = fn.basicBlocks
        let nodeCount = blocks.count
        let edgeCount = blocks.reduce(0) { $0 + ($1.successors?.count ?? 0) }
        let branchBlockCount = blocks.filter { ($0.successors?.count ?? 0) > 1 }.count
        let maxOutDegree = blocks.map { $0.successors?.count ?? 0 }.max() ?? 0
        // E - N + 2P, with P = 1 (one connected component: this function).
        let cyclomatic = max(1, edgeCount - nodeCount + 2)

        // Same iterative-DFS back-edge detection the native CFG canvas uses
        // (UCCFGView.computeLoopBlockIds in UCDisasmViewController.m) — a
        // block reached again while still on the DFS stack means the edge
        // that reached it loops back, i.e. a real loop in this function.
        var loopEdgeCount = 0
        if let entry = blocks.first(where: { $0.type == .entry || ($0.predecessors?.count ?? 0) == 0 }) ?? blocks.first {
            var stack: [UCBasicBlock] = [entry]
            var visited = Set<Int>()
            var onStack = Set<Int>()
            onStack.insert(entry.blockId)
            while let current = stack.last {
                let curId = current.blockId
                if visited.contains(curId) {
                    stack.removeLast()
                    onStack.remove(curId)
                    continue
                }
                visited.insert(curId)
                // `successors` is an ObjC `NSArray<UCBasicBlock *> *` bridged into
                // Swift as `[Any]` here (not `[UCBasicBlock]`), so each element has
                // to be cast before `.blockId` is reachable on it. The `for case
                // let ... as` form skips anything that isn't a UCBasicBlock instead
                // of force-casting and crashing on a stray entry.
                for case let succ as UCBasicBlock in current.successors ?? [] {
                    let succId = succ.blockId
                    if visited.contains(succId) && onStack.contains(succId) {
                        loopEdgeCount += 1
                        continue
                    }
                    if !visited.contains(succId) {
                        stack.append(succ)
                        onStack.insert(succId)
                    }
                }
            }
        }

        // "sub_<hex>" is this codebase's synthesized fallback name for a
        // function nothing else could name — anything else means a real
        // symbol or recovered Objective-C selector was found for it.
        let hasRecoveredName = !fn.name.hasPrefix("sub_")

        return FunctionComplexity(
            nodeCount: nodeCount,
            edgeCount: edgeCount,
            cyclomaticComplexity: cyclomatic,
            loopCount: loopEdgeCount,
            branchBlockCount: branchBlockCount,
            maxOutDegree: maxOutDegree,
            hasRecoveredName: hasRecoveredName
        )
    }

    /// One stat tile in the Complexity section.
    private func complexityTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
            Text(label).font(.caption2).foregroundStyle(Theme.subtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Interactive call graph — the view

    private var callGraphSheet: some View {
        NavigationStack {
            Group {
                if let root = callGraphRoot {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(root.name).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(Theme.text)
                                Text(String(format: "0x%llx", root.address)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.subtle)
                            }
                            Button {
                                Task {
                                    let sites = await scanCallerSites(of: root.address)
                                    await prepareBatchPatch(callSites: sites, title: "NOP \(sites.count) real caller\(sites.count == 1 ? "" : "s") of \(root.name)")
                                }
                            } label: {
                                Label("Preview: patch all real callers (NOP)", systemImage: "scissors.badge.ellipsis")
                            }.font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(blue)
                        }.listRowBackground(Color(white: 0.08))

                        Section {
                            CallGraphTree(node: root, direction: .callees, blue: blue,
                                          onExpand: { n in Task { await loadCallees(for: n) } },
                                          onJump: { addr, kind in jumpCallGraph(to: addr, kind: kind) })
                        } header: {
                            Text("Calls out to")
                        } footer: {
                            Text("Green = resolves to another real function. Purple = a real imported API, resolved via LC_DYSYMTAB's indirect symbol table (otool -I's own mechanism). Orange = a branch target that's neither — not covered by LC_FUNCTION_STARTS nor a recognized stub. Red = an indirect call through a register (blr), with no static target at all. Expand up to 3 levels out; tap a row to open its CFG (imported/unresolved rows have nothing local to open).")
                        }.listRowBackground(Color(white: 0.08))

                        Section {
                            CallGraphTree(node: root, direction: .callers, blue: blue,
                                          onExpand: { n in Task { await loadCallers(for: n) } },
                                          onJump: { addr, kind in jumpCallGraph(to: addr, kind: kind) })
                        } header: {
                            Text("Called from")
                        } footer: {
                            Text("Every real `bl` in __text that resolves to each node's address — scanned fresh per node, not limited to one function's own window.")
                        }.listRowBackground(Color(white: 0.08))
                    }
                    .scrollContentBackground(.hidden).background(Color.black)
                } else {
                    VStack(spacing: 18) {
                        AirShareWatermark(size: 96)
                        VStack(spacing: 10) {
                            ProgressView(value: 0.5).tint(blue).frame(width: 180)
                            Text("Building call graph…").font(.caption).foregroundStyle(Theme.subtle)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                }
            }
            .background(Color.black)
            .navigationTitle("Call Graph").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { showCallGraph = false } } }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Strings

    private var stringsView: some View {
        VStack(spacing: 0) {
            // Category chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(categories, id: \.0) { key, label in
                        Button { catFilter = key } label: {
                            Text(label).font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(catFilter == key ? Color(red: 0.2, green: 0.85, blue: 0.5) : Color(red: 0.2, green: 0.85, blue: 0.5).opacity(0.14))
                                .foregroundStyle(catFilter == key ? .black : Color(red: 0.2, green: 0.85, blue: 0.5))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            Divider().overlay(Color.white.opacity(0.08))

            List {
                if loading {
                    Section { HStack { Spacer(); ProgressView().tint(blue); Spacer() } }.listRowBackground(Color.clear)
                } else if filtered.isEmpty {
                    Section { Text(hits.isEmpty ? "No editable strings found." : "No matches.").foregroundStyle(Theme.subtle) }
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(filtered) { hit in
                        Button { if hit.editable == "yes" { editHit = hit } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.string).font(.system(size: 15)).foregroundStyle(Theme.text).lineLimit(2)
                                HStack(spacing: 8) {
                                    Text(hit.module ?? "—").font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color(red: 0.2, green: 0.85, blue: 0.5))
                                    if let k = hit.kind, k.contains("string") || k == "cfstring" || k == "ustring" {
                                        Text("NSString").font(.system(size: 12, weight: .semibold)).foregroundStyle(blue)
                                    }
                                    Spacer()
                                    Text("\(hit.string.utf8.count)b").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.subtle)
                                }
                                if patches.contains(where: { $0.fileOffset == hitOffset(hit) }) {
                                    Text("→ patched (applies at sign)").font(.system(size: 11)).foregroundStyle(.green)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.black)
                        .listRowSeparatorTint(Color.white.opacity(0.06))
                    }
                }
            }
            .listStyle(.plain).scrollContentBackground(.hidden).background(Color.black)
        }
        .background(Color.black)
    }

    private var categories: [(String, String)] {
        [("all", "All"), ("paywall", "Paywall"), ("login", "Login"), ("url", "URL/API"), ("analytics", "Analytics"), ("settings", "Settings")]
    }

    private func editBadge(_ e: String?) -> some View {
        let (t, c): (String, Color) = e == "yes" ? ("EDITABLE", .green)
            : e == "limited" ? ("LIMITED", .orange)
            : e == "resource" ? ("RESOURCE", blue) : ("READ-ONLY", Theme.subtle)
        return Text(t).font(.system(size: 8.5, weight: .heavy, design: .monospaced)).kerning(0.5)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(c.opacity(0.18)).foregroundStyle(c).clipShape(Capsule())
    }

    private func hitOffset(_ h: AVXScanHit) -> Int { Int(h.address.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? -1 }

    // MARK: Dependencies

    private var dependenciesView: some View {
        List {
            if let err = machoError { Section { Text(err).foregroundStyle(.orange) }.listRowBackground(Color(white: 0.08)) }
            if let slice = macho?.arm64 {
                Section("Linked (\(slice.dylibs.count))") {
                    ForEach(slice.dylibs, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text) }
                }.listRowBackground(Color(white: 0.08))
                if !slice.weakDylibs.isEmpty {
                    Section("Weak (\(slice.weakDylibs.count))") {
                        ForEach(slice.weakDylibs, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).foregroundStyle(.orange) }
                    }.listRowBackground(Color(white: 0.08))
                }
                if !slice.rpaths.isEmpty {
                    Section("RPaths (\(slice.rpaths.count))") {
                        ForEach(slice.rpaths, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.subtle) }
                    }.listRowBackground(Color(white: 0.08))
                }
            } else {
                Section { Text("No arm64 slice found.").foregroundStyle(Theme.subtle) }.listRowBackground(Color(white: 0.08))
            }
        }
        .scrollContentBackground(.hidden).background(Color.black)
    }

    // MARK: Disassemble

    private var disassembleView: some View {
        List {
            Section {
                HStack {
                    TextField("VA e.g. 0x100004abc", text: $disasmVA)
                        .font(.system(size: 13, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Go") { Task { await disassembleAt() } }.foregroundStyle(blue)
                }
            }.listRowBackground(Color(white: 0.08))
            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    Button { Task { await openLocalCFG() } } label: {
                        Label("CFG Viewer", systemImage: "point.3.connected.trianglepath.dotted")
                            .lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                    }

                    Button {
                        Task { await openDisassemblerBrowser() }
                    } label: {
                        Label("Disassembler", systemImage: "list.bullet.rectangle")
                            .lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                    }

                    Button {
                        guard cfgFunction != nil else { cfgStatus = "Open CFG Viewer once to build the annotated function."; return }
                        showAnalysisCenter = true
                    } label: {
                        Label("Analysis", systemImage: "square.grid.3x3")
                            .lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                    }

                    Button {
                        openPseudocode()
                    } label: {
                        Label("Pseudocode", systemImage: "chevron.left.forwardslash.chevron.right")
                            .lineLimit(1).minimumScaleFactor(0.8).frame(maxWidth: .infinity)
                    }
                    .disabled(cfgFunction == nil)
                }
                .buttonStyle(.bordered)
                .tint(blue)
                .font(.footnote.weight(.semibold))
                if let cfgStatus {
                    Text(cfgStatus).font(.caption).foregroundStyle(Theme.subtle)
                }
            }.listRowBackground(Color(white: 0.08))
            if disasm.isEmpty {
                Section { Text("Enter a virtual address to disassemble 96 instructions.").font(.caption).foregroundStyle(Theme.subtle) }
                    .listRowBackground(Color(white: 0.08))
            } else {
                Section {
                    ForEach(Array(disasm.enumerated()), id: \.offset) { _, insn in
                        HStack(spacing: 10) {
                            Text(String(format: "0x%llx", insn.va)).font(.system(size: 11, design: .monospaced)).foregroundStyle(blue)
                            Text("\(insn.mnem) \(insn.ops)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                            Spacer()
                        }
                    }
                }.listRowBackground(Color(white: 0.08))
            }
        }
        .scrollContentBackground(.hidden).background(Color.black)
    }

    // MARK: Patch Functions

    private var patchView: some View {
        List {
            Section {
                Text("Disassemble a function (Disassemble ARM64), then NOP or RET its entry to neutralize it. Patches apply to the binary at sign time.")
                    .font(.caption).foregroundStyle(Theme.subtle)
            }.listRowBackground(Color(white: 0.08))
            Section {
                HStack {
                    TextField("Entry VA e.g. 0x100004abc", text: $disasmVA)
                        .font(.system(size: 13, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Button { Task { await patchFunc(ret: false) } } label: { Label("NOP first instruction", systemImage: "scissors") }.foregroundStyle(blue)
                Button { Task { await patchFunc(ret: true) } } label: { Label("RET first instruction (return early)", systemImage: "arrow.uturn.backward") }.foregroundStyle(blue)
            }.listRowBackground(Color(white: 0.08))
            if !patches.isEmpty {
                Section("Pending patches (\(patches.count))") {
                    ForEach(patches) { p in
                        HStack {
                            Text(p.label).font(.system(size: 12)).foregroundStyle(Theme.text)
                            Spacer()
                            Button { patches.removeAll { $0.id == p.id } } label: { Image(systemName: "trash").foregroundStyle(.red) }
                        }
                    }
                }.listRowBackground(Color(white: 0.08))
            }
        }
        .scrollContentBackground(.hidden).background(Color.black)
    }

    // MARK: Inject Data (Mcrypted-512)

    @State private var showInjectPicker = false
    @State private var injectWords: [String] = []       // active recovery key (24 words, 256-bit)
    @State private var injectEntropy: Data? = nil
    @State private var showKeyScreen = false
    @State private var enterWords = ""                  // paste box for an existing key
    @State private var injectStatus: String?
    @State private var injectError: String?
    @State private var extracted: (name: String, data: Data)?
    @State private var showExtractShare = false

    private var injectDataView: some View {
        List {
            Section {
                Text("Hide a picture or document inside the app binary. It's encrypted with Mcrypted-512 (AES-256-GCM + HMAC-SHA-512) using a 24-word (256-bit) recovery key and appended to the main Mach-O before signing, so it rides inside the signed app.")
                    .font(.caption).foregroundStyle(Theme.subtle)
            }.listRowBackground(Color(white: 0.08))

            Section("Recovery key") {
                if injectWords.isEmpty {
                    Button { generateKey() } label: { Label("Generate new 12-word key", systemImage: "key.horizontal.fill") }
                    NavigationLink { enterKeyView } label: { Label("Enter an existing key", systemImage: "square.and.pencil") }
                } else {
                    Button { showKeyScreen = true } label: {
                        Label("View & verify key (\(injectWords.prefix(2).joined(separator: " "))…)", systemImage: "key.fill")
                    }
                    Button(role: .destructive) { injectWords = []; injectEntropy = nil; injectBlob = nil } label: {
                        Label("Clear key", systemImage: "trash")
                    }
                }
            }.listRowBackground(Color(white: 0.08))

            Section("Payload") {
                Button { injectError = nil; injectStatus = nil; showInjectPicker = true } label: {
                    Label(injectName.isEmpty ? "Choose file to hide" : injectName, systemImage: "doc.badge.plus")
                }
                Button { embedPayload() } label: {
                    Label(injectBlob == nil ? "Encrypt & stage for signing" : "Re-encrypt", systemImage: "lock.fill")
                }
                .disabled(injectName.isEmpty || injectEntropy == nil || pendingFile == nil)
                if injectBlob != nil {
                    HStack {
                        Label("Staged — embeds when you Sign IPA", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.caption)
                        Spacer()
                        Button { injectBlob = nil; injectStatus = nil } label: { Image(systemName: "trash").foregroundStyle(.red) }
                    }
                }
                if let injectStatus { Text(injectStatus).font(.caption).foregroundStyle(.green) }
                if let injectError { Text(injectError).font(.caption).foregroundStyle(.orange) }
            }.listRowBackground(Color(white: 0.08))

            Section("Recover from this IPA") {
                Text(injectWords.isEmpty ? "Enter or generate a key above, then extract." : "Uses the key above.")
                    .font(.caption).foregroundStyle(Theme.subtle)
                Button { Task { await extractPayload() } } label: { Label("Extract hidden payload", systemImage: "lock.open.fill") }
                    .disabled(injectEntropy == nil)
                NavigationLink { McryptedRecoverView(embeddedInSheet: true) } label: {
                    Label("Recover from another IPA…", systemImage: "app.badge")
                }
                if let extracted {
                    HStack {
                        Label("\(extracted.name) · \(ByteCountFormatter.string(fromByteCount: Int64(extracted.data.count), countStyle: .file))", systemImage: "doc.fill")
                            .font(.caption).foregroundStyle(Theme.text)
                        Spacer()
                        Button { showExtractShare = true } label: { Image(systemName: "square.and.arrow.up").foregroundStyle(blue) }
                    }
                }
            }.listRowBackground(Color(white: 0.08))
        }
        .scrollContentBackground(.hidden).background(Color.black)
        .sheet(isPresented: $showInjectPicker) {
            DocPicker(types: [.item]) { urls in
                guard let u = urls.first else { return }
                let scoped = u.startAccessingSecurityScopedResource()
                defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                if let d = try? Data(contentsOf: u) { pendingFile = d; injectName = u.lastPathComponent }
            }
        }
        .sheet(isPresented: $showKeyScreen) {
            McryptedKeyScreen(words: injectWords) { showKeyScreen = false }
                .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showExtractShare) {
            if let e = extracted {
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(e.name)
                let _ = try? e.data.write(to: tmp)
                ShareSheet(items: [tmp])
            }
        }
    }

    private var enterKeyView: some View {
        List {
            Section("Enter your 24 words") {
                TextField("word1 word2 … word24", text: $enterWords, axis: .vertical)
                    .font(.system(size: 14, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Use this key") {
                    let ws = enterWords.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
                    if let e = Mcrypted512.entropy(fromWords: ws) {
                        injectWords = ws; injectEntropy = e; injectError = nil
                    } else { injectError = "Invalid key — need 24 valid words." }
                }
                .disabled(enterWords.split(separator: " ").count < 24)
                if let injectError { Text(injectError).font(.caption).foregroundStyle(.orange) }
            }.listRowBackground(Color(white: 0.08))
        }
        .scrollContentBackground(.hidden).background(Color.black)
        .navigationTitle("Enter Key").navigationBarTitleDisplayMode(.inline)
    }

    @State private var pendingFile: Data?

    private func generateKey() {
        let (w, e) = Mcrypted512.newRecoveryKey()
        injectWords = w; injectEntropy = e; injectBlob = nil
        showKeyScreen = true
    }

    private func embedPayload() {
        injectError = nil; injectStatus = nil
        guard let file = pendingFile else { injectError = "Pick a file first."; return }
        guard let e = injectEntropy else { injectError = "Generate or enter a key first."; return }
        do {
            let blob = try Mcrypted512.makeBlob(payload: file, filename: injectName, entropy: e)
            injectBlob = blob
            injectStatus = "Encrypted \(ByteCountFormatter.string(fromByteCount: Int64(file.count), countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: Int64(blob.count), countStyle: .file)) blob."
        } catch { injectError = error.localizedDescription }
    }

    private func extractPayload() async {
        injectError = nil; extracted = nil
        guard let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil) else {
            injectError = "Couldn't read the binary."; return
        }
        // Search the FULL (fat) binary bytes for the payload — it lives past the code.
        guard let full = await LocalBinaryScanner.mcryptedPayload(ipaURL: ipaURL) else {
            injectError = "Couldn't read the binary."; return
        }
        guard let e = injectEntropy else { injectError = "Enter or generate the key first."; return }
        do {
            let r = try Mcrypted512.extract(fromBinary: full, entropy: e)
            extracted = (name: r.filename, data: r.payload)
        } catch { injectError = error.localizedDescription }
        _ = ctx
    }


    // MARK: Engine calls

    private func runScan() async {
        loading = true
        if let r = await LocalBinaryScanner.scan(ipaURL: ipaURL, localPath: nil) { hits = r.hits }
        loading = false
    }

    private func disassembleAt() async {
        guard let va = UInt64(disasmVA.replacingOccurrences(of: "0x", with: ""), radix: 16),
              let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil) else { disasm = []; return }
        disasm = AVXDisassembler.disassemble(atVA: va, count: 96, thin: ctx.thin, segments: ctx.segments)
    }

    private func openPseudocode() {
        guard cfgFunction != nil else {
            cfgStatus = "Open CFG Viewer once to build the annotated function."
            return
        }
        showPseudocodeViewer = true
    }

    private func openDisassemblerBrowser() async {
        if cfgFunction != nil {
            showDisassemblerBrowser = true
            return
        }
        cfgStatus = "Loading annotated ARM64 disassembly…"
        guard let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil),
              let text = MachOTools.textSection(ctx.sections, in: ctx.thin) else {
            cfgStatus = "Unable to locate the __TEXT,__text section."
            return
        }
        let requestedVA = UInt64(disasmVA.replacingOccurrences(of: "0x", with: ""), radix: 16)
        let startVA = requestedVA.map { va in
            va >= text.vmaddr && va < text.vmaddr + UInt64(text.data.count) ? va : text.vmaddr
        } ?? text.vmaddr
        let delta = Int(startVA - text.vmaddr)
        let maxBytes = min(64 * 1024, max(0, text.data.count - delta))
        guard maxBytes >= 4 else {
            cfgStatus = "Not enough executable bytes for disassembly."
            return
        }
        let window = text.data.subdata(in: delta ..< delta + maxBytes)
        guard let result = UCDisassembler.sharedInstance().disassembleData(window, baseAddress: startVA),
              !result.instructions.isEmpty else {
            cfgStatus = "Capstone could not decode this ARM64 region."
            return
        }
        let blocks = UCDisassembler.sharedInstance().buildCFG(result.instructions) ?? []
        let function = UCFunction()
        function.startAddress = startVA
        function.endAddress = result.instructions.last.map { $0.address + UInt64($0.size) } ?? startVA
        function.size = UInt(function.endAddress - function.startAddress)
        function.boundaryIsBounded = true
        function.name = disasmVA.isEmpty ? "__text @ \(String(format: "0x%llx", startVA))" : "Disassembly @ \(disasmVA)"
        function.instructions = result.instructions
        function.basicBlocks = blocks
        function.basicBlockCount = UInt(blocks.count)
        cfgFunction = function
        cfgStatus = "Capstone · \(result.instructions.count) instructions · \(blocks.count) blocks · bounded analysis window · annotations enabled"
        showDisassemblerBrowser = true
    }

    private func openLocalCFG() async {
        cfgStatus = "Loading ARM64 text with Capstone…"
        guard let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil),
              let text = MachOTools.textSection(ctx.sections, in: ctx.thin) else {
            cfgStatus = "Unable to locate the __TEXT,__text section."
            return
        }
        let requestedVA = UInt64(disasmVA.replacingOccurrences(of: "0x", with: ""), radix: 16)
        let startVA = requestedVA.map { va in
            va >= text.vmaddr && va < text.vmaddr + UInt64(text.data.count) ? va : text.vmaddr
        } ?? text.vmaddr
        let delta = Int(startVA - text.vmaddr)

        // Bound the decode window to the real function this address belongs to — the
        // next real LC_FUNCTION_STARTS entry after it — so picking a function shows
        // exactly that function's own section of the graph, not a wall of whatever
        // unrelated code happens to sit after it in memory. Falls back to a flat 64KB
        // safety cap only when no function table is available (functionIndex empty).
        let bounds = functionBounds(containing: startVA)
        let cap = bounds.map { Int($0.end - startVA) } ?? (64 * 1024)
        let maxBytes = min(max(cap, 4), min(64 * 1024, max(0, text.data.count - delta)))
        guard maxBytes >= 4 else {
            cfgStatus = "Not enough executable bytes for CFG analysis."
            return
        }
        let window = text.data.subdata(in: delta ..< delta + maxBytes)
        guard let result = UCDisassembler.sharedInstance().disassembleData(window, baseAddress: startVA),
              !result.instructions.isEmpty else {
            cfgStatus = "Capstone could not decode this ARM64 region."
            return
        }
        // disassembleData: already runs the shared annotation pass, so the
        // function and its CFG blocks inherit those exact annotated objects.
        let blocks = UCDisassembler.sharedInstance().buildCFG(result.instructions) ?? []
        guard !blocks.isEmpty else {
            cfgStatus = "No control-flow blocks were produced."
            return
        }
        let function = UCFunction()
        function.startAddress = startVA
        function.endAddress = result.instructions.last.map { $0.address + UInt64($0.size) } ?? startVA
        function.size = UInt(function.endAddress - function.startAddress)
        function.boundaryIsBounded = true
        if let b = bounds, b.start == startVA {
            function.name = b.name
        } else if let b = bounds {
            function.name = String(format: "%@+0x%llx", b.name, startVA - b.start)
        } else {
            function.name = disasmVA.isEmpty ? "__text CFG" : "CFG @ \(disasmVA)"
        }
        function.instructions = result.instructions
        function.basicBlocks = blocks
        function.basicBlockCount = UInt(blocks.count)
        cfgFunction = function
        let refs = references(for: result.instructions, thin: ctx.thin, sections: ctx.sections, segments: ctx.segments)
        cfgRefStrings = refs.strings
        cfgRefSelectors = refs.selectors
        cfgRefClasses = refs.classes
        cfgStatus = "Capstone · \(blocks.count) blocks · \(result.instructions.count) instructions · bounded analysis window"
        showCFGViewer = true
        if autoShowInfoOnLoad {
            autoShowInfoOnLoad = false
            showFunctionInfo = true
            Task { await loadCallers(of: function.startAddress) }
        }
    }

    private func patchFunc(ret: Bool) async {
        guard let va = UInt64(disasmVA.replacingOccurrences(of: "0x", with: ""), radix: 16) else { return }
        await preparePatchPreview(va: va, ret: ret)
    }

    /// Builds a real preview of what a NOP/RET patch at `va` would do —
    /// decoding the actual current bytes at that exact file offset (fresh
    /// Capstone decode, not assumed) so the original instruction shown is
    /// the real one sitting there right now, not a label. Nothing is queued
    /// here; `commitPatch` does that only after the user confirms.
    private func preparePatchPreview(va: UInt64, ret: Bool) async {
        guard let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil),
              let off = MachOTools.fileOffset(forVA: va, segments: ctx.segments) else {
            cfgStatus = "Could not resolve a file offset for 0x\(String(va, radix: 16))."
            return
        }
        guard off + 4 <= ctx.thin.count else {
            cfgStatus = "That address falls outside the binary's mapped bytes."
            return
        }
        let origBytes = Array(ctx.thin[off ..< off + 4])
        // NOP = 0x1F2003D5 (little-endian D503201F), RET = 0xC0035FD6.
        let newBytes: [UInt8] = ret ? [0xC0, 0x03, 0x5F, 0xD6] : [0x1F, 0x20, 0x03, 0xD5]
        let origText = decodeInstructionText(origBytes, at: va) ?? "(could not decode — raw bytes shown below)"
        let newText = decodeInstructionText(newBytes, at: va) ?? (ret ? "ret" : "nop")
        patchPreview = PatchPreview(va: va, fileOffset: off, ret: ret, originalBytes: origBytes, originalText: origText, newBytes: newBytes, newText: newText)
    }

    /// Fresh single-instruction Capstone decode of a raw 4-byte buffer at a
    /// given VA — shared by the single and batch patch-preview builders so
    /// the "original"/"replacement" text shown is always a real decode, not
    /// a label, in both flows.
    private func decodeInstructionText(_ bytes: [UInt8], at va: UInt64) -> String? {
        guard let result = UCDisassembler.sharedInstance().disassembleData(Data(bytes), baseAddress: va),
              let first = result.instructions.first else { return nil }
        return first.fullText
    }

    /// Actually queues the patch the user just confirmed in the preview sheet
    /// — identical write `patchAt` used to do immediately, just moved behind
    /// the confirm step so nothing lands in `patches` unseen.
    private func commitPatch(_ p: PatchPreview) {
        let label = "\(p.ret ? "RET" : "NOP") @ \(String(format: "0x%llx", p.va))"
        let patch = BinaryPatch(label: label, fileOffset: p.fileOffset, bytes: p.newBytes, original: p.originalBytes)
        patches.removeAll { $0.fileOffset == p.fileOffset }
        patches.append(patch)
        patchPreview = nil
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: Batch patch preview — e.g. every real caller of a function, reviewed together

    /// Builds one `PatchPreview` per real address in `callSites` — same real
    /// decode (original bytes + a fresh Capstone pass) as the single-patch
    /// flow, just gathered into one confirm screen. Only NOPs call sites
    /// (overwriting the `bl` itself, not the callee) — a real limitation
    /// worth stating plainly: if the call's result is used afterward (a
    /// non-void return consumed by later code), NOPing it leaves that
    /// register's old/garbage value in place, which can misbehave. This
    /// builds the preview only; nothing is queued until confirmed.
    private func prepareBatchPatch(callSites: [UInt64], title: String) async {
        guard let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil) else {
            cfgStatus = "Could not open the binary to build patch previews."
            return
        }
        var items: [PatchPreview] = []
        for va in callSites {
            guard let off = MachOTools.fileOffset(forVA: va, segments: ctx.segments), off + 4 <= ctx.thin.count else { continue }
            let origBytes = Array(ctx.thin[off ..< off + 4])
            let newBytes: [UInt8] = [0x1F, 0x20, 0x03, 0xD5]   // NOP
            let origText = decodeInstructionText(origBytes, at: va) ?? "(could not decode — raw bytes shown below)"
            let newText = decodeInstructionText(newBytes, at: va) ?? "nop"
            items.append(PatchPreview(va: va, fileOffset: off, ret: false, originalBytes: origBytes, originalText: origText, newBytes: newBytes, newText: newText))
        }
        guard !items.isEmpty else {
            cfgStatus = "None of those call sites resolved to a patchable file offset."
            return
        }
        batchPatchPreview = BatchPatchPreview(title: title, items: items)
    }

    /// Queues every item in a confirmed batch — same single write `commitPatch`
    /// does, just looped, so every site lands in `patches` individually and
    /// can still be removed one at a time from the Pending patches list.
    private func commitBatchPatch(_ b: BatchPatchPreview) {
        for p in b.items {
            let label = "\(p.ret ? "RET" : "NOP") @ \(String(format: "0x%llx", p.va))"
            let patch = BinaryPatch(label: label, fileOffset: p.fileOffset, bytes: p.newBytes, original: p.originalBytes)
            patches.removeAll { $0.fileOffset == p.fileOffset }
            patches.append(patch)
        }
        batchPatchPreview = nil
    }

    private func batchPatchPreviewSheet(_ b: BatchPatchPreview) -> some View {
        NavigationStack {
            List {
                Section {
                    ForEach(b.items) { (p: PatchPreview) in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(String(format: "0x%llx", p.va)).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                            Text("was: \(p.originalText)  [\(hex(p.originalBytes))]").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.subtle).lineLimit(1)
                            Text("new: \(p.newText)  [\(hex(p.newBytes))]").font(.system(size: 10, design: .monospaced)).foregroundStyle(.orange).lineLimit(1)
                        }
                    }
                } header: {
                    Text(b.title)
                } footer: {
                    Text("Each row is the exact real instruction currently at that file offset, and the exact 4 bytes that would overwrite it. NOPing a call site that feeds its return value into later code can misbehave — review before queuing.")
                }.listRowBackground(Color(white: 0.08))

                Section {
                    Button(role: .destructive) { batchPatchPreview = nil } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                    Button { commitBatchPatch(b) } label: {
                        Label("Queue All \(b.items.count) Patches", systemImage: "checkmark.seal")
                    }.foregroundStyle(blue)
                }.listRowBackground(Color(white: 0.08))
            }
            .scrollContentBackground(.hidden).background(Color.black)
            .navigationTitle("Verify Batch Patch").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { batchPatchPreview = nil } } }
        }
        .preferredColorScheme(.dark)
    }

    private var patchPreviewSheet: some View {
        Group {
            if let p = patchPreview {
                patchPreviewDetail(p)
            } else {
                EmptyView()
            }
        }
    }

    /// Split out of `patchPreviewSheet` so the view-builder expression stays
    /// small enough for the type checker — a single giant `NavigationStack`
    /// with four inline `Section`s here previously caused "unable to
    /// type-check this expression in reasonable time" in CI.
    private func patchPreviewDetail(_ p: PatchPreview) -> some View {
        NavigationStack {
            List {
                Section {
                    Text(String(format: "0x%llx", p.va)).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                    Text("File offset \(p.fileOffset) (0x\(String(p.fileOffset, radix: 16)))").font(.caption).foregroundStyle(Theme.subtle)
                } header: {
                    Text("Address")
                }.listRowBackground(Color(white: 0.08))

                Section {
                    Text(p.originalText).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.text)
                    Text(hex(p.originalBytes)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.subtle)
                } header: {
                    Text("Original instruction — real bytes currently on disk")
                }.listRowBackground(Color(white: 0.08))

                Section {
                    Text(p.newText).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(.orange)
                    Text(hex(p.newBytes)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.subtle)
                } header: {
                    Text("Proposed replacement")
                } footer: {
                    Text("Queuing writes these exact 4 bytes over the original at the file offset above. The patch doesn't touch the binary until you sign — you can still remove it from the Pending patches list before then.")
                }.listRowBackground(Color(white: 0.08))

                Section {
                    Button(role: .destructive) { patchPreview = nil } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                    Button { commitPatch(p) } label: {
                        Label("Queue Patch", systemImage: "checkmark.seal")
                    }.foregroundStyle(blue)
                }.listRowBackground(Color(white: 0.08))
            }
            .scrollContentBackground(.hidden).background(Color.black)
            .navigationTitle("Verify Patch").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { patchPreview = nil } } }
        }
        .preferredColorScheme(.dark)
    }
}

private struct CFGViewerController: UIViewControllerRepresentable {
    let function: UCFunction

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = UCDisasmViewController(function: function, title: function.name)
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

/// One expandable row of the interactive call graph, recursing into its own
/// children (depth-capped at 3) for whichever direction — callees or callers
/// — it was placed in. The row's label is a plain `Button` (tap → jump to
/// that function's CFG); the disclosure chevron is a separate gesture target
/// that lazily triggers the real scan for this node's own children the first
/// time it's opened, so nothing past the root is computed until asked for.
private struct CallGraphTree: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @ObservedObject var node: DeveloperToolSheet.CallGraphNode
    let direction: DeveloperToolSheet.CallGraphDirection
    let blue: Color
    let onExpand: (DeveloperToolSheet.CallGraphNode) -> Void
    let onJump: (UInt64, DeveloperToolSheet.CallGraphEdgeKind) -> Void

    @State private var expanded = false

    private var children: [DeveloperToolSheet.CallGraphNode] { direction == .callees ? node.callees : node.callers }
    private var loaded: Bool { direction == .callees ? node.calleesLoaded : node.callersLoaded }
    private var loading: Bool { direction == .callees ? node.isLoadingCallees : node.isLoadingCallers }
    private var canExpand: Bool { node.depth < 3 && (node.kind == .direct || node.kind == .root) }

    var body: some View {
        if node.depth == 0 || canExpand {
            DisclosureGroup(isExpanded: Binding(
                get: { expanded || node.depth == 0 },
                set: { newValue in
                    expanded = newValue
                    if newValue, !loaded, !loading { onExpand(node) }
                }
            )) {
                if loading {
                    HStack { ProgressView().tint(blue); Text("Scanning real \(direction == .callees ? "callees" : "callers")…").font(.caption).foregroundStyle(Theme.subtle) }
                } else if loaded && children.isEmpty {
                    Text(direction == .callees ? "Calls nothing further in this window." : "Nothing in-module calls this directly.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                } else {
                    ForEach(children) { child in
                        CallGraphTree(node: child, direction: direction, blue: blue, onExpand: onExpand, onJump: onJump)
                    }
                }
            } label: {
                row
            }
        } else {
            row
        }
    }

    private var row: some View {
        Button { onJump(node.address, node.kind) } label: {
            HStack(spacing: 8) {
                Circle().fill(color(for: node.kind)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name)
                        .font(.system(size: 12, weight: node.depth == 0 ? .bold : .regular, design: .monospaced))
                        .foregroundStyle(Theme.text).lineLimit(1)
                    Text(String(format: "0x%llx", node.address)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.subtle)
                }
                Spacer()
                if node.kind == .direct || node.kind == .root {
                    Image(systemName: "arrow.forward.circle").foregroundStyle(blue).font(.caption)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func color(for kind: DeveloperToolSheet.CallGraphEdgeKind) -> Color {
        switch kind {
        case .root: return .blue
        case .direct: return .green
        case .imported: return .purple
        case .external: return .orange
        case .indirect: return .red
        }
    }
}

private struct AnalysisCenterController: UIViewControllerRepresentable {
    let function: UCFunction
    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: UCAnalysisCenterViewController(function: function))
    }
    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

private struct PseudocodeViewerController: UIViewControllerRepresentable {
    let function: UCFunction

    func makeUIViewController(context: Context) -> UINavigationController {
        let text = UCPseudocodeViewController.pseudocode(for: function)
        let vc = UCPseudocodeViewController(pseudocode: text, title: "Pseudocode")
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

private struct DisassemblerBrowserController: UIViewControllerRepresentable {
    let function: UCFunction

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = UCDisassemblerBrowserViewController(function: function, title: "Disassembler")
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}
}

/// Adds a search bar to the Strings tool only.
private struct StringSearchable: ViewModifier {
    let mode: DeveloperToolSheet.Mode
    @Binding var text: String
    func body(content: Content) -> some View {
        if mode == .strings { content.searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search strings") }
        else { content }
    }
}

// MARK: - Mcrypted recovery-key screen (12-word grid + verify challenge)

struct McryptedKeyScreen: View {
    let words: [String]
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var verifying = false
    @State private var challenge: [Int] = []        // 1-based positions to confirm
    @State private var answers: [Int: String] = [:]
    @State private var verifyResult: Bool?

    private let navy = Color(red: 0.11, green: 0.16, blue: 0.29)
    private let cell = Color(red: 0.20, green: 0.26, blue: 0.42)

    var body: some View {
        NavigationStack {
            Group { if verifying { verifyView } else { showView } }
                .background(Color(red: 0.07, green: 0.11, blue: 0.22).ignoresSafeArea())
                .navigationTitle("Mcrypted Key").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Done") { onDone(); dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { UIPasteboard.general.string = words.joined(separator: " ") } label: { Image(systemName: "doc.on.doc") }
                    }
                }
        }
    }

    private var showView: some View {
        ScrollView {
            VStack(spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34)).foregroundStyle(.white)
                    Text("Save these words in a secure place! You need them to decrypt your files if you lose this device. Anyone with this key can decrypt your payloads.")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                }
                .padding(16)
                .background(Color(red: 0.62, green: 0.44, blue: 0.05))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange, lineWidth: 2))
                .clipShape(RoundedRectangle(cornerRadius: 14))

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                        HStack(spacing: 8) {
                            Text("\(i+1)").font(.system(size: 15, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                            Text(w).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 14)
                        .background(cell).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }

                Button {
                    startChallenge()
                } label: {
                    Text("Verify Key").font(.system(size: 17, weight: .bold)).foregroundStyle(Color(red: 0.07, green: 0.11, blue: 0.22))
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(Color(red: 0.62, green: 0.71, blue: 0.98)).clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
    }

    private var verifyView: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Enter words \(challenge.map { "#\($0)" }.joined(separator: ", "))")
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(challenge, id: \.self) { pos in
                    HStack(spacing: 12) {
                        Text("#\(pos)").font(.system(size: 16, weight: .bold)).foregroundStyle(.white.opacity(0.6)).frame(width: 44, alignment: .leading)
                        TextField("word", text: Binding(get: { answers[pos] ?? "" }, set: { answers[pos] = $0 }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.system(size: 16, design: .monospaced)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 12)
                            .background(cell).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }

                if let verifyResult {
                    Text(verifyResult ? "✓ Key verified — you've backed it up correctly." : "✗ Doesn't match. Check the words and try again.")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(verifyResult ? .green : .orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Button { verifying = false; verifyResult = nil } label: {
                        Text("Back").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 14).background(cell).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    Button { checkChallenge() } label: {
                        Text("Check").font(.system(size: 16, weight: .bold)).foregroundStyle(Color(red: 0.07, green: 0.11, blue: 0.22))
                            .frame(maxWidth: .infinity).padding(.vertical, 14).background(Color(red: 0.62, green: 0.71, blue: 0.98)).clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding(.top, 6)
            }
            .padding(20)
        }
    }

    private func startChallenge() {
        // 3 random distinct positions, presented in random order.
        challenge = Array(1...words.count).shuffled().prefix(3).shuffled()
        answers = [:]; verifyResult = nil; verifying = true
    }

    private func checkChallenge() {
        let ok = challenge.allSatisfy { pos in
            (answers[pos] ?? "").lowercased().trimmingCharacters(in: .whitespaces) == words[pos - 1]
        }
        verifyResult = ok
        if ok { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }
}

// MARK: - In-place string editor (length-guarded)

struct StringEditSheet: View {
    let hit: AVXScanHit
    let blue: Color
    let onSave: (BinaryPatch) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(hit: AVXScanHit, blue: Color, onSave: @escaping (BinaryPatch) -> Void) {
        self.hit = hit; self.blue = blue; self.onSave = onSave
        _text = State(initialValue: hit.string)
    }

    private var capacity: Int { hit.string.utf8.count }           // must fit in original byte length
    private var fits: Bool { text.utf8.count <= capacity }
    private var offset: Int { Int(hit.address.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? -1 }

    var body: some View {
        NavigationStack {
            List {
                Section("Original") { Text(hit.string).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.subtle) }
                    .listRowBackground(Color(white: 0.08))
                Section("Replacement") {
                    TextField("New string", text: $text, axis: .vertical)
                        .font(.system(size: 14)).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text(fits ? "Fits in-place (\(text.utf8.count)/\(capacity) bytes)"
                              : "Too long — must be ≤ \(capacity) bytes (\(text.utf8.count) now)")
                        .font(.caption).foregroundStyle(fits ? .green : .orange)
                }.listRowBackground(Color(white: 0.08))
            }
            .scrollContentBackground(.hidden).background(Color.black)
            .navigationTitle("Edit String").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        // NUL-terminate + pad to the original byte length so surrounding data is preserved.
                        var b = Array(text.utf8)
                        b.append(0)
                        while b.count < capacity + 1 { b.append(0) }
                        let orig = Array(hit.string.utf8) + [0]
                        onSave(BinaryPatch(label: "str \(hit.address): \"\(text.prefix(20))\"", fileOffset: offset, bytes: b, original: orig))
                        dismiss()
                    }.disabled(!fits).foregroundStyle(fits ? blue : Theme.subtle)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}


private struct KeyValueEditorList: View {
    let title: String
    @Binding var values: [String: String]
    let addLabel: String
    var onRemoveKey: ((String) -> Void)? = nil

    @State private var newKey = ""
    @State private var newValue = "true"

    private var sortedKeys: [String] { values.keys.sorted() }

    var body: some View {
        List {
            ForEach(sortedKeys, id: \.self) { key in
                VStack(alignment: .leading, spacing: 6) {
                    Text(key).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(0.75))
                    TextField("Value", text: Binding(
                        get: { values[key] ?? "" },
                        set: { values[key] = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15))
                }
                .padding(.vertical, 6)
                .listRowBackground(Color(white: 0.08))
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        values.removeValue(forKey: key)
                        onRemoveKey?(key)
                    } label: { Label("Remove", systemImage: "minus.circle.fill") }
                }
            }

            Section {
                VStack(spacing: 8) {
                    TextField("Key", text: $newKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Value", text: $newValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        let k = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !k.isEmpty else { return }
                        values[k] = newValue
                        newKey = ""
                        newValue = "true"
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill").foregroundStyle(.green)
                            Text(addLabel)
                            Spacer()
                        }
                    }
                }
                .font(.system(size: 15))
                .padding(.vertical, 8)
            }
            .listRowBackground(Color(white: 0.08))
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
    }
}


// MARK: - Turbo local bulk signer

private struct TurboBulkSigningView: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    let defaultOptions: SignOptions
    @Environment(\.dismiss) private var dismiss
    @State private var showPicker = false
    @State private var files: [URL] = []
    @State private var running = false
    @State private var completed = 0
    @State private var results: [BulkSignResult] = []
    @State private var log: [String] = []
    @State private var error: String?

    private var succeeded: Int { results.filter { if case .success = $0.outcome { return true }; return false }.count }
    private var failed: Int { results.filter { if case .failure = $0.outcome { return true }; return false }.count }
    private var totalTime: Double { results.reduce(0) { $0 + $1.elapsedSeconds } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    Text("ZSign Turbo")
                        .font(.title2.bold())
                    Text("Local bulk signing · adaptive workers · per-job parallelism")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 10)

                HStack(spacing: 10) {
                    metric("Queued", "\(files.count)")
                    metric("Done", "\(completed)")
                    metric("Failed", "\(failed)")
                    metric("Workers", "\(Signer.recommendedBulkConcurrency(parallelSigning: defaultOptions.parallelSigning))")
                }

                Button {
                    showPicker = true
                } label: {
                    Label(files.isEmpty ? "Choose IPAs" : "Add IPAs", systemImage: "plus.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(running)

                if !files.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(files.enumerated()), id: \.offset) { index, url in
                                HStack {
                                    Image(systemName: "doc.zipper")
                                    Text(url.lastPathComponent).lineLimit(1)
                                    Spacer()
                                    Text("#\(index + 1)").font(.caption2.monospaced()).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                }

                if running {
                    ProgressView(value: Double(completed), total: Double(max(files.count, 1)))
                    Text("Signing \(completed) / \(files.count)…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !results.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Results").font(.headline)
                        Text("\(succeeded) succeeded · \(failed) failed · aggregate job time \(String(format: "%.2f", totalTime))s")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let error {
                    Text(error).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()

                Button {
                    start()
                } label: {
                    Label(running ? "Signing…" : "Sign All Locally", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(files.isEmpty || running)
            }
            .padding(16)
            .navigationTitle("Bulk Sign")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .disabled(running)
                }
            }
            .sheet(isPresented: $showPicker) {
                DocPicker(types: [UTType(filenameExtension: "ipa") ?? .data]) { urls in
                    let incoming = urls.filter { $0.pathExtension.lowercased() == "ipa" }
                    let existing = Set(files.map(\.standardizedFileURL))
                    files.append(contentsOf: incoming.filter { !existing.contains($0.standardizedFileURL) })
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func start() {
        guard !running else { return }
        guard let material = try? CertificateStore.shared.activeMaterial() else {
            error = "No active certificate."
            return
        }
        running = true
        completed = 0
        results = []
        error = nil
        var options = defaultOptions
        options.parallelSigning = true
        let batchFiles = files
        WidgetDataManager.shared.setBulkState(running: batchFiles.count, failed: 0)

        Task.detached(priority: .userInitiated) {
            let batch = await Signer.signBatch(
                ipaURLs: batchFiles,
                material: material,
                options: options,
                onProgress: { done, _, _ in
                    Task { @MainActor in
                        completed = done
                        WidgetDataManager.shared.setBulkState(running: max(0, batchFiles.count - done), failed: 0)
                    }
                },
                onLog: { line in
                    Task { @MainActor in log.append(line) }
                }
            )
            await MainActor.run {
                results = batch.sorted { $0.index < $1.index }
                completed = batch.count
                running = false
                let failureCount = batch.reduce(0) { partial, result in
                    switch result.outcome {
                    case .success: return partial
                    case .failure: return partial + 1
                    }
                }
                WidgetDataManager.shared.setBulkState(running: 0, failed: failureCount)
            }
        }
    }
}

struct DocPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        p.allowsMultipleSelection = true
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coord { Coord(onPick: onPick) }

    final class Coord: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls) }
    }
}

// MARK: - Signing terminal (AirShare-style full-screen zsign log)

struct SigningTerminalView: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    let appName: String
    let bundle: String
    let icon: Data?
    @Binding var lines: [String]
    @Binding var done: Bool
    let result: SignedEntry?
    let error: String?
    var certName: String = ""
    var sizeBefore: Int64 = 0
    var sizeAfter: Int64 = 0
    var onInstall: (SignedEntry) -> Void
    var onExit: () -> Void

    @State private var lineTimes: [Date] = []
    @State private var showAll = false
    @State private var lastStepCount = 0

    private var accent: Color { Theme.accent }
    private var blue: Color { Theme.accent }
    private let green = Color(red: 0.2, green: 1.0, blue: 0.45)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().overlay(Color.white.opacity(0.08))
                logScroll
                if done { bottomBar }
            }
        }
    }

    // Icon left · name+bundle centre · X right
    private var header: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                iconThumb(44)
                ZStack {
                    Circle().fill(Color.black).frame(width: 20, height: 20)
                    if done {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color(red: 0.2, green: 1.0, blue: 0.45))
                    } else {
                        ProgressView().tint(accent).scaleEffect(0.65)
                    }
                }
                .offset(x: 5, y: 5)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(appName).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                Text(bundle).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.40)).lineLimit(1)
            }
            Spacer()
            Button(action: onExit) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(.white.opacity(0.25))
            }
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
        .background(Color(white: 0.06))
    }

    private var logScroll: some View {
        ScrollViewReader { proxy in
            TimelineView(.periodic(from: .now, by: done ? 3600 : 0.25)) { tl in
                let now = tl.date
                let steps = AgentStepParser.parse(lines, times: lineTimes, error: error, finished: done)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Show all / collapse finished
                        HStack {
                            Spacer()
                            Button { withAnimation(.easeInOut(duration: 0.15)) { showAll.toggle() } } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: showAll ? "rectangle.compress.vertical" : "rectangle.expand.vertical").font(.system(size: 10, weight: .bold))
                                    Text(showAll ? "Collapse finished" : "Show all").font(.system(size: 11, weight: .bold))
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.white.opacity(0.06)).foregroundStyle(.white.opacity(0.7)).clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.bottom, 4)

                        ForEach(Array(steps.enumerated()), id: \.element.id) { i, st in
                            AgentStepRow(step: st, isActive: !done && i == steps.count - 1, forceExpanded: showAll || done && i == steps.count - 1, now: now)
                        }
                        if !done {
                            AgentWorkingRow(text: "AirShare is working…", since: lineTimes.first, now: now).padding(.top, 6)
                        } else if error == nil {
                            AgentStepRow(step: AgentStep(icon: "checkmark.circle", title: "Ready to install", kind: .done, startedAt: lineTimes.last, endedAt: lineTimes.last))
                            if NativeInstaller.isSelected, let result {
                                NativeInstallTile(entry: result).padding(.top, 14)
                            } else {
                                AgentSummaryCard(summary: summary(steps)).padding(.top, 10)
                            }
                        }
                        Color.clear.frame(height: done ? 100 : 24).id("BOTTOM")
                    }
                    .padding(.horizontal, 16).padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: steps.count) { n in
                    if n > lastStepCount, lastStepCount > 0 { UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6) }
                    lastStepCount = n
                }
            }
            .onAppear { syncTimes() }
            .onChange(of: lines.count) { _ in
                syncTimes()
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
            .onChange(of: done) { _ in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
        }
        .background(Color.black)
    }

    /// One timestamp per log line, recorded as lines arrive (drives per-step timings).
    private func syncTimes() {
        while lineTimes.count < lines.count { lineTimes.append(Date()) }
        if lineTimes.count > lines.count { lineTimes = Array(lineTimes.prefix(lines.count)) }
    }

    private func summary(_ steps: [AgentStep]) -> AgentSummary {
        let files = steps.filter { $0.title.hasPrefix("Sign ") && $0.title.hasSuffix("file") || $0.title.hasPrefix("Sign ") && $0.title.hasSuffix("files") }
            .reduce(0) { $0 + $1.children.count }
        let warnings = steps.first { $0.kind == .warn }?.children.count ?? 0
        let total = (lineTimes.first).map { (lineTimes.last ?? $0).timeIntervalSince($0) } ?? 0
        return AgentSummary(app: appName, bundle: bundle, version: result?.version ?? "—", cert: certName,
                            sizeBefore: sizeBefore, sizeAfter: sizeAfter, filesSigned: files + (steps.contains { $0.title == "Sign app bundle" } ? 1 : 0),
                            duration: total, warnings: warnings, mdid: StaffGate.shared.mdid)
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.10))
            HStack(spacing: 0) {
                Button {
                    if let r = result { UIActivityViewController.share(r.ipaURL) }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 26))
                        Text("Download").font(.system(size: 13, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(result == nil ? Color.white.opacity(0.35) : .white.opacity(0.9)).frame(maxWidth: .infinity)
                }
                .disabled(result == nil)

                VStack(spacing: 2) {
                    Text("MRZefV")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("Powered by DELvEK.NET")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity)

                Button {
                    guard let r = result else { return }
                    onInstall(r)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "signature").font(.system(size: 26))
                        Text(result == nil ? "Sign IPA" : "Install").font(.system(size: 13, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(result == nil ? Color.white.opacity(0.35) : .white.opacity(0.9)).frame(maxWidth: .infinity)
                }
                .disabled(result == nil)
            }
            .padding(.top, 12).padding(.bottom, 6)
            .background(Color(white: 0.06))
        }
    }

    private func iconThumb(_ side: CGFloat) -> some View {
        Group {
            if let icon, let img = UIImage(data: icon) { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: 10).fill(accent.opacity(0.15)).overlay(Image(systemName: "app.fill").foregroundStyle(accent)) }
        }
        .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
    }

}

struct TerminalCursor: View {
    let color: Color
    @State private var on = true
    var body: some View {
        Rectangle().fill(color).frame(width: 9, height: 15)
            .opacity(on ? 1 : 0)
            .onAppear { withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { on = false } }
    }
}

extension UIActivityViewController {
    static func share(_ url: URL) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.rootViewController }
            .first?.present(vc, animated: true)
    }
}

// MARK: - Install prompt (AirShare-style pre-install detail card)

struct InstallPromptOverlay: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    let name: String
    let bundle: String
    let version: String
    let sizeBytes: Int64
    let icon: Data?
    let source: String
    var mdid: String = ""
    var cert: String = ""
    let entitlements: [String: String]
    var onInstall: () -> Void
    var onCancel: () -> Void
    /// Only shown when non-nil — the caller passes this exactly when
    /// OTAInstaller.trollStoreAvailable detected TrollStore on-device.
    var onTrollStore: (() -> Void)? = nil

    @State private var showSandboxing = false
    @State private var showCapabilities = false
    @State private var showContainers = false
    @State private var copied = false

    private var accent: Color { Theme.accent }
    private var blue: Color { Theme.accent }

    private var sizeText: String { sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) : "—" }
    private var isUnsandboxed: Bool { entitlements["platform-application"] == "true" || entitlements["com.apple.security.app-sandbox"] == "false" }
    private var sandboxLabel: String { isUnsandboxed ? "Unsandboxed (platform-application active)" : "Standard iOS sandbox — app restricted to its container" }
    private var capabilityKeys: [String] {
        let skip: Set<String> = ["application-identifier", "com.apple.developer.team-identifier", "keychain-access-groups", "com.apple.security.application-groups", "platform-application", "get-task-allow"]
        return entitlements.keys.filter { !skip.contains($0) }.sorted().map {
            $0.replacingOccurrences(of: "com.apple.developer.", with: "")
              .replacingOccurrences(of: "com.apple.security.", with: "")
              .replacingOccurrences(of: "com.apple.", with: "")
        }
    }
    private var appGroups: [String] { (entitlements["com.apple.security.application-groups"] ?? "").components(separatedBy: ", ").filter { !$0.isEmpty } }
    private var keychainGroups: [String] { (entitlements["keychain-access-groups"] ?? "").components(separatedBy: ", ").filter { !$0.isEmpty } }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea().onTapGesture { onCancel() }
            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        header
                        Divider().overlay(Color.white.opacity(0.10))
                        info
                        section("Sandboxing", $showSandboxing) {
                            Text(sandboxLabel).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                        }
                        section("Capabilities", $showCapabilities) {
                            if capabilityKeys.isEmpty { Text("None").font(.caption).foregroundStyle(Theme.subtle) }
                            else { ForEach(capabilityKeys.prefix(40), id: \.self) { bullet($0) } }
                        }
                        section("Accessible Containers", $showContainers) {
                            if !appGroups.isEmpty {
                                Text("App Groups").font(.system(size: 12, weight: .bold)).foregroundStyle(blue)
                                ForEach(appGroups, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.7)) }
                            }
                            if !keychainGroups.isEmpty {
                                Text("Keychain Groups").font(.system(size: 12, weight: .bold)).foregroundStyle(blue).padding(.top, 6)
                                ForEach(keychainGroups, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.7)) }
                            }
                            if appGroups.isEmpty && keychainGroups.isEmpty { Text("None").font(.caption).foregroundStyle(Theme.subtle) }
                        }
                        Text("\(source) | ᴍʀZefv").font(.system(size: 12, weight: .semibold)).foregroundStyle(blue).padding(.vertical, 12)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: 460)
                if let onTrollStore {
                    Divider().overlay(Color.white.opacity(0.10))
                    Button(action: onTrollStore) {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill").font(.system(size: 13, weight: .bold))
                            Text("Install with TrollStore").font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.0))
                        .frame(maxWidth: .infinity, minHeight: 40)
                    }
                }
                Divider().overlay(Color.white.opacity(0.10))
                HStack(spacing: 0) {
                    Button(action: onCancel) { Text("Cancel").font(.system(size: 16)).foregroundStyle(blue).frame(maxWidth: .infinity, minHeight: 52) }
                    Rectangle().fill(Color.white.opacity(0.10)).frame(width: 1, height: 52)
                    Button(action: onInstall) { Text("Install").font(.system(size: 16, weight: .bold)).foregroundStyle(blue).frame(maxWidth: .infinity, minHeight: 52) }
                }
                .frame(height: 52)
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(white: 0.11)).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(maxWidth: 360)
            .padding(24)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            iconThumb(64)
            Text(name).font(.system(size: 16, weight: .bold)).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(2)
        }
        .padding(.top, 20).padding(.bottom, 12)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Bundle ID", bundle)
            row("Version", version)
            row("Size", sizeText)
            HStack(alignment: .top, spacing: 4) {
                Text("Partner:").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).frame(width: 72, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Reputable Repository").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.88))
                    Text(source).font(.system(size: 10, design: .monospaced)).foregroundStyle(accent.opacity(0.75))
                }
                Spacer()
                Button {
                    UIPasteboard.general.string = source
                    withAnimation { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { copied = false } }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 13))
                        .foregroundStyle(copied ? Color(red: 0.2, green: 1, blue: 0.45) : accent.opacity(0.65)).frame(width: 28, height: 28)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            if !mdid.isEmpty { row("ADID", mdid) }
            if !cert.isEmpty { row("Cert", cert) }
        }
        .padding(.vertical, 6)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(k + ":").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.5)).frame(width: 72, alignment: .leading)
            Text(v).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.9)).textSelection(.enabled)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }

    @ViewBuilder private func section<C: View>(_ title: String, _ open: Binding<Bool>, @ViewBuilder content: () -> C) -> some View {
        Divider().overlay(Color.white.opacity(0.08))
        Button { withAnimation { open.wrappedValue.toggle() } } label: {
            HStack {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.5)).rotationEffect(.degrees(open.wrappedValue ? 180 : 0))
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }.buttonStyle(.plain)
        if open.wrappedValue {
            VStack(alignment: .leading, spacing: 5) { content() }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(blue).frame(width: 6, height: 6).padding(.top, 6)
            Text(s).font(.system(size: 13, design: .monospaced)).foregroundStyle(.white.opacity(0.85)).lineLimit(1).truncationMode(.tail)
            Spacer()
        }
    }

    private func iconThumb(_ side: CGFloat) -> some View {
        Group {
            if let icon, let img = UIImage(data: icon) { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: 15).fill(accent.opacity(0.15)).overlay(Image(systemName: "app.fill").foregroundStyle(accent)) }
        }
        .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.08)))
    }
}

// MARK: - "Sent to Home Screen" success overlay (AirShare-style)

/// Native install status, drawn like an app installing on the Home Screen:
/// dimmed icon with a progress ring, app name, a progress bar, then "Sent to Home Screen".
struct NativeInstallTile: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    let entry: SignedEntry
    @ObservedObject private var installer = NativeInstaller.shared

    private var mine: Bool {
        guard let job = installer.job else { return false }
        return job.bundleID == entry.bundleID || job.name == entry.name
    }
    private var done: Bool { mine && installer.stage == .done }
    private var failed: String? { if mine, case .failed(let m) = installer.stage { return m }; return nil }
    private var fraction: Double { done ? 1 : (mine ? min(max(installer.progress, 0), 1) : 0) }
    private var status: String {
        if let failed { return failed }
        if done { return "Sent to Home Screen" }
        guard mine else { return "Preparing…" }
        switch installer.stage {
        case .packing: return "Preparing…"
        case .connecting: return "Connecting…"
        case .uploading: return "Sending…"
        case .installing: return "Installing…"
        default: return "Waiting…"
        }
    }
    private var icon: UIImage? { entry.iconURL.flatMap { UIImage(contentsOfFile: $0.path) } }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Group {
                    if let icon { Image(uiImage: icon).resizable().scaledToFill() }
                    else { RoundedRectangle(cornerRadius: 16).fill(Theme.accent.opacity(0.18)).overlay(Image(systemName: "app.fill").font(.system(size: 30)).foregroundStyle(Theme.accent)) }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                if !done && failed == nil {
                    RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Color.black.opacity(0.5)).frame(width: 76, height: 76)
                    Circle().stroke(Color.white.opacity(0.25), lineWidth: 4).frame(width: 34, height: 34)
                    Circle().trim(from: 0, to: max(0.04, fraction)).stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 34, height: 34).rotationEffect(.degrees(-90))
                }
                if done {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 24))
                        .foregroundStyle(Color(red: 0.2, green: 1.0, blue: 0.45), .black)
                        .background(Circle().fill(Color.black).frame(width: 22, height: 22))
                        .offset(x: 30, y: 30)
                }
            }
            .frame(width: 84, height: 84)
            Text(entry.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            if failed == nil {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(done ? Color(red: 0.2, green: 1.0, blue: 0.45) : Theme.accent)
                            .frame(width: g.size.width * fraction)
                    }
                }
                .frame(height: 5).padding(.horizontal, 40)
            }
            Text(status).font(.system(size: 14, weight: done ? .bold : .medium))
                .foregroundStyle(failed != nil ? Color.red : (done ? Color(red: 0.2, green: 1.0, blue: 0.45) : .white.opacity(0.7)))
                .multilineTextAlignment(.center)
            if !done && failed == nil {
                if BackgroundKeepAlive.enabled {
                    VStack(spacing: 4) {
                        Label("You can leave AirShare", systemImage: "checkmark.shield.fill")
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(Color(red: 0.2, green: 1.0, blue: 0.45))
                        Text("The install keeps going in the background and you'll get a notification when it's done.")
                            .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                    }
                    .padding(12).frame(maxWidth: .infinity)
                    .background(Color(red: 0.2, green: 1.0, blue: 0.45).opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 4)
                } else {
                VStack(spacing: 4) {
                    Label("Keep AirShare open", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(Color(red: 1, green: 0.8, blue: 0.3))
                    Text("Please stay on this screen until the app finishes installing. Leaving AirShare may interrupt the installation process.")
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                }
                .padding(12).frame(maxWidth: .infinity)
                .background(Color(red: 1, green: 0.8, blue: 0.3).opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20).padding(.horizontal, 16)
        .background(Color(white: 0.09)).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: fraction)
        .animation(.easeInOut(duration: 0.25), value: done)
    }
}

struct SentToHomeOverlay: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    let name: String
    let icon: Data?
    let host: String
    var title: String = "Sent to Home Screen"
    @State private var progress: CGFloat = 0

    private var blue: Color { Theme.accent }

    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    iconThumb(60)
                    ZStack {
                        Circle().fill(Color.black).frame(width: 22, height: 22)
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 20))
                            .foregroundStyle(Color(red: 0.2, green: 1.0, blue: 0.45))
                    }
                    .offset(x: 5, y: 5)
                }
                Text(name).font(.system(size: 13)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text(host).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color(white: 0.18)).clipShape(Capsule())
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12)).frame(height: 5)
                        Capsule().fill(blue).frame(width: g.size.width * progress, height: 5)
                    }
                }
                .frame(height: 5).padding(.horizontal, 20).padding(.top, 2)
            }
            .padding(.vertical, 20).padding(.horizontal, 22)
            .frame(maxWidth: 270)
            .background(Color(white: 0.11)).clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .onAppear { withAnimation(.easeInOut(duration: 2.4)) { progress = 1 } }
        }
    }

    private func iconThumb(_ side: CGFloat) -> some View {
        Group {
            if let icon, let img = UIImage(data: icon) { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: side * 0.22).fill(blue.opacity(0.15)).overlay(Image(systemName: "app.fill").foregroundStyle(blue)) }
        }
        .frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
    }
}
