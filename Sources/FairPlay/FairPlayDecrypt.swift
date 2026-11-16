//
// Brand: Tetherless · https://tetherless.dev
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
    case outOfMemory(String)

    var errorDescription: String? {
        switch self {
        case .failed(let m), .stillEncrypted(let m), .noInstalledApp(let m),
             .missingLicense(let m), .mainExecutableFailed(let m), .outOfMemory(let m):
            return m
        }
    }
}

/// Map fpcore failure class + log text into a user-facing message (keys vs OOM vs still encrypted).
enum FairPlayFailureClass: String {
    case none, outOfMemory, licenseOrKeys, stillEncrypted, io, other

    static func current(fromLogs lines: [String] = []) -> FairPlayFailureClass {
        let kind = Int(fp_last_fail_kind())
        switch kind {
        case Int(FP_FAIL_NOMEM): return .outOfMemory
        case Int(FP_FAIL_PERM): return .licenseOrKeys
        case Int(FP_FAIL_STILL_ENC): return .stillEncrypted
        case Int(FP_FAIL_IO): return .io
        case Int(FP_FAIL_OTHER): break
        default: break
        }
        let blob = lines.joined(separator: "\n").lowercased()
        if blob.contains("errno 12") || blob.contains("cannot allocate") || blob.contains("enomem")
            || blob.contains("low memory") || blob.contains("out-of-memory") {
            return .outOfMemory
        }
        if blob.contains("eperm") || blob.contains("-42004") || blob.contains("-42110")
            || blob.contains("license") || blob.contains("media & purchases") {
            return .licenseOrKeys
        }
        if blob.contains("still encrypted") || blob.contains("cryptid") {
            return .stillEncrypted
        }
        return kind == Int(FP_FAIL_NONE) ? .none : .other
    }

    var userMessage: String {
        switch self {
        case .outOfMemory:
            return "Not enough memory to decrypt this binary (mremap ENOMEM). Close other apps, keep Tetherless in the foreground, and retry."
        case .licenseOrKeys:
            return AppStoreDecryptGuide.failureHint
        case .stillEncrypted:
            return "FairPlay still reports encryption after remap. \(AppStoreDecryptGuide.failureHint)"
        case .io:
            return "Couldn't read or write the encrypted binary. Re-download the IPA and retry."
        case .other, .none:
            return AppStoreDecryptGuide.failureHint
        }
    }
}

/// Per-Mach-O cryptid line from `verifyApp` / `verifyIPA` (FairPlayed `verify_ipa.sh` style).
struct FairPlayCryptidEntry: Sendable, Identifiable {
    var id: String { path }
    var path: String
    /// Highest cryptid across slices; `<0` unknown (parse/timeout/skip), `0` clear / no LC, `>0` still encrypted.
    var cryptid: Int
    var detail: String

    var isEncrypted: Bool { cryptid > 0 }
    /// Parse failure, probe timeout, or intentionally skipped live-install probe — never treat as clear.
    var isUnknown: Bool { cryptid < 0 }
}

struct FairPlayVerifyReport: Sendable {
    var entries: [FairPlayCryptidEntry] = []
    var encrypted = 0
    var clear = 0
    var plain = 0
    /// Binaries that could not be inspected (timeout, parse error, skipped live probe).
    var unknown = 0

