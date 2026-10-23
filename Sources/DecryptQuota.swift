//
//  DecryptQuota.swift
//  Today's decrypt allowance (guest 3 · signed in 10 · developer 25 · staff and admin unlimited), as the
//  server counts it. Shown in the account dropdown, on the Decrypt tab and on the Partner card.
//

import SwiftUI

struct DecryptQuota: Equatable {
    var tier: String
    var limit: Int?          // nil = unlimited
    var used: Int
    var left: Int?
    var resetsAt: Date?

    var unlimited: Bool { limit == nil }
    var exhausted: Bool { !unlimited && (left ?? 0) <= 0 }

    init?(json: [String: Any]) {
        guard (json["ok"] as? Bool) != false else { return nil }
        tier = (json["tier"] as? String) ?? "guest"
        limit = json["limit"] as? Int
        used = (json["used"] as? Int) ?? 0
        left = json["left"] as? Int
        if (json["unlimited"] as? Bool) == true { limit = nil; left = nil }
        if let s = json["resets_at"] as? String {
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resetsAt = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }
    }

    /// "7 of 10 left today" · "Unlimited"
    var summary: String { unlimited ? "Unlimited" : "\(left ?? 0) of \(limit ?? 0) left today" }

    var tierTitle: String {
        switch tier {
        case "staff": return "Staff"
        case "developer": return "Developer"
        case "member": return "Member"
        default: return "Guest"
        }
    }
}

/// Dropdown row, same look as the storage row.
struct DecryptQuotaRow: View {
    @ObservedObject private var client = DecryptClient.shared

    var body: some View {
        Group {
            if let q = client.quota {
              VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("DECRYPTS TODAY")
                            .font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1.4).foregroundStyle(Theme.subtle)
                        Spacer()
                        Text(q.tierTitle.uppercased())
                            .font(.system(size: 8, weight: .heavy, design: .monospaced)).foregroundStyle(Theme.subtle)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        if q.unlimited {
                            Label("Unlimited", systemImage: "infinity").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.text)
                        } else {
                            Text("\(q.left ?? 0) left").font(.system(size: 15, weight: .bold))
                                .foregroundStyle(q.exhausted ? Color.orange : Theme.text)
                            Spacer(minLength: 4)
                            Text("of \(q.limit ?? 0)").font(.system(size: 10)).foregroundStyle(Theme.subtle)
                        }
                    }
                    if !q.unlimited, let limit = q.limit, limit > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.stroke)
                                Capsule().fill(q.exhausted ? Color.orange : Theme.accent)
                                    .frame(width: max(q.exhausted ? 0 : 4, geo.size.width * CGFloat(q.left ?? 0) / CGFloat(limit)))
                            }
                        }
                        .frame(height: 8)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .accessibilityElement(children: .combine)
                Divider().overlay(Theme.stroke)
              }
            }
        }
        .task { await client.refreshQuota() }
    }
}
