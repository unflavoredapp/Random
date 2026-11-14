//
//  FairPlayDecrypt.swift
//  On-device FairPlay decrypt via mremap_encrypted (FairPlayed/fpcore) — real kernel path, no mock.
//

import Foundation
import ZIPFoundation

enum FairPlayDecryptError: LocalizedError {
    case failed(String)
    case stillEncrypted(String)
    case noInstalledApp(String)
    var errorDescription: String? {
        switch self {
        case .failed(let m), .stillEncrypted(let m), .noInstalledApp(let m): return m
        }
    }
}

enum FairPlayDecrypt {
    /// Resolve the on-disk .app path for an installed bundle (same device) via LSApplicationWorkspace.
    static func installedAppURL(bundleID: String) -> URL? {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        // Private MobileCoreServices API — available on device; returns nil in Simulator / without class.
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return nil }
        let selDefault = NSSelectorFromString("defaultWorkspace")
        guard workspaceClass.responds(to: selDefault),
              let workspace = workspaceClass.perform(selDefault)?.takeUnretainedValue() as? NSObject else { return nil }
        let selURL = NSSelectorFromString("URLForApplicationWithBundleIdentifier:")
        guard workspace.responds(to: selURL),
              let url = workspace.perform(selURL, with: id)?.takeUnretainedValue() as? URL else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return url
    }

    /// Decrypt every Mach-O inside an .app directory in place (main binary, frameworks, appex).
    /// Prefer `decryptInstalledApp` when the source is an App Store install — fairplayd needs SC_Info on a readable path.
    @discardableResult
    static func decryptAppBundle(at appURL: URL) throws -> Int {
        try decryptMachOs(readingFrom: appURL, writingTo: appURL)
    }

    /// Read encrypted Mach-Os from `sourceApp` (installed path fairplayd can open) and write cleartext into `destApp`.
    @discardableResult
    static func decryptMachOs(readingFrom sourceApp: URL, writingTo destApp: URL) throws -> Int {
        var decrypted = 0
        var failed = 0
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: sourceApp, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else {
            throw FairPlayDecryptError.failed("Couldn't read app bundle.")
        }
        for case let file as URL in enumerator {
            let name = file.lastPathComponent
            if ["png", "jpg", "jpeg", "gif", "car", "json", "plist", "strings", "nib", "storyboardc", "html", "js", "css", "mp3", "m4a", "caf"].contains(file.pathExtension.lowercased()) {
                continue
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard let fh = try? FileHandle(forReadingFrom: file),
                  let magic = try? fh.read(upToCount: 4), magic.count == 4 else { continue }
            try? fh.close()
            let m = magic.withUnsafeBytes { $0.load(as: UInt32.self) }
            let machoMagics: Set<UInt32> = [0xfeedface, 0xcefaedfe, 0xfeedfacf, 0xcffaedfe, 0xcafebabe, 0xbebafeca]
            guard machoMagics.contains(m) else { continue }

            let rel = file.path.replacingOccurrences(of: sourceApp.path, with: "")
            let outFile = destApp.appendingPathComponent(String(rel.drop(while: { $0 == "/" })))
            try? fm.createDirectory(at: outFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = outFile.appendingPathExtension("fpdec")
            let rc = file.path.withCString { inPath in
                tmp.path.withCString { outPath in
                    fp_decrypt_file(inPath, outPath, nil, nil)
                }
            }
            if rc == 0 {
                try? fm.removeItem(at: outFile)
                try fm.moveItem(at: tmp, to: outFile)
                decrypted += 1
            } else if rc == 1 {
                try? fm.removeItem(at: tmp)
                if sourceApp != destApp, !fm.fileExists(atPath: outFile.path) {
                    try? fm.copyItem(at: file, to: outFile)
                }
            } else {
                try? fm.removeItem(at: tmp)
                failed += 1
            }
        }
        if decrypted == 0 && failed > 0 {
            throw FairPlayDecryptError.stillEncrypted("FairPlay decrypt failed on \(failed) binary(ies). \(AppStoreDecryptGuide.failureHint)")
        }
        return decrypted
    }

    /// Copy an installed App Store .app → Payload, decrypt Mach-Os from the live install path, zip IPA.
    static func decryptInstalledApp(bundleID: String, displayName: String) throws -> URL {
        guard let source = installedAppURL(bundleID: bundleID) else {
            throw FairPlayDecryptError.noInstalledApp("Couldn't find \(bundleID) on this iPhone. Install it from the App Store, then try again.")
        }
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("fp-inst-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        let appName = source.lastPathComponent
        let destApp = payload.appendingPathComponent(appName)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)
        try copyAppTree(from: source, to: destApp)
        let count = try decryptMachOs(readingFrom: source, writingTo: destApp)
        let safe = displayName.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        let base = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let outName = (base.isEmpty ? "App" : base) + "-decrypted.ipa"
        let dest = AppPaths.dir("inbox").appendingPathComponent(outName)
        try? fm.removeItem(at: dest)
        try fm.zipItem(at: payload, to: dest, shouldKeepParent: true, compressionMethod: .deflate)
        if count == 0 {
            // Already clear or no encrypted slices — still a valid IPA.
        }
        return dest
    }

    /// Unpack IPA → decrypt Payload/*.app → re-zip to Documents/inbox.
    /// Note: fairplayd often cannot read SC_Info from Documents; prefer `decryptInstalledApp` for App Store apps.
    static func decryptIPA(at ipaURL: URL, displayName: String) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.unzipItem(at: ipaURL, to: work)
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        guard let app = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw FairPlayDecryptError.failed("No .app in IPA.")
        }
        // If Info.plist has a bundle id that is installed, decrypt from the live install path.
        if let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any],
           let bid = info["CFBundleIdentifier"] as? String,
           let installed = installedAppURL(bundleID: bid) {
            _ = try decryptMachOs(readingFrom: installed, writingTo: app)
        } else {
            _ = try decryptAppBundle(at: app)
        }
        let safe = displayName.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        let base = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let outName = (base.isEmpty ? "App" : base) + "-decrypted.ipa"
        let dest = AppPaths.dir("inbox").appendingPathComponent(outName)
        try? fm.removeItem(at: dest)
        try fm.zipItem(at: payload, to: dest, shouldKeepParent: true, compressionMethod: .deflate)
        return dest
    }

    /// Copy app tree, tolerating unreadable SC_Info (sandbox); FairPlay still reads those from `source` at decrypt time.
    private static func copyAppTree(from source: URL, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw FairPlayDecryptError.failed("Couldn't enumerate app bundle.")
        }
        for case let item as URL in enumerator {
            let rel = item.path.replacingOccurrences(of: source.path, with: "")
            let target = dest.appendingPathComponent(String(rel.drop(while: { $0 == "/" })))
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            // Skip SC_Info contents — unreadable to the sandbox; fairplayd reads them from the install path.
            if item.path.contains("/SC_Info/") || item.lastPathComponent == "SC_Info" {
                continue
            }
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: item, to: target)
        }
    }
}
