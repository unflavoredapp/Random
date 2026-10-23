//
//  SignCache.swift
//  Signing the same IPA with the same certificate and the same options gives the same result, so the
//  second time it's a file copy instead of a full sign. The cache lives in the system Caches folder
//  (iOS may purge it, which is fine) and keeps only the few newest builds.
//

import CryptoKit
import Foundation

nonisolated enum SignCache {
    static let maxEntries = 4
    static let maxBytes: Int64 = 2_500_000_000

    private struct Meta: Codable {
        var name: String, bundleID: String, version: String
        var entitlements: [String: String]
        var sizeBytes: Int64
    }

    static var dir: URL {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirShare/sign-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private static func sha(_ d: Data?) -> String {
        guard let d else { return "-" }
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    private static func fileStamp(_ u: URL) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: u.path)
        let size = (a?[.size] as? Int64) ?? 0
        let m = Int((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        return "\(u.lastPathComponent)|\(size)|\(m)"
    }

    /// nil when the inputs can't be fingerprinted reliably (then we just sign normally).
    static func key(ipa: URL, material: CertMaterial, options o: SignOptions) -> String? {
        guard FileManager.default.fileExists(atPath: ipa.path) else { return nil }
        var s = "v1\n" + fileStamp(ipa) + "\n"
        s += sha(material.p12) + sha(material.provision) + material.password + "\n"
        s += String(describing: o) + "\n"
        s += sha(o.iconPNG) + sha(o.entitlementsPlistData) + "\n"
        for d in o.injectDylibs { s += fileStamp(d.url) + (d.weak ? "w" : "s") + "\n" }
        return sha(Data(s.utf8))
    }

    /// A temp copy of the cached IPA as a ready-to-use outcome (SignedStore moves it away, so never hand out the original).
    static func lookup(_ key: String) -> SignOutcome? {
        let fm = FileManager.default
        let ipa = dir.appendingPathComponent(key + ".ipa")
        let metaURL = dir.appendingPathComponent(key + ".json")
        guard fm.fileExists(atPath: ipa.path), let d = try? Data(contentsOf: metaURL),
              let m = try? JSONDecoder().decode(Meta.self, from: d) else { return nil }
        let out = fm.temporaryDirectory.appendingPathComponent("\(m.name)-signed-\(UUID().uuidString)").appendingPathExtension("ipa")
        guard (try? fm.copyItem(at: ipa, to: out)) != nil else { return nil }
        try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: ipa.path)      // most-recently-used
        return SignOutcome(ipaURL: out, name: m.name, bundleID: m.bundleID, version: m.version,
                           entitlements: m.entitlements, sizeBytes: m.sizeBytes)
    }

    static func store(_ key: String, outcome: SignOutcome) {
        let fm = FileManager.default
        let ipa = dir.appendingPathComponent(key + ".ipa")
        try? fm.removeItem(at: ipa)
        guard (try? fm.copyItem(at: outcome.ipaURL, to: ipa)) != nil else { return }
        let m = Meta(name: outcome.name, bundleID: outcome.bundleID, version: outcome.version,
                     entitlements: outcome.entitlements, sizeBytes: outcome.sizeBytes)
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: dir.appendingPathComponent(key + ".json")) }
        trim()
    }

    /// Keep the newest few builds under the size cap.
    @discardableResult
    static func trim(maxEntries: Int = SignCache.maxEntries, maxBytes: Int64 = SignCache.maxBytes) -> Int64 {
        let fm = FileManager.default
        var items: [(url: URL, date: Date, size: Int64)] = []
        for u in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? [] where u.pathExtension == "ipa" {
            let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            items.append((u, v?.contentModificationDate ?? .distantPast, Int64(v?.fileSize ?? 0)))
        }
        items.sort { $0.date > $1.date }
        var total: Int64 = 0, freed: Int64 = 0
        for (i, it) in items.enumerated() {
            total += it.size
            if i >= maxEntries || total > maxBytes {
                freed += it.size
                try? fm.removeItem(at: it.url)
                try? fm.removeItem(at: it.url.deletingPathExtension().appendingPathExtension("json"))
            }
        }
        return freed
    }

    @discardableResult
    static func clear() -> Int64 { trim(maxEntries: 0, maxBytes: 0) }
}
