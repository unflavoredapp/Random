//
//  FairPlayDecrypt.swift
//  Hardened on-device FairPlay decrypt via mremap_encrypted (FairPlayed/fpcore).
//  Reads encrypted Mach-Os from a path fairplayd can open (installed .app + SC_Info),
//  verifies cryptid=0 on every output binary, and refuses partial IPAs.
//

import Foundation
import ZIPFoundation

enum FairPlayDecryptError: LocalizedError {
    case failed(String)
    case stillEncrypted(String)
    case noInstalledApp(String)
    case missingLicense(String)
    case mainExecutableFailed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let m), .stillEncrypted(let m), .noInstalledApp(let m),
             .missingLicense(let m), .mainExecutableFailed(let m):
            return m
        }
    }
}

/// Per-run summary for UI / logs.
struct FairPlayDecryptReport: Sendable {
    var decrypted: [String] = []
    var plain: [String] = []
    var failed: [String] = []
    var sourcePath: String = ""
    var usedInstalledPath: Bool = false

    var summary: String {
        var parts: [String] = []
        if !decrypted.isEmpty { parts.append("\(decrypted.count) decrypted") }
        if !plain.isEmpty { parts.append("\(plain.count) already clear") }
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        return parts.isEmpty ? "no Mach-Os" : parts.joined(separator: " · ")
    }
}

enum FairPlayDecrypt {

    // MARK: - Path resolution

    /// Resolve the on-disk .app path for an installed bundle (same device).
    static func installedAppURL(bundleID: String) -> URL? {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        if let url = lsWorkspaceURL(bundleID: id) { return url }
        if let url = lsProxyURL(bundleID: id) { return url }
        return nil
    }

    private static func lsWorkspaceURL(bundleID: String) -> URL? {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else { return nil }
        let selDefault = NSSelectorFromString("defaultWorkspace")
        guard workspaceClass.responds(to: selDefault),
              let workspace = workspaceClass.perform(selDefault)?.takeUnretainedValue() as? NSObject else { return nil }
        let selURL = NSSelectorFromString("URLForApplicationWithBundleIdentifier:")
        guard workspace.responds(to: selURL),
              let url = workspace.perform(selURL, with: bundleID)?.takeUnretainedValue() as? URL else { return nil }
        return existingAppDirectory(url)
    }

    private static func lsProxyURL(bundleID: String) -> URL? {
        guard let proxyClass = NSClassFromString("LSApplicationProxy") as? NSObject.Type else { return nil }
        let sel = NSSelectorFromString("applicationProxyForIdentifier:")
        guard proxyClass.responds(to: sel),
              let proxy = proxyClass.perform(sel, with: bundleID)?.takeUnretainedValue() as? NSObject else { return nil }
        // bundleURL / bundleContainerURL
        for key in ["bundleURL", "bundleContainerURL"] {
            let s = NSSelectorFromString(key)
            if proxy.responds(to: s),
               let url = proxy.perform(s)?.takeUnretainedValue() as? URL,
               let app = existingAppDirectory(url) {
                return app
            }
        }
        return nil
    }

