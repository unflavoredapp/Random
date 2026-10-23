import Foundation
import SwiftUI

@MainActor
final class CertificateRequestClient: ObservableObject {
    static let shared = CertificateRequestClient()
    @Published var error: String?
    @Published var busy = false
    private init() {}

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
            _ = try await request("POST", body: [
                "action": "create",
                "certificate_type": type.rawValue,
                "reason": reason,
                "udid": udid,
                "benefit": benefit,
                "adid": MDID.current
            ])
            return true
        } catch let e {
            error = (e as? ZefvAccount.Err)?.message ?? e.localizedDescription
            return false
        }
    }
}

enum CertificateRequestType: String, CaseIterable, Identifiable {
    case development = "Development"
    case testing = "Testing"
    case personal = "Personal use"
    case other = "Other"
    var id: String { rawValue }
}

struct CertificateRequestView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var client = CertificateRequestClient.shared
    @State private var type: CertificateRequestType = .development
    @State private var reason = ""
    @State private var udid = CertificateStore.knownUDID() ?? ""
    @State private var benefit = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Certificate") {
                    Picker("Type", selection: $type) {
                        ForEach(CertificateRequestType.allCases) { Text($0.rawValue).tag($0) }
                    }
                    TextField("UDID", text: $udid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Why do you need a certificate?") {
                    TextEditor(text: $reason).frame(minHeight: 100)
                }
                Section("How will this benefit AirShare?") {
                    TextEditor(text: $benefit).frame(minHeight: 100)
                }
                Section {
                    Button {
                        Task {
                            if await client.submit(type: type, reason: reason, udid: udid, benefit: benefit) { dismiss() }
                        }
                    } label: {
                        HStack {
                            if client.busy { ProgressView() }
                            Text("Submit request")
                        }
                    }
                    .disabled(client.busy || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || udid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || benefit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let error = client.error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Request Certificate")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
