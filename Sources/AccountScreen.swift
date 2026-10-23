//
//  AccountScreen.swift
//  Settings › Account. Guest → sign in / register (ZefvAccountScreen inline).
//  Signed in → local user settings (username · role · ADID · email), change password,
//  sign out. Roles are assigned on the website (airshare.lol/admin/app).
//

import SwiftUI

struct AccountScreen: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read accent live (auto-cycle) without rebuilding
    @ObservedObject private var account = ZefvAccount.shared
    @ObservedObject private var staff = StaffGate.shared
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var newName = ""
    @State private var curPass = ""
    @State private var newPass = ""
    @State private var adminMDID = MDID.current
    @State private var showMembers = false
    @State private var toast: String?
    @State private var accountUDID = CertificateStore.knownUDID() ?? ""
    @State private var confirAirShareOut = false
    @State private var draft: UserStyle = ZefvAccount.shared.style
    @State private var pickedColor: Color = Theme.accent
    @AppStorage("as_profile_settings_open") private var showAccountOptions = false

    private var role: UserRole { staff.isStaff ? staff.role : account.role }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ThemeBackgroundLayer()
            if account.isLoggedIn { userSettings } else { ZefvAccountScreen(mode: .signIn, dismissOnSuccess: false) }
        }
        .overlay(alignment: .topTrailing) {
            if !account.isLoggedIn { closeButton.padding(.top, 8).padding(.trailing, 16) }
        }
        .preferredColorScheme(AppTheme.shared.colorScheme)
        .task {
            await account.refreshProfile()
            email = account.email ?? ""
            draft = account.style
            refreshAccountUDID()
        }
        .onAppear { refreshAccountUDID() }
        .onReceive(NotificationCenter.default.publisher(for: .airshareKnownUDIDDidChange)) { _ in
            refreshAccountUDID()
        }
        .sheet(isPresented: $showMembers) { AdminMembersSheet().preferredColorScheme(AppTheme.shared.colorScheme) }
        .onChange(of: account.email) { email = $0 ?? "" }
        .onChange(of: account.style) { draft = $0 }
        .onReceive(CertificateStore.shared.$certificates) { _ in refreshAccountUDID() }
    }

    // MARK: - User settings

    private var userSettings: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                // Header: title + close
                HStack {
                    Text("Profile").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                    Spacer()
                    closeButton
                }
                .padding(.top, 4)
                // Identity card
                VStack(spacing: 12) {
                    ZStack {
                        Circle().fill(role.color.opacity(0.18)).frame(width: 84, height: 84)
                        Circle().stroke(role.color.opacity(0.5), lineWidth: 2).frame(width: 84, height: 84)
                        Text(String((account.username ?? "?").prefix(1)).uppercased())
                            .font(.system(size: 34, weight: .heavy, design: .rounded)).foregroundStyle(role.color)
                    }
                    StyledUsername(name: account.username ?? "", style: account.style, base: 24)

                    // Account role — the primary account classification.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ROLE")
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .kerning(1.5)
                            .foregroundStyle(Theme.subtle)

                        HStack(spacing: 8) {
                            Image(systemName: role.icon)
                                .font(.system(size: 13, weight: .bold))
                            Text(role.badgeText)
                                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                .kerning(1)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(role.color.opacity(0.18))
                        .foregroundStyle(role.color)
                        .overlay(Capsule().stroke(role.color.opacity(0.5), lineWidth: 1))
                        .clipShape(Capsule())
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)

                    // Groups are the account badges attached to the user.
                    VStack(alignment: .leading, spacing: 8) {
                        Text("GROUPS")
                            .font(.system(size: 11, weight: .heavy, design: .monospaced))
                            .kerning(1.5)
                            .foregroundStyle(Theme.subtle)

                        if account.style.badges.isEmpty {
                            Text("No groups")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.subtle)
                        } else {
                            BadgeRow(badges: account.style.badges)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)

                    // Sponsor (set by an admin).
                    if !account.sponsor.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SPONSOR")
                                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                .kerning(1.5)
                                .foregroundStyle(Theme.subtle)
                            HStack(spacing: 6) {
                                Image(systemName: "star.circle.fill").font(.system(size: 13, weight: .bold))
                                Text(account.sponsor).font(.system(size: 13, weight: .bold))
                            }
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5))
                            .background(Color(red: 0.4, green: 0.9, blue: 0.5).opacity(0.16))
                            .overlay(Capsule().stroke(Color(red: 0.4, green: 0.9, blue: 0.5).opacity(0.5), lineWidth: 1))
                            .clipShape(Capsule())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                    }

                    // Private device identifier.
                    Button {
                        if !accountUDID.isEmpty {
                            UIPasteboard.general.string = accountUDID
                            flash("UDID copied")
                        }
                    } label: {
                        HStack(spacing: 10) {
                            PhoneIcon(height: 34).frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("UDID")
                                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                                    .kerning(1.2)
                                    .foregroundStyle(Theme.subtle)

                                Text(accountUDID.isEmpty ? "Not set" : accountUDID)
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Theme.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()
                            if !accountUDID.isEmpty {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Theme.subtle)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 22)
                .background(ProfileBackdrop(style: account.style))
                .overlay(alignment: .topTrailing) {            // gear: show / hide the customization options
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showAccountOptions.toggle() }
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(showAccountOptions ? Color.black : Theme.accent)
                            .frame(width: 34, height: 34)
                            .background(showAccountOptions ? Theme.accent : Theme.accent.opacity(0.16), in: Circle())
                    }
                    .buttonStyle(.plain).padding(12)
                }
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.stroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 18))

                if showAccountOptions {
                // Style (registered users)
                Card {
                    section("Username style")
                    VStack(alignment: .leading, spacing: 12) {
                        // Color
                        Text("COLOR").font(.system(size: 10, weight: .bold)).kerning(1.2).foregroundStyle(Theme.subtle)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                swatch(nil)
                                ForEach(UserStyle.presets, id: \.self) { swatch($0) }
                                ColorPicker("", selection: $pickedColor, supportsOpacity: false)
                                    .labelsHidden().frame(width: 28, height: 28)
                                    .onChange(of: pickedColor) { c in
                                        if let h = c.hexString() { draft.colorHex = "#" + h.uppercased().replacingOccurrences(of: "#", with: "") }
                                    }
                            }
                            .padding(.vertical, 2)
                        }
                        // Rainbow
                        Toggle(isOn: $draft.rainbow) {
                            HStack(spacing: 8) {
                                Image(systemName: "rainbow").symbolRenderingMode(.multicolor)
                                Text("Rainbow name").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                            }
                        }
                        .tint(Theme.accent)
                        // Font + size
                        HStack(spacing: 10) {
                            Menu {
                                ForEach(UserStyle.fonts, id: \.name) { f in
                                    Button {
                                        draft.fontName = f.name
                                    } label: {
                                        if f.name == draft.fontName { Label(f.label, systemImage: "checkmark") } else { Text(f.label) }
                                    }
                                }
                            } label: {
                                pickerLabel("FONT", draft.fontLabel)
                            }
                            .buttonStyle(.plain)
                            Menu {
                                ForEach(UserStyle.sizes, id: \.step) { sz in
                                    Button {
                                        draft.sizeStep = sz.step
                                    } label: {
                                        if sz.step == draft.sizeStep { Label(sz.label, systemImage: "checkmark") } else { Text(sz.label) }
                                    }
                                }
                            } label: {
                                pickerLabel("SIZE", UserStyle.sizes.first { $0.step == draft.sizeStep }?.label ?? "M")
                            }
                            .buttonStyle(.plain)
                        }
                        // Animated background
                        Text("ANIMATED BACKGROUND (GIF URL)").font(.system(size: 10, weight: .bold)).kerning(1.2).foregroundStyle(Theme.subtle)
                        field("https://…/background.gif", text: $draft.gifURL, secure: false, keyboard: .URL)
                        if draft.hasGIF, let u = URL(string: draft.gifURL) {
                            GeometryReader { g in
                                AnimatedImageView(url: u).frame(width: g.size.width, height: g.size.height).clipped()
                            }
                            .frame(height: 90).frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
                        }
                        // Preview + save
                        HStack {
                            Text("Preview:").font(.system(size: 12)).foregroundStyle(Theme.subtle)
                            StyledUsername(name: account.username ?? "", style: draft, base: 16)
                            Spacer()
                            Button {
                                Task { if await account.setStyle(draft) { flash("Style saved") } }
                            } label: {
                                HStack(spacing: 6) { if account.busy { ProgressView().tint(.black) }; Text("Save style").font(.system(size: 13, weight: .bold)) }
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(Theme.accent).foregroundStyle(.black).clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(account.busy || draft == account.style)
                        }
                    }
                }

                // Role explainer
                Card {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(role.isElevated ? "Staff tools unlocked" : "Standard access")
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                            Text("Roles are assigned by AirShare staff. Pull to re-check after a change.")
                                .font(.system(size: 12)).foregroundStyle(Theme.subtle)
                        }
                        Spacer()
                        Button {
                            Task { await account.refreshProfile(); flash("Role: \(role.title)") }
                        } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                                .frame(width: 30, height: 30).background(Theme.accent.opacity(0.14)).clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Admin ADID reassignment
                if role == .admin {
                    Card {
                        section("Admin ADID")
                        Text("Assign a new ADID to this admin account. The server updates the account and role mapping first; AirShare changes its local ADID only after the server accepts the new value.")
                            .font(.system(size: 11)).foregroundStyle(Theme.subtle)
                        HStack(spacing: 10) {
                            field("AS-XXXXXX-XX", text: $adminMDID, secure: false, keyboard: .asciiCapable)
                            Button("Update") {
                                let requested = adminMDID
                                Task {
                                    if await account.adminChangeOwnMDID(requested) {
                                        adminMDID = MDID.current
                                        flash("ADID updated")
                                    }
                                }
                            }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .disabled(account.busy || !MDIDManager.shared.isValid(adminMDID))
                        }
                        HStack(spacing: 8) {
                            Text("Current: \(MDID.current)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.accent)
                            Spacer()
                            Button("Random") {
                                adminMDID = MDID.randomPreview()
                            }
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.accent)
                        }
                    }
                }

                // Admin: groups & sponsors
                if role == .admin {
                    Card {
                        section("Groups & sponsors")
                        Text("Put members in groups (Admin, Co-Admin, Staff, Sponsor…) and set their sponsor. Only admins can change these.")
                            .font(.system(size: 11)).foregroundStyle(Theme.subtle)
                        Button { showMembers = true } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "person.3.fill")
                                Text("Manage members").font(.system(size: 14, weight: .bold))
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                            }
                            .foregroundStyle(Theme.accent)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Username
                Card {
                    section("Username")
                    HStack(spacing: 10) {
                        field(account.username ?? "username", text: $newName, secure: false)
                        Button("Rename") {
                            Task { if await account.setUsername(newName) { newName = ""; flash("Username changed") } }
                        }
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                        .disabled(account.busy || newName.count < 3 || newName == account.username)
                    }
                    Text("3–32 characters · letters, digits, _ or . · roles follow the account, not the name")
                        .font(.system(size: 11)).foregroundStyle(Theme.subtle).padding(.top, 6)
                }

                // Email
                Card {
                    section("Email")
                    HStack(spacing: 10) {
                        field("you@example.com", text: $email, secure: false, keyboard: .emailAddress)
                        Button("Save") { Task { if await account.setEmail(email) { flash("Email saved") } } }
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                            .disabled(account.busy || email == (account.email ?? ""))
                    }
                }

                // Password
                Card {
                    section("Change password")
                    VStack(spacing: 8) {
                        field("Current password", text: $curPass, secure: true)
                        field("New password (min 6)", text: $newPass, secure: true)
                        Button {
                            Task {
                                if await account.changePassword(current: curPass, new: newPass) { curPass = ""; newPass = ""; flash("Password changed") }
                            }
                        } label: {
                            HStack { if account.busy { ProgressView().tint(.black) }; Text("Update password").font(.system(size: 15, weight: .bold)) }
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Theme.accent).foregroundStyle(.black)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(account.busy || curPass.isEmpty || newPass.count < 6)
                    }
                }

                } // showAccountOptions

                if let e = account.lastError {
                    Text(e).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(role: .destructive) { confirAirShareOut = true } label: {
                    Text("Sign out").font(.system(size: 15, weight: .semibold)).foregroundStyle(.red)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.red.opacity(0.12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.35), lineWidth: 1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .confirmationDialog("Sign out of \(account.username ?? "")?", isPresented: $confirAirShareOut, titleVisibility: .visible) {
                    Button("Sign out", role: .destructive) { Task { await account.logout() } }
                    Button("Cancel", role: .cancel) {}
                }
            }
            .padding(16)
        }
        .refreshable { await account.refreshProfile() }
        .scrollDismissesKeyboard(.interactively)
        .overlay(alignment: .bottom) {
            if let toast {
                Text(toast).font(.system(size: 13, weight: .semibold)).foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Theme.accent).clipShape(Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var header: some View {
        ZStack {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(Theme.accent)
                Text("USER SETTINGS").font(.system(size: 15, weight: .heavy, design: .rounded)).kerning(1).foregroundStyle(Theme.text)
                Spacer()
            }
            Text(account.username ?? "").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.subtle)
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

    // MARK: - Bits

    private func section(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(1).foregroundStyle(Theme.subtle).padding(.bottom, 8)
    }

    private func field(_ ph: String, text: Binding<String>, secure: Bool, keyboard: UIKeyboardType = .default) -> some View {
        Group {
            if secure { SecureField(ph, text: text) }
            else { TextField(ph, text: text).keyboardType(keyboard).autocorrectionDisabled().textInputAutocapitalization(.never) }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(Color.white.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func pickerLabel(_ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 9, weight: .bold)).kerning(1).foregroundStyle(Theme.subtle)
                Text(value).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.subtle)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    private func swatch(_ hex: String?) -> some View {
        let selected = (hex ?? "") == draft.colorHex
        return Button { draft.colorHex = hex ?? "" } label: {
            ZStack {
                Circle().fill(hex.map { Color(hex: String($0.dropFirst())) } ?? Theme.card).frame(width: 28, height: 28)
                if hex == nil { Image(systemName: "slash.circle").font(.system(size: 14)).foregroundStyle(Theme.subtle) }
            }
            .overlay(Circle().stroke(selected ? Color.white : Theme.stroke, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                .frame(width: 34, height: 34).background(Color.white.opacity(0.10), in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel("Close")
    }

    /// Saved UDID, else one detected from the active certificate (named after the UDID / single-device profile).
    /// A detected value is persisted so it survives restarts and shows everywhere.
    private func refreshAccountUDID() {
        CertificateStore.shared.adoptUDIDFromActiveCertificate()
        accountUDID = CertificateStore.knownUDID(certName: CertificateStore.shared.active?.name) ?? ""
    }

    private func flash(_ m: String) {
        withAnimation { toast = m }
        Task { try? await Task.sleep(nanoseconds: 1_600_000_000); withAnimation { toast = nil } }
    }
}
