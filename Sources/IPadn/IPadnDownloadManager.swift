//
//  IPadnDownloadManager.swift
//  Real download queue modeled on mengangs/ipadn DownloadManager (GPL-2.0).
//  English UI; Store IPA via AppStoreClient, then FairPlay via DeviceDecryptService.
//  URL/import via URLSession resume data. Install → SignQueue / OTA / Native.
//

import Foundation
import Network
import UniformTypeIdentifiers
import UIKit

// MARK: - Models

enum IPadnDownloadStatus: String, Codable, CaseIterable {
    case queued, running, pausing, paused, processing, completed, failed

    var title: String {
        switch self {
        case .queued: return "Waiting"
        case .running: return "Downloading"
        case .pausing: return "Pausing"
        case .paused: return "Paused"
        case .processing: return "Decrypting"
        case .completed: return "Completed"
        case .failed: return "Download failed"
        }
    }
}

enum IPadnDownloadFilter: String, CaseIterable, Identifiable {
    case all, active, paused, completed, failed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .active: return "Active"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }
    var symbol: String {
        switch self {
        case .all: return "line.3.horizontal.decrease.circle"
        case .active: return "arrow.down.circle"
        case .paused: return "pause.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
    func includes(_ status: IPadnDownloadStatus) -> Bool {
        switch self {
        case .all: return true
        case .active: return [.queued, .running, .pausing, .processing].contains(status)
        case .paused: return status == .paused
        case .completed: return status == .completed
        case .failed: return status == .failed
        }
    }
}

struct IPadnDownloadJob: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var bundleID: String = ""
    var version: String = ""
    var adamId: Int?
    var iconURL: URL?
    var storeURL: String = ""
    var sourceURL: URL?
    var status: IPadnDownloadStatus = .queued
    var downloaded: Int64 = 0
    var expected: Int64 = 0
    var localFilename: String?
    var error: String?
    var createdAt = Date()
    var kind: Kind = .store
    /// Pin a specific store build when set.
    var externalVersionId: String? = nil

    enum Kind: String, Codable { case store, url, importIPA }

    var progress: Double {
        expected > 0 ? min(1, max(0, Double(downloaded) / Double(expected))) : 0
    }

    var sizeLabel: String {
        guard expected > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
    }

    var progressLabel: String {
        let done = ByteCountFormatter.string(fromByteCount: downloaded, countStyle: .file)
        if expected > 0 {
            let total = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
            return "\(done) / \(total)"
        }
        return done
    }

    var fileURL: URL? {
        guard let localFilename else { return nil }
        return IPadnDownloadStorage.packagesDir.appendingPathComponent(localFilename)
    }
}

@MainActor
final class IPadnDownloadProgress: ObservableObject {
    @Published var written: Int64 = 0
    @Published var expected: Int64 = 0
}

// MARK: - Storage

enum IPadnDownloadStorage {
    static var root: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TetherLess/ipadn-downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var packagesDir: URL {
        let u = root.appendingPathComponent("packages", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var jobsURL: URL { root.appendingPathComponent("jobs.json") }
    static func resumeURL(_ id: UUID) -> URL { root.appendingPathComponent("\(id.uuidString).resume") }

    static func loadJobs() -> [IPadnDownloadJob] {
        guard let data = try? Data(contentsOf: jobsURL),
              let jobs = try? JSONDecoder().decode([IPadnDownloadJob].self, from: data) else { return [] }
        return jobs
    }

    static func saveJobs(_ jobs: [IPadnDownloadJob]) {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: jobsURL, options: .atomic)
    }
}

// MARK: - Manager

@MainActor
final class IPadnDownloadManager: NSObject, ObservableObject {
    static let shared = IPadnDownloadManager()

    @Published private(set) var jobs: [IPadnDownloadJob] = []
    @Published private(set) var waitingForWiFi = false
    @Published var storageError: String?

    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var progressState: [UUID: IPadnDownloadProgress] = [:]
    private var resumeData: [UUID: Data] = [:]
    private var storeTasks: [UUID: Task<Void, Never>] = [:]
    /// Serializes FairPlay handoffs so DeviceDecryptService.busy is not contended.
    private var decryptTail: Task<Void, Never>?
    private var session: URLSession!
    private var maxConcurrent = 3
    private var pathMonitor: NWPathMonitor?
    private var onCellular = false
    private var wifiOnly = false

