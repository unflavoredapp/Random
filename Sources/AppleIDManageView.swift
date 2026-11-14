//
//  AppleIDManageView.swift
//  In-app Apple ID management: certificates, App IDs, devices, revoke.
//

import SwiftUI

struct AppleIDManageView: View {
    @ObservedObject private var store = AppleIDStore.shared
    @ObservedObject private var certs = CertificateStore.shared
    @State private var newAppID = ""
    @State private var newUDID = ""
    @State private var certPendingRevoke: Certificate?
    @State private var showLinkPicker = false

    private var account: AppleIDAccount? { store.activeAccount }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if let account {
                    header(account)
                    certificatesSection(account)
                    appIDsSection(account)
                    devicesSection(account)
                    freeSigningHint
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
        .confirmationDialog(
            "Revoke certificate?",
            isPresented: Binding(
                get: { certPendingRevoke != nil },
                set: { if !$0 { certPendingRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke & free slot", role: .destructive) {
                if let c = certPendingRevoke {
                    store.revokeCertificate(c.id)
                }
                certPendingRevoke = nil
            }
            Button("Cancel", role: .cancel) { certPendingRevoke = nil }
        } message: {
            if let c = certPendingRevoke {
                Text("Unlink “\(c.name)” from \(store.email). You can import a new development certificate into the freed slot.")
            }
        }
        .sheet(isPresented: $showLinkPicker) {
            NavigationStack {
                List {
                    ForEach(certs.certificates) { c in
                        Button {
                            store.linkCertificate(c.id)
                            showLinkPicker = false
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.name).foregroundStyle(.primary)
                                    if let exp = certs.cachedProfileInfo(for: c).expires {
                                        Text(exp, style: .date).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if account?.linkedCertificateIDs.contains(c.id) == true {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Link Certificate")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showLinkPicker = false }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .onAppear { store.syncProfileMetadataFromCertificates() }
    }

    private func header(_ account: AppleIDAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(account.email)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            Text("Signing certificates, App IDs, and devices for this Apple ID — manage them here without the Developer portal.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            if let msg = store.statusMessage, !msg.isEmpty {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(TetherlessPalette.accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tetherlessGlassCard(cornerRadius: 18)
    }

    private func certificatesSection(_ account: AppleIDAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Signing Certificates", actionTitle: "Link", action: { showLinkPicker = true })

            let linked = certs.certificates.filter { account.linkedCertificateIDs.contains($0.id) }
            if linked.isEmpty {
                emptyLine("No certificates linked. Link a free development certificate to sign with this Apple ID.")
            } else {
                ForEach(linked) { c in
                    let info = certs.cachedProfileInfo(for: c)
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(TetherlessPalette.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(c.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                            if let exp = info.expires {
                                Text("Expires \(exp.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                            Text("\(info.udids.count) device\(info.udids.count == 1 ? "" : "s") in profile")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        Spacer(minLength: 4)
                        Menu {
                            Button("Use for signing") {
                                store.linkCertificate(c.id)
                                CertificateStore.shared.activeID = c.id
                                UserDefaults.standard.set("appleid", forKey: "uzd_signing_method")
                            }
                            Button("Unlink") { store.unlinkCertificate(c.id) }
                            Button("Revoke slot", role: .destructive) { certPendingRevoke = c }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .padding(14)
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }

            if !account.revokedCertificateIDs.isEmpty {
                Text("\(account.revokedCertificateIDs.count) revoked slot\(account.revokedCertificateIDs.count == 1 ? "" : "s") freed on this device")
                    .font(.caption2)
                    .foregroundStyle(.orange.opacity(0.8))
            }
        }
        .padding(16)
        .tetherlessGlassCard(cornerRadius: 18)
    }

    private func appIDsSection(_ account: AppleIDAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("App IDs", actionTitle: nil, action: nil)
            if account.appIDs.isEmpty {
                emptyLine("App IDs from linked provisioning profiles appear here. You can also add one manually.")
            } else {
                ForEach(account.appIDs, id: \.self) { id in
                    HStack {
                        Image(systemName: "app.badge")
                            .foregroundStyle(.white.opacity(0.55))
                        Text(id)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            store.removeAppID(id)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
            HStack(spacing: 10) {
                TextField("com.example.app", text: $newAppID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color.black.opacity(0.28), in: Capsule())
                Button("Add") {
                    store.addAppID(newAppID)
                    newAppID = ""
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TetherlessPalette.accent)
                .disabled(newAppID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .tetherlessGlassCard(cornerRadius: 18)
    }

    private func devicesSection(_ account: AppleIDAccount) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Devices", actionTitle: "Sync", action: { store.syncProfileMetadataFromCertificates() })
            if account.deviceUDIDs.isEmpty {
                emptyLine("UDIDs from linked profiles show up here. Add this iPhone’s UDID if missing.")
            } else {
                ForEach(account.deviceUDIDs, id: \.self) { udid in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "iphone")
                            .foregroundStyle(.white.opacity(0.55))
                        Text(udid)
                            .font(.caption.monospaced())
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            store.removeDeviceUDID(udid)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
            HStack(spacing: 10) {
                TextField("UDID", text: $newUDID)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color.black.opacity(0.28), in: Capsule())
                Button("Add") {
                    store.addDeviceUDID(newUDID)
                    newUDID = ""
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(TetherlessPalette.accent)
                .disabled(newUDID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let known = CertificateStore.knownUDID() {
                Button("Add this device (\(String(known.prefix(8)))…)") {
                    store.addDeviceUDID(known)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(TetherlessPalette.accent)
            }
        }
        .padding(16)
        .tetherlessGlassCard(cornerRadius: 18)
    }

    private var freeSigningHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Free Apple ID signing")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text("Link a development certificate to this Apple ID, then choose Apple ID as the signing method when you install. TetherLess will prefer the linked cert automatically.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.55))
            Button {
                store.activatePreferredSigningCertificate()
                UserDefaults.standard.set("appleid", forKey: "uzd_signing_method")
                store.statusMessage = "Apple ID signing method selected."
            } label: {
                Text("Use Apple ID for next sign")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(TetherlessPalette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(16)
        .tetherlessGlassCard(cornerRadius: 18)
    }

    private func sectionTitle(_ title: String, actionTitle: String?, action: (() -> Void)?) -> some View {
        HStack {
            Text(title)
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
                    .buttonStyle(.plain)
            }
        }
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
    }
}
