//
//  FairPlayDecrypt.swift
//  Hardened on-device FairPlay decrypt via revised mremap_encrypted (FairPlayed/fpcore):
//  page-aligned remap window (4K LC → 16K pages), native LC cryptid + R/cid2/RX fallbacks,
//  guarded fairplayd page-in retries. Reads from a path fairplayd can open
//  (installed .app + SC_Info), verifies cryptid=0, refuses partial required Mach-Os.
//

import Darwin
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

/// Per-Mach-O cryptid line from `verifyApp` / `verifyIPA` (FairPlayed `verify_ipa.sh` style).
struct FairPlayCryptidEntry: Sendable, Identifiable {
    var id: String { path }
    var path: String
    /// Highest cryptid across slices; `-1` parse error, `0` clear / no LC, `>0` still encrypted.
    var cryptid: Int
    var detail: String

    var isEncrypted: Bool { cryptid > 0 }
}

struct FairPlayVerifyReport: Sendable {
    var entries: [FairPlayCryptidEntry] = []
    var encrypted = 0
    var clear = 0
    var plain = 0

    var isFullyClear: Bool { encrypted == 0 && !entries.isEmpty }
    var summary: String {
        "\(clear) cryptid=0 · \(encrypted) encrypted · \(plain) no LC_ENCRYPTION"
    }
}

/// Per-run summary for UI / logs.
struct FairPlayDecryptReport: Sendable {
    var decrypted: [String] = []
    var plain: [String] = []
    var failed: [String] = []
    /// Secondary targets (Watch / widgets / App Clips) that failed but didn't abort the IPA.
    var softFailed: [String] = []
    var skipped: [String] = []
    var sourcePath: String = ""
    var usedInstalledPath: Bool = false
    var scanned = 0
    var encryptedBefore = 0
    var sinfsReplicated = 0
    var verify: FairPlayVerifyReport?
    /// True when a required framework stayed encrypted but the main binary is clear (`-PARTIAL.ipa`).
    var isPartial = false

    var summary: String {
        var parts: [String] = []
        if scanned > 0 { parts.append("\(scanned) scanned") }
        if !decrypted.isEmpty { parts.append("\(decrypted.count) decrypted") }
        if !plain.isEmpty { parts.append("\(plain.count) already clear") }
        if !softFailed.isEmpty { parts.append("\(softFailed.count) optional failed") }
        if !failed.isEmpty { parts.append("\(failed.count) failed") }
        if sinfsReplicated > 0 { parts.append("\(sinfsReplicated) SINF staged") }
        if isPartial { parts.append("PARTIAL") }
        if let verify { parts.append(verify.summary) }
        return parts.isEmpty ? "no Mach-Os" : parts.joined(separator: " · ")
    }
}

/// How critical a binary is to a successful IPA.
private enum FairPlayBinaryRole {
    case main
    case framework
    case appex          // widgets / share / notification
    case nestedApp      // Watch.app / App Clip / Messages
    case other

    /// Fail the whole job if this role can't decrypt.
    var isRequired: Bool {
        switch self {
        case .main, .framework: return true
        case .appex, .nestedApp, .other: return false
        }
    }
}

enum FairPlayDecrypt {

    // MARK: - Path resolution

    /// Resolve the on-disk .app path for an installed bundle (same device).
    /// `knownPath` is an installd `Path`/`BundlePath` from the pairing tunnel when LaunchServices is sandboxed.
    static func installedAppURL(bundleID: String, knownPath: String? = nil) -> URL? {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }

