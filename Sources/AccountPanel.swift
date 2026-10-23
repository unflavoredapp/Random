//
//  AccountPanel.swift
//  Bottom account chip + compact user-settings dropdown.
//
import SwiftUI

@MainActor
final class AppNav: ObservableObject {
    static let shared = AppNav()
    @Published var requestedTab: Int?
    @Published var openAccountScreen = false
    private init() {}
    func go(_ tab: Int) { requestedTab = tab; ZefvAccount.shared.panelShown = false }
}

struct AccountChip: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read accent live (auto-cycle) without rebuilding
    @ObservedObject private var account = ZefvAccount.shared
    @ObservedObject private var staff = StaffGate.shared
    private var role: UserRole { staff.isStaff ? staff.role : account.role }

    var body: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            account.panelShown.toggle()
        } label: {
            HStack(spacing: 6) {
                if account.isLoggedIn {
                    Circle().fill(Theme.accent).frame(width: 24, height: 24)
                        .overlay(Text(String((account.username ?? "?").prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(.black))
                    VStack(alignment: .leading, spacing: 1) {
                        StyledUsername(name: account.username ?? "", style: account.style, base: 11)
                        Text(role == .member ? "ACCOUNT" : role.badgeText)
                            .font(.system(size: 7, weight: .heavy, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("SIGN IN").font(.system(size: 8, weight: .heavy, design: .monospaced)).foregroundStyle(Theme.subtle)
                        Text(staff.mdid).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent).lineLimit(1)
                    }
                }
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.subtle)
                    .rotationEffect(.degrees(account.panelShown ? 180 : 0))
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.white.opacity(0.05))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(account.isLoggedIn ? "User settings" : "Sign in")
    }
}

struct AccountDropdown: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read accent live (auto-cycle) without rebuilding
    @ObservedObject private var account = ZefvAccount.shared
    @ObservedObject private var staff = StaffGate.shared
    @ObservedObject private var signed = SignedStore.shared
    @ObservedObject private var nav = AppNav.shared
    @State private var registering = false
    @State private var username = ""
    @State private var password = ""
    @State private var confirmLogout = false

    private var accountUDID: String { CertificateStore.knownUDID(certName: CertificateStore.shared.active?.name) ?? "" }

    private var role: UserRole { staff.isStaff ? staff.role : account.role }
    private var signsToday: Int {
        let cal = Calendar.current
        return max(account.signsToday, signed.entries.filter { cal.isDateInToday($0.signedAt) }.count)
    }
    private var signsTotal: Int { max(account.signsTotal, signed.entries.count) }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.accent).frame(height: 2)
            if account.isLoggedIn { signedIn } else { guest }
        }
        .frame(width: 280)
        .background(Theme.bg)
        .task { await account.refreshProfile(); await account.refreshSignCounts() }
    }

    private var guest: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("LOCAL ACCOUNT").font(.system(size: 11, weight: .heavy, design: .monospaced)).kerning(1).foregroundStyle(Theme.subtle)
                Text(staff.mdid).font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(Theme.accent)
            }.padding(14)
            Divider().overlay(Theme.stroke)
            VStack(spacing: 9) {
                field("Username", text: $username, secure: false)
                field("Password", text: $password, secure: true)
                if let e = account.lastError { Text(e).font(.caption).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading) }
                Button {
                    Task {
                        let ok = registering ? await account.register(username: username, password: password) : await account.login(username: username, password: password)
                        if ok { username = ""; password = "" }
                    }
                } label: {
                    HStack(spacing: 7) {
                        if account.busy { ProgressView().tint(.black) }
                        else { Image(systemName: registering ? "person.crop.circle.badge.plus" : "arrow.right.square.fill") }
                        Text(registering ? "REGISTER" : "SIGN IN").font(.system(size: 14, weight: .heavy, design: .monospaced)).kerning(1)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(Theme.accent).foregroundStyle(.black).clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(account.busy || username.isEmpty || password.isEmpty)
                HStack(spacing: 4) {
                    Text(registering ? "Have an account?" : "No account?").foregroundStyle(Theme.subtle)
                    Button(registering ? "Sign in" : "Register") { withAnimation { registering.toggle(); account.lastError = nil } }.foregroundStyle(Theme.accent)
                }.font(.system(size: 12, weight: .medium))
            }.padding(14)
        }
    }

    private var signedIn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(Theme.accent).frame(width: 42, height: 42)
                    .overlay(Text(String((account.username ?? "?").prefix(1)).uppercased()).font(.system(size: 17, weight: .heavy, design: .rounded)).foregroundStyle(.black))
                VStack(alignment: .leading, spacing: 3) {
                    StyledUsername(name: account.username ?? "", style: account.style, base: 16)
                    Text(accountUDID.isEmpty ? staff.mdid : accountUDID)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.subtle)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if role != .member {
                    HStack(spacing: 5) {
                        Image(systemName: role.icon)
                        Text(role.badgeText)
                    }
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundStyle(role.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(role.color.opacity(0.14))
                    .overlay(Capsule().stroke(role.color.opacity(0.55), lineWidth: 1))
                    .clipShape(Capsule())
                }
            }.padding(14)

            Divider().overlay(Theme.stroke)

            VStack(alignment: .leading, spacing: 8) {
                Text("GROUPS")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .kerning(1.4)
                    .foregroundStyle(Theme.subtle)
                HStack(spacing: 6) {
                    ForEach(account.style.badges.filter { $0 != "verified" }, id: \.self) { badge in
                        if let meta = UserStyle.badgeMeta[badge] {
                            HStack(spacing: 3) {
                                Image(systemName: meta.icon)
                                Text(meta.title).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                            }
                            .font(.system(size: 8, weight: .heavy, design: .monospaced))
                            .foregroundStyle(meta.color)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(meta.color.opacity(0.14))
                            .overlay(Capsule().stroke(meta.color.opacity(0.5), lineWidth: 1))
                            .clipShape(Capsule())
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().overlay(Theme.stroke)

            HStack(spacing: 10) {
                PhoneIcon(height: 30).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("UDID")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .kerning(1.1)
                        .foregroundStyle(Theme.subtle)
                    Text(accountUDID.isEmpty ? "Not set" : accountUDID)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if !accountUDID.isEmpty {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.subtle)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().overlay(Theme.stroke)

            HStack {
                stat("\(signsToday)", "today")
                Rectangle().fill(Theme.stroke).frame(width: 1, height: 30)
                stat("\(signsTotal)", "total")
            }.padding(12)
            Divider().overlay(Theme.stroke)

            Button {
                nav.openAccountScreen = true
                nav.go(4)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape.fill").foregroundStyle(Theme.accent).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("USER SETTINGS").font(.system(size: 13, weight: .heavy, design: .monospaced)).foregroundStyle(Theme.text)
                        Text("Account, device, username and security").font(.system(size: 10)).foregroundStyle(Theme.subtle)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.subtle)
                }
                .padding(14)
            }.buttonStyle(.plain)

            Button { nav.go(1) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "signature").foregroundStyle(Theme.accent).frame(width: 22)
                    Text("SIGNER").font(.system(size: 13, weight: .heavy, design: .monospaced)).foregroundStyle(Theme.text)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.subtle)
                }.padding(14)
            }.buttonStyle(.plain)

            Divider().overlay(Theme.stroke)
            Button { confirmLogout = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("LOGOUT").font(.system(size: 12, weight: .heavy, design: .monospaced)).kerning(1)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 11).foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .confirmationDialog("Log out of \(account.username ?? "")?", isPresented: $confirmLogout, titleVisibility: .visible) {
                Button("Log out", role: .destructive) { Task { await account.logout() } }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func stat(_ value: String, _ title: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(Theme.accent)
            Text(title.uppercased()).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(Theme.subtle)
        }.frame(maxWidth: .infinity)
    }

    private func field(_ placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        Group { if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text).textInputAutocapitalization(.never).autocorrectionDisabled() } }
            .foregroundStyle(Theme.text).padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.white.opacity(0.05)).overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke, lineWidth: 1)).clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
