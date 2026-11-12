//
//  LocalDecryptAPI.swift
//  Decrypt functions on the local TrustCore engine (the on-device Vapor server).
//
//  These routes use exactly the same data as the Decrypt tab: the same backend routes
//  (api/appsearch · api/appinfo · api/decrypt · api/decrypt/versions · api/decrypt/:id ·
//  api/decrypt/quota · api/decrypt/history · api/ipa/file/:up), the same device ADID and the
//  same account token. The engine only relays and tracks the job; nothing is decrypted here.
//  A finished job lands in the Library inbox, ready for POST /v1/sign.
//
//  Routes (all need the X-mSign-Local-Token header, like /v1/sign):
//    GET  /v1/decrypt/search?q=<text or apps.apple.com link>
//    POST /v1/decrypt/versions        {"url": "...", "page": 1}
//    GET  /v1/decrypt/quota
//    GET  /v1/decrypt/history
//    POST /v1/decrypt/history/clear
//    POST /v1/decrypt                 {"url": "...", "version": "optional"}  -> job
//    GET  /v1/decrypt/jobs            -> [job]
//    GET  /v1/decrypt/jobs/:id        -> job (queued · running · downloading · done · failed · cancelled)
//    POST /v1/decrypt/jobs/:id/cancel
//    GET  /v1/decrypt/jobs/:id/download
//

import Foundation
import Vapor

// MARK: - Models

nonisolated struct LocalDecryptRequest: Content, Sendable {
    var url: String
    var version: String?
}

nonisolated struct LocalDecryptVersionsRequest: Content, Sendable {
    var url: String
    var page: Int?
}

nonisolated struct LocalDecryptJob: Sendable {
    let id: UUID
    var url: String
    var version: String?
    var status: String = "queued"      // queued · running · downloading · done · failed · cancelled
    var message: String = "Queued"
    var queue: Int = 0
    var name: String?
    var appVersion: String?
    var output: URL?
    var error: String?
    var createdAt = Date()
}

nonisolated struct LocalDecryptJobResponse: Content, Sendable {
    var id: String
    var status: String
    var message: String
    var queue: Int
    var name: String?
    var version: String?
    var output: String?       // file name in the Library inbox; pass the full path to /v1/sign
    var path: String?
    var error: String?
}

// MARK: - Backend relay (same requests as DecryptClient)

