//
// Brand: AppAssassin · https://fastdecrypt.ai
//  DecryptCompanionRuntime.swift
//  When this process is the installed “FastDecryptBot” companion (lean
//  DecryptHelper binary + EmbeddedPayload), run FairPlayed-style export and write the clear IPA
//  into the shared Documents/Decrypted folder for the host app to pick up.
//
//  Helper contract (DECRYPT_HELPER): installed-companion subordinate process (not XPC),
//  stream-only FairPlay + streaming zip, live Store path for keys (never key blobs).
//

import Foundation
import UIKit
import ZIPFoundation
#if !DECRYPT_HELPER
import SwiftUI
#endif

@MainActor
enum DecryptCompanionRuntime {
    /// True when Info.plist says we're the companion role, or EmbeddedPayload exists.
    static var isCompanionProcess: Bool {
        if Bundle.main.object(forInfoDictionaryKey: "TLCompanionRole") as? Bool == true {
            return true
        }
        if Bundle.main.bundleIdentifier?.hasSuffix(".decrypt") == true {
            return true
        }
        let embed = Bundle.main.bundleURL.appendingPathComponent("EmbeddedPayload", isDirectory: true)
        return FileManager.default.fileExists(atPath: embed.path)
    }

    static var embeddedPayloadRoot: URL {
        Bundle.main.bundleURL.appendingPathComponent("EmbeddedPayload", isDirectory: true)
    }

    static func embeddedAppName() -> String? {
        let root = embeddedPayloadRoot
        let man = root.appendingPathComponent("manifest.plist")
        if let plist = NSDictionary(contentsOf: man) as? [String: Any],
           let name = plist["name"] as? String, !name.isEmpty {
            return name
        }
        let kids = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return kids.first(where: {
            ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                && $0.lastPathComponent != "Watch"
        })?.lastPathComponent
    }

