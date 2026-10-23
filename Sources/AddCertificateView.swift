//
//  AddCertificateView.swift
//  Pushed from the Certificates screen: pick the .p12 + .mobileprovision together (or one .zip, with an
//  optional password .txt), check what was found, then import.
//

import SwiftUI
import UIKit

struct AddCertificateScreen: View {
    @ObservedObject private var store = CertificateStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var p12: CertImportBundle.File?
    @State private var profile: CertImportBundle.File?
    @State private var passwordFromFile = false
    @State private var certName = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var notes: [String] = []
    @State private var error: String?
    @State private var importing = false
    @State private var whyOpen = false
    @State private var showHow = false

    private var canImport: Bool { p12 != nil && profile != nil }
    private var hasFiles: Bool { p12 != nil || profile != nil || passwordFromFile }
    private var udid: String? { CertificateStore.knownUDID(certName: store.active?.name) }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Provide certificate").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                    Button { showHow = true } label: {
                        Text("How to get a certificate with a developer account?")
                            .font(.system(size: 12)).foregroundStyle(Color(red: 0.29, green: 0.64, blue: 1))
                            .multilineTextAlignment(.leading)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4).padding(.top, 6)

                if hasFiles { filesCard } else { chooseCard; typeCard("Distribution / Enterprise certificate", "For installing apps with Ad Hoc or Enterprise provisioning profiles."); typeCard("Development certificate", "Required to sign apps that use extra capabilities. Also used for testing and debugging apps.") }

                whyCard
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(Theme.bg.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            TabTitleBar(title: "Add Certificate", showsAccount: false) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .accessibilityLabel("Back")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $showHow) { TutorialsListScreen().preferredColorScheme(.dark) }
    }

    // MARK: - Before choosing

    private var chooseCard: some View {
        Button(action: pick) {
            VStack(spacing: 6) {
                Image(systemName: "square.and.arrow.down.on.square").font(.system(size: 32)).foregroundStyle(Theme.accent)
                Text("Add everything at once").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                Text("Select your .p12 and .mobileprovision together, or one .zip that contains them. Add a .txt with the password if it has one.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.subtle).multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    kind("key.fill", ".p12"); kind("doc.badge.gearshape", ".mobileprovision")
                    kind("doc.zipper", ".zip"); kind("doc.text", ".txt")
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20).padding(.horizontal, 12)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.subtle.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(14).background(panelBackground)
    }

    private func typeCard(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                CertificateBadge(size: 54)
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                Spacer(minLength: 6)
                Button(action: pick) {
                    HStack(spacing: 4) { Image(systemName: "plus").font(.system(size: 11, weight: .heavy)); Text("Add").font(.system(size: 13, weight: .bold)) }
                        .foregroundStyle(.black).padding(.horizontal, 13).padding(.vertical, 7)
                        .background(Color(white: 0.95)).clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Text(detail).font(.system(size: 12)).foregroundStyle(Theme.subtle)
        }
        .padding(14).background(panelBackground)
    }

    private func kind(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.accent)
            Text(text).font(.system(size: 10.5)).foregroundStyle(Theme.text.opacity(0.85))
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.white.opacity(0.07)).clipShape(Capsule())
    }

    // MARK: - After choosing

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                foundRow("key.fill", p12?.name, "Certificate", missing: "Missing .p12. Choose it too.")
                foundRow("doc.badge.gearshape", profile?.name, profileSubtitle, missing: "Missing .mobileprovision. Choose it too.")
                if passwordFromFile { foundRow("doc.text", "Password file", "Password found. Filled in below.", missing: "") }
                Button(action: pick) {
                    Text(canImport ? "Choose different files" : "Choose more files")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent).frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke, lineWidth: 1.5))

            ForEach(notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }

            labeled("Name") { TextField("My Dev Cert", text: $certName).autocorrectionDisabled() }
            labeled(".p12 password") {
                HStack {
                    Group {
                        if showPassword { TextField(passwordFromFile ? "From the .txt file" : "Leave blank if none", text: $password) }
                        else { SecureField(passwordFromFile ? "From the .txt file" : "Leave blank if none", text: $password) }
                    }
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button { showPassword.toggle() } label: { Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(Theme.subtle) }
                }
            }

            if let error { Text(error).font(.caption).foregroundStyle(.orange) }

            Button { doImport() } label: {
                HStack(spacing: 8) {
                    if importing { ProgressView().tint(.black) } else { Image(systemName: "checkmark.seal.fill") }
                    Text("Import & activate").fontWeight(.bold)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(canImport ? Theme.accent : Color.white.opacity(0.18))
                .foregroundStyle(canImport ? Color.black : Theme.subtle)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain).disabled(!canImport || importing)
        }
        .padding(14).background(panelBackground)
    }

    private func foundRow(_ icon: String, _ name: String?, _ subtitle: String, missing: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: name == nil ? "circle.dashed" : icon).font(.system(size: 20))
                .foregroundStyle(name == nil ? Theme.subtle : Theme.accent).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(name ?? missing).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(name == nil ? Theme.subtle : Theme.text).lineLimit(1)
                if name != nil { Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.subtle).lineLimit(2) }
            }
            Spacer(minLength: 4)
            if name != nil { Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(.green) }
        }
    }

    private var profileSubtitle: String {
        guard let profile else { return "" }
        let info = CertificateStore.profileInfo(profile.data)
        if info.udids.isEmpty { return "Profile · no device list (enterprise)" }
        switch CertificateStore.profileIncludesDevice(info, udid: udid) {
        case .some(true):  return "Profile · includes this device"
        case .some(false): return "Profile · does NOT include this device"
        case .none:        return "Profile · \(info.udids.count) devices"
        }
    }

    // MARK: - Why

    private var whyCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { whyOpen.toggle() } } label: {
                HStack {
                    Text("Why do we need these files?").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                    Spacer()
                    Image(systemName: whyOpen ? "chevron.up" : "chevron.down").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.subtle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if whyOpen {
                Text("The .p12 is your signing identity. The .mobileprovision lists the devices it can install on. The password unlocks the .p12; leave it blank if it has none. Everything stays on this device.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.text.opacity(0.8)).padding(.top, 10)
            }
        }
        .padding(14).background(panelBackground)
    }

    // MARK: - Logic

    private func pick() {
        DocumentPickerPresenter.pickFiles { urls in
            guard !urls.isEmpty else { return }
            ingest(urls)
        }
    }

    private func ingest(_ urls: [URL]) {
        let bundle = CertImportBundle.read(urls)
        notes = bundle.problems
        error = nil
        if let f = bundle.p12 {
            p12 = f
            if certName.isEmpty { certName = (f.name as NSString).deletingPathExtension }
        }
        if let f = bundle.profile {
            profile = f
            if certName.isEmpty, let n = CertificateStore.profileInfo(f.data).name { certName = n }
        }
        if let pw = bundle.password { password = pw; passwordFromFile = true }
    }

    private func doImport() {
        guard let p12, let profile else { return }
        importing = true; error = nil
        do {
            try store.importPair(name: certName, p12: p12.data, password: password, provision: profile.data)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            importing = false
            dismiss()
            return
        } catch { self.error = error.localizedDescription }
        importing = false
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder _ field: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.subtle)
            field()
                .padding(11).background(Theme.bg).foregroundStyle(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}
