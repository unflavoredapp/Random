//
//  LocalWorkflowAPI.swift
//  One tracked transaction across the decrypt and sign stages of the local TrustCore engine.
//
//  A workflow owns a parent ID. The decrypt job and the sign job keep their own IDs (and their own
//  routes), and the workflow records both so the whole operation reads as one thing:
//
//    POST /v1/workflows                 {"url": "...", "version": "...", "signAfter": true, "install": false,
//                                        "signOptions": {"name": "...", "bundleID": "...", "version": "...", "parallelSigning": true}}
//    GET  /v1/workflows                 -> [workflow]
//    GET  /v1/workflows/:id             -> workflow (stage, overall progress, both child jobs inline)
//    POST /v1/workflows/:id/cancel      -> cancels whichever stage is running, nothing later starts
//    POST /v1/workflows/:id/retry       -> resumes at the stage that stopped (a finished decrypt is reused)
//
//  Status: queued · decrypting · signing · completed · failed · cancelling · cancelled · interrupted
//

import Foundation
import Vapor

nonisolated struct LocalWorkflowSignOptions: Content, Sendable, Codable {
    var name: String?
    var bundleID: String?
    var version: String?
    var parallelSigning: Bool?
}

nonisolated struct LocalWorkflowRequest: Content, Sendable {
    var url: String
    var version: String?            // App Store version to decrypt (same as POST /v1/decrypt)
    var signAfter: Bool?            // default true; false stops after the decrypt
    var install: Bool?              // default false; true publishes the OTA install link after signing
    var signOptions: LocalWorkflowSignOptions?
}

nonisolated struct LocalWorkflow: Sendable, Codable {
    let id: UUID
    var kind: String
    var status: String = "queued"
    var stage: String = "decrypt"       // decrypt · sign · done
    var url: String
    var version: String?
    var signAfter: Bool
    var install: Bool
    var signOptions: LocalWorkflowSignOptions?
    var decryptJobIDs: [UUID] = []
    var signJobIDs: [UUID] = []
    var decryptedPath: String?
    var failedStage: String?
    var cancelledStage: String?
    var error: String?
    var createdAt = Date()
    var updatedAt = Date()
}

nonisolated struct LocalWorkflowResponse: Content, Sendable {
    var id: String
    var kind: String
    var status: String
    var stage: String
    var progress: Double
    var failedStage: String?
    var cancelledStage: String?
    var error: String?
    var decryptJobID: String?
    var signJobID: String?
    var decryptJobIDs: [String]
    var signJobIDs: [String]
    var decrypt: LocalDecryptJobResponse?
    var sign: LocalZSignJobResponse?
    var decryptedPath: String?
    var createdAt: Date
    var updatedAt: Date
}

private struct StageFailure: LocalizedError {
    let stage: String
    let message: String
    var errorDescription: String? { message }
}

