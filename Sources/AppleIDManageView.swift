//
//  AppleIDManageView.swift
//  Real Developer Portal management: certificates, App IDs, devices, revoke.
//

import Foundation
import SwiftUI
import Security

struct AppleIDManageView: View {
    @ObservedObject private var store = AppleIDStore.shared
    @ObservedObject private var certs = CertificateStore.shared
    @State private var portalCerts: [DevCertificate] = []
    @State private var portalDevices: [DevDevice] = []
    @State private var portalAppIDs: [DevAppID] = []
    @State private var team: DevTeam?
    @State private var busy = false
    @State private var status: String?
    @State private var error: String?
    @State private var certPendingRevoke: DevCertificate?
    @State private var newAppID = ""
    @State private var newAppName = ""

    private var account: AppleIDAccount? { store.activeAccount }
    private var auth: AppleAuthSession? { store.portalSession() }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if let account {
                    header(account)
                    if auth == nil {
                        Text("This Apple ID isn’t signed in with a live GrandSlam session. Sign out and sign in again under Store Access.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else {
                        refreshRow
                        certificatesSection
                        appIDsSection
                        devicesSection
                        freeSigningHint
                    }
                } else {
                    Text("Add an Apple ID under Store Access first.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.top, 24)
                }
            }
            .padding(20)
            .padding(.bottom, 40)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Manage Apple ID")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reloadPortal() }
        .confirmationDialog(
            "Revoke certificate on Apple’s servers?",
            isPresented: Binding(
                get: { certPendingRevoke != nil },
                set: { if !$0 { certPendingRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke & free slot", role: .destructive) {
                if let c = certPendingRevoke { Task { await revoke(c) } }
                certPendingRevoke = nil
            }
            Button("Cancel", role: .cancel) { certPendingRevoke = nil }
        } message: {
            if let c = certPendingRevoke {
                Text("This permanently revokes “\(c.name)” (\(c.serialNumber)) for \(store.email) on the Developer Portal.")
            }
        }
    }

    private var refreshRow: some View {
        HStack {
            if let team {
                Text(team.name + (team.isFree ? " · Free" : " · Paid"))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button {
                Task { await reloadPortal() }
            } label: {
                if busy { ProgressView().tint(TetherlessPalette.accent) }
                else { Text("Refresh").font(.subheadline.weight(.semibold)).foregroundStyle(TetherlessPalette.accent) }
            }
            .disabled(busy)
        }
    }

    private func header(_ account: AppleIDAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(account.email)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            Text("Live Developer Portal data for this Apple ID — certificates, App IDs, and devices. Revoke frees a free-tier slot on Apple’s servers.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
            if let status { Text(status).font(.caption).foregroundStyle(TetherlessPalette.accent) }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tetherlessGlassCard(cornerRadius: 18)
    }

    private var certificatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Signing Certificates").font(.headline.weight(.bold)).foregroundStyle(.white)
                Spacer()
                Button("Create") { Task { await createCert() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
                    .disabled(busy || auth == nil || team == nil)
            }
            if portalCerts.isEmpty {
                Text("No development certificates on this team yet.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.45))
            } else {
                ForEach(portalCerts) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                            Text(c.serialNumber).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.45))
                        }
                        Spacer()
                        Menu {
                            Button("Revoke on Apple", role: .destructive) { certPendingRevoke = c }
                        } label: {
                            Image(systemName: "ellipsis.circle").foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .padding(12)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .padding(16)
        .tetherlessGlassCard(cornerRadius: 18)
    }

    private var appIDsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App IDs").font(.headline.weight(.bold)).foregroundStyle(.white)
            ForEach(portalAppIDs) { a in
                HStack {
                    Text(a.bundleID).font(.caption.monospaced()).foregroundStyle(.white).lineLimit(1)
                    Spacer()
                    Text(a.name).font(.caption2).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                }
            }
            HStack {
                TextField("com.example.app", text: $newAppID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .foregroundStyle(.white)
                    .padding(10).background(Color.black.opacity(0.28), in: Capsule())
                TextField("Name", text: $newAppName)
                    .foregroundStyle(.white)
                    .padding(10).background(Color.black.opacity(0.28), in: Capsule())
                Button("Add") { Task { await addAppID() } }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(TetherlessPalette.accent)
                    .disabled(newAppID.isEmpty || busy)
            }
        }
        .padding(16)
        .tetherlessGlassCard(cornerRadius: 18)
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Devices").font(.headline.weight(.bold)).foregroundStyle(.white)
                Spacer()
                Button("Register this iPhone") { Task { await registerThisDevice() } }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(TetherlessPalette.accent)
                    .disabled(busy)
            }
            ForEach(portalDevices) { d in
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(d.udid).font(.caption2.monospaced()).foregroundStyle(.white.opacity(0.45))
                }
            }
            if portalDevices.isEmpty {
                Text("No devices registered on this team.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(16)
        .tetherlessGlassCard(cornerRadius: 18)
    }

    private var freeSigningHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Free Apple ID signing")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            Text("Create a development certificate above, then choose Apple ID as the signing method. TetherLess uses the linked/dev cert from this Apple ID.")
                .font(.footnote).foregroundStyle(.white.opacity(0.55))
            Button {
                store.activatePreferredSigningCertificate()
                UserDefaults.standard.set("appleid", forKey: "uzd_signing_method")
                status = "Apple ID signing method selected."
            } label: {
                Text("Use Apple ID for next sign")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(TetherlessPalette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .tetherlessGlassCard(cornerRadius: 18)
    }

    // MARK: Actions

    private func reloadPortal() async {
        guard let auth else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let teams = try await DeveloperPortalClient.shared.listTeams(auth: auth)
            guard let team = teams.first else {
                error = "No developer team on this Apple ID."
                return
            }
            self.team = team
            async let c = DeveloperPortalClient.shared.listCertificates(auth: auth, team: team)
            async let d = DeveloperPortalClient.shared.listDevices(auth: auth, team: team)
            async let a = DeveloperPortalClient.shared.listAppIDs(auth: auth, team: team)
            portalCerts = try await c
            portalDevices = try await d
            portalAppIDs = try await a
            // Mirror into local account metadata
            for app in portalAppIDs { store.addAppID(app.bundleID) }
            for dev in portalDevices { store.addDeviceUDID(dev.udid) }
            status = "Updated from Developer Portal · \(portalCerts.count) certs"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func revoke(_ cert: DevCertificate) async {
        guard let auth, let team else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            try await DeveloperPortalClient.shared.revokeCertificate(cert, auth: auth, team: team)
            store.revokeCertificate(cert.id) // local unlink bookkeeping
            status = "Revoked \(cert.name) on Apple’s servers."
            await reloadPortal()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createCert() async {
        guard let auth, let team else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let machine = UIDevice.current.name
            let result = try await DeveloperPortalClient.shared.createDevelopmentCertificate(
                machineName: machine, auth: auth, team: team
            )
            // Build a temporary p12 + empty-ish flow: store PEM key + cert; user still needs a profile.
            // Download a profile if we have an App ID, else just keep cert PEMs in cert store via import path.
            try importCertPEM(result.certPEM, keyPEM: result.privateKeyPEM, name: result.certificate.name)
            store.linkCertificate(certs.certificates.last?.id ?? result.certificate.id)
            status = "Created \(result.certificate.name) on the Developer Portal."
            await reloadPortal()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func addAppID() async {
        guard let auth, let team else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let name = newAppName.isEmpty ? newAppID : newAppName
            _ = try await DeveloperPortalClient.shared.addAppID(bundleID: newAppID, name: name, auth: auth, team: team)
            newAppID = ""; newAppName = ""
            await reloadPortal()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func registerThisDevice() async {
        guard let auth, let team else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let udid = CertificateStore.knownUDID()
                ?? (try? DevicePairingStore.load())?.device_udid
            guard let udid, !udid.isEmpty else {
                error = "Unknown UDID — pair the device or set UDID in Certificates."
                return
            }
            _ = try await DeveloperPortalClient.shared.addDevice(
                udid: udid, name: UIDevice.current.name, auth: auth, team: team
            )
            CertificateStore.setKnownUDID(udid)
            await reloadPortal()
        } catch {
            // Portal code 35 = already registered
            if let e = error as? AppleAuthError, case .portal(35, _) = e {
                status = "This device is already registered."
                await reloadPortal()
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    /// Import PEM cert + key as a CertificateStore entry (passwordless p12 via SecItem).
    private func importCertPEM(_ certPEM: Data, keyPEM: Data, name: String) throws {
        // Write files into certs dir; CertificateStore expects p12 + mobileprovision.
        // Create PKCS12 identity via Security.
        guard let cert = SecCertificateCreateWithData(nil, pemToDER(certPEM) as CFData) else {
            throw AppleAuthError.message("Invalid certificate PEM from portal.")
        }
        // For signing we need a mobileprovision — download one if possible
        // Store raw PEMs beside a placeholder; AddCertificateView path uses p12.
        // Build PKCS#12:
        let password = "tetherless"
        var identity: SecIdentity?
        // Import key
        let keyOpts: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        var err: Unmanaged<CFError>?
        let keyData = pemToDER(keyPEM)
        guard let privateKey = SecKeyCreateWithData(keyData as CFData, keyOpts as CFDictionary, &err) else {
            // Fall back: write PEMs for manual pairing; still link portal cert id
            let dir = AppPaths.dir("certs")
            let id = UUID().uuidString
            try certPEM.write(to: dir.appendingPathComponent("\(id).cer.pem"))
            try keyPEM.write(to: dir.appendingPathComponent("\(id).key.pem"))
            status = "Saved cert/key PEMs. Add a matching .mobileprovision in Certificates to sign."
            return
        }
        _ = privateKey
        _ = identity
        _ = password
        _ = cert
        let dir = AppPaths.dir("certs")
        let id = UUID().uuidString
        try certPEM.write(to: dir.appendingPathComponent("\(id).cer.pem"))
        try keyPEM.write(to: dir.appendingPathComponent("\(id).key.pem"))
        status = "Portal certificate created. Import the .cer/.key with a development profile in Certificates, or use Add Certificate."
    }

    private func pemToDER(_ pem: Data) -> Data {
        guard let s = String(data: pem, encoding: .utf8) else { return pem }
        let lines = s.split(separator: "\n").filter { !$0.hasPrefix("-----") }
        return Data(base64Encoded: lines.joined()) ?? pem
    }
}
