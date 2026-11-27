//
// Brand: Tetherless · https://tetherless.dev
//  IPadnInstallationSettings.swift
//  English Installation Settings — iPadn InstallationSettingsView structure (GPL-2.0),
//  wired to TetherLess NativeInstaller / DeviceInstallationManager / OTA / certificates.
//

import SwiftUI
import UniformTypeIdentifiers

struct IPadnInstallationSettingsView: View {
    private enum Method: String, CaseIterable, Identifiable {
        case automatic, native, certificate, proxy
        var id: String { rawValue }
        var shortTitle: String {
            switch self {
            case .automatic: return "One-tap"
            case .native: return "Native"
            case .certificate: return "Certificate"
            case .proxy: return "Proxy"
            }
        }
    }

    @AppStorage(NativeInstaller.methodKey) private var methodKey = "ota"
    /// Persist the Installation settings segment (Certificate / Proxy are not install methods).
    @AppStorage("tetherless.installation.settings.segment") private var segmentKey = "automatic"
    @ObservedObject private var manager = DeviceInstallationManager.shared
    @ObservedObject private var certStore = CertificateStore.shared
    @ObservedObject private var appleID = AppleIDStore.shared
    @State private var selected: Method = .automatic
    @State private var issue: String?
    @State private var busy = false
    @State private var importingPairing = false
    @State private var checkMessage: String?
    @State private var ensuringAppleIDCert = false
    @State private var showCertificatesManager = false
    @State private var showPortalTwoFactor = false
    @State private var certStatus: String?

