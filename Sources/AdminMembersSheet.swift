//
//  AdminMembersSheet.swift
//  Admin-only: put members in groups (Admin, Co-Admin, Staff, Sponsor, …) and set a sponsor.
//  The server rejects these calls for anyone who isn't an admin.
//

import SwiftUI

struct AdminMembersSheet: View {
    @ObservedObject private var account = ZefvAccount.shared
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @State private var catalog: [String] = []
    @State private var users: [ZefvAccount.AdminMember] = []
    @State private var sponsorDraft: [String: String] = [:]
    @State private var loading = false
    @State private var note: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("MEMBERS").font(.system(size: 15, weight: .bold)).kerning(1).foregroundStyle(Theme.text)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text)
                            .frame(width: 32, height: 32).background(Color.white.opacity(0.12)).clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)

                TextField("Search username", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(10).background(Theme.card).foregroundStyle(Theme.text)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 16).padding(.bottom, 8)

                if let note {
                    Text(note).font(.system(size: 12)).foregroundStyle(.orange).padding(.horizontal, 16).padding(.bottom, 6)
                }

                ScrollView {
                    LazyVStack(spacing: 12) {
                        if loading && users.isEmpty { ProgressView().tint(Theme.accent).padding(.top, 30) }
                        ForEach(users) { u in row(u) }
                        if !loading && users.isEmpty {
                            Text("No members found.").font(.system(size: 13)).foregroundStyle(Theme.subtle).padding(.top, 30)
                        }
                    }
                    .padding(.horizontal, 16).padding(.bottom, 30)
                }
            }
        }
        .task { await reload() }
        .onChange(of: query) { _ in
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
    }

    private func reload() async {
        loading = true; note = nil
        if let r = await account.adminListUsers(query.trimmingCharacters(in: .whitespaces)) {
            catalog = r.groups; users = r.users
            for u in r.users where sponsorDraft[u.username] == nil { sponsorDraft[u.username] = u.sponsor }
        } else {
            note = account.lastError ?? "Couldn't load members."
        }
        loading = false
    }

    private func row(_ u: ZefvAccount.AdminMember) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(u.username).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                Text(u.role.uppercased()).font(.system(size: 9, weight: .heavy, design: .monospaced)).foregroundStyle(Theme.subtle)
                Spacer()
            }

            Text("GROUPS").font(.system(size: 10, weight: .heavy, design: .monospaced)).kerning(1.2).foregroundStyle(Theme.subtle)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(catalog, id: \.self) { g in chip(u, g) }
            }

            Text("SPONSOR").font(.system(size: 10, weight: .heavy, design: .monospaced)).kerning(1.2).foregroundStyle(Theme.subtle)
            HStack(spacing: 8) {
                TextField("e.g. FastDecryptBot", text: Binding(
                    get: { sponsorDraft[u.username] ?? u.sponsor },
                    set: { sponsorDraft[u.username] = $0 }))
                    .autocorrectionDisabled()
                    .padding(9).background(Color.white.opacity(0.05)).foregroundStyle(Theme.text)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                Button("Save") { Task { await saveSponsor(u, sponsorDraft[u.username] ?? "") } }
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                if !u.sponsor.isEmpty {
                    Button("Clear") { Task { await saveSponsor(u, "") } }
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(.red)
                }
            }
        }
        .padding(14)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.stroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func chip(_ u: ZefvAccount.AdminMember, _ g: String) -> some View {
        let meta = UserStyle.badgeMeta[g]
        let tint = meta?.color ?? Theme.accent
        let on = u.groups.contains(g)
        return Button { Task { await toggle(u, g) } } label: {
            HStack(spacing: 4) {
                Image(systemName: on ? "checkmark" : (meta?.icon ?? "circle")).font(.system(size: 9, weight: .bold))
                Text(meta?.title ?? g.uppercased()).font(.system(size: 10, weight: .heavy, design: .monospaced)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .foregroundStyle(on ? tint : Theme.subtle)
            .background(on ? tint.opacity(0.18) : Color.white.opacity(0.04))
            .overlay(Capsule().stroke(on ? tint.opacity(0.6) : Theme.stroke, lineWidth: 1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ u: ZefvAccount.AdminMember, _ g: String) async {
        var next = u.groups
        if let i = next.firstIndex(of: g) { next.remove(at: i) } else { next.append(g) }
        UISelectionFeedbackGenerator().selectionChanged()
        if let saved = await account.adminSetGroups(u.username, next), let i = users.firstIndex(where: { $0.username == u.username }) {
            users[i].groups = saved; note = nil
        } else { note = account.lastError }
    }

    private func saveSponsor(_ u: ZefvAccount.AdminMember, _ value: String) async {
        if let saved = await account.adminSetSponsor(u.username, value), let i = users.firstIndex(where: { $0.username == u.username }) {
            users[i].sponsor = saved; sponsorDraft[u.username] = saved; note = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else { note = account.lastError }
    }
}