nonisolated enum LocalDecryptBridge {
    struct Failure: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    static func request(_ path: String, query: [String: String] = [:], body: [String: Any]? = nil, timeout: TimeInterval = 30) throws -> URLRequest {
        guard var c = URLComponents(string: DecryptClient.siteBase + path) else { throw Failure("Bad URL") }
        if !query.isEmpty { c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        guard let url = c.url else { throw Failure("Bad URL") }
        var r = URLRequest(url: url)
        r.timeoutInterval = timeout
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue(MDID.current, forHTTPHeaderField: "X-AS-ADID")
        if let t = ZefvAccount.currentSessionToken, !t.isEmpty { r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body {
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    /// Raw backend JSON, so the local API returns the same fields the tab reads.
    static func sendRaw(_ r: URLRequest) async throws -> (Data, [String: Any]) {
        let (d, resp) = try await URLSession.shared.data(for: r)
        let o = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 || (o["ok"] as? Bool) == false {
            throw Failure((o["error"] as? String) ?? "Server error (\(code))")
        }
        return (d, o)
    }

    static func isStoreLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("https://apps.apple.com/") || t.hasPrefix("https://itunes.apple.com/")
    }

    static func int(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String, let i = Int(s) { return i }
        return 0
    }
}

// MARK: - Job store

actor LocalDecryptJobs {
    private var jobs: [UUID: LocalDecryptJob] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]

    func all() -> [LocalDecryptJob] { jobs.values.sorted { $0.createdAt > $1.createdAt } }
    func get(_ id: UUID) -> LocalDecryptJob? { jobs[id] }
    func hasActive() -> Bool { jobs.values.contains { ["queued", "running", "downloading"].contains($0.status) } }

    func update(_ id: UUID, _ mutate: (inout LocalDecryptJob) -> Void) {
        guard var j = jobs[id] else { return }
        // A cancelled job stays cancelled.
        if j.status == "cancelled" { return }
        mutate(&j)
        jobs[id] = j
    }

    func start(url: String, version: String?) -> LocalDecryptJob {
        let job = LocalDecryptJob(id: UUID(), url: url, version: version)
        jobs[job.id] = job
        let id = job.id
        tasks[id] = Task { [weak self] in
            await self?.run(id)
        }
        // Keep the newest 50.
        if jobs.count > 50 {
            for old in jobs.values.sorted(by: { $0.createdAt < $1.createdAt }).prefix(jobs.count - 50) where tasks[old.id] == nil {
                jobs[old.id] = nil
            }
        }
        return job
    }

    func cancel(_ id: UUID) -> LocalDecryptJob? {
        guard var j = jobs[id] else { return nil }
        if ["queued", "running", "downloading"].contains(j.status) {
            tasks[id]?.cancel()
            j.status = "cancelled"; j.message = "Cancelled"
            jobs[id] = j
        }
        return j
    }

    private func finish(_ id: UUID) { tasks[id] = nil }

    private func run(_ id: UUID) async {
        defer { finish(id) }
        guard let job = jobs[id] else { return }
        do {
            var body: [String: Any] = ["url": job.url]
            if let v = job.version, !v.isEmpty { body["version"] = v }
            let (_, o) = try await LocalDecryptBridge.sendRaw(LocalDecryptBridge.request("api/decrypt", body: body))
            guard let remoteID = o["id"] as? String else { throw LocalDecryptBridge.Failure("Server didn't start the job.") }

            var up: String?
            var name = ""
            var ver = ""
            var misses = 0
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let s: [String: Any]
                do { (_, s) = try await LocalDecryptBridge.sendRaw(LocalDecryptBridge.request("api/decrypt/\(remoteID)")); misses = 0 }
                catch let e as LocalDecryptBridge.Failure { throw e }
                catch { misses += 1; if misses >= 4 { throw error }; continue }
                let st = (s["status"] as? String) ?? ""
                let msg = (s["msg"] as? String) ?? ""
                let q = LocalDecryptBridge.int(s["queue"])
                if st == "done" {
                    up = s["up"] as? String
                    name = (s["name"] as? String) ?? name
                    ver = (s["ver"] as? String) ?? ""
                    break
                }
                if st == "error" { throw LocalDecryptBridge.Failure((s["error"] as? String) ?? "Decrypt failed.") }
                update(id) { $0.status = st == "queued" ? "queued" : "running"; if !msg.isEmpty { $0.message = msg }; $0.queue = q }
            }
            guard let up, !Task.isCancelled else { return }
            update(id) { $0.status = "downloading"; $0.message = "Downloading IPA"; $0.name = name; $0.appVersion = ver }
            let file = try await Self.download(up: up, name: name, version: ver)
            update(id) { $0.status = "done"; $0.message = "Saved to Library"; $0.output = file; $0.name = name; $0.appVersion = ver }
        } catch {
            if Task.isCancelled { return }
            update(id) { $0.status = "failed"; $0.error = error.localizedDescription; $0.message = "Failed" }
        }
    }

    private static func download(up: String, name: String, version: String) async throws -> URL {
        let r = try LocalDecryptBridge.request("api/ipa/file/\(up)", timeout: 180)
        let (tmp, resp) = try await URLSession.shared.download(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw LocalDecryptBridge.Failure(code == 404 ? "The file expired. Decrypt it again." : "Download failed (\(code)).")
        }
        let safe = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        let base = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let file = (base.isEmpty ? "App" : base) + (version.isEmpty ? "" : "-\(version)") + ".ipa"
        let dest = AppPaths.dir("inbox").appendingPathComponent(file)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }
}

// MARK: - Routes

nonisolated enum LocalDecryptAPI {
    static let jobs = LocalDecryptJobs()

    private static func json(_ data: Data) -> Response {
        var h = HTTPHeaders(); h.contentType = .json
        return Response(status: .ok, headers: h, body: .init(data: data))
    }

    static func response(_ j: LocalDecryptJob) -> LocalDecryptJobResponse {
        .init(id: j.id.uuidString, status: j.status, message: j.message, queue: j.queue, name: j.name, version: j.appVersion,
              output: j.output?.lastPathComponent, path: j.output?.path, error: j.error)
    }

    private static func relay(_ r: URLRequest) async throws -> Response {
        do { return json(try await LocalDecryptBridge.sendRaw(r).0) }
        catch { throw Abort(.badGateway, reason: error.localizedDescription) }
    }

    static func register(on app: Application, authorize: @escaping @Sendable (Request) throws -> Void) {
        app.get("v1", "decrypt", "search") { req async throws -> Response in
            try authorize(req)
            let q = (req.query[String.self, at: "q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard q.count >= 2 else { throw Abort(.badRequest, reason: "Search text is too short.") }
            let r = LocalDecryptBridge.isStoreLink(q)
                ? try LocalDecryptBridge.request("api/appinfo", query: ["url": q])
                : try LocalDecryptBridge.request("api/appsearch", query: ["q": q])
            return try await relay(r)
        }

        app.post("v1", "decrypt", "versions") { req async throws -> Response in
            try authorize(req)
            let b = try req.content.decode(LocalDecryptVersionsRequest.self)
            return try await relay(try LocalDecryptBridge.request("api/decrypt/versions", body: ["url": b.url, "page": b.page ?? 1], timeout: 150))
        }

        app.get("v1", "decrypt", "quota") { req async throws -> Response in
            try authorize(req)
            return try await relay(try LocalDecryptBridge.request("api/decrypt/quota"))
        }

        app.get("v1", "decrypt", "history") { req async throws -> Response in
            try authorize(req)
            return try await relay(try LocalDecryptBridge.request("api/decrypt/history"))
        }

        app.post("v1", "decrypt", "history", "clear") { req async throws -> Response in
            try authorize(req)
            return try await relay(try LocalDecryptBridge.request("api/decrypt/history/delete", body: ["all": true]))
        }

        app.post("v1", "decrypt") { req async throws -> LocalDecryptJobResponse in
            try authorize(req)
            let b = try req.content.decode(LocalDecryptRequest.self)
            guard LocalDecryptBridge.isStoreLink(b.url) else { throw Abort(.badRequest, reason: "Send an apps.apple.com link (use /v1/decrypt/search to find one).") }
            // Same rule as the tab: one decrypt at a time.
            if await jobs.hasActive() { throw Abort(.conflict, reason: "A decrypt is already running.") }
            return response(await jobs.start(url: b.url, version: b.version))
        }

        app.get("v1", "decrypt", "jobs") { req async throws -> [LocalDecryptJobResponse] in
            try authorize(req)
            return await jobs.all().map(response)
        }

        app.get("v1", "decrypt", "jobs", ":id") { req async throws -> LocalDecryptJobResponse in
            try authorize(req)
            guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw), let j = await jobs.get(id) else { throw Abort(.notFound) }
            return response(j)
        }

        app.post("v1", "decrypt", "jobs", ":id", "cancel") { req async throws -> LocalDecryptJobResponse in
            try authorize(req)
            guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw), let j = await jobs.cancel(id) else { throw Abort(.notFound) }
            return response(j)
        }

        app.get("v1", "decrypt", "jobs", ":id", "download") { req async throws -> Response in
            try authorize(req)
            guard let raw = req.parameters.get("id"), let id = UUID(uuidString: raw),
                  let j = await jobs.get(id), let out = j.output, FileManager.default.fileExists(atPath: out.path) else { throw Abort(.notFound) }
            return req.fileio.streamFile(at: out.path)
        }
    }
}