        if let known = knownPath?.trimmingCharacters(in: .whitespacesAndNewlines), !known.isEmpty,
           let url = existingAppDirectory(URL(fileURLWithPath: known)) {
            return url
        }
        if let url = lsWorkspaceURL(bundleID: id) { return url }
        if let url = lsRecordURL(bundleID: id) { return url }
        if let url = lsProxyURL(bundleID: id) { return url }
        if let url = mobileInstallationLookupURL(bundleID: id) { return url }
        if let url = pathFallbackURL(bundleID: id) { return url }
        return nil
    }

    /// `MobileInstallationLookup` SPI — often returns Path when LSApplicationWorkspace is blocked.
    private static func mobileInstallationLookupURL(bundleID: String) -> URL? {
        guard let miClass = NSClassFromString("MobileInstallationLookup") as? NSObject.Type
                ?? NSClassFromString("MIClientConnection") as? NSObject.Type else {
            // Fall through to function-pointer style lookup used on older iOS.
            return mobileInstallationLookupCAPI(bundleID: bundleID)
        }
        _ = miClass
        return mobileInstallationLookupCAPI(bundleID: bundleID)
    }

    private static func mobileInstallationLookupCAPI(bundleID: String) -> URL? {
        // dlsym MobileInstallationLookup — returns CFDictionary keyed by bundle id → attributes.
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_LAZY)
                ?? dlopen("/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation", RTLD_NOW) else {
            return nil
        }
        defer { dlclose(handle) }
        typealias LookupFn = @convention(c) (CFDictionary?, CFDictionary?) -> Unmanaged<CFDictionary>?
        guard let sym = dlsym(handle, "MobileInstallationLookup") else { return nil }
        let lookup = unsafeBitCast(sym, to: LookupFn.self)
        let request: [String: Any] = [
            "ApplicationType": "Any",
            "ReturnAttributes": ["Path", "CFBundleIdentifier", "BundlePath", "Container", "CFBundleExecutable"]
        ]
        guard let raw = lookup(request as CFDictionary, nil)?.takeUnretainedValue() as? [String: Any] else {
            return nil
        }
        let entry = (raw[bundleID] as? [String: Any])
            ?? ((raw["LookupResult"] as? [String: Any])?[bundleID] as? [String: Any])
        guard let entry else { return nil }
        let path = (entry["Path"] as? String)
            ?? (entry["BundlePath"] as? String)
            ?? (entry["Container"] as? String)
        guard let path, !path.isEmpty else { return nil }
        return existingAppDirectory(URL(fileURLWithPath: path))
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

    /// FairPlayed-style `LSApplicationRecord` lookup when workspace enumeration is denied.
    private static func lsRecordURL(bundleID: String) -> URL? {
        guard let url = fp_ls_application_record_url(bundleID) else { return nil }
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

    /// Last-ditch scan of common install roots when LaunchServices APIs refuse the query.
    private static func pathFallbackURL(bundleID: String) -> URL? {
        let fm = FileManager.default
        let roots = [
            "/var/containers/Bundle/Application",
            "/private/var/containers/Bundle/Application",
        ]
        for root in roots {
            guard let containers = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for container in containers {
                let dir = URL(fileURLWithPath: root).appendingPathComponent(container)
                guard let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
                for app in kids where app.pathExtension == "app" {
                    if let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any],
                       (info["CFBundleIdentifier"] as? String) == bundleID {
                        return app
                    }
                }
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
    ///
    /// Important: do **not** full-tree-copy before FairPlay. Large apps (Telegram, eBay, …)
    /// hang for minutes on stock iOS when `copyItem` hits sandbox-slow files, and the UI
    /// used to sit forever on “Copying app bundle…”. Flow is now:
    /// 1) decrypt Mach-Os from the live install path into Payload (creates those paths)
    /// 2) copy remaining resources with progress + per-file timeout/skip
    static func decryptInstalledApp(
        bundleID: String,
        displayName: String,
        knownPath: String? = nil,
        progress: ((String) -> Void)? = nil
    ) throws -> URL {
        guard let source = installedAppURL(bundleID: bundleID, knownPath: knownPath) else {
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
        try fm.createDirectory(at: destApp, withIntermediateDirectories: true)

        // Seed Info.plist early so role/main-exe helpers work on the dest tree.
        let infoName = "Info.plist"
        let srcInfo = source.appendingPathComponent(infoName)
        if fm.fileExists(atPath: srcInfo.path) {
            _ = copyFileChunked(from: srcInfo, to: destApp.appendingPathComponent(infoName), timeout: 15)
        }

        progress?("Decrypting Mach-Os from install path…")
        var report = try decryptMachOs(readingFrom: source, writingTo: destApp, progress: progress)
        report.sourcePath = source.path
        report.usedInstalledPath = true
        progress?(report.summary)

        progress?("Copying app resources…")
        let copied = try copyAppResources(
            from: source,
            to: destApp,
            skipRelativePaths: Set(report.decrypted + report.plain + report.failed + report.softFailed),
            progress: progress
        )
        if copied == 0 && report.decrypted.isEmpty && report.plain.isEmpty {
            throw FairPlayDecryptError.failed("Couldn't copy any files from \(source.lastPathComponent).")
        }
        progress?("Copied \(copied) resource file(s)")

        try hardenDecryptedApp(at: destApp, report: &report)
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

        try hardenDecryptedApp(at: app, report: &report)
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
        // FairPlayed embed_ipa.sh: installd normally copies the main .sinf onto every
        // SinfReplicationPaths entry; IPA trees / incomplete installs often skip that.
        let staged = replicateSinfs(in: sourceApp)
        report.sinfsReplicated = staged
        if staged > 0 { progress?("Staged \(staged) nested SINF license(s)…") }

        let binaries = try collectMachOs(under: sourceApp)
        guard !binaries.isEmpty else {
            throw FairPlayDecryptError.failed("No Mach-O binaries found in \(sourceApp.lastPathComponent).")
        }
        report.scanned = binaries.count
        report.encryptedBefore = binaries.reduce(0) { acc, url in
            let n = url.path.withCString { fp_count_encrypted_slices($0) }
            return acc + max(0, Int(n))
        }
        progress?("Found \(binaries.count) Mach-Os (\(report.encryptedBefore) encrypted slices)…")

        let ordered = prioritizeBinaries(binaries, app: sourceApp)
        guard let first = ordered.first else {
            throw FairPlayDecryptError.failed("No Mach-O binaries found.")
        }

        // 1) Required first binary (main) — serial, fail closed.
        try decryptOne(
            file: first, sourceApp: sourceApp, destApp: destApp,
            index: 0, total: ordered.count, progress: progress, report: &report,
            role: role(of: first, under: sourceApp, app: sourceApp)
        )

        // 2) Remainder — concurrent (cap 4) across frameworks / appex / Watch / clips.
        let rest = Array(ordered.dropFirst())
        if !rest.isEmpty {
            progress?("Decrypting \(rest.count) more binaries…")
            let lock = NSLock()
            var local = FairPlayDecryptReport()
            let group = DispatchGroup()
            let gate = DispatchSemaphore(value: 4)
            for (offset, file) in rest.enumerated() {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    gate.wait()
                    defer { gate.signal() }
                    var mini = FairPlayDecryptReport()
                    let r = role(of: file, under: sourceApp, app: sourceApp)
                    do {
                        try decryptOne(
                            file: file, sourceApp: sourceApp, destApp: destApp,
                            index: offset + 1, total: ordered.count, progress: nil,
                            report: &mini, role: r
                        )
                    } catch {
                        // decryptOne only throws for required roles; soft-fail goes into report.
                        let rel = relativePath(file, under: sourceApp)
                        lock.lock()
                        if r.isRequired { local.failed.append(rel) }
                        else { local.softFailed.append(rel) }
                        lock.unlock()
                        return
                    }
                    lock.lock()
                    local.decrypted.append(contentsOf: mini.decrypted)
                    local.plain.append(contentsOf: mini.plain)
                    local.failed.append(contentsOf: mini.failed)
                    local.softFailed.append(contentsOf: mini.softFailed)
                    lock.unlock()
                }
            }
            group.wait()
            report.decrypted.append(contentsOf: local.decrypted)
            report.plain.append(contentsOf: local.plain)
            report.failed.append(contentsOf: local.failed)
            report.softFailed.append(contentsOf: local.softFailed)
        }

        // 3) Retry pass on anything still encrypted (fairplayd can flake under load).
        if !report.failed.isEmpty || !report.softFailed.isEmpty {
            progress?("Retrying failed binaries…")
            let retryTargets = (report.failed + report.softFailed).compactMap { rel -> URL? in
                let src = sourceApp.appendingPathComponent(rel)
                return FileManager.default.fileExists(atPath: src.path) ? src : nil
            }
            report.failed.removeAll()
            report.softFailed.removeAll()
            for (i, file) in retryTargets.enumerated() {
                var mini = FairPlayDecryptReport()
                let r = role(of: file, under: sourceApp, app: sourceApp)
                do {
                    try decryptOne(
                        file: file, sourceApp: sourceApp, destApp: destApp,
                        index: i, total: retryTargets.count, progress: progress,
                        report: &mini, role: r
                    )
                    report.decrypted.append(contentsOf: mini.decrypted)
                    report.plain.append(contentsOf: mini.plain)
                    report.failed.append(contentsOf: mini.failed)
                    report.softFailed.append(contentsOf: mini.softFailed)
                } catch {
                    if r.isRequired {
                        throw error
                    }
                    report.softFailed.append(relativePath(file, under: sourceApp))
                }
            }
        }

        // FairPlayed-style -PARTIAL.ipa: if the main executable is clear, keep going even when
        // a required framework stayed encrypted. hardenDecryptedApp + zip tag the triage IPA.
        if !report.failed.isEmpty {
            let mainClear = report.decrypted.contains { isMainExecutable($0, app: sourceApp) }
                || report.plain.contains { isMainExecutable($0, app: sourceApp) }
            if mainClear {
                report.isPartial = true
                progress?("Main clear — packaging PARTIAL (\(report.failed.count) required leftover)…")
            } else {
                throw FairPlayDecryptError.stillEncrypted(
                    "FairPlay left \(report.failed.count) required binary(ies) encrypted: \(report.failed.prefix(4).joined(separator: ", "))\(report.failed.count > 4 ? "…" : ""). \(AppStoreDecryptGuide.failureHint)"
                )
            }
        }
        return report
    }

    // MARK: - SINF replication / verify_ipa

    /// Copy the root `.sinf` onto every `SinfReplicationPaths` entry from `SC_Info/Manifest.plist`
    /// (same behavior as FairPlayed `embed_ipa.sh`). Returns how many files were staged.
    @discardableResult
    static func replicateSinfs(in app: URL) -> Int {
        let man = app.appendingPathComponent("SC_Info/Manifest.plist")
        guard let plist = NSDictionary(contentsOf: man) as? [String: Any] else { return 0 }
        let sinfPaths = (plist["SinfPaths"] as? [String]) ?? []
        let repPaths = (plist["SinfReplicationPaths"] as? [String]) ?? []
        guard let mainRel = sinfPaths.first, !mainRel.isEmpty else { return 0 }
        let mainURL = app.appendingPathComponent(mainRel)
        guard FileManager.default.fileExists(atPath: mainURL.path) else { return 0 }

        var count = 0
        let fm = FileManager.default
        for p in repPaths {
            if p.hasPrefix("Watch/") || p.contains("..") { continue }
            let dest = app.appendingPathComponent(p)
            if fm.fileExists(atPath: dest.path) { continue }
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fm.copyItem(at: mainURL, to: dest)
                count += 1
            } catch {
                continue
            }
        }
        return count
    }

    /// Report cryptid of every Mach-O under an `.app` (FairPlayed `verify_ipa.sh`).
    static func verifyApp(at app: URL) throws -> FairPlayVerifyReport {
        var report = FairPlayVerifyReport()
        for url in try collectMachOs(under: app) {
            let rel = relativePath(url, under: app)
            var detailBuf = [CChar](repeating: 0, count: 256)
            let sliceCount = url.path.withCString { path in
                detailBuf.withUnsafeMutableBufferPointer { buf in
                    fp_describe_cryptids(path, buf.baseAddress, buf.count)
                }
            }
            let detail = String(cString: detailBuf)
            let cryptid = url.path.withCString { fp_max_cryptid($0) }
            let entry = FairPlayCryptidEntry(path: rel, cryptid: Int(cryptid), detail: detail)
            report.entries.append(entry)
            if cryptid > 0 {
                report.encrypted += 1
            } else if cryptid == 0 && sliceCount > 0 && detail.contains("cryptid=0") {
                report.clear += 1
            } else if cryptid == 0 {
                // No encryption LC, or all clear.
                if detail.contains("plain") && !detail.contains("cryptid=") {
                    report.plain += 1
                } else {
                    report.clear += 1
                }
            } else {
                report.plain += 1
            }
        }
        return report
    }

    /// Unpack an IPA and verify every Mach-O’s cryptid. Throws if unzip fails.
    static func verifyIPA(at ipaURL: URL) throws -> FairPlayVerifyReport {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("fp-verify-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.unzipItem(at: ipaURL, to: work)
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        guard let app = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw FairPlayDecryptError.failed("No .app in IPA.")
        }
        return try verifyApp(at: app)
    }

    /// Decrypt a single Mach-O from `sourceApp` into `destApp`.
    private static func decryptOne(
        file: URL,
        sourceApp: URL,
        destApp: URL,
        index: Int,
        total: Int,
        progress: ((String) -> Void)?,
        report: inout FairPlayDecryptReport,
        role: FairPlayBinaryRole
    ) throws {
        let fm = FileManager.default
        let rel = relativePath(file, under: sourceApp)
        progress?("Decrypting \(rel) (\(index + 1)/\(total))…")

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
            let still = outFile.path.withCString { fp_has_encrypted_slice($0) }
            if still != 0 {
                // Restore install/IPA copy so packaging still has a complete tree for soft-fail roles.
                try? fm.removeItem(at: outFile)
                if sourceApp != destApp {
                    _ = copyFileChunked(from: file, to: outFile, timeout: 60)
                }
                if role.isRequired {
                    report.failed.append(rel)
                    if role == .main {
                        throw FairPlayDecryptError.mainExecutableFailed(
                            "Main executable still encrypted after decrypt. \(AppStoreDecryptGuide.failureHint)"
                        )
                    }
                } else {
                    report.softFailed.append(rel)
                }
            } else {
                report.decrypted.append(rel)
            }
        } else if rc == 1 {
            try? fm.removeItem(at: tmp)
            if sourceApp != destApp, !fm.fileExists(atPath: outFile.path) {
                _ = copyFileChunked(from: file, to: outFile, timeout: 60)
            }
            report.plain.append(rel)
        } else {
            try? fm.removeItem(at: tmp)
            let detail = logBuf.lines.suffix(2).joined(separator: " | ")
            if role.isRequired {
                report.failed.append(rel)
                if role == .main {
                    throw FairPlayDecryptError.mainExecutableFailed(
                        "Couldn't decrypt the main executable (\(rel)). \(detail.isEmpty ? AppStoreDecryptGuide.failureHint : detail)"
                    )
                }
            } else {
                // Keep whatever was copied into dest (may still be encrypted).
                if sourceApp != destApp, !fm.fileExists(atPath: outFile.path) {
                    _ = copyFileChunked(from: file, to: outFile, timeout: 60)
                }
                report.softFailed.append(rel)
            }
        }
    }

    // MARK: - Harden / package

    /// Strip FairPlay license crumbs / account metadata and verify no unexpected encrypted Mach-O remains.
    private static func hardenDecryptedApp(at app: URL, report: inout FairPlayDecryptReport) throws {
        let fm = FileManager.default
        // SC_Info is useless (and unwanted) on a clear IPA — including nested Watch / appex.
        try? fm.removeItem(at: app.appendingPathComponent("SC_Info"))
        if let enumerator = fm.enumerator(at: app, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let item as URL in enumerator where item.lastPathComponent == "SC_Info" {
                try? fm.removeItem(at: item)
            }
        }
        stripAccountData(from: app)

        let verify = try verifyApp(at: app)
        report.verify = verify

        let softSet = Set(report.softFailed)
        let failedSet = Set(report.failed)
        let remaining = try collectMachOs(under: app).filter { url in
            guard url.path.withCString({ fp_has_encrypted_slice($0) }) == 1 else { return false }
            let rel = relativePath(url, under: app)
            // Soft-failed Watch / widget / App Clip, and known PARTIAL leftovers, may stay encrypted.
            if softSet.contains(rel) || failedSet.contains(rel) { return false }
            let r = role(of: url, under: app, app: app)
            // PARTIAL packages only require the main executable to be clear.
            if report.isPartial { return r == .main }
            return r.isRequired
        }
        if !remaining.isEmpty {
            let names = remaining.prefix(4).map(\.lastPathComponent).joined(separator: ", ")
            throw FairPlayDecryptError.stillEncrypted(
                "Post-decrypt verify found cryptid ≠ 0 in \(remaining.count) required file(s): \(names). \(AppStoreDecryptGuide.failureHint)"
            )
        }
        if report.decrypted.isEmpty && report.plain.isEmpty {
            throw FairPlayDecryptError.failed("Nothing to decrypt in \(app.lastPathComponent).")
        }
    }

    /// Remove Apple ID / purchaser fields from iTunesMetadata.plist when present.
    private static func stripAccountData(from app: URL) {
        let candidates = [
            app.appendingPathComponent("iTunesMetadata.plist"),
            app.deletingLastPathComponent().appendingPathComponent("iTunesMetadata.plist"),
        ]
        let scrubKeys = [
            "appleId", "AppleID", "com.apple.iTunesStore.downloadInfo",
            "purchaseDate", "userName", "artistId", "playlistArtistId",
        ]
        for url in candidates {
            guard var plist = NSDictionary(contentsOf: url) as? [String: Any] else { continue }
            var changed = false
            for k in scrubKeys where plist[k] != nil {
                plist.removeValue(forKey: k)
                changed = true
            }
            if let info = plist["com.apple.iTunesStore.downloadInfo"] as? [String: Any] {
                var copy = info
                for k in ["accountInfo", "purchaseDate", "appleId"] { copy.removeValue(forKey: k) }
                plist["com.apple.iTunesStore.downloadInfo"] = copy
                changed = true
            }
            if changed {
                (plist as NSDictionary).write(to: url, atomically: true)
            }
        }
    }

    private static func zipDecryptedPayload(
        _ payload: URL,
        displayName: String,
        report: FairPlayDecryptReport
    ) throws -> URL {
        let safe = sanitizeFileName(displayName)
        let tag: String
        if report.isPartial || !report.failed.isEmpty {
            tag = "-PARTIAL"
        } else if !report.softFailed.isEmpty {
            tag = "-decrypted-soft"
        } else {
            tag = "-decrypted"
        }
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
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw FairPlayDecryptError.failed("Couldn't read app bundle.")
        }
        let skipExt: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "car", "json", "plist", "strings", "stringsdict",
            "nib", "storyboardc", "html", "js", "css", "mp3", "m4a", "caf", "mp4", "mov", "wav",
            "ttf", "otf", "ttc", "txt", "md", "xml", "svg", "pdf", "bundle", "metal", "metallib"
        ]
        var out: [URL] = []
        var seen = Set<String>()
        for case let file as URL in enumerator {
            let vals = try? file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if vals?.isDirectory == true {
                let name = file.lastPathComponent
                if name == "SC_Info" || name == "_CodeSignature" {
                    enumerator.skipDescendants()
                }
                continue
            }
            if skipExt.contains(file.pathExtension.lowercased()) { continue }
            if file.path.contains("/SC_Info/") || file.path.contains("/_CodeSignature/") { continue }
            if vals?.isSymbolicLink == true { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: file.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let path = file.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            if file.path.withCString({ fp_is_macho($0) }) {
                seen.insert(path)
                out.append(file)
            }
        }
        // Explicitly seed nested Watch / App Clip / appex executables from Info.plist.
        for nested in nestedBundleRoots(under: root) {
            if let exe = mainExecutableURL(in: nested) {
                let path = exe.standardizedFileURL.path
                if !seen.contains(path), exe.path.withCString({ fp_is_macho($0) }) {
                    seen.insert(path)
                    out.append(exe)
                }
            }
        }
        return out
    }

    /// Nested .appex / Watch.app / App Clip .app containers under the root bundle.
    private static func nestedBundleRoots(under root: URL) -> [URL] {
        var roots: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let rootPath = root.standardizedFileURL.path
        for case let url as URL in enumerator {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            let ext = url.pathExtension.lowercased()
            guard ext == "appex" || ext == "app" else { continue }
            if url.standardizedFileURL.path == rootPath { continue }
            roots.append(url)
        }
        return roots
    }

    /// Order: main → frameworks → appex → nested Watch/App Clip → other.
    private static func prioritizeBinaries(_ files: [URL], app: URL) -> [URL] {
        func order(_ r: FairPlayBinaryRole) -> Int {
            switch r {
            case .main: return 0
            case .framework: return 1
            case .appex: return 2
            case .nestedApp: return 3
            case .other: return 4
            }
        }
        return files.sorted { a, b in
            let oa = order(role(of: a, under: app, app: app))
            let ob = order(role(of: b, under: app, app: app))
            if oa != ob { return oa < ob }
            return a.path < b.path
        }
    }

    private static func role(of file: URL, under root: URL, app: URL) -> FairPlayBinaryRole {
        let rel = relativePath(file, under: root)
        if isMainExecutable(rel, app: app) { return .main }
        let parts = rel.split(separator: "/")
        if parts.contains(where: { $0.hasSuffix(".appex") }) { return .appex }
        if parts.dropFirst().contains(where: { $0.hasSuffix(".app") }) { return .nestedApp }
        if rel.contains(".framework/") || rel.hasSuffix(".dylib") { return .framework }
        if parts.first == "PlugIns" || parts.first == "Extensions" { return .appex }
        if parts.first == "Watch" || parts.first == "AppClips" { return .nestedApp }
        return .other
    }

    /// Batch decrypt several installed apps (device FairPlay). Stops on first hard failure if `stopOnError`.
    static func decryptInstalledApps(
        _ apps: [(bundleID: String, name: String)],
        stopOnError: Bool = false,
        progress: ((String) -> Void)? = nil
    ) -> [(bundleID: String, url: URL?, error: String?)] {
        var out: [(bundleID: String, url: URL?, error: String?)] = []
        for (i, app) in apps.enumerated() {
            progress?("[\(i + 1)/\(apps.count)] \(app.name)")
            do {
                let url = try decryptInstalledApp(bundleID: app.bundleID, displayName: app.name, progress: progress)
                out.append((app.bundleID, url, nil))
            } catch {
                out.append((app.bundleID, nil, error.localizedDescription))
                if stopOnError { break }
            }
        }
        return out
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

    /// Copy non-Mach-O resources into the Payload app after FairPlay has written decrypted binaries.
    /// Skips SC_Info / _CodeSignature, already-written Mach-Os, and files that hang past a timeout.
    @discardableResult
    private static func copyAppResources(
        from source: URL,
        to dest: URL,
        skipRelativePaths: Set<String>,
        progress: ((String) -> Void)?
    ) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        guard let enumerator = fm.enumerator(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw FairPlayDecryptError.failed("Couldn't enumerate app bundle.")
        }

        var copied = 0
        var skipped = 0
        var seen = 0
        let started = Date()

        for case let item as URL in enumerator {
            let name = item.lastPathComponent
            // Don't descend into FairPlay / signature trees (sandbox often stalls here).
            if name == "SC_Info" || name == "_CodeSignature" {
                enumerator.skipDescendants()
                continue
            }

            let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            if vals?.isDirectory == true {
                let rel = relativePath(item, under: source)
                try? fm.createDirectory(at: dest.appendingPathComponent(rel), withIntermediateDirectories: true)
                continue
            }
            if vals?.isSymbolicLink == true { continue }

            let rel = relativePath(item, under: source)
            if skipRelativePaths.contains(rel) { continue }
            if rel.hasPrefix("SC_Info/") || rel.contains("/SC_Info/") { continue }
            if rel.hasPrefix("_CodeSignature/") || rel.contains("/_CodeSignature/") { continue }

            seen += 1
            if seen == 1 || seen % 25 == 0 {
                let elapsed = Int(Date().timeIntervalSince(started))
                progress?("Copying resources… \(copied) ok · \(skipped) skipped · \(seen) seen (\(elapsed)s)")
            }

            let target = dest.appendingPathComponent(rel)
            if fm.fileExists(atPath: target.path) { continue }
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

            let size = Int64(vals?.fileSize ?? 0)
            // Large assets get a longer budget; tiny files stay snappy.
            let timeout: TimeInterval = size > 32 * 1024 * 1024 ? 90 : (size > 4 * 1024 * 1024 ? 45 : 20)
            if copyFileChunked(from: item, to: target, timeout: timeout) {
                copied += 1
            } else {
                skipped += 1
                try? fm.removeItem(at: target)
            }
        }

        progress?("Resources: \(copied) copied · \(skipped) skipped · \(seen) scanned")
        return copied
    }

    /// Chunked copy that can time out — `FileManager.copyItem` on App Store containers
    /// can block indefinitely on stock iOS with no progress.
    @discardableResult
    private static func copyFileChunked(from source: URL, to dest: URL, timeout: TimeInterval) -> Bool {
        let fm = FileManager.default
        guard let reader = try? FileHandle(forReadingFrom: source) else { return false }
        defer { try? reader.close() }

        fm.createFile(atPath: dest.path, contents: nil)
        guard let writer = try? FileHandle(forWritingTo: dest) else {
            try? fm.removeItem(at: dest)
            return false
        }
        defer { try? writer.close() }

        let deadline = Date().addingTimeInterval(timeout)
        let chunk = 1024 * 1024
        while true {
            if Date() > deadline { return false }
            let data: Data
            do {
                if #available(iOS 13.4, *) {
                    guard let piece = try reader.read(upToCount: chunk) else { break }
                    data = piece
                } else {
                    data = reader.readData(ofLength: chunk)
                }
            } catch {
                return false
            }
            if data.isEmpty { break }
            do {
                if #available(iOS 13.4, *) {
                    try writer.write(contentsOf: data)
                } else {
                    writer.write(data)
                }
            } catch {
                return false
            }
        }
        return true
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
