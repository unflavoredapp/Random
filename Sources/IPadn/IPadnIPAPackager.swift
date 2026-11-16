//
//  IPadnIPAPackager.swift
//  Write iTunesMetadata + FairPlay sinfs into a CDN IPA (mengangs/ipadn PackageService style).
//

import Foundation
import ZIPFoundation

enum IPadnIPAPackager {
    static func writeMetadata(_ meta: [String: Any], email: String, intoIPA ipa: URL) throws {
        var m = meta
        m["apple-id"] = email
        m["userName"] = email
        let data = try PropertyListSerialization.data(fromPropertyList: m, format: .binary, options: 0)
        let archive = try Archive(url: ipa, accessMode: .update)
        if let existing = archive["iTunesMetadata.plist"] {
            try archive.remove(existing)
        }
        try archive.addEntry(with: "iTunesMetadata.plist", type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position) ..< Int(position) + size)
        }
    }

    static func injectSinfs(_ sinfs: [Data], intoIPA ipa: URL) throws {
        guard !sinfs.isEmpty else { return }
        let archive = try Archive(url: ipa, accessMode: .update)
        let bundleName = try payloadAppBundleName(in: archive)
        let appPrefix = "Payload/\(bundleName).app/"

        if let paths = try readSinfPathsFromManifest(in: archive, appPrefix: appPrefix), !paths.isEmpty {
            guard paths.count == sinfs.count else {
                throw IPadnToolError.message("FairPlay license count does not match SC_Info Manifest.plist.")
            }
            for (index, rel) in paths.enumerated() {
                let path = appPrefix + rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                try addOrReplace(archive, path: path, data: sinfs[index])
            }
            return
        }

        guard let exe = try readBundleExecutable(in: archive, appPrefix: appPrefix) else {
            throw IPadnToolError.message("Could not locate app executable for FairPlay license inject.")
        }
        try addOrReplace(archive, path: "\(appPrefix)SC_Info/\(exe).sinf", data: sinfs[0])
    }

    private static func addOrReplace(_ archive: Archive, path: String, data: Data) throws {
        if let existing = archive[path] {
            try archive.remove(existing)
        }
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position) ..< Int(position) + size)
        }
    }

    private static func payloadAppBundleName(in archive: Archive) throws -> String {
        for entry in archive {
            let path = entry.path
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
        let path = appPrefix + "SC_Info/Manifest.plist"
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let paths = plist["SinfPaths"] as? [String], !paths.isEmpty else {
            return nil
        }
        return paths
    }

    private static func readBundleExecutable(in archive: Archive, appPrefix: String) throws -> String? {
        let path = appPrefix + "Info.plist"
        guard let entry = archive[path] else { return nil }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        return plist?["CFBundleExecutable"] as? String
    }
}
