//
// Brand: AppAssassin · https://fastdecrypt.ai
//  AppPaths.swift
//  Shared Documents helpers for host + DecryptHelper (kept out of CertificateStore).
//

import Foundation

nonisolated enum AppPaths {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    /// Private storage for locked certificates (Application Support is not exposed through the Files app).
    static var lockedCerts: URL {
        var u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirShare/locked-certs", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = URLResourceValues(); v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
        return u
    }
    static func dir(_ name: String) -> URL {
        let u = documents.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}
