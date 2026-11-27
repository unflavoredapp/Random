//
// Brand: Tetherless · https://tetherless.dev
//  IPadnIPAPackager.swift
//  Write iTunesMetadata + FairPlay sinfs into a CDN IPA (mengangs/ipadn PackageService style).
//

import Foundation
import ZIPFoundation

enum IPadnIPAPackager {
    /// Peek target CFBundleIdentifier from a Store IPA without a full unzip.
    /// Prefers `Payload/*.app/Info.plist`, then `iTunesMetadata.plist` ticket fields.
    static func bundleID(fromIPA ipa: URL) -> String? {
        guard let archive = try? Archive(url: ipa, accessMode: .read) else { return nil }
        for entry in archive {
            let path = normalizeIPAEntryPath(entry.path)
            guard path.hasPrefix("Payload/"),
                  path.hasSuffix(".app/Info.plist"),
                  !path.contains("/Watch/"),
                  !path.contains(".appex/") else { continue }
            var data = Data()
            do {
                _ = try archive.extract(entry) { data.append($0) }
            } catch {
                continue
            }
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let bid = (plist["CFBundleIdentifier"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !bid.isEmpty else { continue }
            return bid
        }
        for entry in archive {
            guard normalizeIPAEntryPath(entry.path) == "iTunesMetadata.plist" else { continue }
            var data = Data()
            do {
                _ = try archive.extract(entry) { data.append($0) }
            } catch {
                break
            }
            guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                break
            }
            for key in ["softwareVersionBundleId", "bundleId", "software-version-bundle-id"] {
                if let bid = (plist[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !bid.isEmpty {
                    return bid
                }
            }
            break
        }
        return nil
    }

    /// Strip leading `./` so `./Payload/Foo.app/Info.plist` still matches.
    static func normalizeIPAEntryPath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while p.hasPrefix("./") { p = String(p.dropFirst(2)) }
        while p.hasPrefix("/") { p = String(p.dropFirst()) }
        return p
    }

    /// Count `.sinf` license entries inside a Store IPA (skips Watch).
    static func countSinfs(inIPA ipa: URL) -> Int {
        guard let archive = try? Archive(url: ipa, accessMode: .read) else { return 0 }
        var n = 0
        for entry in archive {
            let path = normalizeIPAEntryPath(entry.path)
            guard path.lowercased().hasSuffix(".sinf") else { continue }
            if path.contains("/Watch/") { continue }
            n += 1
        }
        return n
    }

    static func writeMetadata(_ meta: [String: Any], email: String, intoIPA ipa: URL) throws {
        var m = meta
        m["apple-id"] = email
        m["userName"] = email
        let data = try PropertyListSerialization.data(fromPropertyList: m, format: .binary, options: 0)
        let archive = try Archive(url: ipa, accessMode: .update)
        if let existing = entry(in: archive, normalizedPath: "iTunesMetadata.plist") {
            try archive.remove(existing)
        }
        try archive.addEntry(with: "iTunesMetadata.plist", type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position) ..< Int(position) + size)
        }
    }

    /// Inject `songList` sinfs into `Payload/<App>.app/SC_Info/…`.
    /// CDN Manifest often lists more `SinfPaths` than songList returns — place what we have
    /// (FairPlayed replicates the root license onto the rest after unzip). Verify the IPA
    /// actually contains `.sinf` entries; ZIPFoundation `.update` can silently no-op, so
    /// fall back to unzip → write → rezip when needed.
    static func injectSinfs(_ sinfs: [Data], intoIPA ipa: URL) throws {
        guard !sinfs.isEmpty else { return }
        do {
            try injectSinfsUpdating(sinfs, intoIPA: ipa)
        } catch {
            // Fall through to unzip path when update-mode inject fails.
            try injectSinfsViaUnzip(sinfs, intoIPA: ipa)
            guard countSinfs(inIPA: ipa) > 0 else { throw error }
            return
        }
        if countSinfs(inIPA: ipa) > 0 { return }
        try injectSinfsViaUnzip(sinfs, intoIPA: ipa)
        guard countSinfs(inIPA: ipa) > 0 else {
            throw IPadnToolError.message(
                "FairPlay licenses did not stick in the Store IPA (0 .sinf after inject). Retry Get."
            )
        }
    }

    private static func injectSinfsUpdating(_ sinfs: [Data], intoIPA ipa: URL) throws {
        let archive = try Archive(url: ipa, accessMode: .update)
        let bundleName = try payloadAppBundleName(in: archive)
        let appPrefix = "Payload/\(bundleName).app/"
        try writeSinfs(sinfs, into: archive, appPrefix: appPrefix)
    }

