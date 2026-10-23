import Foundation

/// Local storage accounting and temporary-workspace cleanup used at launch.
///
/// AirShare keeps durable app data under Documents (inbox/signed) while signing
/// work is staged in the app's temporary directory. Completed signing paths
/// already clean themselves up; this manager removes any stale leftovers that
/// survive an interrupted/crashed operation.
nonisolated enum PortalStorage {
    struct Snapshot: Sendable {
        let inboxBytes: Int64
        let signedBytes: Int64
        let temporaryBytes: Int64

        var durableBytes: Int64 { inboxBytes + signedBytes }
        var totalBytes: Int64 { durableBytes + temporaryBytes }
    }

    static func snapshot() async -> Snapshot {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let documents = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let inbox = documents.appendingPathComponent("inbox", isDirectory: true)
            let signed = documents.appendingPathComponent("signed", isDirectory: true)
            let temporary = fm.temporaryDirectory

            return Snapshot(
                inboxBytes: directorySize(inbox, fm: fm),
                signedBytes: directorySize(signed, fm: fm),
                temporaryBytes: directorySize(temporary, fm: fm)
            )
        }.value
    }

    /// Removes temporary artifacts older than five minutes. Active signing jobs
    /// are therefore left alone while interrupted/crashed work does not linger.
    static func cleanupStaleTemporaryFiles(olderThan age: TimeInterval = 300) async -> Int {
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let root = fm.temporaryDirectory
            let cutoff = Date().addingTimeInterval(-age)
            var removed = 0

            guard let items = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }

            for item in items {
                guard let values = try? item.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = values.contentModificationDate,
                      modified < cutoff else { continue }
                do {
                    try fm.removeItem(at: item)
                    removed += 1
                } catch {
                    // A file can legitimately be in use by an active operation.
                    // Leave it alone and let the next cleanup pass handle it.
                }
            }
            return removed
        }.value
    }

    /// Explicit cleanup for the "Clean Temporary Files" action.
    /// The same five-minute safety window is used so an active signing job
    /// cannot have its workspace deleted from under it.
    static func cleanTemporaryFiles() async -> Int {
        await cleanupStaleTemporaryFiles(olderThan: 300)
    }

    private static func directorySize(_ url: URL, fm: FileManager) -> Int64 {
        guard fm.fileExists(atPath: url.path) else { return 0 }
        var total: Int64 = 0
        if let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
