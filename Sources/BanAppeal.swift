//
//  BanAppeal.swift
//  Lets a banned account send one appeal message to the admins, and shows it back (pending / reviewed,
//  with the admin's note once there is one) instead of just a static "you're banned" string.
//
//  Two places show this:
//   - AccountBannedOverlay: app-wide, for a ban caught by autologin (the person may never open Settings).
//   - BanAppealCard embedded directly in ZefvAccountScreen: a ban caught while signing in by hand.
//  A banned account has no working session/token, so submitting re-sends the password (same proof login
//  itself would check) rather than needing to sign in first.
//

import SwiftUI

struct BanAppeal {
    var id: Int?
    var submitted: Bool
    var status: String?       // "pending" | "reviewed"
    var message: String?
    var gifURL: URL?
    var adminNote: String?
    var at: String?

    init(json: [String: Any]) {
        id = json["id"] as? Int
        submitted = (json["submitted"] as? Bool) ?? false
        status = json["status"] as? String
        message = json["message"] as? String
        if let g = json["gif_url"] as? String, !g.isEmpty { gifURL = URL(string: g) }
        adminNote = json["admin_note"] as? String
        at = json["at"] as? String
    }
}

struct BanInfo {
    var banned: Bool
    var reason: String?
    var until: String?       // ISO 8601
    var appeal: BanAppeal?

    init(banned: Bool, reason: String?, until: String?, appeal: BanAppeal?) {
        self.banned = banned; self.reason = reason; self.until = until; self.appeal = appeal
    }

    /// `fallbackMessage` is accepted so callers can pass the server's own plain-English ban message, but
    /// `message` below always builds its own copy from `reason`/`until` so the two stay word-for-word consistent.
    init(json: [String: Any], fallbackMessage: String) {
        banned = (json["banned"] as? Bool) ?? true
        reason = json["reason"] as? String
        until = json["until"] as? String
        appeal = (json["appeal"] as? [String: Any]).map(BanAppeal.init(json:))
    }

    var untilDate: Date? {
        guard let until, !until.isEmpty else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: until) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: until)
    }

    var message: String {
        var m = "This account has been banned."
        if let reason, !reason.isEmpty { m += " Reason: \(reason)" }
        if let d = untilDate {
            let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
            m += " It lifts \(df.string(from: d))."
        } else {
            m += " This ban is permanent."
        }
        return m
    }
}

/// Full-screen lock shown app-wide whenever `ZefvAccount.shared.banInfo` is set — mainly for a ban that
/// autologin discovers on launch, before the person has any reason to open Settings themselves.
struct AccountBannedOverlay: View {
    @ObservedObject private var account = ZefvAccount.shared

    var body: some View {
        if let ban = account.banInfo, ban.banned {
            ZStack {
                Color.black.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 18) {
                        Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 40)).foregroundStyle(.orange)
                        Text("Account banned").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                        BanAppealCard(ban: ban, username: account.username ?? "")
                    }
                    .padding(28)
                }
            }
            .transition(.opacity)
        }
    }
}

/// The reusable appeal panel: ban details, then either the one-time appeal form or what was already sent.
struct BanAppealCard: View {
    @ObservedObject private var account = ZefvAccount.shared
    let ban: BanInfo
    let username: String
    @State private var password = ""
    @State private var message = ""
    @State private var gifURL = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(detailLine).font(.system(size: 13)).foregroundStyle(Theme.subtle).multilineTextAlignment(.leading)

            if let appeal = ban.appeal, appeal.submitted {
                submitted(appeal)
            } else {
                form
            }
            if let e = account.appealError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.orange.opacity(0.4), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var detailLine: String {
        var s = (ban.reason?.isEmpty == false) ? "Reason: \(ban.reason!)" : "No reason was given."
        if let d = ban.untilDate {
            let df = DateFormatter(); df.dateStyle = .medium
            s += " Lifts \(df.string(from: d))."
        } else {
            s += " This ban is permanent."
        }
        return s
    }

    private func submitted(_ appeal: BanAppeal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(appeal.status == "reviewed" ? "Appeal reviewed" : "Appeal submitted")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                if appeal.status != "reviewed" {
                    Text("PENDING").font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18)).foregroundStyle(.orange).clipShape(Capsule())
                }
            }
            if let m = appeal.message, !m.isEmpty {
                Text("\u{201C}\(m)\u{201D}").font(.system(size: 13)).foregroundStyle(Theme.subtle)
            }
            if let u = appeal.gifURL {
                AnimatedImageView(url: u).frame(height: 120).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
            }
            if let note = appeal.adminNote, !note.isEmpty {
                Text("Response: \(note)").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
            } else if appeal.status != "reviewed" {
                Text("You'll see a response here once it's reviewed.").font(.system(size: 12)).foregroundStyle(Theme.subtle)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("You can send one appeal message. An admin will review it.")
                .font(.system(size: 12)).foregroundStyle(Theme.subtle)
            SecureField("Password", text: $password)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(Theme.bg).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            ZStack(alignment: .topLeading) {
                if message.isEmpty {
                    Text("Explain why this ban should be lifted\u{2026}")
                        .font(.system(size: 14)).foregroundStyle(Theme.subtle.opacity(0.7))
                        .padding(.horizontal, 14).padding(.vertical, 14)
                }
                TextEditor(text: $message)
                    .font(.system(size: 14)).foregroundStyle(Theme.text).scrollContentBackground(.hidden)
                    .padding(8)
            }
            .frame(minHeight: 90)
            .background(Theme.bg).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            TextField("GIF link (optional, https://…)", text: $gifURL)
                .foregroundStyle(Theme.text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(Theme.bg).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if gifURL.lowercased().hasPrefix("https://"), let u = URL(string: gifURL) {
                AnimatedImageView(url: u).frame(height: 100).frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
            }
            Button(action: submit) {
                HStack {
                    if account.busy { ProgressView().tint(.black) }
                    Text("Submit appeal").font(.system(size: 15, weight: .bold))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Theme.accent).foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(account.busy || username.isEmpty || password.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
        }
    }

    private func submit() {
        Task {
            if await account.submitAppeal(username: username, password: password, message: message, gifURL: gifURL) {
                password = ""; message = ""; gifURL = ""
            }
        }
    }
}