    /// Reliable path when ZIP `.update` leaves the central directory without new `.sinf` entries.
    private static func injectSinfsViaUnzip(_ sinfs: [Data], intoIPA ipa: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("tl-sinf-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        try fm.unzipItem(at: ipa, to: work)
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        guard let app = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw IPadnToolError.message("Could not find Payload/*.app for FairPlay license inject.")
        }

        let paths = readSinfPathsFromApp(app)
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any]
        let exe = (info?["CFBundleExecutable"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let paths, !paths.isEmpty {
            let n = min(paths.count, sinfs.count)
            for i in 0..<n {
                let rel = paths[i].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let dest = app.appendingPathComponent(rel)
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try sinfs[i].write(to: dest, options: .atomic)
            }
            // Always ensure root license lands on SinfPaths[0] when songList only returned one blob.
            if sinfs.count == 1, let first = paths.first {
                let dest = app.appendingPathComponent(first.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try sinfs[0].write(to: dest, options: .atomic)
            }
        } else {
            guard let exe, !exe.isEmpty else {
                throw IPadnToolError.message("Could not locate app executable for FairPlay license inject.")
            }
            let sc = app.appendingPathComponent("SC_Info", isDirectory: true)
            try fm.createDirectory(at: sc, withIntermediateDirectories: true)
            try sinfs[0].write(to: sc.appendingPathComponent("\(exe).sinf"), options: .atomic)
        }

        let rebuilt = work.appendingPathComponent("rebuilt.ipa")
        try? fm.removeItem(at: rebuilt)
        try fm.zipItem(at: payload, to: rebuilt, shouldKeepParent: true, compressionMethod: .deflate)
        try? fm.removeItem(at: ipa)
        try fm.moveItem(at: rebuilt, to: ipa)
    }

    private static func writeSinfs(_ sinfs: [Data], into archive: Archive, appPrefix: String) throws {
        if let paths = try readSinfPathsFromManifest(in: archive, appPrefix: appPrefix), !paths.isEmpty {
            // songList often returns 1 sinf while Manifest lists many framework paths.
            // Place what we have; FairPlayed replicateSinfs fills the rest after unzip.
            let n = min(paths.count, sinfs.count)
            for i in 0..<n {
                let path = appPrefix + paths[i].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                try addOrReplace(archive, path: path, data: sinfs[i])
            }
            if sinfs.count == 1 {
                let path = appPrefix + paths[0].trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                try addOrReplace(archive, path: path, data: sinfs[0])
            }
            return
        }

        guard let exe = try readBundleExecutable(in: archive, appPrefix: appPrefix) else {
            throw IPadnToolError.message("Could not locate app executable for FairPlay license inject.")
        }
        try addOrReplace(archive, path: "\(appPrefix)SC_Info/\(exe).sinf", data: sinfs[0])
    }

    private static func addOrReplace(_ archive: Archive, path: String, data: Data) throws {
        if let existing = entry(in: archive, normalizedPath: normalizeIPAEntryPath(path)) {
            try archive.remove(existing)
        }
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position) ..< Int(position) + size)
        }
    }

    private static func entry(in archive: Archive, normalizedPath: String) -> Entry? {
        let want = normalizeIPAEntryPath(normalizedPath)
        for entry in archive where normalizeIPAEntryPath(entry.path) == want {
            return entry
        }
        // Exact subscript fallback for callers that already normalized.
        return archive[want] ?? archive[normalizedPath]
    }

    private static func payloadAppBundleName(in archive: Archive) throws -> String {
        for entry in archive {
            let path = normalizeIPAEntryPath(entry.path)
            guard path.contains(".app/Info.plist"), !path.contains("/Watch/") else { continue }
            let parts = path.split(separator: "/")
            guard parts.count >= 2 else { continue }
            let app = parts[parts.count - 2]
            if app.hasSuffix(".app") {
                return String(app.dropLast(4))
            }
        }
        throw IPadnToolError.message("Could not find Payload/*.app in downloaded IPA.")
    }

    private static func readSinfPathsFromManifest(in archive: Archive, appPrefix: String) throws -> [String]? {
        let path = normalizeIPAEntryPath(appPrefix + "SC_Info/Manifest.plist")
        guard let entry = entry(in: archive, normalizedPath: path) else { return nil }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let paths = plist["SinfPaths"] as? [String], !paths.isEmpty else {
            return nil
        }
        return paths
    }

    private static func readSinfPathsFromApp(_ app: URL) -> [String]? {
        let man = app.appendingPathComponent("SC_Info/Manifest.plist")
        guard let plist = NSDictionary(contentsOf: man) as? [String: Any],
              let paths = plist["SinfPaths"] as? [String], !paths.isEmpty else {
            return nil
        }
        return paths
    }

    private static func readBundleExecutable(in archive: Archive, appPrefix: String) throws -> String? {
        let path = normalizeIPAEntryPath(appPrefix + "Info.plist")
        guard let entry = entry(in: archive, normalizedPath: path) else { return nil }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return plist?["CFBundleExecutable"] as? String
    }
}