    private override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        jobs = IPadnDownloadStorage.loadJobs().map { job in
            var j = job
            if j.status == .running || j.status == .pausing || j.status == .queued {
                j.status = .paused
            }
            return j
        }
        persist()
        startPathMonitor()
        schedule()
    }

    func progress(for id: UUID) -> IPadnDownloadProgress {
        if let p = progressState[id] { return p }
        let p = IPadnDownloadProgress()
        if let job = jobs.first(where: { $0.id == id }) {
            p.written = job.downloaded
            p.expected = job.expected
        }
        progressState[id] = p
        return p
    }

    var activeCount: Int {
        jobs.filter { [.queued, .running, .pausing, .processing].contains($0.status) }.count
    }

    // MARK: Enqueue

    func enqueueStore(app: DecryptApp, externalVersionId: String? = nil) throws {
        let pin = (externalVersionId ?? app.externalVersionId).trimmingCharacters(in: .whitespacesAndNewlines)
        if jobs.contains(where: {
            let sameApp = ($0.adamId.map { "\($0)" } == app.id.components(separatedBy: "-").last
                || (!$0.bundleID.isEmpty && $0.bundleID == app.bundle))
            let samePin = ($0.externalVersionId ?? "") == pin
            return sameApp && samePin && ![.completed, .failed].contains($0.status)
        }) {
            throw IPadnDownloadError.message("This version already has a download task.")
        }
        let adam = Int(app.id.split(separator: "-").last.map(String.init) ?? "")
            ?? Int(app.id.filter(\.isNumber))
        let job = IPadnDownloadJob(
            name: app.name,
            bundleID: app.bundle,
            version: app.version,
            adamId: adam,
            iconURL: app.icon,
            storeURL: app.url,
            status: .queued,
            expected: app.sizeBytes,
            kind: .store,
            externalVersionId: pin.isEmpty ? nil : pin
        )
        jobs.insert(job, at: 0)
        persist()
        schedule()
    }

    func enqueueStore(owned: OwnedStoreApp) throws {
        try enqueueStore(app: owned.asDecryptApp)
    }

