//
//  CertificatesView.swift
//  Device card, certificate options, your certificates, the activation steps for a requested
//  certificate, and Services. Presented full-screen from Settings.
//

import SwiftUI
import UIKit

struct CertificatesScreen: View {
    @ObservedObject private var store = CertificateStore.shared
    @ObservedObject private var requests = CertificateRequestClient.shared
    @ObservedObject private var account = ZefvAccount.shared
    @ObservedObject private var decrypt = DecryptClient.shared
    @Environment(\.dismiss) private var dismiss

    @State private var udidText = UserDefaults.standard.string(forKey: "uzd_device_udid") ?? ""
    @State private var udidTick = 0
    @State private var copied = false
    @State private var showUDIDEdit = false
    @State private var showHelp = false
    @State private var showInfo = false
    @State private var showStepInfo = false
    @State private var removeTarget: Certificate?
    @State private var showLockedInfo = false
    @State private var collapsed: Set<String> = []
    @State private var error: String?

    private var udid: String? {
        _ = udidTick
        return CertificateStore.knownUDID(certName: store.active?.name)
    }

    private var hasPremium: Bool { requests.server?.premiumActive == true }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    deviceCard
                    helpButton
                    sectionHeader
                    if store.certificates.isEmpty && requests.pending == nil {
                        Text("Select one of the options to access apps.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.subtle)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                    }
                    if store.certificates.isEmpty && requests.pending == nil {
                        NavigationLink { CertificateRequestView(embedded: true) } label: {
                            optionRow(asset: "CertCrown", title: "Request a Certificate",
                                      detail: "Ask for a certificate for this device.", glow: true)
                        }
                        .buttonStyle(.plain)
                    }
                    if store.certificates.isEmpty {
                        NavigationLink { AddCertificateScreen() } label: {
                            optionRow(asset: "CertSeal", title: "Add Certificate",
                                      detail: "Import your own .p12 and .mobileprovision.", glow: false)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(store.certificates) { certCard($0) }
                    if !store.certificates.isEmpty {
                        NavigationLink { AddCertificateScreen() } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.circle.fill").foregroundStyle(Theme.accent)
                                Text("Add another certificate").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.card)
                            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                    if let pending = requests.pending, store.certificates.isEmpty { activationCard(pending) }
                    servicesSection
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 24)
            }
            .background(Theme.bg.ignoresSafeArea())
            .safeAreaInset(edge: .top, spacing: 0) {
                TabTitleBar(title: "Certificates",
                            center: "\(store.certificates.count) Certificate\(store.certificates.count == 1 ? "" : "s")",
                            showsAccount: false) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.accent)
                            .frame(width: 30, height: 30).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close")
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .scrollDismissesKeyboard(.interactively)
        .task {
            clearPendingIfDone()
            await account.refreshProfile()
            await requests.refreshStatus()
            await decrypt.refreshQuota()
            clearPendingIfDone()
        }
        .onChange(of: store.certificates.count) { _ in clearPendingIfDone() }
        .onReceive(NotificationCenter.default.publisher(for: .airshareKnownUDIDDidChange)) { _ in udidTick += 1 }
        .alert("Device UDID", isPresented: $showUDIDEdit) {
            TextField("00008110-000209003C60E01E", text: $udidText)
                .autocorrectionDisabled().textInputAutocapitalization(.characters)
            Button("Save") {
                CertificateStore.setKnownUDID(udidText)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                udidTick += 1
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter your UDID once and every profile shows whether it includes this device. If your certificate is named after your UDID, it's detected automatically.")
        }
        .alert("About certificates", isPresented: $showInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("AirShare signs apps with the active certificate. Development and ad-hoc profiles only install on devices listed inside them, so check that this device shows as included.")
        }
        .alert("About your request", isPresented: $showStepInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Requests are reviewed by hand. When yours is approved the certificate is added to this screen automatically. Open it again to refresh.")
        }
        .confirmationDialog("Remove this certificate?", isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }),
                            titleVisibility: .visible, presenting: removeTarget) { cert in
            Button("Remove \(cert.name)", role: .destructive) { store.delete(cert) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Apps already signed with it keep working until the profile expires.")
        }
        .fullScreenCover(isPresented: $showHelp) {
            TutorialsListScreen(tutorials: TutorialLibrary.certHelp, title: "Certificate help",
                                footer: "Start with the first guide if you're new. If an app won't install or won't open, the next two go through every cause and its fix. The last one sets up native installs on iOS 27.")
                .preferredColorScheme(.dark)
        }
        .alert("Provided by your admin", isPresented: $showLockedInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This certificate was attached to your account by AirShare staff. You can sign with it, but it can't be exported, removed, or included in a local backup on any device.")
        }
    }

    private func clearPendingIfDone() {
        if requests.pending != nil, !store.certificates.isEmpty { requests.clearPending() }
    }

    // MARK: - Device

    private func maskedUDID(_ u: String) -> String {
        u.count > 20 ? String(u.prefix(10)) + "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}" + String(u.suffix(8)) : u
    }

    private var certChip: (text: String, icon: String, color: Color) {
        if let c = store.active {
            let info = store.cachedProfileInfo(for: c)
            if info.isExpired { return ("Certificate", "exclamationmark.triangle.fill", .orange) }
            return ("Certificate", "checkmark.circle.fill", .green)
        }
        if requests.pending != nil { return ("Certificate", "clock.fill", .orange) }
        return ("Certificate", "xmark.circle.fill", Theme.subtle)
    }

    private func chip(_ text: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text)
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Color.white.opacity(0.08)).clipShape(Capsule())
    }

    private var deviceCard: some View {
        panel {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    PhoneIcon(height: 78)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(UIDevice.current.name).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.text)
                        Text("UDID:").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                        if let u = udid {
                            Text(maskedUDID(u)).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.subtle)
                        } else {
                            Text("Not set").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
                        }
                        HStack(spacing: 6) {
                            let c = certChip
                            chip(c.text, c.icon, c.color)
                            if hasPremium { chip("Premium", "checkmark.circle.fill", .green) }
                        }
                        .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    wideButton(udid == nil ? "Set UDID" : (copied ? "Copied" : "Copy UDID"),
                               icon: udid == nil ? "pencil" : (copied ? "checkmark" : "doc.on.doc")) {
                        if let u = udid {
                            UIPasteboard.general.string = u
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        } else { showUDIDEdit = true }
                    }
                    if udid != nil {
                        Button { showUDIDEdit = true } label: {
                            Image(systemName: "pencil").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                                .frame(width: 46, height: 44).background(Color.white.opacity(0.07))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain).accessibilityLabel("Edit UDID")
                    }
                }
            }
        }
    }

    private var helpButton: some View {
        Button { showHelp = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                Text("Help and Support").font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var sectionHeader: some View {
        HStack {
            Text("Certificate").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
            Spacer()
            Button { showInfo = true } label: {
                Image(systemName: "info.circle").font(.system(size: 20)).foregroundStyle(Color(red: 0.29, green: 0.64, blue: 1))
            }
            .accessibilityLabel("About certificates")
        }
        .padding(.horizontal, 4).padding(.top, 6)
    }

    private func optionRow(asset: String, title: String, detail: String, glow: Bool) -> some View {
        HStack(spacing: 14) {
            AssetIcon(name: asset, size: 56, fallback: glow ? "crown.fill" : "rosette")
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.subtle).multilineTextAlignment(.leading)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.subtle)
        }
        .padding(14)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .stroke(glow ? Theme.accent.opacity(0.6) : Theme.stroke, lineWidth: glow ? 1.5 : 1))
        .shadow(color: glow ? Theme.accent.opacity(0.35) : .clear, radius: 12)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(Rectangle())
    }

    // MARK: - Certificates

    private func certCard(_ c: Certificate) -> some View {
        let active = store.activeID == c.id
        let open = !collapsed.contains(c.id)
        let info = store.cachedProfileInfo(for: c)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if open { collapsed.insert(c.id) } else { collapsed.remove(c.id) }
                }
            } label: {
                HStack(spacing: 12) {
                    ZStack(alignment: .bottomTrailing) {
                        CertificateBadge(size: 60)
                        if c.isLocked {
                            Image(systemName: "lock.fill").font(.system(size: 10, weight: .black)).foregroundStyle(.black)
                                .frame(width: 20, height: 20)
                                .background(Theme.accent)
                                .overlay(Circle().stroke(Theme.bg, lineWidth: 2))
                                .clipShape(Circle())
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                        if let t = info.team { Text(t).font(.system(size: 12)).foregroundStyle(Theme.subtle).lineLimit(1) }
                        if let e = info.expires {
                            let expired = e < Date()
                            let days = info.daysUntilExpiry
                            Text((expired ? "Expired " : "Expires ") + e.formatted(date: .abbreviated, time: .omitted)
                                 + (!expired && days != nil ? " \u{00B7} \(days!) days" : ""))
                                .font(.system(size: 12)).foregroundStyle(expired ? .orange : Theme.subtle)
                        }
                        if c.isLocked {
                            HStack(spacing: 4) {
                                Image(systemName: "lock.fill").font(.system(size: 8, weight: .heavy))
                                Text("PROVIDED BY ADMIN \u{00B7} CAN'T EXPORT").font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(0.3)
                            }
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Theme.accent.opacity(0.16)).clipShape(Capsule())
                            .padding(.top, 2)
                        }
                    }
                    Spacer(minLength: 6)
                    if active {
                        Text("ACTIVE").font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Theme.accent.opacity(0.2)).foregroundStyle(Theme.accent).clipShape(Capsule())
                    }
                    Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.subtle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                perk("square.stack.3d.up.fill", "Install apps natively with the built-in VPN", Theme.text)
                perk("signature", "Access to Signer", Theme.text)
                deviceLine(info, certName: c.name)

                HStack(spacing: 10) {
                    if !active {
                        cardAction("Use", icon: "checkmark.circle", color: Theme.accent) { store.activeID = c.id }
                    } else if !c.isLocked {
                        cardAction("Export", icon: "square.and.arrow.up", color: Theme.text) { export(c) }
                    }
                    if c.isLocked {
                        lockedAction
                    } else {
                        cardAction("Remove", icon: "minus.circle", color: Color(red: 1, green: 0.35, blue: 0.3)) { removeTarget = c }
                    }
                }
                .padding(.top, 16)
            }
        }
        .padding(14)
        .background(
            LinearGradient(colors: [active ? Theme.accent.opacity(0.16) : Theme.card, Theme.card], startPoint: .top, endPoint: .bottom)
        )
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(active ? Theme.accent.opacity(0.45) : Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    // MARK: - Activation

    private func activationCard(_ pending: PendingCertificateRequest) -> some View {
        let days = max(0, Calendar.current.dateComponents([.day], from: pending.submittedAt, to: Date()).day ?? 0)
        let server = requests.server
        return panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    AssetIcon(name: "CertActivation", size: 52, fallback: "hourglass")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Activation process").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                        Text("\(pending.type) certificate request").font(.system(size: 12)).foregroundStyle(Theme.subtle)
                    }
                    Spacer()
                }
                step(done: true, title: "Request sent", detail: "Submitted \(pending.submittedAt.formatted(date: .abbreviated, time: .omitted)).")
                step(done: server?.isApproved == true,
                     title: server?.isRejected == true ? "Request declined" : "Being reviewed",
                     detail: "You've been here \(days)d" + (server?.message.map { " \u{00B7} \($0)" } ?? ""),
                     pill: server?.etaText, info: true)
                step(done: false, title: "Certificate added", detail: "It appears on this screen and is activated automatically.", last: true)
                Text("You don't need to keep this screen open.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.subtle)
                if (server?.status ?? "pending").lowercased() == "pending" {
                    Button { Task { await requests.cancel() } } label: {
                        Text("Cancel request").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(red: 1, green: 0.35, blue: 0.3))
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Color.white.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                if let e = requests.error { Text(e).font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    private func step(done: Bool, title: String, detail: String, pill: String? = nil, info: Bool = false, last: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).foregroundStyle(done ? Color.green : Theme.subtle)
                if !last { Rectangle().fill(Theme.stroke).frame(width: 1.5).frame(maxHeight: .infinity) }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    if info {
                        Button { showStepInfo = true } label: {
                            Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(Color(red: 0.29, green: 0.64, blue: 1))
                        }
                        .buttonStyle(.plain).accessibilityLabel("More info")
                    }
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(Theme.subtle)
                if let pill {
                    Text(pill).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Theme.accent.opacity(0.18)).clipShape(Capsule())
                }
            }
            .padding(.bottom, last ? 0 : 6)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Services

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Services").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                .padding(.horizontal, 4).padding(.top, 6)
            if hasPremium {
                panel {
                    HStack(spacing: 14) {
                        AssetIcon(name: "PremiumAccess", size: 56, fallback: "crown.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Premium Access").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                            if let e = requests.server?.premiumExpires {
                                let d = requests.server?.premiumDaysLeft ?? 0
                                Text("\(d) day\(d == 1 ? "" : "s") left \u{00B7} until " + e.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 12)).foregroundStyle(Theme.subtle)
                            } else {
                                Text("Active").font(.system(size: 12)).foregroundStyle(Theme.subtle)
                            }
                        }
                        Spacer()
                    }
                }
            }
            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { AppNav.shared.go(2) }
            } label: {
                panel {
                    HStack(spacing: 14) {
                        AssetIcon(name: "PartnerFastDecrypt", size: 56, fallback: "lock.open.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Partner").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.text)
                            Text("@FastDecryptBot").font(.system(size: 12)).foregroundStyle(Theme.subtle)
                            if let q = decrypt.quota {
                                Text(q.unlimited ? "Unlimited decrypts" : "\(q.left ?? 0) of \(q.limit ?? 0) decrypts left today")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(q.exhausted ? Color.orange : Theme.accent)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.subtle)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func perk(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(color).frame(width: 24)
            Text(text).font(.system(size: 14)).foregroundStyle(color)
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
    }

    private func deviceStatus(_ info: ProfileInfo, certName: String) -> (icon: String, text: String, color: Color) {
        let r = CertificateStore.profileIncludesDevice(info, udid: CertificateStore.knownUDID(certName: certName))
        if info.udids.isEmpty { return ("building.2", "No device list (enterprise / in-house)", Theme.subtle) }
        switch r {
        case .some(true):  return ("checkmark.seal.fill", "This device is in the profile (\(info.udids.count) device\(info.udids.count == 1 ? "" : "s"))", .green)
        case .some(false): return ("xmark.octagon.fill", "This device is NOT in the profile (\(info.udids.count) devices). Apps won't install.", .orange)
        case .none:        return ("questionmark.circle", "\(info.udids.count) devices. Set your UDID above to check.", Theme.subtle)
        }
    }

    private func deviceLine(_ info: ProfileInfo, certName: String) -> some View {
        let s = deviceStatus(info, certName: certName)
        return perk(s.icon, s.text, s.color)
    }

    private func export(_ c: Certificate) {
        do {
            CertificateShare.present(try CertificateExporter.zipURL(for: c))
        } catch {
            self.error = "Couldn't export: \(error.localizedDescription)"
        }
    }

    // MARK: - Pieces

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func wideButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func cardAction(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title).font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(color)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// Stands in for Export/Remove on an admin-provided cert: visually distinct (dashed, dim, locked icon)
    /// so the absence of a real export button reads as "blocked on purpose", not a missing feature — and
    /// explains why when tapped, instead of just not being there.
    private var lockedAction: some View {
        Button { showLockedInfo = true } label: {
            HStack(spacing: 7) {
                Image(systemName: "lock.fill")
                Text("Can't export").font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(Theme.subtle)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(Color.white.opacity(0.03))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundStyle(Theme.subtle.opacity(0.35)))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
