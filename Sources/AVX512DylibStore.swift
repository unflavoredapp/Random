import Foundation

/// Persists the staff-selected AVX512 dylib outside the public Documents area.
/// The signing sheet can automatically inject this dylib into the current IPA
/// when the AVX512 experimental bridge is enabled.
enum AVX512DylibStore {
    private static let directoryName = "AVX512"
    private static let fileName = "AVX512.dylib"

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static var storedURL: URL? {
        let url = directory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    static func install(from source: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }

        let destination = directory.appendingPathComponent(fileName)
        if source.pathExtension.lowercased() != "dylib" {
            throw CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "AVX512 must be a .dylib file."])
        }
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: source, to: destination)
        return destination
    }

    static func remove() {
        if let url = storedURL { try? FileManager.default.removeItem(at: url) }
    }
}