actor LocalWorkflowStore {
    private var flows: [UUID: LocalWorkflow] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let fileURL: URL

    private static let active: Set<String> = ["queued", "decrypting", "signing", "cancelling"]

    /// Saved to disk. A workflow that was mid-flight when the app closed comes back as "interrupted";
    /// retry resumes at the stage that stopped and reuses a finished decrypt if its file is still there.
    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrustCore", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("workflows.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([LocalWorkflow].self, from: data) {
            let cutoff = Date().addingTimeInterval(-7 * 86_400)
            for var w in saved where w.createdAt > cutoff {
                if Self.active.contains(w.status) {
                    w.status = "interrupted"
                    w.failedStage = w.stage == "done" ? nil : w.stage
                    w.error = "TrustCore was closed during the \(w.stage) stage. Retry with POST /v1/workflows/\(w.id.uuidString)/retry."
                }
                flows[w.id] = w
            }
            if let data = try? JSONEncoder().encode(Array(flows.values)) { try? data.write(to: fileURL, options: .atomic) }
        }
    }

    private func persist() {
        let newest = flows.values.sorted { $0.createdAt > $1.createdAt }.prefix(100)
        if let data = try? JSONEncoder().encode(Array(newest)) { try? data.write(to: fileURL, options: .atomic) }
    }

    func all() -> [LocalWorkflow] { flows.values.sorted { $0.createdAt > $1.createdAt } }
    func get(_ id: UUID) -> LocalWorkflow? { flows[id] }
    func hasActive() -> Bool { flows.values.contains { Self.active.contains($0.status) } }

    private func update(_ id: UUID, _ mutate: (inout LocalWorkflow) -> Void) {
        guard var w = flows[id] else { return }
        mutate(&w)
        w.updatedAt = Date()
        flows[id] = w
        persist()
    }

    // MARK: Lifecycle

    func create(_ r: LocalWorkflowRequest) -> LocalWorkflow {
        let sign = r.signAfter ?? true
        let install = sign && (r.install ?? false)
        let kind = !sign ? "decrypt" : (install ? "decrypt-sign-install" : "decrypt-sign")
        let w = LocalWorkflow(id: UUID(), kind: kind, url: r.url, version: r.version, signAfter: sign, install: install, signOptions: r.signOptions)
        flows[w.id] = w
        persist()
        launch(w.id)
        return w
    }

    func retry(_ id: UUID) -> LocalWorkflow? {
        guard let w = flows[id], ["failed", "cancelled", "interrupted"].contains(w.status) else { return nil }
        update(id) { $0.status = "queued"; $0.error = nil; $0.failedStage = nil; $0.cancelledStage = nil }
        launch(id)
        return flows[id]
    }

    /// Cancels whichever stage is running. The orchestrator sees the flag, cancels the child job and stops.
    func cancel(_ id: UUID) async -> LocalWorkflow? {
        guard let w = flows[id] else { return nil }
        guard ["queued", "decrypting", "signing"].contains(w.status) else { return w }
        update(id) { $0.status = "cancelling" }
        if w.stage == "decrypt", let d = w.decryptJobIDs.last { _ = await LocalDecryptAPI.jobs.cancel(d) }
        if w.stage == "sign", let s = w.signJobIDs.last { await LocalZSignAPI.shared.requestSignCancel(s) }
        return flows[id]
    }

    private func launch(_ id: UUID) {
        tasks[id] = Task { [weak self] in await self?.run(id) }
    }

    private func isCancelling(_ id: UUID) -> Bool { flows[id]?.status == "cancelling" }

    private func finishCancelled(_ id: UUID, stage: String) {
        update(id) { $0.status = "cancelled"; $0.cancelledStage = stage; $0.error = nil }
    }

    // MARK: Orchestration

    private func run(_ id: UUID) async {
        defer { tasks[id] = nil }
        guard let start = flows[id] else { return }
        do {
            // ---- Stage 1: decrypt (skipped on retry when the file from an earlier attempt is still there)
            let reusable = start.decryptedPath.map { FileManager.default.fileExists(atPath: $0) } ?? false
            if !reusable {
                if isCancelling(id) { finishCancelled(id, stage: "decrypt"); return }
                if await LocalDecryptAPI.jobs.hasActive() { throw StageFailure(stage: "decrypt", message: "Another decrypt is already running.") }
                update(id) { $0.status = "decrypting"; $0.stage = "decrypt"; $0.decryptedPath = nil }
                let dj = await LocalDecryptAPI.jobs.start(url: start.url, version: start.version)
                update(id) { $0.decryptJobIDs.append(dj.id) }
                if isCancelling(id) { _ = await LocalDecryptAPI.jobs.cancel(dj.id) }
                while true {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let j = await LocalDecryptAPI.jobs.get(dj.id) else { throw StageFailure(stage: "decrypt", message: "The decrypt job disappeared.") }
                    if j.status == "done", let out = j.output {
                        update(id) { $0.decryptedPath = out.path }
                        break
                    }
                    if j.status == "failed" { throw StageFailure(stage: "decrypt", message: j.error ?? "Decrypt failed.") }
                    if j.status == "cancelled" {
                        if isCancelling(id) { finishCancelled(id, stage: "decrypt"); return }
                        throw StageFailure(stage: "decrypt", message: "The decrypt job was cancelled.")
                    }
                    if isCancelling(id) { _ = await LocalDecryptAPI.jobs.cancel(dj.id) }
                }
            }

            guard let w1 = flows[id], let path = w1.decryptedPath else { throw StageFailure(stage: "decrypt", message: "No decrypted IPA.") }
            if !w1.signAfter { update(id) { $0.status = "completed"; $0.stage = "done" }; return }

            // ---- Stage 2: sign (and publish the install link when asked)
            if isCancelling(id) { finishCancelled(id, stage: "sign"); return }
            update(id) { $0.status = "signing"; $0.stage = "sign" }
            let o = w1.signOptions
            let signID: UUID
            do {
                signID = try await LocalZSignAPI.shared.startWorkflowSign(path: path, name: o?.name, bundleID: o?.bundleID,
                                                                          version: o?.version, parallelSigning: o?.parallelSigning,
                                                                          publishOTA: w1.install)
            } catch {
                throw StageFailure(stage: "sign", message: (error as? AbortError)?.reason ?? error.localizedDescription)
            }
            update(id) { $0.signJobIDs.append(signID) }
            if isCancelling(id) { await LocalZSignAPI.shared.requestSignCancel(signID) }
            while true {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let s = await LocalZSignAPI.shared.signJob(signID) else { throw StageFailure(stage: "sign", message: "The sign job disappeared.") }
                switch s.status {
                case "completed":
                    update(id) { $0.status = "completed"; $0.stage = "done" }
                    return
                case "failed", "interrupted":
                    throw StageFailure(stage: "sign", message: s.error ?? "Signing failed.")
                case "cancelled":
                    if isCancelling(id) { finishCancelled(id, stage: "sign"); return }
                    throw StageFailure(stage: "sign", message: "The sign job was cancelled.")
                default:
                    // The signer can't be interrupted mid-call, so the cancel lands when it returns.
                    if isCancelling(id) { await LocalZSignAPI.shared.requestSignCancel(signID) }
                }
            }
        } catch let f as StageFailure {
            update(id) { $0.status = "failed"; $0.failedStage = f.stage; $0.error = f.message }
        } catch {
            let stage = flows[id]?.stage ?? "decrypt"
            update(id) { $0.status = "failed"; $0.failedStage = stage; $0.error = error.localizedDescription }
        }
    }
}