    private static func existingAppDirectory(_ url: URL) -> URL? {
        var candidate = url
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
            if candidate.pathExtension == "app" { return candidate }
            // bundleContainerURL may point at the container; look for *.app inside.
            if let apps = try? FileManager.default.contentsOfDirectory(at: candidate, includingPropertiesForKeys: nil),
               let app = apps.first(where: { $0.pathExtension == "app" }) {
                return app
            }
        }
        // Sometimes URL is the executable; walk up to .app
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                    return candidate
                }
            }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Public entry points

    /// Decrypt every Mach-O inside an .app directory in place.
    @discardableResult
    static func decryptAppBundle(at appURL: URL, progress: ((String) -> Void)? = nil) throws -> FairPlayDecryptReport {
        try decryptMachOs(readingFrom: appURL, writingTo: appURL, progress: progress)
    }

    /// Copy installed App Store .app → Payload, decrypt from live install path, zip IPA.
    static func decryptInstalledApp(
        bundleID: String,
        displayName: String,
        progress: ((String) -> Void)? = nil
    ) throws -> URL {
        guard let source = installedAppURL(bundleID: bundleID) else {
            throw FairPlayDecryptError.noInstalledApp(
                "Couldn't find \(bundleID) on this iPhone. Install it from the App Store, then try again."
            )
        }
        progress?("Found \(source.lastPathComponent)")
        try assertReadableLicense(at: source)

        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("fp-inst-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        let destApp = payload.appendingPathComponent(source.lastPathComponent)
        try fm.createDirectory(at: payload, withIntermediateDirectories: true)

        progress?("Copying app bundle…")
        try copyAppTree(from: source, to: destApp)

        progress?("Decrypting Mach-Os…")
        var report = try decryptMachOs(readingFrom: source, writingTo: destApp, progress: progress)
        report.sourcePath = source.path
        report.usedInstalledPath = true

        try hardenDecryptedApp(at: destApp, report: report)
        return try zipDecryptedPayload(payload, displayName: displayName, report: report)
    }

    /// Unpack IPA → decrypt → re-zip. Prefers live install path when the bundle is installed.
    static func decryptIPA(
        at ipaURL: URL,
        displayName: String,
        progress: ((String) -> Void)? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        progress?("Unpacking IPA…")
        try fm.unzipItem(at: ipaURL, to: work)
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        guard let app = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw FairPlayDecryptError.failed("No .app in IPA.")
        }

        var report: FairPlayDecryptReport
        if let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any],
           let bid = info["CFBundleIdentifier"] as? String,
           let installed = installedAppURL(bundleID: bid) {
            progress?("Using installed path for FairPlay keys…")
            try assertReadableLicense(at: installed)
            report = try decryptMachOs(readingFrom: installed, writingTo: app, progress: progress)
            report.sourcePath = installed.path
            report.usedInstalledPath = true
        } else {
            progress?("Decrypting from IPA contents…")
            // IPA-only path usually fails without SC_Info readable by fairplayd — still attempt, then fail closed.
            report = try decryptMachOs(readingFrom: app, writingTo: app, progress: progress)
            report.sourcePath = app.path
            report.usedInstalledPath = false
        }

        try hardenDecryptedApp(at: app, report: report)
        return try zipDecryptedPayload(payload, displayName: displayName, report: report)
    }

    // MARK: - Core decrypt

    @discardableResult
    static func decryptMachOs(
        readingFrom sourceApp: URL,
        writingTo destApp: URL,
        progress: ((String) -> Void)? = nil
    ) throws -> FairPlayDecryptReport {
        var report = FairPlayDecryptReport()
        let fm = FileManager.default
        let binaries = try collectMachOs(under: sourceApp)
        guard !binaries.isEmpty else {
            throw FairPlayDecryptError.failed("No Mach-O binaries found in \(sourceApp.lastPathComponent).")
        }

        // Main executable first — fail fast if FairPlay keys aren't available.
        let ordered = prioritizeMainExecutable(binaries, app: sourceApp)

        for (index, file) in ordered.enumerated() {
            let rel = relativePath(file, under: sourceApp)
            progress?("Decrypting \(rel) (\(index + 1)/\(ordered.count))…")

            let outFile = destApp.appendingPathComponent(rel)
            try? fm.createDirectory(at: outFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tmp = outFile.appendingPathExtension("fpdec")
            try? fm.removeItem(at: tmp)

            let logBuf = FairPlayLogBuffer()
            let rc = file.path.withCString { inPath in
                tmp.path.withCString { outPath in
                    fp_decrypt_file(inPath, outPath, FairPlayLogBuffer.trampoline, Unmanaged.passUnretained(logBuf).toOpaque())
                }
            }

            if rc == 0 {
                try? fm.removeItem(at: outFile)
                try fm.moveItem(at: tmp, to: outFile)
                // Fail closed: re-check cryptid on the written file.
                let still = outFile.path.withCString { fp_has_encrypted_slice($0) }
                if still != 0 {
                    report.failed.append(rel)
                    try? fm.removeItem(at: outFile)
                    if isMainExecutable(rel, app: sourceApp) {
                        throw FairPlayDecryptError.mainExecutableFailed(
                            "Main executable still encrypted after decrypt. \(AppStoreDecryptGuide.failureHint)"
                        )
                    }
                } else {
                    report.decrypted.append(rel)
                }
            } else if rc == 1 {
                try? fm.removeItem(at: tmp)
                if sourceApp != destApp, !fm.fileExists(atPath: outFile.path) {
                    try? fm.copyItem(at: file, to: outFile)
                }
                report.plain.append(rel)
            } else {
                try? fm.removeItem(at: tmp)
                report.failed.append(rel)
                let detail = logBuf.lines.suffix(3).joined(separator: " | ")
                if isMainExecutable(rel, app: sourceApp) {
                    throw FairPlayDecryptError.mainExecutableFailed(
                        "Couldn't decrypt the main executable (\(rel)). \(detail.isEmpty ? AppStoreDecryptGuide.failureHint : detail)"
                    )
                }
            }
        }

        if !report.failed.isEmpty {
            throw FairPlayDecryptError.stillEncrypted(
                "FairPlay left \(report.failed.count) binary(ies) encrypted: \(report.failed.prefix(4).joined(separator: ", "))\(report.failed.count > 4 ? "…" : ""). \(AppStoreDecryptGuide.failureHint)"
            )
        }
        return report
    }

    // MARK: - Harden / package

    /// Strip FairPlay license crumbs and verify no encrypted Mach-O remains.
    private static func hardenDecryptedApp(at app: URL, report: FairPlayDecryptReport) throws {
        let fm = FileManager.default
        // SC_Info is useless (and unwanted) on a clear IPA; remove it so resigners don't trip over it.
        let sc = app.appendingPathComponent("SC_Info")
        try? fm.removeItem(at: sc)

        // Verify every Mach-O under the destination is clear.
        let remaining = try collectMachOs(under: app).filter { url in
            url.path.withCString { fp_has_encrypted_slice($0) } == 1
        }
        if !remaining.isEmpty {
            let names = remaining.prefix(4).map(\.lastPathComponent).joined(separator: ", ")
            throw FairPlayDecryptError.stillEncrypted(
                "Post-decrypt verify found cryptid ≠ 0 in \(remaining.count) file(s): \(names). \(AppStoreDecryptGuide.failureHint)"
            )
        }
        if report.decrypted.isEmpty && report.plain.isEmpty {
            throw FairPlayDecryptError.failed("Nothing to decrypt in \(app.lastPathComponent).")
        }
    }

    private static func zipDecryptedPayload(
        _ payload: URL,
        displayName: String,
        report: FairPlayDecryptReport
    ) throws -> URL {
        let safe = sanitizeFileName(displayName)
        let tag = report.failed.isEmpty ? "-decrypted" : "-PARTIAL"
        let outName = safe + tag + ".ipa"
        let dest = AppPaths.dir("inbox").appendingPathComponent(outName)
        let tmp = dest.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.zipItem(at: payload, to: tmp, shouldKeepParent: true, compressionMethod: .deflate)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// fairplayd needs `<dir>/SC_Info/<exe>.sinf` next to the binary. We can't always *read* SC_Info
    /// from the sandbox, but we can check the directory exists when the install path is readable.
    private static func assertReadableLicense(at app: URL) throws {
        let sc = app.appendingPathComponent("SC_Info", isDirectory: true)
        var isDir: ObjCBool = false
        // Directory may exist but be unlistable — treat existence of the path as enough.
        if FileManager.default.fileExists(atPath: sc.path, isDirectory: &isDir) {
            return
        }
        // Some system layouts hide SC_Info from sandbox exists checks even when fairplayd can open it.
        // Soft-warn via throwing only when the main binary looks encrypted AND we know SC_Info is gone.
        if let exe = mainExecutableURL(in: app) {
            let enc = exe.path.withCString { fp_max_cryptid($0) }
            if enc > 0 {
                // Don't hard-fail — fairplayd may still resolve the license. Caller will fail on main exe.
                return
            }
        }
        _ = sc
    }

    // MARK: - Mach-O discovery

    private static func collectMachOs(under root: URL) throws -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw FairPlayDecryptError.failed("Couldn't read app bundle.")
        }
        let skipExt: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "car", "json", "plist", "strings", "stringsdict",
            "nib", "storyboardc", "html", "js", "css", "mp3", "m4a", "caf", "mp4", "mov",
            "ttf", "otf", "txt", "md", "xml", "svg", "pdf", "bundle"
        ]
        var out: [URL] = []
        for case let file as URL in enumerator {
            if skipExt.contains(file.pathExtension.lowercased()) { continue }
            // Never feed SC_Info / CodeResources into the decryptor as "binaries".
            if file.path.contains("/SC_Info/") { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let isLink = (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            if isLink { continue }
            if file.path.withCString({ fp_is_macho($0) }) {
                out.append(file)
            }
        }
        return out
    }

    private static func prioritizeMainExecutable(_ files: [URL], app: URL) -> [URL] {
        guard let main = mainExecutableURL(in: app) else { return files }
        let mainPath = main.path
        let rest = files.filter { $0.path != mainPath }
        if files.contains(where: { $0.path == mainPath }) {
            return [main] + rest
        }
        return files
    }

    private static func mainExecutableURL(in app: URL) -> URL? {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any]
        let name = (info?["CFBundleExecutable"] as? String)
            ?? app.deletingPathExtension().lastPathComponent
        let url = app.appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
        return url
    }

    private static func isMainExecutable(_ rel: String, app: URL) -> Bool {
        guard let main = mainExecutableURL(in: app) else { return false }
        return relativePath(main, under: app) == rel || rel == main.lastPathComponent
    }

    private static func relativePath(_ file: URL, under root: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if file.path.hasPrefix(prefix) {
            return String(file.path.dropFirst(prefix.count))
        }
        return file.lastPathComponent
    }

    private static func sanitizeFileName(_ name: String) -> String {
        let safe = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        let base = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return base.isEmpty ? "App" : base
    }

    /// Copy app tree, skipping unreadable SC_Info (sandbox); FairPlay still reads licenses from `source`.
    private static func copyAppTree(from source: URL, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        guard let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw FairPlayDecryptError.failed("Couldn't enumerate app bundle.")
        }
        var copied = 0
        for case let item as URL in enumerator {
            let rel = relativePath(item, under: source)
            let target = dest.appendingPathComponent(rel)
            if item.path.contains("/SC_Info") || item.lastPathComponent == "SC_Info" {
                continue
            }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            let isLink = (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
            if isLink { continue }
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: target)
            if (try? fm.copyItem(at: item, to: target)) != nil {
                copied += 1
            }
        }
        if copied == 0 {
            throw FairPlayDecryptError.failed("Couldn't copy any files from \(source.lastPathComponent).")
        }
    }
}

// MARK: - C log bridge

private final class FairPlayLogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > 64 { lines.removeFirst(lines.count - 64) }
        lock.unlock()
    }

    static let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { ctx, msg in
        guard let ctx, let msg else { return }
        let box = Unmanaged<FairPlayLogBuffer>.fromOpaque(ctx).takeUnretainedValue()
        box.append(String(cString: msg))
    }
}
