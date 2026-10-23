import Foundation
import SwiftUI

/// A certificate request this device has sent. Kept locally so the Certificates screen can show the
/// activation steps even before the server reports anything.
struct PendingCertificateRequest: Codable, Equatable {
    var submittedAt: Date
    var type: String
    var requestID: Int? = nil     // the server's id, used to cancel
}

/// Optional extras the server may send with the request status (all fields are optional).
struct CertificateServerStatus: Equatable {
    var status: String?          // "pending" · "approved" / "ready" / "issued" · "rejected" / "denied"
    var message: String?         // shown under the current step
    var etaText: String?         // e.g. "Usually 1-3 days"
    var premiumActive = false
    var premiumExpires: Date?
    var premiumDaysLeft = 0

    var isRejected: Bool { ["denied", "cancelled"].contains((status ?? "").lowercased()) }
    var isApproved: Bool { ["approved", "done"].contains((status ?? "").lowercased()) }
}

@MainActor
final class CertificateRequestClient: ObservableObject {
    static let shared = CertificateRequestClient()
    @Published var error: String?
    @Published var busy = false
    @Published private(set) var pending: PendingCertificateRequest?
    @Published private(set) var server: CertificateServerStatus?

    private static let pendingKey = "AirShare.certRequest.pending"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.pendingKey),
           let value = try? JSONDecoder().decode(PendingCertificateRequest.self, from: data) { pending = value }
    }

    private func request(_ method: String = "GET", body: [String: Any] = [:]) async throws -> [String: Any] {
        guard let base = URL(string: ZefvAccount.apiBase) else { throw ZefvAccount.Err.badURL }
        let url = base.appendingPathComponent("certificate-requests")
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue(ServerConfig.certSourceToken, forHTTPHeaderField: "X-OTA-Token")
        if let token = ZefvAccount.shared.sessionToken {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if method != "GET" {
            var payload = body
            if let token = ZefvAccount.shared.sessionToken { payload["token"] = token }
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 { throw ZefvAccount.Err.server((object["error"] as? String) ?? "Server error (\(code))") }
        return object
    }

    func submit(type: CertificateRequestType, reason: String, udid: String, benefit: String) async -> Bool {
        busy = true
        error = nil
        defer { busy = false }
        do {
            let reply = try await request("POST", body: [
                "action": "create",
                "certificate_type": type.rawValue,
                "reason": reason,
                "udid": udid,
                "benefit": benefit,
                "adid": MDID.current,
                "device_name": UIDevice.current.name
            ])
            setPending(PendingCertificateRequest(submittedAt: Date(), type: type.rawValue, requestID: reply["id"] as? Int))
            server = nil
            return true
        } catch let e {
            error = (e as? ZefvAccount.Err)?.message ?? e.localizedDescription
            return false
        }
    }

    /// Asks the server for the request status. Anything missing from the reply is simply left out, and a
    /// failed call keeps whatever was known before.
    func refreshStatus() async {
        guard ZefvAccount.shared.sessionToken != nil, let object = try? await request() else { return }
        var status = CertificateServerStatus()
        var source = object
        if let list = object["requests"] as? [[String: Any]], let latest = list.first { source = latest }   // server sends newest first
        status.status = source["status"] as? String
        status.message = (source["message"] as? String) ?? (source["note"] as? String)
        if let days = (source["eta_days"] as? Int) ?? (source["max_days"] as? Int) {
            status.etaText = "About \(days) day\(days == 1 ? "" : "s")"
        } else if let eta = source["eta"] as? String, !eta.isEmpty {
            status.etaText = eta
        }
        if let premium = (object["premium"] as? [String: Any]) ?? (source["premium"] as? [String: Any]) {
            status.premiumActive = (premium["active"] as? Bool) ?? true
            status.premiumExpires = Self.date(premium["expires"])
            status.premiumDaysLeft = (premium["days_left"] as? Int) ?? 0
            if status.premiumDaysLeft == 0 && !(premium["active"] as? Bool ?? false) { status.premiumActive = false }
        }
        server = status
        if status.status?.lowercased() == "cancelled", pending != nil { clearPending() }
        // A request made earlier (or on another install) still shows its steps while it is open.
        if pending == nil, let s = status.status?.lowercased(), s == "pending" || s == "approved",
           let created = Self.date(source["created_at"]) {
            setPending(PendingCertificateRequest(submittedAt: created, type: (source["type"] as? String) ?? "Other", requestID: source["id"] as? Int))
        }
    }

    /// Withdraws the open request on the server, then forgets it here.
    func cancel() async {
        guard let id = pending?.requestID else { clearPending(); return }
        do {
            _ = try await request("POST", body: ["action": "cancel", "id": id])
            clearPending()
            server = nil
        } catch let e {
            error = (e as? ZefvAccount.Err)?.message ?? e.localizedDescription
        }
    }

    func clearPending() {
        pending = nil
        UserDefaults.standard.removeObject(forKey: Self.pendingKey)
    }

    private func setPending(_ value: PendingCertificateRequest) {
        pending = value
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: Self.pendingKey) }
    }

    private static func date(_ raw: Any?) -> Date? {
        if let seconds = raw as? Double { return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1000 : seconds) }
        if let seconds = raw as? Int { return date(Double(seconds)) }
        guard let text = raw as? String else { return nil }
        if let value = ISO8601DateFormatter().date(from: text) { return value }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }
}