    func enqueueURL(_ url: URL, name: String? = nil) throws {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw IPadnDownloadError.message("Enter a valid HTTPS download link.")
        }
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let job = IPadnDownloadJob(
            name: (label?.isEmpty == false) ? label! : (url.deletingPathExtension().lastPathComponent),
            sourceURL: url,
            status: .queued,
            kind: .url
        )
        jobs.insert(job, at: 0)
        persist()
        schedule()
    }

    func importFile(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let name = url.deletingPathExtension().lastPathComponent
        let filename = "\(UUID().uuidString)_\(url.lastPathComponent)"
        let dest = IPadnDownloadStorage.packagesDir.appendingPathComponent(filename)
        try data.write(to: dest, options: .atomic)
        var job = IPadnDownloadJob(
            name: name.isEmpty ? "Imported IPA" : name,
            status: .completed,
            expected: Int64(data.count),
            downloaded: Int64(data.count),
            localFilename: filename,
            kind: .importIPA
        )
        jobs.insert(job, at: 0)
        persist()
    }

    // MARK: Controls

    func pause(_ id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        let status = jobs[idx].status
        if status == .queued {
            jobs[idx].status = .paused
            persist()
            return
        }
        if jobs[idx].kind == .store {
            storeTasks[id]?.cancel()
            storeTasks[id] = nil
            jobs[idx].status = .paused
            persist()
            return
        }
        guard let task = tasks[id] else {
            jobs[idx].status = .paused
            persist()
            return
        }
        jobs[idx].status = .pausing
        persist()
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                guard let self, let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
                if let data {
                    self.resumeData[id] = data
                    try? data.write(to: IPadnDownloadStorage.resumeURL(id), options: .atomic)
                }
                self.tasks[id] = nil
                self.jobs[i].status = .paused
                self.persist()
                self.schedule()
            }
        })
    }

    func resume(_ id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        guard jobs[idx].status == .paused || jobs[idx].status == .failed else { return }
        jobs[idx].status = .queued
        jobs[idx].error = nil
        persist()
        schedule()
    }

    func retry(_ id: UUID) { resume(id) }

    func pauseAll() {
        for job in jobs where [.queued, .running].contains(job.status) {
            pause(job.id)
        }
    }

    func resumeAll() {
        for job in jobs where job.status == .paused || job.status == .failed {
            resume(job.id)
        }
    }

    func remove(_ ids: Set<UUID>) {
        for id in ids {
            pause(id)
            storeTasks[id]?.cancel()
            storeTasks[id] = nil
            tasks[id]?.cancel()
            tasks[id] = nil
            if let file = jobs.first(where: { $0.id == id })?.fileURL {
                try? FileManager.default.removeItem(at: file)
            }
            try? FileManager.default.removeItem(at: IPadnDownloadStorage.resumeURL(id))
            resumeData[id] = nil
            progressState[id] = nil
        }
        jobs.removeAll { ids.contains($0.id) }
        persist()
        schedule()
    }

    func install(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }),
              let url = job.fileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        SignQueue.shared.enqueue(url)
    }

    // MARK: Scheduling

    private func schedule() {
        if wifiOnly && onCellular {
            waitingForWiFi = true
            return
        }
        waitingForWiFi = false
        let running = jobs.filter { $0.status == .running || $0.status == .processing }.count
        let slots = max(0, maxConcurrent - running)
        guard slots > 0 else { return }
        let queued = jobs.filter { $0.status == .queued }.prefix(slots)
        for job in queued {
            start(job.id)
        }
    }

    private func start(_ id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].status = .running
        persist()
        switch jobs[idx].kind {
        case .store:
            startStore(id)
        case .url:
            startURL(id)
        case .importIPA:
            jobs[idx].status = .completed
            persist()
        }
    }

    private func startStore(_ id: UUID) {
        storeTasks[id]?.cancel()
        storeTasks[id] = Task { [weak self] in
            guard let self, let idx = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            let job = self.jobs[idx]
            do {
                self.jobs[idx].status = .running
                self.persist()
                let app = DecryptApp(
                    id: job.adamId.map { "owned-\($0)" } ?? job.bundleID,
                    name: job.name,
                    bundle: job.bundleID,
                    icon: job.iconURL,
                    dev: "",
                    version: job.version,
                    url: job.storeURL,
                    externalVersionId: job.externalVersionId ?? ""
                )
                let dest = IPadnDownloadStorage.packagesDir
                    .appendingPathComponent("\(id.uuidString)_\(job.bundleID.isEmpty ? "app" : job.bundleID).ipa")

                // Same Store reinforce as DeviceDecryptService silent purchase.
                guard let reinforced = await AppleIDStore.shared.reinforceStoreConnection() else {
                    throw IPadnDownloadError.message(
                        "Sign in under Settings › Store Access with the Apple ID that owns this app."
                    )
                }
                var account = reinforced

                if let adam = job.adamId, adam > 0 {
                    let result: (url: URL, item: StoreDownloadItem)
                    do {
                        result = try await AppStoreClient.shared.purchaseAndDownload(
                            adamId: adam,
                            account: account,
                            destination: dest,
                            externalVersionId: job.externalVersionId,
                            version: job.version.isEmpty ? nil : job.version,
                            onProgress: { [weak self] msg in
                                Task { @MainActor in
                                    guard let self, let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
                                    if let (w, e) = Self.parseBytes(msg) {
                                        self.jobs[i].downloaded = w
                                        self.jobs[i].expected = e
                                        let p = self.progress(for: id)
                                        p.written = w; p.expected = e
                                    }
                                }
                            }
                        )
                    } catch {
                        // Full device path has 403 remint / backend / installed-embed fallbacks.
                        try Task.checkCancellation()
                        await self.runOwnedStoreDecrypt(id: id, app: app, job: job)
                        _ = account
                        self.storeTasks[id] = nil
                        self.schedule()
                        return
                    }
                    try Task.checkCancellation()
                    if result.url != dest {
                        try? FileManager.default.removeItem(at: dest)
                        try FileManager.default.copyItem(at: result.url, to: dest)
                    }
                    let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
                    guard let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
                    self.jobs[i].localFilename = dest.lastPathComponent
                    self.jobs[i].downloaded = size
                    self.jobs[i].expected = size
                    self.jobs[i].status = .processing
                    self.jobs[i].error = nil
                    if self.jobs[i].version.isEmpty { self.jobs[i].version = result.item.displayVersion }
                    if self.jobs[i].bundleID.isEmpty { self.jobs[i].bundleID = result.item.bundleID }
                    self.persist()
                    _ = account
                    // iPadn IPA on disk → FairPlay companion / in-app decrypt.
                    await self.enqueueSerialDecrypt(id: id, ipa: dest, name: job.name)
                } else {
                    // No adam on the job — resolve via store URL / bundle in DeviceDecryptService.
                    await self.runOwnedStoreDecrypt(id: id, app: app, job: job)
                }
            } catch is CancellationError {
                guard let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
                if self.jobs[i].status != .paused { self.jobs[i].status = .paused }
                self.persist()
            } catch {
                guard let i = self.jobs.firstIndex(where: { $0.id == id }) else { return }
                self.jobs[i].status = .failed
                self.jobs[i].error = error.localizedDescription
                self.persist()
            }
            self.storeTasks[id] = nil
            self.schedule()
        }
    }

    private func enqueueSerialDecrypt(id: UUID, ipa: URL, name: String) async {
        let previous = decryptTail
        let done = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self.performStoreDecrypt(id: id, ipa: ipa, name: name)
        }
        decryptTail = done
        await done.value
    }

    private func performStoreDecrypt(id: UUID, ipa: URL, name: String) async {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].status = .processing
        persist()
        await DeviceDecryptService.shared.decryptDownloadedStoreIPA(at: ipa, displayName: name)
        guard let j = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch DecryptClient.shared.phase {
        case .handedOff:
            jobs[j].status = .completed
            jobs[j].error = nil
        case .done:
            if let clear = DecryptClient.shared.finished,
               FileManager.default.fileExists(atPath: clear.path) {
                let filename = "\(id.uuidString)_decrypted_\(clear.lastPathComponent)"
                let dest = IPadnDownloadStorage.packagesDir.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.copyItem(at: clear, to: dest)
                if FileManager.default.fileExists(atPath: dest.path) {
                    if let old = jobs[j].fileURL, old != dest {
                        try? FileManager.default.removeItem(at: old)
                    }
                    jobs[j].localFilename = filename
                    let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
                    jobs[j].downloaded = size
                    jobs[j].expected = size
                }
            }
            jobs[j].status = .completed
            jobs[j].error = nil
        case .failed:
            jobs[j].status = .failed
            jobs[j].error = DecryptClient.shared.error
                ?? DecryptClient.shared.message
                ?? "Decrypt failed."
        default:
            // Still running / unknown — treat as completed if IPA exists.
            jobs[j].status = jobs[j].fileURL != nil ? .completed : .failed
            if jobs[j].status == .failed {
                jobs[j].error = DecryptClient.shared.message.isEmpty
                    ? "Decrypt did not finish."
                    : DecryptClient.shared.message
            }
        }
        persist()
    }

    private func runOwnedStoreDecrypt(id: UUID, app: DecryptApp, job: IPadnDownloadJob) async {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].status = .processing
        persist()
        let previous = decryptTail
        let done = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            let deviceApp = DeviceApp(
                bundleID: app.bundle.isEmpty ? job.bundleID : app.bundle,
                name: app.name,
                version: app.version.isEmpty ? job.version : app.version,
                isAppStore: true
            )
            await DeviceDecryptService.shared.decryptOwnedStoreApp(
                deviceApp,
                storeURL: app.url.isEmpty ? job.storeURL : app.url,
                version: job.version.isEmpty ? nil : job.version,
                externalVersionId: job.externalVersionId
            )
            guard let j = self.jobs.firstIndex(where: { $0.id == id }) else { return }
            switch DecryptClient.shared.phase {
            case .handedOff, .done:
                if let clear = DecryptClient.shared.finished,
                   FileManager.default.fileExists(atPath: clear.path) {
                    let filename = "\(id.uuidString)_decrypted_\(clear.lastPathComponent)"
                    let dest = IPadnDownloadStorage.packagesDir.appendingPathComponent(filename)
                    try? FileManager.default.removeItem(at: dest)
                    try? FileManager.default.copyItem(at: clear, to: dest)
                    if FileManager.default.fileExists(atPath: dest.path) {
                        self.jobs[j].localFilename = filename
                        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
                        self.jobs[j].downloaded = size
                        self.jobs[j].expected = size
                    }
                }
                self.jobs[j].status = .completed
                self.jobs[j].error = nil
            case .failed:
                self.jobs[j].status = .failed
                self.jobs[j].error = DecryptClient.shared.error
                    ?? DecryptClient.shared.message
                    ?? "Decrypt failed."
            default:
                self.jobs[j].status = .failed
                self.jobs[j].error = DecryptClient.shared.message.isEmpty
                    ? "Decrypt did not finish."
                    : DecryptClient.shared.message
            }
            self.persist()
        }
        decryptTail = done
        await done.value
    }

    private func startURL(_ id: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        let job = jobs[idx]
        let task: URLSessionDownloadTask
        if let data = resumeData[id] ?? (try? Data(contentsOf: IPadnDownloadStorage.resumeURL(id))) {
            task = session.downloadTask(withResumeData: data)
            resumeData[id] = nil
        } else if let url = job.sourceURL {
            task = session.downloadTask(with: url)
        } else {
            jobs[idx].status = .failed
            jobs[idx].error = "Missing download URL."
            persist()
            return
        }
        task.taskDescription = id.uuidString
        tasks[id] = task
        task.resume()
    }

    private func persist() {
        IPadnDownloadStorage.saveJobs(jobs)
        objectWillChange.send()
    }

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.onCellular = path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
                self.schedule()
            }
        }
        monitor.start(queue: DispatchQueue(label: "ipadn.dl.path"))
    }

    private static func parseBytes(_ msg: String) -> (Int64, Int64)? {
        // Accept "12 MB / 100 MB" style hints if the client emits them.
        let parts = msg.components(separatedBy: "/")
        guard parts.count == 2 else { return nil }
        func bytes(_ s: String) -> Int64? {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let num = Double(t.split(whereSeparator: { !$0.isNumber && $0 != "." && $0 != "," }).joined()
                .replacingOccurrences(of: ",", with: "")) ?? 0
            if t.contains("GB") { return Int64(num * 1_000_000_000) }
            if t.contains("MB") { return Int64(num * 1_000_000) }
            if t.contains("KB") { return Int64(num * 1_000) }
            return Int64(num)
        }
        guard let a = bytes(parts[0]), let b = bytes(parts[1]), b > 0 else { return nil }
        return (a, b)
    }

    fileprivate func finishURLDownload(id: UUID, temp: URL) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        do {
            let name = jobs[idx].sourceURL?.lastPathComponent ?? "download.ipa"
            let filename = "\(id.uuidString)_\(name)"
            let dest = IPadnDownloadStorage.packagesDir.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temp, to: dest)
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            jobs[idx].localFilename = filename
            jobs[idx].downloaded = size
            jobs[idx].expected = size
            jobs[idx].status = .completed
            jobs[idx].error = nil
            try? FileManager.default.removeItem(at: IPadnDownloadStorage.resumeURL(id))
            persist()
        } catch {
            jobs[idx].status = .failed
            jobs[idx].error = error.localizedDescription
            persist()
        }
        tasks[id] = nil
        schedule()
    }

    fileprivate func failURL(id: UUID, error: Error, resume: Data?) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        if let resume {
            resumeData[id] = resume
            try? resume.write(to: IPadnDownloadStorage.resumeURL(id), options: .atomic)
        }
        if jobs[idx].status == .pausing {
            jobs[idx].status = .paused
        } else {
            jobs[idx].status = .failed
            jobs[idx].error = error.localizedDescription
        }
        tasks[id] = nil
        persist()
        schedule()
    }

    fileprivate func updateProgress(id: UUID, written: Int64, expected: Int64) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].downloaded = written
        if expected > 0 { jobs[idx].expected = expected }
        let p = progress(for: id)
        p.written = written
        p.expected = expected > 0 ? expected : jobs[idx].expected
    }
}

enum IPadnDownloadError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let m) = self { return m }
        return nil
    }
}

extension IPadnDownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let idString = downloadTask.taskDescription ?? ""
        guard let id = UUID(uuidString: idString) else { return }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString + ".ipa")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.copyItem(at: location, to: tmp)
        Task { @MainActor in
            IPadnDownloadManager.shared.finishURLDownload(id: id, temp: tmp)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let idString = downloadTask.taskDescription ?? ""
        guard let id = UUID(uuidString: idString) else { return }
        Task { @MainActor in
            IPadnDownloadManager.shared.updateProgress(
                id: id,
                written: totalBytesWritten,
                expected: totalBytesExpectedToWrite
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let idString = task.taskDescription ?? ""
        guard let id = UUID(uuidString: idString) else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            IPadnDownloadManager.shared.failURL(id: id, error: error, resume: resume)
        }
    }
}