    /// Paint the console immediately on launch (name, icon, Starting…) before FairPlay work.
    static func bootstrapCompanionUI() {
        let ctrl = DecryptCompanionController.shared
        let mode = (Bundle.main.object(forInfoDictionaryKey: DecryptCompanionIdentity.helperModeKey) as? String)
            ?? ((Bundle.main.object(forInfoDictionaryKey: "TLDecryptHelper") as? Bool) == true
                ? DecryptCompanionIdentity.helperModeLean
                : DecryptCompanionIdentity.helperModeHostFallback)
        ctrl.appendLog("shell=\(mode) · process=installed-companion (not XPC)")
        guard let name = embeddedAppName() else {
            ctrl.present(name: DecryptCompanionIdentity.companionDisplayName, clearLog: false)
            ctrl.statusTitle = "Starting…"
            ctrl.appendLog("Looking for EmbeddedPayload…")
            return
        }
        let src = embeddedPayloadRoot.appendingPathComponent(name, isDirectory: true)
        let version = embeddedAppVersion(at: src) ?? ""
        let icon = loadTargetIconFromCompanionBundle()
            ?? loadEmbeddedAppIcon(at: src)
        ctrl.present(name: name, version: version, iconImage: icon, clearLog: false)
        ctrl.statusTitle = "Starting…"
        ctrl.appendLog("FastDecryptBot · \(name)\(version.isEmpty ? "" : " · \(version)")")
        ctrl.appendLog("Preparing FairPlay…")
        ctrl.appendLog(FairPlayJetsam.memorySummary(prefix: "boot"))
        let man = NSDictionary(contentsOf: embeddedPayloadRoot.appendingPathComponent("manifest.plist")) as? [String: Any]
        let snap = DecryptCompanionHandoff.readHostSnapshot(fromManifest: man)
        let embedInfo = NSDictionary(
            contentsOf: src.appendingPathComponent("Info.plist")
        ) as? [String: Any]
        let bid = ((embedInfo?["CFBundleIdentifier"] as? String)
            ?? (man?["bundleID"] as? String)
            ?? (snap["bundleID"] as? String)
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let live = ((man?["hostLiveInstallPath"] as? String)
            ?? (snap["hostLiveInstallPath"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        ctrl.setBreadcrumb(
            bid: bid.isEmpty ? nil : bid,
            livePath: live.isEmpty ? nil : live,
            appGroup: DecryptCompanionHandoff.appGroupAvailable,
            exportNote: DecryptCompanionHandoff.appGroupAvailable
                ? "Export · pending (App Group → host)"
                : "Export · pending (Share-only — free cert)",
            logMirror: true
        )
        if live.isEmpty {
            ctrl.appendLog("Preflight live · (not stamped — re-Get after App Store install)")
        }
        if let n = man?["encryptedMachOs"] as? Int ?? (man?["encryptedMachOs"] as? NSNumber)?.intValue {
            ctrl.appendLog("Preflight · \(n) encrypted Mach-O(s)")
        }
        if let crypt = man?["largestCryptsize"] as? Int64
            ?? (man?["largestCryptsize"] as? NSNumber)?.int64Value,
           crypt > 0 {
            ctrl.appendLog(String(format: "Preflight · largest crypt %.1f MB", Double(crypt) / (1024 * 1024)))
        }
    }

    /// Identity pack: `TargetIcon.png` at companion `.app` root.
    static func loadTargetIconFromCompanionBundle() -> UIImage? {
        let url = Bundle.main.bundleURL.appendingPathComponent(DecryptCompanionIdentity.targetIconFileName)
        return UIImage(contentsOfFile: url.path)
    }

    /// Expected encrypted Mach-O count from packager manifest (full IPA audit before slim).
    static func expectedEncryptedCount() -> Int? {
        let man = embeddedPayloadRoot.appendingPathComponent("manifest.plist")
        guard let plist = NSDictionary(contentsOf: man) as? [String: Any] else { return nil }
        if let n = plist["encryptedMachOs"] as? Int { return n }
        if let n = plist["encryptedMachOs"] as? NSNumber { return n.intValue }
        return nil
    }

    /// FairPlayed `embeddedExport` + fail-closed DRM audit of the entire IPA:
    /// pre-scan cryptids → decrypt → verify copied tree → zip → verifyIPA.
    /// When Mac-only routing is on, bounce straight to the host Mac decrypt API.
    static func runEmbeddedDecrypt(progress: ((String) -> Void)? = nil) async throws -> URL {
        let fm = FileManager.default
        let log: (String) -> Void = { line in
            progress?(line)
            DecryptCompanionController.shared.appendLog(line)
        }

        if DecryptMacRouting.macOnly {
            log("Server-only decrypt — skipping on-device companion FairPlay, opening Decrypt site URL…")
            DecryptCompanionController.shared.statusTitle = "Decrypting on server…"
            DecryptCompanionHandoff.requestServerFallback(reason: "mac-only")
            throw DecryptError("Finishing decrypt on Decrypt site URL (Linux VPS / server).")
        }

        guard let name = embeddedAppName() else {
            throw DecryptError("No EmbeddedPayload in FastDecryptBot — reinstall the companion from TetherLess.")
        }
        // Path traversal guard — only allow a single path component under EmbeddedPayload.
        guard !name.contains("/") && !name.contains("..") && !name.hasPrefix(".") else {
            throw DecryptError("Invalid EmbeddedPayload name.")
        }
        // Apple first-party titles (TestFlight, …) are not valid FairPlay targets and often ENOMEM.
        let embedInfo = NSDictionary(
            contentsOf: embeddedPayloadRoot
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent("Info.plist")
        ) as? [String: Any]
        let embedBid = embedInfo?["CFBundleIdentifier"] as? String
        if AppleSystemAppGate.isBlocked(bundleID: embedBid, storeURL: nil)
            || name.localizedCaseInsensitiveContains("TestFlight") {
            throw DecryptError(AppleSystemAppGate.userMessage)
        }
        let src = embeddedPayloadRoot.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        let embedRoot = embeddedPayloadRoot.standardizedFileURL
        guard src.path.hasPrefix(embedRoot.path + "/") || src.path == embedRoot.path else {
            throw DecryptError("EmbeddedPayload path escaped bundle — refusing decrypt.")
        }
        guard fm.fileExists(atPath: src.path) else {
            throw DecryptError("EmbeddedPayload/\(name) missing.")
        }

        let version = Self.embeddedAppVersion(at: src) ?? ""
        let icon = Self.loadEmbeddedAppIcon(at: src)
            ?? TetherlessBrand.appIconImage()
        // Refresh identity without wiping bootstrap logs (clearLog: false).
        DecryptCompanionController.shared.present(
            name: name,
            version: version,
            iconImage: icon,
            clearLog: false
        )
        DecryptCompanionController.shared.statusTitle = "Decrypting…"
        log("Found embedded app: \(name)")
        let man = NSDictionary(contentsOf: embeddedPayloadRoot.appendingPathComponent("manifest.plist")) as? [String: Any]
        let snap = DecryptCompanionHandoff.readHostSnapshot(fromManifest: man)
        if let hint = snap["hostEmailHint"] as? String, !hint.isEmpty {
            log("Host session \(hint)")
        }
        if let email = (snap["hostEmail"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            log("FairPlay Apple ID · \(email)")
        }

        // FairPlayed (iOS 27 + Developer Mode): mremap from EmbeddedPayload inside THIS
        // companion bundle — fairplayd reads SC_Info next to those binaries. Live Store
        // Mach-Os often open(2) EPERM from a sideloaded helper; tmp EncryptedSource unpacks
        // sit in data containers fairplayd cannot read. Never use those as FairPlay in_path.
        // Tetherless-style companion policy: serial, PARTIAL OK. Lean helper never auto-bounces
        // mid-decrypt (UIKit / fat shell offer backup server after ENOMEM instead).
        // Streaming page capture is forced in fpcore (FP_FORCE_LEAN) on device.
        var fpOpts = FairPlayAdvancedOptions.Resolved.from(snapshot: snap)
        // Honor Advanced “live install” only when explicitly selected; default = embed.
        if fpOpts.sourceMode != .liveInstall {
            fpOpts.sourceMode = .embeddedPayload
        }
        fpOpts.forceSerialDecrypt = true
        fpOpts.preferPartialOnLowRAM = true
        fpOpts.requireAllFrameworks = false
#if DECRYPT_HELPER
        fpOpts.bounceLargeCryptToServer = false
        // Helper contract: stream-only, no key blobs, subordinate installed process.
        log("policy=serial+partialOK+stream · FairPlay=EmbeddedPayload (FairPlayed / cryptid=2)")
#else
        // Fat host-shell companion may honor Advanced “bounce large crypt to server”.
        log("policy=serial+partialOK · bounceLargeCrypt=\(fpOpts.bounceLargeCryptToServer)")
#endif
        log(FairPlayJetsam.memorySummary(prefix: "preflight"))
        let snapBid = (snap["bundleID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expectedBid = (embedBid
            ?? (man?["bundleID"] as? String)
            ?? (snapBid.isEmpty ? nil : snapBid)
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !expectedBid.isEmpty {
            log("Target bid · \(expectedBid)")
            DecryptCompanionController.shared.setBreadcrumb(bid: expectedBid)
        } else {
            log("Target bid · (missing from EmbeddedPayload / manifest)")
        }
        // Live path is diagnostic / ownership hint only — not the FairPlay read root.
        var liveURL = DecryptCompanionHandoff.resolveLiveInstallURL(
            manifest: man,
            expectedBundleID: expectedBid
        )
        if let liveURL {
            log("Stamped live install path (hint): \(liveURL.path)")
            DecryptCompanionController.shared.setBreadcrumb(livePath: liveURL.path)
        } else {
            log("Stamped live install path: (none — OK; FairPlay reads EmbeddedPayload)")
        }
        if liveURL == nil, !expectedBid.isEmpty {
            let known = ((man?["hostLiveInstallPath"] as? String)
                ?? (snap["hostLiveInstallPath"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let known, !known.isEmpty {
                let knownURL = URL(fileURLWithPath: known)
                if let accepted = Self.acceptRediscoveredLiveURL(knownURL, expectedBid: expectedBid) {
                    liveURL = accepted
                    log("Host-stamped live path (hint): \(accepted.path)")
                    DecryptCompanionController.shared.setBreadcrumb(livePath: accepted.path)
                }
            }
            if liveURL == nil,
               let found = FairPlayDecrypt.installedAppURL(
                bundleID: expectedBid,
                knownPath: (known?.isEmpty == false) ? known : nil
               ),
               let accepted = Self.acceptRediscoveredLiveURL(found, expectedBid: expectedBid) {
                liveURL = accepted
                log("Rediscovered live App Store install (hint): \(accepted.path)")
                DecryptCompanionHandoff.publishLiveInstallPath(accepted.path, bundleID: expectedBid)
                DecryptCompanionController.shared.setBreadcrumb(livePath: accepted.path)
            }
        }

        let preferLive = fpOpts.sourceMode == .liveInstall
        let readRoot: URL
        if preferLive, let liveURL {
            readRoot = liveURL
            log("Advanced FairPlay · source=Live install (experimental) · retries=\(fpOpts.retryRounds)")
            log("FairPlay read root · live install: \(liveURL.path)")
        } else {
            if preferLive {
                log("Advanced live-install selected but no live path — falling back to EmbeddedPayload.")
            }
            readRoot = src
            log("Advanced FairPlay · source=EmbeddedPayload (FairPlayed) · retries=\(fpOpts.retryRounds)")
            log("FairPlay read root · EmbeddedPayload: \(src.path)")
        }
        DecryptCompanionController.shared.setBreadcrumb(
            bid: expectedBid.isEmpty ? nil : expectedBid,
            livePath: liveURL?.path,
            appGroup: DecryptCompanionHandoff.appGroupAvailable,
            logMirror: true
        )

        // FairPlayed: fairplayd opens <dir>/SC_Info/<exe>.sinf next to the remmap input.
        // Missing licenses here surface as mremap EPERM and used to look like “keys”.
        let sinfN = Self.countEmbeddedSinfs(under: src)
        log("EmbeddedPayload SC_Info · \(sinfN) .sinf")
        if sinfN == 0, readRoot == src {
            throw DecryptError(
                "EmbeddedPayload has no SC_Info/.sinf for \(name). Delete FastDecryptBot, re-run Get from a Store IPA download so licenses are packaged beside the Mach-Os, then open the companion again."
            )
        }

        var before = try FairPlayDecrypt.verifyApp(at: readRoot)
        if before.entries.isEmpty, readRoot != src {
            let embedAudit = try FairPlayDecrypt.verifyApp(at: src)
            if !embedAudit.entries.isEmpty {
                before = embedAudit
                log("Live path cryptid probe empty — using EmbeddedPayload counts (\(before.encrypted) encrypted).")
            }
        }
        if before.entries.isEmpty {
            throw DecryptError(
                "No Mach-Os found under EmbeddedPayload for \(name). Delete FastDecryptBot, re-run Get so Mach-Os + SC_Info are embedded, then open FastDecryptBot again (Developer Mode on)."
            )
        }
        let work = fm.temporaryDirectory.appendingPathComponent("tl-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        let destApp = payload.appendingPathComponent("\(name).app", isDirectory: true)
        try fm.createDirectory(at: destApp, withIntermediateDirectories: true)

        log("Copying app bundle…")
        // Seed export resources from EmbeddedPayload; FairPlay overwrites clear Mach-Os into dest.
        try copyTree(from: src, to: destApp)

        let verbose = fpOpts.verboseConsole
        let progressBridge: @Sendable (String) -> Void = { msg in
            // Lean console by default; verbose advanced mode surfaces retries / SINF / paths.
            let keep = verbose
                || msg.hasPrefix("[DECRYPTED]")
                || msg.hasPrefix("[plain]")
                || msg.hasPrefix("[FAILED]")
                || (msg.hasPrefix("Decrypting ") && msg.contains("Mach-O file"))
                || msg.localizedCaseInsensitiveContains("retry")
                || msg.localizedCaseInsensitiveContains("staged")
                || msg.localizedCaseInsensitiveContains("jetsam")
                || msg.localizedCaseInsensitiveContains("low memory")
                || msg.localizedCaseInsensitiveContains("cryptsize")
                || msg.localizedCaseInsensitiveContains("serial")
                || msg.localizedCaseInsensitiveContains("partial")
                || msg.localizedCaseInsensitiveContains("bounce")
                || msg.localizedCaseInsensitiveContains("stream")
                || msg.localizedCaseInsensitiveContains("lean")
                || msg.localizedCaseInsensitiveContains("enomem")
                || msg.localizedCaseInsensitiveContains("soft-fail")
                || msg.localizedCaseInsensitiveContains("partial")
                || msg.localizedCaseInsensitiveContains("rss")
                || msg.localizedCaseInsensitiveContains("freed")
                || msg.localizedCaseInsensitiveContains("embeddedpayload")
                || msg.localizedCaseInsensitiveContains("fairplay read root")
            if keep {
                progress?(msg)
                Task { @MainActor in DecryptCompanionController.shared.appendLog(msg) }
            }
        }
        func runDecrypt(from root: URL) throws -> FairPlayDecryptReport {
            FairPlayJetsam.purgeTransientMemory()
            log(FairPlayJetsam.memorySummary(prefix: "pre-mremap"))
            log("Streaming FairPlay page capture from \(root == src ? "EmbeddedPayload" : "live install")…")
            return try FairPlayDecrypt.decryptMachOs(
                readingFrom: root,
                writingTo: destApp,
                quietConsole: !verbose,
                options: fpOpts,
                progress: progressBridge
            )
        }

        func isLicenseEPERM(_ error: Error) -> Bool {
            FairPlayFailureClass.current(fromLogs: [error.localizedDescription]) == .licenseOrKeys
        }
        func isSandboxOpen(_ error: Error) -> Bool {
            FairPlayFailureClass.current(fromLogs: [error.localizedDescription]) == .sandboxOpen
        }

        let licenseHint =
            "FairPlay remmap EPERM for \(name) (license / SC_Info / keys). Confirm Store login + Media & Purchases for the owning Apple ID, enable Developer Mode, delete FastDecryptBot, re-run Get from a Store IPA (so SC_Info is embedded), then open it again. \(AppStoreDecryptGuide.failureHint)"
        let sandboxHint =
            "FairPlay could not open the Mach-O (sandbox). FastDecryptBot must remmap from its own EmbeddedPayload — delete it, re-run Get so Mach-Os + SC_Info are embedded, enable Developer Mode, then open the companion again."

        var report: FairPlayDecryptReport
        do {
            report = try runDecrypt(from: readRoot)
        } catch let fp as FairPlayDecryptError {
            switch fp {
            case .bounceToServer(let reason):
                log(reason)
                throw FairPlayDecryptError.outOfMemory(reason)
            case .outOfMemory(let reason):
                log(reason)
                throw fp
            case .missingLicense:
                throw fp
            case .mainExecutableFailed(let detail):
                let klass = FairPlayFailureClass.current(fromLogs: [detail])
                log(detail)
                if klass == .sandboxOpen {
                    // Live-path open EPERM → retry once from EmbeddedPayload.
                    if readRoot != src {
                        log("Live install open EPERM — retrying FairPlay from EmbeddedPayload…")
                        report = try runDecrypt(from: src)
                    } else {
                        throw FairPlayDecryptError.failed(sandboxHint)
                    }
                } else if klass == .licenseOrKeys {
                    throw FairPlayDecryptError.missingLicense(licenseHint)
                } else {
                    throw fp
                }
            default:
                throw fp
            }
        } catch {
            if isSandboxOpen(error), readRoot != src {
                log("Live install open EPERM — retrying FairPlay from EmbeddedPayload…")
                report = try runDecrypt(from: src)
            } else if isLicenseEPERM(error) {
                throw FairPlayDecryptError.missingLicense(licenseHint)
            } else if isSandboxOpen(error) {
                throw FairPlayDecryptError.failed(sandboxHint)
            } else {
                throw error
            }
        }
        let decN = report.decrypted.count
        let plainN = report.plain.count
        log("Done: \(decN) decrypted, \(plainN) already plain.")

        if !report.failed.isEmpty, !report.isPartial {
            let names = report.failed.prefix(6).joined(separator: ", ")
            throw FairPlayDecryptError.stillEncrypted(
                "Companion DRM check failed — \(report.failed.count) required binary(ies) still encrypted: \(names)\(report.failed.count > 6 ? "…" : ""). \(AppStoreDecryptGuide.failureHint)"
            )
        }
        // Opt-in fail-closed only when Require all frameworks is on.
        if report.fullIPACoverage, !report.softFailed.isEmpty {
            let names = report.softFailed.prefix(6).joined(separator: ", ")
            throw FairPlayDecryptError.stillEncrypted(
                "Full IPA decrypt left \(report.softFailed.count) Mach-O(s) uncleared: \(names)\(report.softFailed.count > 6 ? "…" : ""). \(AppStoreDecryptGuide.failureHint)"
            )
        }
        // Live cryptid probes are often -1 (before.encrypted == 0) — also use stamped
        // EmbeddedPayload counts and soft/hard fail lists so we don't ship an empty "success".
        let stampedEncrypted = (man?["encryptedMachOs"] as? Int)
            ?? (man?["encryptedMachOs"] as? NSNumber)?.intValue
            ?? 0
        if (before.encrypted > 0 || stampedEncrypted > 0) && decN == 0 {
            throw FairPlayDecryptError.stillEncrypted(
                "DRM was present (\(max(before.encrypted, stampedEncrypted)) encrypted) but nothing was decrypted. \(AppStoreDecryptGuide.failureHint)"
            )
        }
        if decN == 0, report.plain.isEmpty, (!report.softFailed.isEmpty || !report.failed.isEmpty) {
            throw FairPlayDecryptError.stillEncrypted(
                "FairPlay produced no clear Mach-Os (\(report.softFailed.count) soft-fail, \(report.failed.count) failed). \(AppStoreDecryptGuide.failureHint)"
            )
        }
        if report.isPartial {
            log("PARTIAL OK — main clear, \(report.softFailed.count) soft-fail / \(report.failed.count) leftover (Tetherless-style).")
        }

        DecryptCompanionController.shared.statusTitle = "Done — saving automatically…"
        let afterCopy = try FairPlayDecrypt.verifyApp(at: destApp)
        try assertDecryptAcceptable(afterCopy, stage: "copied Payload", partial: report.isPartial, app: destApp)

        let tag = report.isPartial ? "-PARTIAL" : "-decrypted"
        log("Packaging \(name)\(tag).ipa…")
        try stripLicenseArtifacts(in: destApp)

        // Brand decrypted app icons with the Mach-O cord (lower-left watermark).
        let branded = AppIconCordBranding.brandAppBundle(at: destApp)
        if branded > 0 {
            log("Branded app icon with Mach-O cord (\(branded) file(s)).")
            // Refresh console tile so the finished state shows the stamped icon.
            if let stamped = UIImage(contentsOfFile: destApp.appendingPathComponent("AppIcon60x60@3x.png").path)
                ?? UIImage(contentsOfFile: destApp.appendingPathComponent("AppIcon.png").path) {
                DecryptCompanionController.shared.iconImage = stamped
            }
        }

        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let outDir = docs.appendingPathComponent("Decrypted", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let safeName = name.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "..", with: "_")
        let outIPA = outDir.appendingPathComponent("\(safeName)\(tag).ipa")
        try? fm.removeItem(at: outIPA)

        let tmpZip = outIPA.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmpZip)
        log(FairPlayJetsam.memorySummary(prefix: "pre-zip"))
        try zipClearIPA(payload: payload, to: tmpZip, progress: log)
        try fm.moveItem(at: tmpZip, to: outIPA)
        log(FairPlayJetsam.memorySummary(prefix: "post-zip"))

        let ipaVerify = try FairPlayDecrypt.verifyIPA(at: outIPA)
        try assertDecryptAcceptable(ipaVerify, stage: "packaged IPA", partial: report.isPartial, app: destApp)

        DecryptCompanionController.shared.verifySummary = ipaVerify.summary
        DecryptCompanionController.shared.markFinished(url: outIPA, name: name)
        DecryptCompanionController.shared.statusTitle = report.isPartial ? "Done (PARTIAL)" : "Done"
        log("Wrote \(safeName)\(tag).ipa.")

        let info = NSDictionary(contentsOf: src.appendingPathComponent("Info.plist")) as? [String: Any]
        let bundleID = (info?["CFBundleIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let published = DecryptCompanionHandoff.publishClearIPAExport(
            ipa: outIPA,
            displayName: name,
            bundleID: bundleID,
            version: version,
            verifySummary: ipaVerify.summary
        )
        DecryptCompanionController.shared.exportSentToHost = published
        if published {
            log("Export · App Group → host (appassassin://decrypt-export)")
            DecryptCompanionController.shared.setBreadcrumb(
                appGroup: true,
                exportNote: "Export · App Group → host ✓",
                logMirror: true
            )
            DecryptCompanionHandoff.openHostForClearIPAImport()
        } else {
            log("Export · App Group unavailable — use Share sheet (Open in AppAssassin)")
            DecryptCompanionController.shared.setBreadcrumb(
                appGroup: false,
                exportNote: "Export · Share-only (App Group unavailable)",
                logMirror: true
            )
        }
        // Advanced: optionally drop the durable encrypted IPA after a clear export.
        if !fpOpts.keepEncryptedIPA {
            DecryptCompanionHandoff.purgeRetainedEncryptedIPA()
            log("Dropped stamped encrypted IPA (Keep encrypted IPA is off).")
        }
        return outIPA
    }

    // MARK: - Live path rediscovery

    /// Accept a rediscovered/stamped path only when it looks like a Store `.app` and
    /// does not contradict `expectedBid` (stamp Info.plist when readable).
    private static func acceptRediscoveredLiveURL(_ url: URL, expectedBid: String) -> URL? {
        let want = expectedBid.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = url.resolvingSymlinksInPath().standardizedFileURL
        guard FairPlayDecrypt.isLiveAppStoreInstall(candidate) else { return nil }
        // Prefer a real *.app — bare UUID containers are not FairPlay roots.
        if candidate.pathExtension != "app" {
            var walk = candidate
            var found: URL?
            while walk.path != "/" {
                if walk.pathExtension == "app" { found = walk; break }
                walk = walk.deletingLastPathComponent()
            }
            if found == nil,
               let kids = try? FileManager.default.contentsOfDirectory(
                at: candidate, includingPropertiesForKeys: nil
               ) {
                found = kids.first(where: { $0.pathExtension == "app" })
            }
            guard let app = found else { return nil }
            candidate = app
        }
        if !want.isEmpty,
           let info = NSDictionary(contentsOf: candidate.appendingPathComponent("Info.plist")) as? [String: Any],
           let liveBid = (info["CFBundleIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !liveBid.isEmpty,
           !DecryptCompanionHandoff.bundleIDsMatch(liveBid, want) {
            return nil
        }
        return candidate
    }

    // MARK: - Embedded metadata

    private static func embeddedAppVersion(at app: URL) -> String? {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        if let short, !short.isEmpty { return short }
        if let build, !build.isEmpty { return build }
        return nil
    }

    /// Count `.sinf` files under EmbeddedPayload (FairPlayed license material).
    private static func countEmbeddedSinfs(under root: URL) -> Int {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var n = 0
        for case let url as URL in en where url.pathExtension.lowercased() == "sinf" {
            if url.path.contains("/Watch/") { continue }
            n += 1
        }
        return n
    }

    /// Best-effort icon from EmbeddedPayload (PNGs copied at package time).
    private static func loadEmbeddedAppIcon(at app: URL) -> UIImage? {
        if let stamped = loadTargetIconFromCompanionBundle() { return stamped }
        let fm = FileManager.default
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))
        var bases: [String] = []
        if let icons = info?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            bases.append(contentsOf: files.reversed())
        }
        bases.append(contentsOf: [
            "AppIcon60x60@3x", "AppIcon60x60@2x", "Icon-60@3x", "Icon-60@2x",
            "iTunesArtwork@2x", "iTunesArtwork", "Icon@2x", "Icon"
        ])
        let pngs = (try? fm.contentsOfDirectory(at: app, includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension.lowercased() == "png" } ?? []
        for base in bases {
            if let hit = pngs.first(where: {
                $0.deletingPathExtension().lastPathComponent.hasPrefix(base)
                    || $0.lastPathComponent.hasPrefix(base)
            }), let img = UIImage(contentsOfFile: hit.path) {
                return img
            }
        }
        let iconish = pngs.filter {
            $0.lastPathComponent.localizedCaseInsensitiveContains("AppIcon")
                || $0.lastPathComponent.localizedCaseInsensitiveContains("Icon")
        }
        let pool = iconish.isEmpty ? pngs : iconish
        let largest = pool.max {
            ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return largest.flatMap { UIImage(contentsOfFile: $0.path) }
    }

    /// Stream clear IPA into a zip (file-by-file). Helper prefers this over `zipItem` buffering.
    private static func zipClearIPA(
        payload: URL,
        to dest: URL,
        progress: (String) -> Void
    ) throws {
        let fm = FileManager.default
#if DECRYPT_HELPER
        progress("Streaming clear IPA zip (entry-by-entry)…")
        guard let archive = Archive(url: dest, accessMode: .create) else {
            throw DecryptError("Couldn't create clear IPA archive.")
        }
        let parent = payload.deletingLastPathComponent()
        // Payload/ directory itself as zip root (matches `zipItem(shouldKeepParent: true)`).
        try archive.addEntry(
            with: payload.lastPathComponent + "/",
            type: .directory,
            uncompressedSize: Int64(0)
        ) { _, _ in Data() }
        guard let en = fm.enumerator(
            at: payload,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw DecryptError("Couldn't enumerate Payload for packaging.")
        }
        var files = 0
        for case let file as URL in en {
            let full = file.resolvingSymlinksInPath().standardizedFileURL.path
            let root = parent.resolvingSymlinksInPath().standardizedFileURL.path
            let prefix = root.hasSuffix("/") ? root : root + "/"
            guard full.hasPrefix(prefix) else { continue }
            var rel = String(full.dropFirst(prefix.count))
            var isDir: ObjCBool = false
            fm.fileExists(atPath: file.path, isDirectory: &isDir)
            if isDir.boolValue {
                if !rel.hasSuffix("/") { rel += "/" }
                try archive.addEntry(
                    with: rel,
                    type: .directory,
                    uncompressedSize: Int64(0)
                ) { _, _ in Data() }
                continue
            }
            // Mach-Os / assets are often already compressed — store to cut CPU/RSS.
            let method: CompressionMethod = file.pathExtension.lowercased() == "ipa" ? .deflate : .none
            try archive.addEntry(with: rel, relativeTo: parent, compressionMethod: method)
            files += 1
            if files % 40 == 0 {
                progress(FairPlayJetsam.memorySummary(prefix: "zip \(files)"))
                FairPlayJetsam.purgeTransientMemory()
            }
        }
        progress("Streamed \(files) file(s) into clear IPA")
#else
        try fm.zipItem(at: payload, to: dest, shouldKeepParent: true, compressionMethod: .deflate)
#endif
    }

    // MARK: - Audit helpers

    private static func assertFullyClear(_ report: FairPlayVerifyReport, stage: String) throws {
        try assertDecryptAcceptable(report, stage: stage, partial: false, app: nil)
    }

    /// Full clear normally; PARTIAL only requires the main executable cryptid=0.
    private static func assertDecryptAcceptable(
        _ report: FairPlayVerifyReport,
        stage: String,
        partial: Bool,
        app: URL?
    ) throws {
        guard !report.entries.isEmpty else {
            throw DecryptError("DRM verify found no Mach-Os in \(stage).")
        }
        // Sparse EmbeddedPayload + sandbox-hidden live main must not ship as success.
        if let app {
            let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any]
            let exeName = (info?["CFBundleExecutable"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !exeName.isEmpty {
                let mainURL = app.appendingPathComponent(exeName)
                var isDir: ObjCBool = false
                if !FileManager.default.fileExists(atPath: mainURL.path, isDirectory: &isDir) || isDir.boolValue {
                    throw DecryptError(
                        "Decrypt export missing main executable \(exeName) in \(stage). Live FairPlay likely skipped the main binary — re-run Get with the app installed from the App Store."
                    )
                }
            }
        }
        if partial {
            let mainNames: Set<String> = {
                guard let app,
                      let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist")) as? [String: Any],
                      let exe = info["CFBundleExecutable"] as? String else {
                    return []
                }
                return [exe, "\(exe).dylib"]
            }()
            let mainEncrypted = report.entries.filter { entry in
                guard entry.isEncrypted else { return false }
                let base = URL(fileURLWithPath: entry.path).lastPathComponent
                if !mainNames.isEmpty { return mainNames.contains(base) }
                // Fallback: shallowest path that isn't inside Frameworks/PlugIns.
                return !entry.path.contains(".framework/")
                    && !entry.path.contains(".appex/")
                    && !entry.path.hasPrefix("Watch/")
            }
            if !mainEncrypted.isEmpty {
                let names = mainEncrypted.prefix(4).map(\.path).joined(separator: ", ")
                throw FairPlayDecryptError.stillEncrypted(
                    "PARTIAL verify failed on \(stage): main still encrypted (\(names)). \(AppStoreDecryptGuide.failureHint)"
                )
            }
            return
        }
        guard report.isFullyClear else {
            if report.encrypted > 0 {
                let names = report.entries.filter(\.isEncrypted).prefix(6).map(\.path).joined(separator: ", ")
                throw FairPlayDecryptError.stillEncrypted(
                    "DRM verify failed on \(stage): \(report.encrypted) Mach-O(s) still encrypted (\(names)\(report.encrypted > 6 ? "…" : "")). \(AppStoreDecryptGuide.failureHint)"
                )
            }
            let names = report.entries.filter(\.isUnknown).prefix(6).map(\.path).joined(separator: ", ")
            throw DecryptError(
                "DRM verify failed on \(stage): \(report.unknown) Mach-O(s) could not be inspected (\(names)\(report.unknown > 6 ? "…" : "")). Refusing to treat as clear."
            )
        }
    }

    private static func copyTree(from src: URL, to destApp: URL) throws {
        let fm = FileManager.default
        var failures: [String] = []
        var copied = 0
        guard let en = fm.enumerator(
            at: src,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw DecryptError("Could not enumerate EmbeddedPayload for packaging copy.")
        }
        for case let item as URL in en {
            let vals = try? item.resourceValues(forKeys: [.isDirectoryKey])
            let prefix = src.path.hasSuffix("/") ? src.path : src.path + "/"
            let rel = item.path.hasPrefix(prefix) ? String(item.path.dropFirst(prefix.count)) : item.lastPathComponent
            let out = destApp.appendingPathComponent(rel)
            if vals?.isDirectory == true {
                do {
                    try fm.createDirectory(at: out, withIntermediateDirectories: true)
                } catch {
                    failures.append(rel)
                }
            } else {
                do {
                    try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: out)
                    try fm.copyItem(at: item, to: out)
                    copied += 1
                } catch {
                    failures.append(rel)
                }
            }
        }
        if copied == 0 {
            throw DecryptError("Companion copy produced no files from EmbeddedPayload.")
        }
        if !failures.isEmpty {
            let sample = failures.prefix(6).joined(separator: ", ")
            throw DecryptError(
                "Companion copy failed for \(failures.count) path(s): \(sample)\(failures.count > 6 ? "…" : ""). Refusing to package an incomplete app."
            )
        }
    }

    private static func stripLicenseArtifacts(in app: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: app.appendingPathComponent("SC_Info"))
        if let en = fm.enumerator(at: app, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let item as URL in en where item.lastPathComponent == "SC_Info" {
                try? fm.removeItem(at: item)
            }
        }
    }
}

#if !DECRYPT_HELPER
/// Root scene when the fat host-clone companion is running (SwiftUI).
/// DecryptHelper uses `DecryptCompanionConsoleViewController` instead.
struct DecryptCompanionRoot: View {
    @ObservedObject private var companion = DecryptCompanionController.shared
    @State private var errorText: String?
    @State private var shareURL: URL?
    @State private var didBootstrapUI = false

    var body: some View {
        DecryptCompanionConsole(showsDismiss: false, shareURL: $shareURL)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.05, green: 0.07, blue: 0.12).ignoresSafeArea())
            .onAppear {
                // Paint name / icon / “Starting…” before any FairPlay work — no empty Ready freeze.
                guard !didBootstrapUI else { return }
                didBootstrapUI = true
                DecryptCompanionRuntime.bootstrapCompanionUI()
            }
            .task {
                do {
                    let url = try await DecryptCompanionRuntime.runEmbeddedDecrypt()
                    // Auto-share only when App Group handoff failed (host can't import alone).
                    if !companion.exportSentToHost {
                        shareURL = url
                    }
                } catch {
                    let text = error.localizedDescription
                    errorText = text
                    companion.markFailed(text)
                    if Self.shouldBounceToServer(text) {
                        companion.appendLog("On-device FairPlay failed — opening TetherLess to finish on backup server…")
                        DecryptCompanionHandoff.requestServerFallback(reason: text)
                    }
                }
            }
            .sheet(item: Binding(
                get: { shareURL.map { ShareItem(url: $0) } },
                set: { shareURL = $0?.url }
            )) { item in
                ShareSheet(items: [item.url])
            }
            .alert("Decrypt failed", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                if Self.isLicenseOrKeysFailure(errorText) {
                    Button("Open App Store") {
                        AppStoreDecryptGuide.openAppStore()
                    }
                    Button("Open Settings") {
                        AppStoreDecryptGuide.openSystemSettings()
                    }
                }
                if Self.shouldBounceToServer(errorText) {
                    Button("Use backup server") {
                        DecryptCompanionHandoff.requestServerFallback(reason: errorText ?? "ENOMEM")
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(Self.userFacingError(errorText))
            }
    }

    private static func isLicenseOrKeysFailure(_ text: String?) -> Bool {
        let t = (text ?? "").lowercased()
        return t.contains("media & purchases")
            || t.contains("decryption keys")
            || t.contains("fairplay needs")
            || t.contains("license")
            || t.contains("eperm")
            || t.contains("live path")
            || t.contains("confirm keys")
    }

    /// Memory / remap failures can't finish on-device — bounce to Decrypt site URL host.
    private static func shouldBounceToServer(_ text: String?) -> Bool {
        let t = (text ?? "").lowercased()
        return t.contains("enomem")
            || t.contains("not enough memory")
            || t.contains("mremap")
            || t.contains("out of memory")
            || t.contains("jetsam")
            || t.contains("phone worker")
            || t.contains("unfairplay")
            || t.contains("bounce to")
    }

    private static func userFacingError(_ text: String?) -> String {
        let raw = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "Decrypt failed." }
        if shouldBounceToServer(raw) {
            return raw
                + "\n\nTip: charge the device, free RAM, keep this app foregrounded, and retry a smaller third-party app (not TestFlight). Backup server needs a Linux VPS Phone Worker on a device that still has free memory — or an unfairplay model."
        }
        return raw
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}
#endif
