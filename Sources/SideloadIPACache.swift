//
//  SideloadIPACache.swift
//  LRU retention of decrypted/signed IPAs + resumable Store CDN downloads.
//

import Foundation

@MainActor
final class SideloadIPACache: ObservableObject {
    static let shared = SideloadIPACache()

    enum Kind: String, Codable { case decrypted, signed, storeEncrypted }

    struct Entry: Codable, Identifiable, Equatable {
        var id: String { path }
        var path: String
        var name: String
        var kind: Kind
        var savedAt: Date
        var bytes: Int64
    }

    @Published private(set) var entries: [Entry] = []

    private let maxCount = 12
    private let indexKey = "tetherless.ipaCache.index"
    private let dir: URL

    private init() {
        dir = AppPaths.dir("sideload-cache")
        load()
    }

    func remember(url: URL, kind: Kind, name: String? = nil) {
        let fm = FileManager.default
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        do {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
            let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
            entries.removeAll { $0.path == dest.path }
            entries.insert(Entry(
                path: dest.path,
                name: name ?? url.deletingPathExtension().lastPathComponent,
                kind: kind,
                savedAt: Date(),
                bytes: size
            ), at: 0)
            prune()
            persist()
        } catch {
            // Best-effort cache.
        }
    }

    func url(for entry: Entry) -> URL { URL(fileURLWithPath: entry.path) }

    func clear() {
        let fm = FileManager.default
        for e in entries { try? fm.removeItem(atPath: e.path) }
        entries = []
        persist()
    }

    private func prune() {
        let fm = FileManager.default
        while entries.count > maxCount {
            let old = entries.removeLast()
            try? fm.removeItem(atPath: old.path)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: indexKey),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        let fm = FileManager.default
        entries = list.filter { fm.fileExists(atPath: $0.path) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: indexKey)
        }
    }
}

extension AppStoreClient {
    /// Resumable CDN download (Range) into `destination`.
    func downloadFileResumable(from url: URL, to destination: URL, onProgress: ((String) -> Void)? = nil) async throws {
        let fm = FileManager.default
        let part = destination.appendingPathExtension("part")
        var start: Int64 = 0
        if fm.fileExists(atPath: part.path),
           let size = try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber {
            start = size.int64Value
        }

        var req = URLRequest(url: url)
        req.setValue(StoreDeviceSpoof.current.storeUserAgent(fallbackConfigurator: "Configurator/2.15"), forHTTPHeaderField: "User-Agent")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if start > 0 {
            req.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
            onProgress?("Resuming download at \(ByteCountFormatter.string(fromByteCount: start, countStyle: .file))…")
        }
        for (k, v) in StoreDeviceSpoof.current.storeIdentityHeaders() {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AppStoreClientError.network("IPA CDN download failed (HTTP \(status)).")
        }

        if status == 200, fm.fileExists(atPath: part.path) {
            try? fm.removeItem(at: part)
            start = 0
        }

        if !fm.fileExists(atPath: part.path) {
            fm.createFile(atPath: part.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: part)
        defer { try? handle.close() }
        if start > 0 { try handle.seekToEnd() }

        var written = start
        var buffer = Data()
        buffer.reserveCapacity(256 * 1024)
        for try await b in bytes {
            buffer.append(b)
            if buffer.count >= 256 * 1024 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if written % (4 * 1024 * 1024) < 256 * 1024 {
                    onProgress?("Downloading… \(ByteCountFormatter.string(fromByteCount: written, countStyle: .file))")
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: part, to: destination)
    }
}
