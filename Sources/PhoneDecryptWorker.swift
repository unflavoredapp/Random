//
// Brand: Tetherless · https://tetherless.dev
//  PhoneDecryptWorker.swift
//  Polls the site for decrypt jobs (own TG bot / website queue), runs the same
//  Store → FairPlay path on this iPhone, uploads the clear IPA. Replaces the
//  old FastDecryptBot bridge.
//

import Foundation
import SwiftUI

@MainActor
final class PhoneDecryptWorker: ObservableObject {
    static let shared = PhoneDecryptWorker()

    private static let enabledKey = "tetherless.decrypt.workerEnabled"
    private static let tokenKey = "tetherless.decrypt.workerToken"

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) }
    }
    @Published var workerToken: String {
        didSet { UserDefaults.standard.set(workerToken, forKey: Self.tokenKey) }
    }
    @Published private(set) var status = "Off"
    @Published private(set) var lastError: String?
    @Published private(set) var busy = false

    private var loopTask: Task<Void, Never>?

    private init() {
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        workerToken = UserDefaults.standard.string(forKey: Self.tokenKey) ?? ""
    }

    func startIfNeeded() {
        guard enabled else {
            stop()
            status = "Off"
            return
        }
        guard loopTask == nil else { return }
        status = "Starting…"
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        if !busy { status = enabled ? "Stopped" : "Off" }
    }

    func applyEnabled(_ on: Bool) {
        enabled = on
        if on { startIfNeeded() } else { stop() }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            if !enabled {
                status = "Off"
                break
            }
            let token = workerToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty {
                status = "Set worker token"
                lastError = "Enter the same DECRYPT_WORKER_TOKEN as the server."
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }
            if DecryptClient.phoneWorkerSiteBase == nil {
                status = "Set Decrypt site URL"
                lastError =
                    "Phone Worker needs FairPlay Decrypt → Decrypt site URL set to your Linux VPS (https://…). Don’t leave it empty (that falls back to tetherless.dev)."
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            }
            do {
                if let job = try await claim(token: token) {
                    await handle(job: job, token: token)
                } else {
                    status = "Idle · waiting for jobs"
                    lastError = nil
                }
            } catch {
                lastError = error.localizedDescription
                status = "Claim error"
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
        }
        loopTask = nil
    }

    private struct ClaimedJob {
        let id: String
        let url: String
        let version: String
    }

    private func claim(token: String) async throws -> ClaimedJob? {
        var req = try makeRequest("api/decrypt/worker/claim", token: token)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "adid": MDID.current
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if code == 401 {
            throw DecryptError((json["error"] as? String) ?? "Unauthorized worker token.")
        }
        guard code < 400, (json["ok"] as? Bool) != false else {
            throw DecryptError((json["error"] as? String) ?? "Claim failed (\(code)).")
        }
        guard let job = json["job"] as? [String: Any],
              let id = job["id"] as? String,
              let url = job["url"] as? String,
              !id.isEmpty, !url.isEmpty else {
            return nil
        }
        return ClaimedJob(
            id: id,
            url: url,
            version: (job["version"] as? String) ?? ""
        )
    }

    private func handle(job: ClaimedJob, token: String) async {
        busy = true
        status = "Decrypting…"
        lastError = nil
        defer { busy = false }
        do {
            try await progress(job.id, "Claimed on \(UIDevice.current.name)…", token: token)
            let tokenCapture = token
            let jobID = job.id
            let result = try await DeviceDecryptService.shared.decryptForWorkerUpload(
                storeURL: job.url,
                displayName: "App",
                version: job.version.isEmpty ? nil : job.version
            ) { [weak self] msg in
                Task { @MainActor in
                    self?.status = msg
                    try? await self?.progress(jobID, msg, token: tokenCapture)
                }
            }
            try await progress(job.id, "Uploading clear IPA…", token: token)
            try await upload(jobID: job.id, ipa: result.url, name: result.name, token: token)
            status = "Uploaded \(result.name)"
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            status = "Failed"
            try? await fail(job.id, error.localizedDescription, token: token)
        }
    }

    private func progress(_ id: String, _ msg: String, token: String) async throws {
        var req = try makeRequest("api/decrypt/worker/progress", token: token)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "msg": msg])
        _ = try await URLSession.shared.data(for: req)
    }

    private func fail(_ id: String, _ error: String, token: String) async throws {
        var req = try makeRequest("api/decrypt/worker/fail", token: token)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["id": id, "error": error])
        _ = try await URLSession.shared.data(for: req)
    }

    private func upload(jobID: String, ipa: URL, name: String, token: String) async throws {
        guard let base = DecryptClient.phoneWorkerSiteBase,
              var comps = URLComponents(string: base + "api/decrypt/worker/complete") else {
            throw DecryptError("Set Decrypt site URL to your Linux VPS before uploading.")
        }
        comps.queryItems = [
            URLQueryItem(name: "id", value: jobID),
            URLQueryItem(name: "name", value: name),
        ]
        guard let url = comps.url else { throw DecryptError("Bad worker URL.") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(token, forHTTPHeaderField: "X-Decrypt-Worker-Token")
        req.setValue(MDID.current, forHTTPHeaderField: "X-AS-ADID")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = try Data(contentsOf: ipa)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard code < 400, (json["ok"] as? Bool) != false else {
            throw DecryptError((json["error"] as? String) ?? "Upload failed (\(code)).")
        }
    }

    private func makeRequest(_ path: String, token: String, timeout: TimeInterval = 60) throws -> URLRequest {
        guard let base = DecryptClient.phoneWorkerSiteBase,
              let url = URL(string: base + path) else {
            throw DecryptError("Set Decrypt site URL to your Linux VPS (FairPlay Decrypt settings).")
        }
        var r = URLRequest(url: url)
        r.timeoutInterval = timeout
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue(token, forHTTPHeaderField: "X-Decrypt-Worker-Token")
        r.setValue(MDID.current, forHTTPHeaderField: "X-AS-ADID")
        return r
    }
}