    /// True only when every Mach-O was inspected and none remain encrypted.
    var isFullyClear: Bool { encrypted == 0 && unknown == 0 && !entries.isEmpty }
    var summary: String {
        var parts = [
            "\(clear) cryptid=0",
            "\(encrypted) encrypted",
            "\(plain) no LC_ENCRYPTION",
        ]
        if unknown > 0 { parts.append("\(unknown) unknown") }
        return parts.joined(separator: " · ")
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
    /// Refuses live App Store installs — never mutate `/var/containers/Bundle/Application`.
    @discardableResult
    static func decryptAppBundle(at appURL: URL, progress: ((String) -> Void)? = nil) throws -> FairPlayDecryptReport {
        if isLiveAppStoreInstall(appURL) {
            throw FairPlayDecryptError.failed(
                "Refusing in-place decrypt of a live App Store install. Use decryptInstalledApp (writes a Payload copy) or the companion."
            )
        }
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

        // FairPlayed `exportInstalledApp` / foulplay: mremap_encrypted the live install
        // binary (next to SC_Info) and write cleartext into a writable Payload copy.
        // Competition companion console uses the same line style as FairPlayed's export log.
        let appLabel = source.deletingPathExtension().lastPathComponent
        progress?("Found installed app: \(appLabel)")
        progress?("Decrypting Mach-O file(s) from install path…")
        var report = try decryptMachOs(readingFrom: source, writingTo: destApp, progress: progress)
        report.sourcePath = source.path
        report.usedInstalledPath = true
        let plainN = report.plain.count
        let decN = report.decrypted.count
        progress?("Done: \(decN) decrypted, \(plainN) already plain.")

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
        progress?("Packaging \(sanitizeFileName(displayName))-decrypted.ipa…")
        return try zipDecryptedPayload(payload, displayName: displayName, report: report)
    }

    /// Unpack IPA → decrypt → re-zip.
    /// - Parameter preferIPAContentsOnly: When true, never switch to a live App Store
    ///   install path (avoids hanging cryptid probes after Store package download).
    static func decryptIPA(
        at ipaURL: URL,
        displayName: String,
        preferIPAContentsOnly: Bool = true,
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
        if !preferIPAContentsOnly,
           let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any],
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
        // Never write decrypted binaries (or SINF staging) into a live App Store container.
        if isLiveAppStoreInstall(destApp) {
            throw FairPlayDecryptError.failed(
                "Refusing to write into a live App Store install. Decrypt output must be a Payload/temp copy or companion EmbeddedPayload."
            )
        }
        // FairPlayed embed_ipa.sh: installd normally copies the main .sinf onto every
        // SinfReplicationPaths entry. Never write into a live App Store install container —
        // SC_Info reads/writes there hung decrypt on “Decrypting Mach-Os…”.
        if isLiveAppStoreInstall(sourceApp) {
            progress?("Using live install licenses (no SINF staging)…")
        } else {
            let staged = replicateSinfs(in: sourceApp)
            report.sinfsReplicated = staged
            if staged > 0 { progress?("Staged \(staged) Manifest SINF license(s)…") }
        }

        progress?("Locating Mach-Os under \(isLiveAppStoreInstall(sourceApp) ? "install path" : "app bundle")…")
        let binaries = try collectMachOs(under: sourceApp, progress: progress)
        guard !binaries.isEmpty else {
            throw FairPlayDecryptError.failed("No Mach-O binaries found in \(sourceApp.lastPathComponent).")
        }
        report.scanned = binaries.count
        // Don't pre-open every binary for cryptid counts — that re-hangs on install paths.
        // Count after we know the list, with a short timeout per file.
        var encryptedBins: [URL] = []
        var encCount = 0
        for url in binaries {
            if let n = withTimeout(seconds: 3, work: {
                Int(url.path.withCString { fp_count_encrypted_slices($0) })
            }), n > 0 {
                encCount += n
                encryptedBins.append(url)
            }
        }
        report.encryptedBefore = encCount

        // buddy3 `stage_folder_sinfs`: copy root .sinf next to every encrypted Mach-O
        // (`…/SC_Info/<exe>.sinf`) so fairplayd can resolve licenses without a live install.
        if !isLiveAppStoreInstall(sourceApp), !encryptedBins.isEmpty {
            let perBinary = stageSinfsForEncryptedBinaries(encryptedBins, in: sourceApp)
            report.sinfsReplicated += perBinary
            if perBinary > 0 {
                progress?("Staged \(perBinary) per-binary SINF license(s)…")
            }
        }

        progress?("Decrypting \(binaries.count) Mach-O file(s)…")
        if encCount > 0 {
            progress?("(\(encCount) encrypted slice(s) to clear)")
        }

        let ordered = prioritizeBinaries(binaries, app: sourceApp)
        guard !ordered.isEmpty else {
            throw FairPlayDecryptError.failed("No Mach-O binaries found.")
        }

        // Serial decrypt with live FairPlayed-style console lines (competition companion).
        for (index, file) in ordered.enumerated() {
            pauseIfMemoryPressure(progress: progress)
            let r = role(of: file, under: sourceApp, app: sourceApp)
            let rel = relativePath(file, under: sourceApp)
            let budget: TimeInterval = (r == .main) ? 180 : 90
            let outcome = decryptOneWithTimeout(
                file: file, sourceApp: sourceApp, destApp: destApp,
                index: index, total: ordered.count, role: r, timeout: budget
            )
            switch outcome {
            case .timedOut:
                progress?("[FAILED]    \(rel) (timeout \(Int(budget))s)")
                if r.isRequired {
                    report.failed.append(rel)
                    if r == .main {
                        throw FairPlayDecryptError.mainExecutableFailed(
                            "Timed out decrypting the main executable (\(rel)). \(AppStoreDecryptGuide.failureHint)"
                        )
                    }
                } else {
                    report.softFailed.append(rel)
                }
            case .threw(let error):
                progress?("[FAILED]    \(rel)")
                if r.isRequired {
                    if r == .main { throw error }
                    report.failed.append(rel)
                } else {
                    report.softFailed.append(rel)
                }
            case .ok(let mini):
                report.decrypted.append(contentsOf: mini.decrypted)
                report.plain.append(contentsOf: mini.plain)
                report.failed.append(contentsOf: mini.failed)
                report.softFailed.append(contentsOf: mini.softFailed)
                if mini.decrypted.contains(rel) {
                    progress?("[DECRYPTED] \(rel)")
                } else if mini.plain.contains(rel) {
                    progress?("[plain]     \(rel)")
                } else if mini.failed.contains(rel) || mini.softFailed.contains(rel) {
                    progress?("[FAILED]    \(rel)")
                }
                if r == .main, mini.failed.contains(rel) {
                    throw FairPlayDecryptError.mainExecutableFailed(
                        "Couldn't decrypt the main executable (\(rel)). \(AppStoreDecryptGuide.failureHint)"
                    )
                }
            }
        }

        // buddy3 `verify_with_targeted_retries`: re-probe dest cryptids and retry only
        // still-encrypted required binaries (backoff), instead of blind soft-fail retries.
        try verifyWithTargetedRetries(
            sourceApp: sourceApp,
            destApp: destApp,
            report: &report,
            progress: progress
        )

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
    /// Must only be called on a writable tree (never a live App Store install).
    @discardableResult
    static func replicateSinfs(in app: URL) -> Int {
        if isLiveAppStoreInstall(app) { return 0 }
        let man = app.appendingPathComponent("SC_Info/Manifest.plist")
        // Reading SC_Info on some installs can stall — bound it.
        let plist: [String: Any]? = withTimeout(seconds: 5) {
            NSDictionary(contentsOf: man) as? [String: Any]
        } ?? nil
        guard let plist else { return 0 }
        let sinfPaths = (plist["SinfPaths"] as? [String]) ?? []
        let repPaths = (plist["SinfReplicationPaths"] as? [String]) ?? []
        guard let mainRel = sinfPaths.first, !mainRel.isEmpty else { return 0 }
        let mainURL = app.appendingPathComponent(mainRel)
        guard FileManager.default.fileExists(atPath: mainURL.path) else { return 0 }

        var count = 0
        let fm = FileManager.default
        for p in repPaths {
            if p.hasPrefix("Watch/") { continue }
            guard let dest = secureChildURL(root: app, relative: p) else { continue }
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

    /// buddy3 `find_folder_root_sinf` + `stage_folder_sinfs`: place root license next to each
    /// encrypted binary so IPA-only / silent-download trees decrypt without a live install.
    @discardableResult
    static func stageSinfsForEncryptedBinaries(_ encrypted: [URL], in app: URL) -> Int {
        if isLiveAppStoreInstall(app) { return 0 }
        guard let root = findFolderRootSinf(in: app) else { return 0 }
        let fm = FileManager.default
        var count = 0
        for bin in encrypted {
            let sc = bin.deletingLastPathComponent().appendingPathComponent("SC_Info", isDirectory: true)
            let dest = sc.appendingPathComponent("\(bin.lastPathComponent).sinf")
            if fm.fileExists(atPath: dest.path) { continue }
            if dest.standardizedFileURL == root.standardizedFileURL { continue }
            try? fm.createDirectory(at: sc, withIntermediateDirectories: true)
            do {
                try fm.copyItem(at: root, to: dest)
                count += 1
            } catch {
                continue
            }
        }
        return count
    }

    /// Prefer Manifest `SinfPaths[0]`, else first regular file under `SC_Info/*.sinf`.
    static func findFolderRootSinf(in app: URL) -> URL? {
        let man = app.appendingPathComponent("SC_Info/Manifest.plist")
        // withTimeout wraps T?; plist reads are already T? — flatten like replicateSinfs.
        let plist: [String: Any]? = withTimeout(seconds: 5, work: {
            NSDictionary(contentsOf: man) as? [String: Any]
        }) ?? nil
        if let plist,
           let paths = plist["SinfPaths"] as? [String],
           let first = paths.first, !first.isEmpty {
            let url = app.appendingPathComponent(first)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let sc = app.appendingPathComponent("SC_Info", isDirectory: true)
        if let hit = firstSinf(in: sc) { return hit }
        // Nested frameworks sometimes only keep licenses under Frameworks/*/SC_Info.
        if let enumerator = FileManager.default.enumerator(
            at: app,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "sinf" {
                if url.path.contains("/Watch/") { continue }
                return url
            }
        }
        return nil
    }

    private static func firstSinf(in directory: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return items.first { $0.pathExtension.lowercased() == "sinf" }
    }

    /// buddy3 verify loop: up to 5 rounds, only binaries that still show cryptid ≠ 0.
    private static let verifyRetryBackoffSeconds: [TimeInterval] = [0.10, 0.25, 0.50, 1.0, 2.0]

    private static func verifyWithTargetedRetries(
        sourceApp: URL,
        destApp: URL,
        report: inout FairPlayDecryptReport,
        progress: ((String) -> Void)?
    ) throws {
        let probeRoot = FileManager.default.fileExists(atPath: destApp.path) ? destApp : sourceApp
        var stillEncrypted = stillEncryptedRequired(under: probeRoot, report: report)
        guard !stillEncrypted.isEmpty else {
            // Also clear soft-failed entries that verify says are now clear.
            report.softFailed = report.softFailed.filter { rel in
                let url = probeRoot.appendingPathComponent(rel)
                return url.path.withCString { fp_has_encrypted_slice($0) } == 1
            }
            return
        }

        progress?(
            "\(stillEncrypted.count) binary(ies) still encrypted — targeted retries (up to \(verifyRetryBackoffSeconds.count) rounds)…"
        )

        for (round, delay) in verifyRetryBackoffSeconds.enumerated() {
            guard !stillEncrypted.isEmpty else { break }
            if delay > 0 {
                Thread.sleep(forTimeInterval: delay)
            }
            // Re-stage licenses before each round — IPA trees can lose SC_Info mid-pass.
            if !isLiveAppStoreInstall(sourceApp) {
                let bins = stillEncrypted.map { sourceApp.appendingPathComponent($0) }
                let restaged = stageSinfsForEncryptedBinaries(bins, in: sourceApp)
                if restaged > 0 {
                    progress?("Re-staged \(restaged) SINF(s) before retry \(round + 1)…")
                }
            }
            progress?("Retry \(round + 1)/\(verifyRetryBackoffSeconds.count): \(stillEncrypted.count) file(s)…")

            var recovered: [String] = []
            for (i, rel) in stillEncrypted.enumerated() {
                let file = sourceApp.appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let r = role(of: file, under: sourceApp, app: sourceApp)
                let outcome = decryptOneWithTimeout(
                    file: file, sourceApp: sourceApp, destApp: destApp,
                    index: i, total: stillEncrypted.count, role: r, timeout: 60
                )
                if case .ok(let mini) = outcome {
                    report.decrypted.append(contentsOf: mini.decrypted)
                    report.plain.append(contentsOf: mini.plain)
                    // Drop from failed/softFailed if this pass cleared it.
                    if mini.decrypted.contains(rel) || mini.plain.contains(rel) {
                        recovered.append(rel)
                        report.failed.removeAll { $0 == rel }
                        report.softFailed.removeAll { $0 == rel }
                        progress?("[DECRYPTED] \(rel) (retry \(round + 1))")
                    } else {
                        report.failed.append(contentsOf: mini.failed.filter { !report.failed.contains($0) })
                        report.softFailed.append(contentsOf: mini.softFailed.filter { !report.softFailed.contains($0) })
                    }
                }
            }

            let probe = FileManager.default.fileExists(atPath: destApp.path) ? destApp : sourceApp
            stillEncrypted = stillEncryptedRequired(under: probe, report: report)
            if stillEncrypted.isEmpty {
                progress?("Retry \(round + 1)/\(verifyRetryBackoffSeconds.count) recovered everything.")
                break
            }
            let recoveredCount = recovered.count
            progress?(
                "Retry \(round + 1)/\(verifyRetryBackoffSeconds.count): \(recoveredCount) recovered; \(stillEncrypted.count) remain."
            )
        }

        // Reconcile failed list with final cryptid probe.
        let probe = FileManager.default.fileExists(atPath: destApp.path) ? destApp : sourceApp
        let leftover = stillEncryptedRequired(under: probe, report: report)
        report.failed = Array(Set(report.failed + leftover)).sorted()
        report.softFailed = report.softFailed.filter { !leftover.contains($0) && !report.failed.contains($0) }
    }

    private static func stillEncryptedRequired(
        under app: URL,
        report: FairPlayDecryptReport
    ) -> [String] {
        guard let bins = try? collectMachOs(under: app) else { return [] }
        var out: [String] = []
        for url in bins {
            // Timeout / parse failure must not drop a binary from the retry set.
            let enc = withTimeout(seconds: 3, work: {
                Int(url.path.withCString { fp_has_encrypted_slice($0) })
            })
            let stillHot: Bool
            if let enc {
                stillHot = enc == 1 || enc < 0
            } else {
                stillHot = true
            }
            guard stillHot else { continue }
            let rel = relativePath(url, under: app)
            let r = role(of: url, under: app, app: app)
            if report.isPartial {
                if r == .main { out.append(rel) }
            } else if r.isRequired {
                out.append(rel)
            }
        }
        return out
    }


    /// Report cryptid of every Mach-O under an `.app` (FairPlayed `verify_ipa.sh`).
    /// Cryptid probes are bounded — live App Store installs can hang forever on `fp_*`.
    /// Timeouts and parser failures are counted as **unknown**, never as clear.
    static func verifyApp(at app: URL) throws -> FairPlayVerifyReport {
        if isLiveAppStoreInstall(app) {
            // Never cryptid-probe live containers. Enumerate with timeout-safe collectMachOs
            // and mark entries unknown so callers cannot green-wash skipped probes.
            var report = FairPlayVerifyReport()
            for url in try collectMachOs(under: app) {
                let rel = relativePath(url, under: app)
                report.entries.append(FairPlayCryptidEntry(path: rel, cryptid: -1, detail: "live-install:skipped-cryptid-probe"))
                report.unknown += 1
            }
            return report
        }
        var report = FairPlayVerifyReport()
        for url in try collectMachOs(under: app) {
            let rel = relativePath(url, under: app)
            let probed: (cryptid: Int32, sliceCount: Int32, detail: String) = withTimeout(seconds: 4, work: {
                var detailBuf = [CChar](repeating: 0, count: 256)
                let sliceCount = url.path.withCString { path in
                    detailBuf.withUnsafeMutableBufferPointer { buf in
                        fp_describe_cryptids(path, buf.baseAddress, buf.count)
                    }
                }
                let cryptid = url.path.withCString { fp_max_cryptid($0) }
                return (cryptid, sliceCount, String(cString: detailBuf))
            }) ?? (-1, 0, "cryptid-probe-timed-out")
            let cryptid = Int(probed.cryptid)
            let detail = probed.detail
            let entry = FairPlayCryptidEntry(path: rel, cryptid: cryptid, detail: detail)
            report.entries.append(entry)
            if cryptid > 0 {
                report.encrypted += 1
            } else if cryptid < 0 {
                // fp_max_cryptid / fp_describe parse failure (-1), or probe timeout (-1).
                report.unknown += 1
            } else if probed.sliceCount > 0 && detail.contains("cryptid=0") {
                report.clear += 1
            } else if detail.contains("plain") && !detail.contains("cryptid=") {
                report.plain += 1
            } else {
                // cryptid == 0 with no LC detail — treat as clear only when describe succeeded.
                if probed.sliceCount > 0 {
                    report.clear += 1
                } else {
                    report.unknown += 1
                }
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
    ///
    /// Configuration locked to GitHub references:
    /// - FairPlayed `exportInstalledApp`: `fp_decrypt_file(install/rel, payload/rel)` —
    ///   fairplayd resolves `<dir of binary>/SC_Info/<exe>.sinf` on the **input** path.
    /// - foulplay `main.c`: remaps with the slice’s native `cryptid` (our `FP_MODE_NATIVE` first).
    /// Never feed a Payload/temp copy as `in_path` when a live install path is available.
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
        // Input must stay under the read root (install or IPA app). If somehow swapped,
        // fairplayd would look for SC_Info next to the writable copy and fail.
        // Prefer reconstructing from sourceApp+rel so /var vs /private/var aliases can't
        // accidentally point mremap at the writable Payload copy.
        let inFile = sourceApp.appendingPathComponent(rel)
        var isDir: ObjCBool = false
        let readable = FileManager.default.fileExists(atPath: inFile.path, isDirectory: &isDir) && !isDir.boolValue
        let decryptInput = readable ? inFile : file
        progress?("Decrypting \(rel) (\(index + 1)/\(total))…")

        let outFile = destApp.appendingPathComponent(rel)
        try? fm.createDirectory(at: outFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = outFile.appendingPathExtension("fpdec")
        try? fm.removeItem(at: tmp)

        let logBuf = FairPlayLogBuffer()
        let rc = decryptInput.path.withCString { inPath in
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
                    _ = copyFileChunked(from: decryptInput, to: outFile, timeout: 60)
                }
                if role.isRequired {
                    report.failed.append(rel)
                    if role == .main {
                        throw FairPlayDecryptError.mainExecutableFailed(
                            "Main executable still encrypted after decrypt. \(FairPlayFailureClass.stillEncrypted.userMessage)"
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
                _ = copyFileChunked(from: decryptInput, to: outFile, timeout: 60)
            }
            report.plain.append(rel)
        } else {
            try? fm.removeItem(at: tmp)
            let detail = logBuf.lines.suffix(2).joined(separator: " | ")
            if role.isRequired {
                report.failed.append(rel)
                if role == .main {
                    let klass = FairPlayFailureClass.current(fromLogs: logBuf.lines)
                    if klass == .outOfMemory {
                        throw FairPlayDecryptError.outOfMemory(
                            "Couldn't decrypt the main executable (\(rel)). \(klass.userMessage)"
                        )
                    }
                    throw FairPlayDecryptError.mainExecutableFailed(
                        "Couldn't decrypt the main executable (\(rel)). \(detail.isEmpty ? klass.userMessage : detail)"
                    )
                }
            } else {
                // Keep whatever was copied into dest (may still be encrypted).
                if sourceApp != destApp, !fm.fileExists(atPath: outFile.path) {
                    _ = copyFileChunked(from: decryptInput, to: outFile, timeout: 60)
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

        // Never green-wash failed inspections — unknown ≠ clear.
        if verify.unknown > 0 && !report.isPartial {
            let names = verify.entries.filter(\.isUnknown).prefix(4).map(\.path).joined(separator: ", ")
            throw FairPlayDecryptError.failed(
                "Post-decrypt verify could not inspect \(verify.unknown) Mach-O(s): \(names)\(verify.unknown > 4 ? "…" : ""). Refusing to treat as clear."
            )
        }

        let softSet = Set(report.softFailed)
        let failedSet = Set(report.failed)
        let remaining = try collectMachOs(under: app).filter { url in
            let enc = withTimeout(seconds: 3, work: {
                Int(url.path.withCString { fp_has_encrypted_slice($0) })
            })
            // Timeout / parse error → fail closed (treat as still encrypted).
            let stillHot: Bool
            if let enc {
                stillHot = enc == 1 || enc < 0
            } else {
                stillHot = true
            }
            guard stillHot else { return false }
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
        // Never unbounded-probe live installs — fp_max_cryptid can hang forever.
        if isLiveAppStoreInstall(app) { return }
        // Soft-check: main binary cryptid with timeout. Don't hard-fail — fairplayd may still resolve.
        if let exe = mainExecutableURL(in: app) {
            _ = withTimeout(seconds: 3, work: {
                exe.path.withCString { fp_max_cryptid($0) }
            })
        }
        _ = sc
    }

    // MARK: - Mach-O discovery

    /// Structured Mach-O discovery — matches FairPlayed `machOsUnder` coverage for the
    /// locations that actually carry FairPlay text, without walking every asset
    /// (full-tree `fp_is_macho` hung stock-iOS installs on “Decrypting Mach-Os…”).
    /// Shared by decrypt + companion slim-embed. Internal so packager can reuse the
    /// same Flutter / live-install trust rules (do not reimplement `fp_is_macho` filtering).
    static func collectMachOs(
        under root: URL,
        progress: ((String) -> Void)? = nil
    ) throws -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var seen = Set<String>()
        let liveInstall = isLiveAppStoreInstall(root)

        /// Probe Mach-O magic. On live App Store installs `open()`/`pread` of FairPlay
        /// binaries can hang or fail in-sandbox (Flutter `Runner.app` hit this as
        /// “No Mach-O binaries found”) — treat timeout / open-fail as “assume binary”
        /// for known executable candidates so decrypt can proceed.
        enum MachOProbe { case yes, no, unknown }

        func probeMachO(_ url: URL) -> MachOProbe {
            let box = TimeoutBox<Bool?>()
            let sem = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                let ok = url.path.withCString { fp_is_macho($0) }
                box.value = ok
                sem.signal()
            }
            if sem.wait(timeout: .now() + 4) == .timedOut {
                return .unknown
            }
            switch box.value {
            case true?: return .yes
            case false?: return .no
            default: return .unknown
            }
        }

        func consider(_ url: URL?, trustIfUnreadable: Bool = false) {
            guard let url else { return }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return }
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return }
            // Live App Store installs: `open()` of FairPlay binaries often fails (EPERM) or
            // hangs. `fp_is_macho` returns false on open-fail — same as “not a Mach-O” —
            // which emptied Runner.app for Flutter apps (Cake Wallet). Trusted candidates
            // (CFBundleExecutable, frameworks, Flutter seeds) are included without a magic
            // read so we neither hang per-file nor drop the main binary.
            if trustIfUnreadable && liveInstall {
                seen.insert(path)
                out.append(url)
                return
            }
            switch probeMachO(url) {
            case .yes:
                break
            case .no:
                // On live installs open-fail looks like “not Mach-O”. Keep trusted paths.
                if trustIfUnreadable {
                    progress?("Assuming Mach-O (unreadable for magic check): \(url.lastPathComponent)")
                    break
                }
                return
            case .unknown:
                // Timeout — keep CFBundleExecutable / .dylib / Flutter paths.
                guard trustIfUnreadable || liveInstall else { return }
                progress?("Assuming Mach-O (magic check blocked): \(url.lastPathComponent)")
            }
            seen.insert(path)
            out.append(url)
        }

        /// FairPlayed walks every regular file; we target Frameworks via Info.plist
        /// `CFBundleExecutable` (name can differ from the `.framework` basename) and
        /// recurse nested `Frameworks/` the same way installd stages nested SINFs.
        func collectFrameworks(in container: URL, depth: Int = 0) {
            guard depth < 4 else { return }
            let frameworks = container.appendingPathComponent("Frameworks", isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(
                at: frameworks,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            for item in items {
                let ext = item.pathExtension.lowercased()
                if ext == "framework" {
                    consider(bundleExecutableURL(in: item), trustIfUnreadable: true)
                    // Loose dylibs shipped beside the framework binary.
                    if let nested = try? fm.contentsOfDirectory(
                        at: item,
                        includingPropertiesForKeys: [.isDirectoryKey],
                        options: [.skipsHiddenFiles]
                    ) {
                        for n in nested {
                            let nDir = (try? n.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                            if nDir { continue }
                            if n.pathExtension.lowercased() == "dylib" {
                                consider(n, trustIfUnreadable: true)
                            }
                        }
                    }
                    collectFrameworks(in: item, depth: depth + 1)
                } else if ext == "dylib" {
                    consider(item, trustIfUnreadable: true)
                }
            }
        }

        progress?("Main executable…")
        // Always trust CFBundleExecutable — Flutter uses `Runner`, and live installs
        // often block the magic read that used to drop this candidate.
        consider(bundleExecutableURL(in: root), trustIfUnreadable: true)
        // Explicit Flutter seeds (Cake Wallet / other Runner.app shells).
        for rel in [
            "Runner",
            "Frameworks/App.framework/App",
            "Frameworks/Flutter.framework/Flutter",
        ] {
            consider(root.appendingPathComponent(rel), trustIfUnreadable: true)
        }

        // Loose dylibs / binaries at app root (rare but cheap).
        if let top = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for item in top {
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir { continue }
                let ext = item.pathExtension.lowercased()
                if ext.isEmpty || ext == "dylib" {
                    consider(item, trustIfUnreadable: ext == "dylib" || liveInstall)
                }
            }
        }

        progress?("Frameworks…")
        // Bound Frameworks listing — Flutter apps ship many frameworks; give more budget.
        if withTimeout(seconds: 25, work: { collectFrameworks(in: root); return true }) == nil {
            progress?("Frameworks listing timed out — keeping discovered executables…")
            // Last-chance shallow Frameworks scan (no deep recurse) for Flutter essentials.
            let fw = root.appendingPathComponent("Frameworks", isDirectory: true)
            if let items = try? fm.contentsOfDirectory(at: fw, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                for item in items where item.pathExtension.lowercased() == "framework" {
                    consider(bundleExecutableURL(in: item), trustIfUnreadable: true)
                }
            }
        }

        progress?("PlugIns / Extensions…")
        for folder in ["PlugIns", "Extensions"] {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            let items = withTimeout(seconds: 6, work: {
                try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            }) ?? nil
            guard let items else { continue }
            for item in items where item.pathExtension.lowercased() == "appex" {
                consider(bundleExecutableURL(in: item), trustIfUnreadable: true)
                _ = withTimeout(seconds: 8, work: { collectFrameworks(in: item); return true })
            }
        }

        // FairPlayed `embed_ipa.sh` deletes Watch/ — watchOS Mach-Os are not decryptable
        // with the iPhone's fairplayd, and listing `/Watch` on live App Store installs often
        // hangs forever on stock iOS (UI stuck on “Watch / App Clips…”). Skip Watch always.
        progress?("Skipping Watch (not decryptable on iPhone)…")

        // App Clips are the same hang class: directory listing can return, then nested
        // Frameworks / fp_is_macho on the clip binary blocks forever on stock installs
        // (UI stuck on “App Clips…”). Soft role only — skip like Watch.
        progress?("Skipping App Clips (optional · avoids install-path hang)…")

        if out.isEmpty {
            // Absolute last resort: force-include CFBundleExecutable even if exists-check raced.
            if let main = bundleExecutableURL(in: root) {
                progress?("Force-including main executable \(main.lastPathComponent)…")
                out.append(main)
            }
        }
        if out.isEmpty {
            throw FairPlayDecryptError.failed("No Mach-O binaries found in \(root.lastPathComponent).")
        }
        progress?("Located \(out.count) Mach-O candidate(s)…")
        return out
    }

    private enum DecryptOneOutcome {
        case ok(FairPlayDecryptReport)
        case threw(Error)
        case timedOut
    }

    /// Runs `decryptOne` against an isolated staging `.app` so a timed-out worker cannot
    /// keep writing into `destApp` (or leave a half-moved `.fpdec`) after the caller moves on.
    private static func decryptOneWithTimeout(
        file: URL,
        sourceApp: URL,
        destApp: URL,
        index: Int,
        total: Int,
        role: FairPlayBinaryRole,
        timeout: TimeInterval
    ) -> DecryptOneOutcome {
        final class Job: @unchecked Sendable {
            let lock = NSLock()
            /// Caller gave up — worker must not promote into `destApp`.
            var abandoned = false
            /// Worker finished promote / error publish under the lock.
            var finished = false
            var report = FairPlayDecryptReport()
            var error: Error?
        }
        let job = Job()
        let fm = FileManager.default
        let stagingRoot = fm.temporaryDirectory.appendingPathComponent(
            "fpdec-job-\(UUID().uuidString)", isDirectory: true
        )
        let stagingApp = stagingRoot.appendingPathComponent("Staging.app", isDirectory: true)
        let rel = relativePath(file, under: sourceApp)
        let finalURL = destApp.appendingPathComponent(rel)
        let sem = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                try? fm.removeItem(at: stagingRoot)
                sem.signal()
            }
            do {
                try fm.createDirectory(at: stagingApp, withIntermediateDirectories: true)
                var localReport = FairPlayDecryptReport()
                try decryptOne(
                    file: file, sourceApp: sourceApp, destApp: stagingApp,
                    index: index, total: total, progress: nil,
                    report: &localReport, role: role
                )

                job.lock.lock()
                let abandonedBeforePromote = job.abandoned
                job.lock.unlock()
                if abandonedBeforePromote { return }

                let staged = stagingApp.appendingPathComponent(rel)
                var didPromote = false
                if fm.fileExists(atPath: staged.path) {
                    try fm.createDirectory(
                        at: finalURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try? fm.removeItem(at: finalURL)
                    try fm.moveItem(at: staged, to: finalURL)
                    didPromote = true
                }

                job.lock.lock()
                if job.abandoned {
                    // Timed out during promote — roll back so the caller’s dest stays untouched.
                    if didPromote { try? fm.removeItem(at: finalURL) }
                    job.lock.unlock()
                    return
                }
                job.report = localReport
                job.finished = true
                job.lock.unlock()
            } catch {
                job.lock.lock()
                if !job.abandoned {
                    job.error = error
                    job.finished = true
                }
                job.lock.unlock()
            }
        }

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            job.lock.lock()
            if job.finished {
                let error = job.error
                let report = job.report
                job.lock.unlock()
                if let error { return .threw(error) }
                return .ok(report)
            }
            job.abandoned = true
            job.lock.unlock()
            return .timedOut
        }
        job.lock.lock()
        let error = job.error
        let report = job.report
        job.lock.unlock()
        if let error { return .threw(error) }
        return .ok(report)
    }

    private static func withTimeout<T>(seconds: TimeInterval, work: @escaping () -> T) -> T? {
        let box = TimeoutBox<T>()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value = work()
            sem.signal()
        }
        if sem.wait(timeout: .now() + seconds) == .timedOut {
            return nil
        }
        return box.value
    }

    private final class TimeoutBox<T>: @unchecked Sendable {
        var value: T?
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

    /// True when `app` lives in the system App Store install container (not our temp Payload).
    private static func isLiveAppStoreInstall(_ app: URL) -> Bool {
        let p = app.standardizedFileURL.path
        return p.contains("/Bundle/Application/")
            || p.contains("/Containers/Bundle/")
            || p.contains("/private/var/containers/")
            || p.contains("/var/containers/")
            || p.contains("/AppTranslocation/")
    }

    /// Resolve `CFBundleExecutable` for an `.app` / `.appex` / `.framework` (FairPlayed uses
    /// the same Info.plist field when probing installed apps). Bound on live installs —
    /// plist I/O can stall the same way SC_Info did.
    private static func bundleExecutableURL(in bundle: URL) -> URL? {
        let infoURL = bundle.appendingPathComponent("Info.plist")
        let info: [String: Any]? = withTimeout(seconds: 5) {
            NSDictionary(contentsOf: infoURL) as? [String: Any]
        } ?? nil
        let name = (info?["CFBundleExecutable"] as? String)
            ?? bundle.deletingPathExtension().lastPathComponent
        // Flat iOS layout first; macOS-style Versions/Current as a rare fallback.
        let candidates = [
            bundle.appendingPathComponent(name),
            bundle.appendingPathComponent("Versions/Current/\(name)"),
        ]
        for url in candidates {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                return url
            }
        }
        return nil
    }

    private static func mainExecutableURL(in app: URL) -> URL? {
        bundleExecutableURL(in: app)
    }

    private static func isMainExecutable(_ rel: String, app: URL) -> Bool {
        guard let main = mainExecutableURL(in: app) else { return false }
        return relativePath(main, under: app) == rel || rel == main.lastPathComponent
    }

    private static func relativePath(_ file: URL, under root: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let path = file.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        if path.hasPrefix(rootPath) {
            return String(path.dropFirst(rootPath.count))
        }
        if file.path.hasPrefix(prefix) {
            return String(file.path.dropFirst(prefix.count))
        }
        return file.lastPathComponent
    }

    /// Reject `..`, absolute paths, and escapes outside `root` (SINF / embed staging).
    static func secureChildURL(root: URL, relative: String) -> URL? {
        var rel = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        if rel.isEmpty || rel.hasPrefix("/") || rel.contains("\0") { return nil }
        if rel.contains("..") { return nil }
        let parts = rel.split(separator: "/").map(String.init)
        if parts.contains("..") || parts.contains("") { return nil }
        let url = root.appendingPathComponent(rel).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let child = url.path
        guard child == rootPath || child.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            return nil
        }
        return url
    }

    /// Brief pause when fpcore reports tight memory so Jetsam is less likely mid-decrypt.
    private static func pauseIfMemoryPressure(progress: ((String) -> Void)?) {
        if fp_memory_tight_for(48 * 1024 * 1024) != 0 {
            progress?("Low memory — pausing before next Mach-O…")
            Thread.sleep(forTimeInterval: 0.4)
        }
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
        lines.append(Self.redact(line))
        if lines.count > 64 { lines.removeFirst(lines.count - 64) }
        lock.unlock()
    }

    /// Never surface passwords, PETs, or session tokens if a lower layer echoes them.
    private static func redact(_ line: String) -> String {
        var s = line
        let patterns = [
            #"(?i)(password|passwd|pwd)\s*[:=]\s*\S+"#,
            #"(?i)(passwordToken|petToken|X-Token|myacinfo|Hs01)\s*[:=]\s*\S+"#,
            #"(?i)(Bearer)\s+[A-Za-z0-9\-._~+/]+=*"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p) {
                let range = NSRange(s.startIndex..<s.endIndex, in: s)
                s = re.stringByReplacingMatches(in: s, range: range, withTemplate: "$1=[redacted]")
            }
        }
        return s
    }

    static let trampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { ctx, msg in
        guard let ctx, let msg else { return }
        let box = Unmanaged<FairPlayLogBuffer>.fromOpaque(ctx).takeUnretainedValue()
        box.append(String(cString: msg))
    }
}
