//
//  BackgroundDownloader.swift
//  IPA downloads that keep going after you leave AirShare — even if iOS kills the app.
//
//  The download runs inside iOS's own background transfer service (a background URLSession), so
//  no audio and no special permission is needed. Big files on servers that support byte ranges are
//  pulled as several parallel pieces (all background tasks). Every job is written to disk, so when
//  iOS relaunches AirShare after the pieces finish, they're stitched into the inbox automatically
//  and you get a "Downloaded <app>" notification.
//

import Foundation
import UIKit
import UserNotifications

/// Receives the "your background downloads finished" wake-up from iOS.
final class AirShareAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        IPADownloader.shared.adopt(identifier: identifier, completion: completionHandler)
    }
}

nonisolated final class IPADownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = IPADownloader()
    static let sessionID = "com.mrzefv.airshare.ipa-download"

    struct Part: Codable { var index: Int; var lo: Int64; var hi: Int64; var done: Bool }   // hi < 0 → whole file
    struct Job: Codable {
        var id: String
        var gen: Int
        var destName: String
        var name: String
        var src: String
        var total: Int64                // -1 when unknown
        var etag: String?
        var parts: [Part]
        var fallback: Bool              // already retried as a single stream
    }
    typealias Handler = (progress: @Sendable (Double) -> Void, done: @Sendable (Result<URL, Error>) -> Void)

    private var session: URLSession!
    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var handlers: [String: [Handler]] = [:]
    private var received: [String: [Int: Int64]] = [:]
    private var failures: [String: Error] = [:]
    private var eventDone: (() -> Void)?
    private var expectedSingle: [String: Int64] = [:]
    private var pollTimer: DispatchSourceTimer?
    private var retries: [String: [Int: Int]] = [:]      // piece retries per job (resume instead of restarting)

    override init() {
        super.init()
        jobs = Self.loadIndex()
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 8
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1          // callbacks run one at a time, in order
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
    }

    // MARK: Storage

    private static var root: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirShare/bg-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private static var indexURL: URL { root.appendingPathComponent("jobs.json") }
    private static func jobDir(_ id: String) -> URL {
        let u = root.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private static func partURL(_ id: String, _ i: Int) -> URL { jobDir(id).appendingPathComponent("p\(i)") }
    private static func loadIndex() -> [String: Job] {
        guard let d = try? Data(contentsOf: indexURL),
              let list = try? JSONDecoder().decode([Job].self, from: d) else { return [:] }
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }
    private func saveIndexLocked() {
        if let d = try? JSONEncoder().encode(Array(jobs.values)) { try? d.write(to: Self.indexURL, options: .atomic) }
    }
    private static func destURL(_ job: Job) -> URL { AppPaths.dir("inbox").appendingPathComponent(job.destName) }

    /// Deletes piece folders that no stored job owns (left over from crashes / cancelled jobs).
    @discardableResult
    func pruneOrphans(olderThan age: TimeInterval = 86_400) -> Int64 {
        let fm = FileManager.default
        lock.lock(); let ids = Set(jobs.keys); lock.unlock()
        var freed: Int64 = 0
        for dir in (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            guard dir.lastPathComponent != "jobs.json", !ids.contains(dir.lastPathComponent) else { continue }
            let m = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard Date().timeIntervalSince(m) > age else { continue }
            freed += StorageCleaner.size(of: dir)
            try? fm.removeItem(at: dir)
        }
        return freed
    }

    func adopt(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.sessionID else { completion(); return }
        lock.lock(); eventDone = completion; lock.unlock()
    }

    // MARK: Requests

    static func request(for src: URL) -> URLRequest {
        var req = URLRequest(url: src)
        req.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
        // Our own host counts the download per device; never send the device id to third-party hosts.
        if let h = src.host, h == URL(string: ZefvAccount.apiBase)?.host { req.setValue(MDID.current, forHTTPHeaderField: "X-AS-ADID") }
        return req
    }

    struct RangeProbe { let size: Int64; let etag: String? }

    private static let probeLock = NSLock()
    nonisolated(unsafe) private static var probeCache: [URL: (probe: RangeProbe?, at: Date)] = [:]

    /// Probe with a 10-minute memory: opening an app's page warms it, so tapping Download starts right away.
    static func cachedProbe(_ src: URL) async -> RangeProbe? {
        probeLock.lock(); let hit = probeCache[src]; probeLock.unlock()
        if let hit, Date().timeIntervalSince(hit.at) < 600 { return hit.probe }
        let p = await probeRanges(src)
        probeLock.lock(); probeCache[src] = (p, Date()); probeLock.unlock()
        return p
    }

    /// Called when an app's page opens: opens the connection (DNS + TLS + ranges check) and pulls screenshots into the cache.
    static func prefetch(_ app: SourceApp) async {
        let probeTask = Task { if let u = app.downloadURL { _ = await cachedProbe(u) } }
        for u in ([app.iconURL].compactMap { $0 } + Array(app.screenshots.prefix(4))) {
            var r = URLRequest(url: u); r.cachePolicy = .returnCacheDataElseLoad
            _ = try? await URLSession.shared.data(for: r)
        }
        await probeTask.value
    }

    /// HEAD request: does the server accept byte ranges, and how big is the file?
    static func probeRanges(_ src: URL) async -> RangeProbe? {
        var req = request(for: src)
        req.httpMethod = "HEAD"; req.timeoutInterval = 3
        guard let (_, resp) = try? await URLSession.shared.data(for: req), let h = resp as? HTTPURLResponse, h.statusCode == 200,
              (h.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes"),
              h.expectedContentLength > 0 else { return nil }
        return RangeProbe(size: h.expectedContentLength, etag: h.value(forHTTPHeaderField: "ETag"))
    }

    // MARK: Public API

    /// Downloads to the inbox; returns immediately if it's already on device. Re-attaches to a
    /// download that's still running from before (e.g. you left the app and came back).
    func download(_ app: SourceApp, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let src = app.downloadURL else { throw GitHubError.badConfig("This app has no download URL in the source.") }
        let dest = IPAInbox.url(for: app)
        if FileManager.default.fileExists(atPath: dest.path) { progress(1); return dest }
        let destName = dest.lastPathComponent

        lock.lock(); let existing = jobs.values.first { $0.destName == destName }; lock.unlock()
        if let existing {
            let alive = await session.allTasks.contains { ($0.taskDescription ?? "").hasPrefix(existing.id + "|") }
            if alive { return try await attach(existing.id, launch: nil, progress: progress) }
            // Nothing running (app was killed / network gave up): keep the finished pieces and only fetch the rest.
            if resumable(existing) { return try await attach(existing.id, launch: existing, progress: progress, resumed: true) }
            drop(existing.id)
        }

        var parts = [Part(index: 0, lo: 0, hi: -1, done: false)]
        var total: Int64 = -1
        var etag: String?
        if let probe = await Self.cachedProbe(src), probe.size >= 24_000_000 {
            total = probe.size
            etag = probe.etag
            let wanted: Int64 = probe.size >= 300_000_000 ? 8 : 6
            let step = (probe.size + wanted - 1) / wanted
            let n = Int((probe.size + step - 1) / step)
            parts = (0..<n).map { i in
                let lo = Int64(i) * step
                return Part(index: i, lo: lo, hi: min(probe.size - 1, lo + step - 1), done: false)
            }
        }
        let job = Job(id: UUID().uuidString, gen: 0, destName: destName, name: app.name, src: src.absoluteString,
                      total: total, etag: etag, parts: parts, fallback: false)
        lock.lock(); jobs[job.id] = job; saveIndexLocked(); lock.unlock()
        return try await attach(job.id, launch: job, progress: progress)
    }

    /// A stored job is worth resuming when its finished pieces are still on disk.
    private func resumable(_ job: Job) -> Bool {
        let fm = FileManager.default
        guard job.parts.contains(where: { $0.done }) else { return false }
        return job.parts.filter { $0.done }.allSatisfy { fm.fileExists(atPath: Self.partURL(job.id, $0.index).path) }
    }

    private func attach(_ id: String, launch: Job?, progress: @escaping @Sendable (Double) -> Void, resumed: Bool = false) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
                let h: Handler = (progress, { c.resume(with: $0) })
                lock.lock(); handlers[id, default: []].append(h)
                if resumed, let job = launch {
                    // Count the finished pieces so the bar starts where it left off.
                    var m = received[id] ?? [:]
                    for p in job.parts where p.done {
                        m[p.index] = (try? FileManager.default.attributesOfItem(atPath: Self.partURL(id, p.index).path)[.size] as? Int64) ?? 0
                    }
                    received[id] = m
                }
                lock.unlock()
                self.startPolling()
                if let launch {
                    if launch.parts.allSatisfy({ $0.done }) { self.finalize(launch) } else { self.launchTasks(launch) }
                }
            }
        } onCancel: { self.cancel(id) }
    }

    private func cancel(_ id: String) {
        lock.lock()
        let hs = handlers.removeValue(forKey: id) ?? []
        lock.unlock()
        drop(id)
        for h in hs { h.done(.failure(CancellationError())) }
    }

    /// Forget a job: cancel its tasks and delete its pieces.
    private func drop(_ id: String) {
        lock.lock()
        jobs.removeValue(forKey: id); received.removeValue(forKey: id); failures.removeValue(forKey: id); expectedSingle.removeValue(forKey: id); retries.removeValue(forKey: id)
        saveIndexLocked()
        lock.unlock()
        session.getAllTasks { tasks in
            for t in tasks where (t.taskDescription ?? "").hasPrefix(id + "|") { t.cancel() }
        }
        try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(id))
    }

    private func launchTasks(_ job: Job) {
        guard let src = URL(string: job.src) else { return }
        let ifRange: String? = job.etag.flatMap { $0.hasPrefix("W/") ? nil : $0 }
        for part in job.parts where !part.done { launchPart(job, part, src: src, ifRange: ifRange) }
    }

    private func launchPart(_ job: Job, _ part: Part, src: URL? = nil, ifRange: String? = nil, resumeData: Data? = nil) {
        guard let src = src ?? URL(string: job.src) else { return }
        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var req = Self.request(for: src)
            if part.hi >= 0 {
                req.setValue("bytes=\(part.lo)-\(part.hi)", forHTTPHeaderField: "Range")
                let tag = ifRange ?? job.etag.flatMap { $0.hasPrefix("W/") ? nil : $0 }
                if let tag { req.setValue(tag, forHTTPHeaderField: "If-Range") }
            }
            task = session.downloadTask(with: req)
        }
        task.taskDescription = "\(job.id)|\(job.gen)|\(part.index)"
        task.resume()
    }

    /// One piece failed (network blip, timeout): retry just that piece a few times instead of starting over.
    /// A single-stream download resumes from where it stopped when the server handed back resume data.
    private func retryPiece(_ job: Job, index: Int, error: Error) -> Bool {
        guard let part = job.parts.first(where: { $0.index == index }), !part.done else { return false }
        lock.lock()
        let n = (retries[job.id]?[index] ?? 0) + 1
        guard n <= 4 else { lock.unlock(); return false }
        retries[job.id, default: [:]][index] = n
        lock.unlock()
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        DispatchQueue.global().asyncAfter(deadline: .now() + min(8, 1.0 * Double(n * n))) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.jobs[job.id]; self.lock.unlock()
            guard let current, current.gen == job.gen else { return }
            self.launchPart(current, part, resumeData: part.hi < 0 ? resume : nil)
        }
        return true
    }

    private static func parse(_ task: URLSessionTask) -> (id: String, gen: Int, index: Int)? {
        let p = (task.taskDescription ?? "").split(separator: "|")
        guard p.count == 3, let g = Int(p[1]), let i = Int(p[2]) else { return nil }
        return (String(p[0]), g, i)
    }

    // MARK: Delegate

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let t = Self.parse(downloadTask) else { return }
        lock.lock()
        guard let job = jobs[t.id], job.gen == t.gen else { lock.unlock(); return }
        // A plain 200 on a ranged request means the server ignored the range — stop and fall back.
        if job.parts.count > 1, (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 {
            failures[t.id] = GitHubError.badConfig("Server ignored the byte range.")
            lock.unlock(); downloadTask.cancel(); return
        }
        record(t.id, t.index, totalBytesWritten, expected: totalBytesExpectedToWrite)
        lock.unlock()
        emit(t.id)
    }

    /// Caller holds the lock.
    private func record(_ id: String, _ index: Int, _ bytes: Int64, expected: Int64) {
        var m = received[id] ?? [:]
        m[index] = max(m[index] ?? 0, bytes)
        received[id] = m
        if expected > 0, (jobs[id]?.total ?? -1) <= 0 { expectedSingle[id] = expected }
    }

    /// Pushes the overall fraction to every listener of a job.
    private func emit(_ id: String) {
        lock.lock()
        guard let job = jobs[id] else { lock.unlock(); return }
        let sum = (received[id] ?? [:]).values.reduce(Int64(0), +)
        let total = job.total > 0 ? job.total : (expectedSingle[id] ?? 0)
        let hs = handlers[id] ?? []
        lock.unlock()
        guard total > 0 else { return }
        let fraction = min(1, Double(sum) / Double(total))
        for h in hs { h.progress(fraction) }
    }

    /// Background sessions batch their progress callbacks; polling the task counters keeps the bar smooth.
    private func startPolling() {
        lock.lock()
        guard pollTimer == nil else { lock.unlock(); return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        pollTimer = timer
        lock.unlock()
        timer.schedule(deadline: .now() + 0.15, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock(); let idle = self.handlers.isEmpty; self.lock.unlock()
            if idle { self.stopPolling(); return }
            self.session.getAllTasks { tasks in
                var touched = Set<String>()
                self.lock.lock()
                for t in tasks {
                    guard let info = Self.parse(t), let job = self.jobs[info.id], job.gen == info.gen else { continue }
                    self.record(info.id, info.index, t.countOfBytesReceived, expected: t.countOfBytesExpectedToReceive)
                    touched.insert(info.id)
                }
                self.lock.unlock()
                for id in touched { self.emit(id) }
            }
        }
        timer.resume()
    }

    private func stopPolling() {
        lock.lock(); let t = pollTimer; pollTimer = nil; lock.unlock()
        t?.cancel()
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let t = Self.parse(downloadTask) else { return }
        lock.lock(); let job = jobs[t.id]; lock.unlock()
        guard let job, job.gen == t.gen, let part = job.parts.first(where: { $0.index == t.index }) else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let fm = FileManager.default
        if part.hi >= 0 {
            guard code == 206 else { setFailure(t.id, "Unexpected HTTP \(code) for a byte range."); return }
            let got = (try? fm.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? -1
            guard got == part.hi - part.lo + 1 else { setFailure(t.id, "Piece came back the wrong size."); return }
        } else {
            guard code < 400 else { setFailure(t.id, "Download failed (HTTP \(code))"); return }
        }
        let target = Self.partURL(t.id, t.index)
        do {
            try? fm.removeItem(at: target)
            try fm.moveItem(at: location, to: target)       // must happen now; iOS deletes `location` after this returns
        } catch { lock.lock(); failures[t.id] = error; lock.unlock(); return }
        let finalSize = (try? fm.attributesOfItem(atPath: target.path)[.size] as? Int64) ?? 0
        lock.lock()
        record(t.id, t.index, finalSize, expected: finalSize)
        if var j = jobs[t.id], j.gen == t.gen, let k = j.parts.firstIndex(where: { $0.index == t.index }) {
            j.parts[k].done = true
            jobs[t.id] = j
            saveIndexLocked()
        }
        lock.unlock()
        emit(t.id)
    }

    private func setFailure(_ id: String, _ message: String) {
        lock.lock(); failures[id] = GitHubError.badConfig(message); lock.unlock()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let t = Self.parse(task) else { return }
        lock.lock()
        let job = jobs[t.id]
        let failure = failures[t.id]
        lock.unlock()
        guard let job, job.gen == t.gen else { return }       // stale callback from a cancelled/replaced job

        if let failure { fail(job, failure); return }
        if let error {
            if (error as NSError).code == NSURLErrorCancelled { return }
            if retryPiece(job, index: t.index, error: error) { return }
            fail(job, error); return
        }
        if job.parts.allSatisfy({ $0.done }) { finalize(job) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock(); let done = eventDone; eventDone = nil; lock.unlock()
        if let done { DispatchQueue.main.async { done() } }
    }

    // MARK: Finish

    /// A ranged download failed → retry once as a single stream; otherwise report the error.
    private func fail(_ job: Job, _ error: Error) {
        if job.parts.count > 1, !job.fallback, let src = URL(string: job.src) {
            _ = src
            session.getAllTasks { tasks in
                for t in tasks where (t.taskDescription ?? "").hasPrefix(job.id + "|\(job.gen)|") { t.cancel() }
            }
            try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(job.id))
            var next = job
            next.gen += 1
            next.fallback = true
            next.parts = [Part(index: 0, lo: 0, hi: -1, done: false)]
            next.total = -1
            next.etag = nil
            lock.lock()
            jobs[job.id] = next; received[job.id] = nil; failures[job.id] = nil; retries[job.id] = nil
            saveIndexLocked()
            lock.unlock()
            launchTasks(next)
            return
        }
        lock.lock(); let hs = handlers.removeValue(forKey: job.id) ?? []; lock.unlock()
        drop(job.id)
        for h in hs { h.done(.failure(error)) }
    }

    private func finalize(_ job: Job) {
        let fm = FileManager.default
        let dest = Self.destURL(job)
        do {
            if job.parts.count == 1 {
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: Self.partURL(job.id, 0), to: dest)
            } else {
                let merged = Self.jobDir(job.id).appendingPathComponent("merged.ipa")
                try? fm.removeItem(at: merged)
                try fm.moveItem(at: Self.partURL(job.id, 0), to: merged)
                let w = try FileHandle(forWritingTo: merged)
                defer { try? w.close() }
                try w.seekToEnd()
                for p in job.parts.dropFirst() {
                    let url = Self.partURL(job.id, p.index)
                    let r = try FileHandle(forReadingFrom: url)
                    defer { try? r.close() }
                    while true {
                        let chunk = try autoreleasepool { try r.read(upToCount: 4 << 20) ?? Data() }
                        if chunk.isEmpty { break }
                        try w.write(contentsOf: chunk)
                    }
                    try? fm.removeItem(at: url)
                }
                let size = (try? fm.attributesOfItem(atPath: merged.path)[.size] as? Int64) ?? -1
                guard size == job.total else { throw GitHubError.badConfig("Download pieces didn't add up.") }
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: merged, to: dest)
            }
        } catch {
            fail(job, error)
            return
        }
        lock.lock()
        let hs = handlers.removeValue(forKey: job.id) ?? []
        jobs.removeValue(forKey: job.id); received.removeValue(forKey: job.id); failures.removeValue(forKey: job.id); retries.removeValue(forKey: job.id)
        saveIndexLocked()
        lock.unlock()
        try? fm.removeItem(at: Self.root.appendingPathComponent(job.id))
        for h in hs { h.progress(1); h.done(.success(dest)) }
        notifyDone(job.name)
    }

    /// Only when you're outside AirShare — in the app the download button just turns into a checkmark.
    private func notifyDone(_ name: String) {
        Task { @MainActor in
            guard UIApplication.shared.applicationState != .active else { return }
            let c = UNMutableNotificationContent()
            c.title = "Downloaded \(name)"
            c.body = "Ready to sign in AirShare."
            c.sound = .default
            let req = UNNotificationRequest(identifier: "airshare.download.\(name)", content: c, trigger: nil)
            try? await UNUserNotificationCenter.current().add(req)
        }
    }
}