nonisolated enum LocalWorkflowAPI {
    static let store = LocalWorkflowStore()

    static func response(_ w: LocalWorkflow) async -> LocalWorkflowResponse {
        var d: LocalDecryptJobResponse?
        if let id = w.decryptJobIDs.last, let j = await LocalDecryptAPI.jobs.get(id) { d = LocalDecryptAPI.response(j) }
        var s: LocalZSignJobResponse?
        if let id = w.signJobIDs.last { s = await LocalZSignAPI.shared.signJob(id) }

        // One overall number: decrypt is the first 40%, signing the rest.
        var progress = 0.0
        switch w.stage {
        case "decrypt":
            switch d?.status { case "running": progress = 0.15; case "downloading": progress = 0.3; default: progress = 0.02 }
        case "sign": progress = 0.4 + 0.6 * (s?.progress ?? 0)
        default: progress = w.status == "completed" ? 1 : 0
        }
        if w.status == "completed" { progress = 1 }

        return LocalWorkflowResponse(
            id: w.id.uuidString, kind: w.kind, status: w.status, stage: w.stage, progress: progress,
            failedStage: w.failedStage, cancelledStage: w.cancelledStage, error: w.error,
            decryptJobID: w.decryptJobIDs.last?.uuidString, signJobID: w.signJobIDs.last?.uuidString,
            decryptJobIDs: w.decryptJobIDs.map(\.uuidString), signJobIDs: w.signJobIDs.map(\.uuidString),
            decrypt: d, sign: s, decryptedPath: w.decryptedPath, createdAt: w.createdAt, updatedAt: w.updatedAt)
    }

    static func register(on app: Application, authorize: @escaping @Sendable (Request) throws -> Void) {
        app.post("v1", "workflows") { req async throws -> LocalWorkflowResponse in
            try authorize(req)
            let b = try req.content.decode(LocalWorkflowRequest.self)
            guard LocalDecryptBridge.isStoreLink(b.url) else { throw Abort(.badRequest, reason: "Send an apps.apple.com link (use /v1/decrypt/search to find one).") }
            let busyFlow = await store.hasActive()
            let busyDecrypt = await LocalDecryptAPI.jobs.hasActive()
            if busyFlow || busyDecrypt { throw Abort(.conflict, reason: "A decrypt is already running.") }
            return await response(await store.create(b))
        }

        app.get("v1", "workflows") { req async throws -> [LocalWorkflowResponse] in
            try authorize(req)
            var out: [LocalWorkflowResponse] = []
            for w in await store.all() { out.append(await response(w)) }
            return out
        }

        app.get("v1", "workflows", ":id") { req async throws -> LocalWorkflowResponse in
            try authorize(req)
            guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw), let w = await store.get(id) else { throw Abort(.notFound) }
            return await response(w)
        }

        app.post("v1", "workflows", ":id", "cancel") { req async throws -> LocalWorkflowResponse in
            try authorize(req)
            guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw), let w = await store.cancel(id) else { throw Abort(.notFound) }
            return await response(w)
        }

        app.post("v1", "workflows", ":id", "retry") { req async throws -> LocalWorkflowResponse in
            try authorize(req)
            guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw), await store.get(id) != nil else { throw Abort(.notFound) }
            let busyFlow = await store.hasActive()
            let busyDecrypt = await LocalDecryptAPI.jobs.hasActive()
            if busyFlow || busyDecrypt { throw Abort(.conflict, reason: "Another workflow or decrypt is already running.") }
            guard let w = await store.retry(id) else { throw Abort(.conflict, reason: "Only failed, cancelled or interrupted workflows can be retried.") }
            return await response(w)
        }
    }
}