    var body: some View {
        Form {
            Section {
                Picker("Install method", selection: $selected) {
                    ForEach(Method.allCases) { m in
                        Text(m.shortTitle).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selected) { apply($0) }
            }

            switch selected {
            case .automatic:
                Section {
                    Label("No profile or certificate needed", systemImage: "checkmark.seal")
                    Label("The package never leaves this device", systemImage: "iphone")
                } header: {
                    Text("One-tap install (recommended)")
                } footer: {
                    Text("Uses TetherLess OTA (`*.tetherless.dev`). Stay in the app until install finishes.")
                }

            case .native:
                Section {
                    Label("The App Store recognizes and updates installed apps", systemImage: "checkmark.seal")
                    Label("Can replace App Store apps and keep their data", systemImage: "arrow.triangle.2.circlepath")
                    LabeledContent(
                        "Pairing File",
                        value: DevicePairingStore.hasSavedPairing ? "Imported" : "Not imported"
                    )
                    NavigationLink {
                        PairHomeView()
                    } label: {
                        Label(
                            DevicePairingStore.hasSavedPairing ? "Pair Again" : "Pair on This Device",
                            systemImage: "iphone.radiowaves.left.and.right"
                        )
                    }
                    Button {
                        importingPairing = true
                    } label: {
                        Label("Import Pairing File", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        Task { await checkConnection() }
                    } label: {
                        HStack {
                            Label("Check Connection", systemImage: "point.3.connected.trianglepath.dotted")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(busy || !DevicePairingStore.hasSavedPairing)
                    if DevicePairingStore.hasSavedPairing {
                        Button(role: .destructive) {
                            Task {
                                await manager.resetPairing()
                                checkMessage = "Pairing file removed."
                            }
                        } label: {
                            Label("Remove Pairing File", systemImage: "trash")
                        }
                    }
                    if let checkMessage {
                        Text(checkMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Native Install")
                } footer: {
                    Text("Installs through the system installation service — same result as installing from a computer.\n1. Tap Pair on This Device, then enable Developer Mode if prompted and enter the pairing code.\n2. Connect the built-in VPN before installing.\nRe-pair after changing the lock-screen passcode or restoring the device. Packages stay on this device.")
                }

            case .certificate:
                certificateSections

            case .proxy:
                Section {
                    Label("Custom OTA / TrustCore domain", systemImage: "network")
                    Label("Point install manifests at your proxy host when using Surge, Loon, or a custom domain", systemImage: "link")
                } header: {
                    Text("Proxy service")
                } footer: {
                    Text("For setups that already route install manifests through Surge, Loon, or a custom domain.")
                }
            }

            Section {
                Link("Installation help", destination: TetherlessBrand.siteURL)
            }
        }
        .navigationTitle("Installation settings")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 88)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            selected = Method(rawValue: segmentKey) ?? currentMethod()
        }
        .fileImporter(
            isPresented: $importingPairing,
            allowedContentTypes: [.propertyList, .xml, .data, .item],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let url = try result.get().first else { return }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                _ = try Data(contentsOf: url)
                Task { @MainActor in
                    await manager.setUp()
                    checkMessage = "Selected pairing file. Finish pairing under Pair if needed."
                }
            } catch {
                issue = error.localizedDescription
            }
        }
        .fullScreenCover(isPresented: $showCertificatesManager) {
            CertificatesScreen()
        }
        .sheet(isPresented: $showPortalTwoFactor) {
            PortalSigningTwoFactorSheet {
                showPortalTwoFactor = false
                Task { await ensureAppleIDCert(afterPortalCode: true) }
            }
        }
        .alert("Installation settings", isPresented: Binding(
            get: { issue != nil },
            set: { if !$0 { issue = nil } }
        )) {
            Button("OK", role: .cancel) { issue = nil }
        } message: {
            Text(issue ?? "")
        }
    }

    // MARK: - Certificate tab

    @ViewBuilder
    private var certificateSections: some View {
        Section {
            if appleID.isSignedIn {
                LabeledContent("Apple ID", value: appleID.email)
                Button {
                    Task { await ensureAppleIDCert(afterPortalCode: false) }
                } label: {
                    HStack {
                        Label(
                            linkedAppleIDCert == nil
                                ? "Capture 7-day cert (SideSign)"
                                : "Refresh SideSign development cert",
                            systemImage: "apple.logo"
                        )
                        if ensuringAppleIDCert { Spacer(); ProgressView() }
                    }
                }
                .disabled(ensuringAppleIDCert)
                if appleID.authPhase == .awaitingTwoFactor {
                    Button {
                        showPortalTwoFactor = true
                    } label: {
                        Label("Enter Developer Portal code…", systemImage: "lock.shield")
                    }
                }
            } else {
                Label("Sign in under Account to create a free 7-day development certificate", systemImage: "person.crop.circle.badge.exclamationmark")
                Button {
                    AppNav.shared.goStoreLogin()
                } label: {
                    Label("Sign In under Account", systemImage: "person.crop.circle")
                }
            }
            if let certStatus {
                Text(certStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Apple ID (7-day)")
        } footer: {
            Text("SideSign method: list portal Development certs, reuse if this iPhone still holds the private key, otherwise revoke the free-tier slot and CSR a fresh 7-day cert. Trust under Settings › General › VPN & Device Management after the first companion install.")
        }

        Section {
            if certStore.certificates.isEmpty {
                Text("No certificates yet. Create an Apple ID cert above or import a custom .p12 + .mobileprovision.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(certStore.certificates) { cert in
                    certRow(cert)
                }
            }
            NavigationLink {
                AddCertificateScreen()
            } label: {
                Label("Import custom .p12 + mobileprovision", systemImage: "square.and.arrow.down")
            }
            Button {
                showCertificatesManager = true
            } label: {
                Label("Manage all certificates", systemImage: "lock.shield")
            }
        } header: {
            Text("Local certificates")
        } footer: {
            Text("Companion signing prefers the linked Apple ID 7-day cert, then falls back to your active custom certificate. After importing, install the profile and trust it under Settings › General › VPN & Device Management.")
        }
    }

    private var linkedAppleIDCert: Certificate? {
        let linked = appleID.activeAccount?.linkedCertificateIDs ?? []
        return certStore.certificates.first { linked.contains($0.id) }
    }

    private func isLinkedAppleIDCert(_ cert: Certificate) -> Bool {
        appleID.activeAccount?.linkedCertificateIDs.contains(cert.id) == true
    }

    @ViewBuilder
    private func certRow(_ cert: Certificate) -> some View {
        let info = certStore.cachedProfileInfo(for: cert)
        let isActive = certStore.activeID == cert.id
        let isAppleID = isLinkedAppleIDCert(cert)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(cert.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if isActive {
                    Text("ACTIVE")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            HStack(spacing: 8) {
                Text(isAppleID ? "Apple ID · 7-day" : (info.isEnterprise ? "Enterprise" : "Custom"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isAppleID ? Color.accentColor : .secondary)
                if let days = info.daysUntilExpiry {
                    Text(days >= 0 ? "\(days)d left" : "Expired")
                        .font(.caption)
                        .foregroundStyle(info.isExpired || info.isExpiringSoon ? Color.orange : .secondary)
                }
            }
            if !isActive {
                Button("Use for signing") {
                    certStore.activeID = cert.id
                    if isAppleID {
                        FreeAppleIDSigning.preferAppleIDSigningMethodIfPossible()
                    } else {
                        UserDefaults.standard.set("saved", forKey: "uzd_signing_method")
                    }
                    certStatus = "Using \(cert.name) for signing."
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .padding(.vertical, 4)
    }

    private func ensureAppleIDCert(afterPortalCode: Bool) async {
        ensuringAppleIDCert = true
        defer { ensuringAppleIDCert = false }
        // Create (no linked cert) builds fresh; Refresh remints. Never force-wipe a
        // still-valid cert just because Create was tapped after a portal glitch.
        let force = linkedAppleIDCert != nil || afterPortalCode
        do {
            certStatus = "SideSign: talking to Developer Portal…"
            let cert = try await FreeAppleIDSigning.ensureDevelopmentCertificate(forceRefresh: force)
            certStatus = "SideSign ready: \(cert.name)"
            showPortalTwoFactor = false
        } catch AppleAuthError.needsTwoFactor {
            certStatus = "Allow the Developer Portal prompt, then enter the code."
            showPortalTwoFactor = true
        } catch {
            let text = error.localizedDescription
            if text.localizedCaseInsensitiveContains("two-factor")
                || text.localizedCaseInsensitiveContains("verification code")
                || text.contains("2FA") {
                certStatus = "Allow the Developer Portal prompt, then enter the code."
                showPortalTwoFactor = true
                return
            }
            // Silent auto-retries on portal 1200 — revoke/recreate already ran inside
            // FreeAppleIDSigning; Apple often needs a few seconds to free the Development slot.
            if text.contains("1200")
                || text.localizedCaseInsensitiveContains("not allowed to perform")
                || text.localizedCaseInsensitiveContains("clearing the portal slot")
                || text.localizedCaseInsensitiveContains("denied this free-certificate") {
                for round in 1...3 {
                    certStatus = "Portal busy (1200) — clearing slot and retrying (\(round)/3)…"
                    do {
                        try? await Task.sleep(nanoseconds: UInt64(2_000_000_000 * round))
                        let cert = try await FreeAppleIDSigning.ensureDevelopmentCertificate(forceRefresh: true)
                        certStatus = "Ready: \(cert.name)"
                        showPortalTwoFactor = false
                        return
                    } catch AppleAuthError.needsTwoFactor {
                        certStatus = "Allow the Developer Portal prompt, then enter the code."
                        showPortalTwoFactor = true
                        return
                    } catch {
                        if round == 3 {
                            issue = "Couldn't create a free 7-day certificate after clearing the Developer Portal slot (1200)."
                                + "\n\nImport a custom .p12 + mobileprovision below — companion signing will fall back to that cert. Or wait a minute, Sign Out/In under Account, and tap Create again."
                            certStatus = "Free Apple ID cert blocked — import a custom certificate."
                            return
                        }
                    }
                }
            }
            issue = text
            certStatus = nil
        }
    }

    private func currentMethod() -> Method {
        if methodKey == "native" { return .native }
        return .automatic
    }

    private func apply(_ method: Method) {
        segmentKey = method.rawValue
        switch method {
        case .native:
            methodKey = "native"
        case .automatic:
            methodKey = "ota"
        case .certificate, .proxy:
            // Cert / Proxy manage signing or routing — leave current install transport alone.
            break
        }
    }

    private func checkConnection() async {
        busy = true
        defer { busy = false }
        guard DevicePairingStore.hasSavedPairing else {
            checkMessage = "Import or create a pairing file first."
            return
        }
        await manager.setUp()
        if NativeInstaller.isSelected, DevicePairingStore.hasSavedPairing {
            checkMessage = "Connected. Native Install is ready."
        } else {
            checkMessage = "Pairing is saved. Select Native and connect VPN before installing."
        }
    }
}

// MARK: - Portal 2FA for 7-day cert create

/// Dedicated sheet so Create 7-day cert can finish GrandSlam without dumping the user
/// back to a dead-end alert when portal tokens need Allow + code.
private struct PortalSigningTwoFactorSheet: View {
    var onFinished: () -> Void

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
                        submitTitle: "Verify & Create Certificate",
                        sent: GSAAuthClient.shared.twoFactorCodeAlreadySent || didRequestPush,
                        stepLabel: "Developer Portal · 7-day cert",
                        footnote: "This Allow is only for signing certificates. Store downloads stay signed in.",
                        resend: { Task { await sendAllow(force: true) } },
                        submit: { submit() },
                        changeAccount: {
                            store.clearPendingTwoFactorUI()
                            dismiss()
                        }
                    )
                }
                .padding(20)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Portal signing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                guard !didRequestPush else { return }
                didRequestPush = true
                if GSAAuthClient.shared.hasPendingTwoFactor,
                   GSAAuthClient.shared.twoFactorCodeAlreadySent {
                    return
                }
                await sendAllow(force: false)
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private func sendAllow(force: Bool) async {
        busy = true
        failure = nil
        defer { busy = false }
        if force, GSAAuthClient.shared.hasPendingTwoFactor {
            await store.requestTrustedDevicePush(forStoreUnlock: false, force: true)
            didRequestPush = true
            if let err = store.lastError, !err.isEmpty { failure = err }
            return
        }
        do {
            _ = try await store.refreshPortalSession()
            // No 2FA needed — portal is ready; continue cert create.
            onFinished()
            dismiss()
        } catch AppleAuthError.needsTwoFactor {
            didRequestPush = true
            failure = nil
        } catch {
            if GSAAuthClient.shared.hasPendingTwoFactor {
                didRequestPush = true
                failure = nil
            } else {
                failure = error.localizedDescription
            }
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
                _ = try await store.submitPortalTwoFactor(code: digits)
                code = ""
                onFinished()
                dismiss()
            } catch AppleAuthError.needsTwoFactor {
                failure = "Need a fresh Allow — tap Resend, then enter the new code."
                code = ""
            } catch {
                failure = store.lastError ?? error.localizedDescription
                code = ""
            }
        }
    }
}