enum CertificateRequestType: String, CaseIterable, Identifiable {
    case development = "Development"
    case testing = "Testing"
    case personal = "Personal use"
    case other = "Other"
    var id: String { rawValue }
}

/// Request form. Used on its own from Settings, and pushed from the Certificates screen (`embedded`).
struct CertificateRequestView: View {
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var client = CertificateRequestClient.shared
    @State private var type: CertificateRequestType = .development
    @State private var reason = ""
    @State private var udid = CertificateStore.knownUDID() ?? ""
    @State private var benefit = ""

    private var canSubmit: Bool {
        !client.busy
            && !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !udid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !benefit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if embedded { content } else { NavigationStack { content } }
    }

    private var content: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tell us about it").font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                    Text("Requests are reviewed before a certificate is issued.").font(.system(size: 12)).foregroundStyle(Theme.subtle)
                }
                .padding(.horizontal, 4).padding(.top, 6)

                VStack(alignment: .leading, spacing: 10) {
                    label("Type")
                    FlowChips(items: CertificateRequestType.allCases.map(\.rawValue), selected: type.rawValue) { name in
                        if let t = CertificateRequestType(rawValue: name) { type = t }
                    }
                    label("UDID")
                    field { TextField("00008110-000209003C60E01E", text: $udid)
                        .font(.system(size: 13, design: .monospaced))
                        .textInputAutocapitalization(.characters).autocorrectionDisabled() }
                    label("Why do you need a certificate?")
                    editor($reason)
                    label("How will this benefit AirShare?")
                    editor($benefit)

                    if let error = client.error { Text(error).font(.caption).foregroundStyle(.orange) }

                    Button {
                        Task { if await client.submit(type: type, reason: reason, udid: udid, benefit: benefit) { dismiss() } }
                    } label: {
                        HStack(spacing: 8) {
                            if client.busy { ProgressView().tint(.black) } else { Image(systemName: "paperplane.fill") }
                            Text("Submit request").fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(canSubmit ? Theme.accent : Color.white.opacity(0.18))
                        .foregroundStyle(canSubmit ? Color.black : Theme.subtle)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain).disabled(!canSubmit)
                    .padding(.top, 6)
                }
                .padding(14)
                .background(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .padding(.horizontal, 16).padding(.bottom, 24)
        }
        .background(Theme.bg.ignoresSafeArea())
        .safeAreaInset(edge: .top, spacing: 0) {
            TabTitleBar(title: "Request Certificate", showsAccount: false) {
                Button { dismiss() } label: {
                    Image(systemName: embedded ? "chevron.left" : "xmark").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .accessibilityLabel(embedded ? "Back" : "Close")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.subtle).padding(.top, 4)
    }

    private func field<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(11).background(Theme.bg).foregroundStyle(Theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }

    private func editor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 84)
            .padding(6).background(Theme.bg).foregroundStyle(Theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

/// Wrapping row of selectable pills.
struct FlowChips: View {
    let items: [String]
    let selected: String
    let onSelect: (String) -> Void

    var body: some View {
        // Four short options fit on two lines at most; a plain wrapping HStack keeps this simple.
        let rows = stride(from: 0, to: items.count, by: 2).map { Array(items[$0 ..< min($0 + 2, items.count)]) }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.self) { item in
                        let on = item == selected
                        Button { onSelect(item) } label: {
                            Text(item).font(.system(size: 13, weight: on ? .bold : .medium))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(on ? Theme.accent : Color.white.opacity(0.08))
                                .foregroundStyle(on ? Color.black : Theme.text)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
