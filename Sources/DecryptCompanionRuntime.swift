//
// Brand: Tetherless · https://tetherless.dev
//  DecryptCompanionRuntime.swift
//  When this process is the installed “Tetherless Decrypt” companion (cloned
//  binary + EmbeddedPayload), run FairPlayed-style export and write the clear IPA
//  into the shared Documents/Decrypted folder for the host app to pick up.
//

import Foundation
import SwiftUI
import UIKit
import ZIPFoundation

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
            throw DecryptError("No EmbeddedPayload in Tetherless Decrypt — reinstall the companion from TetherLess.")
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
        DecryptCompanionController.shared.present(
            name: name,
            version: version,
            iconImage: icon,
            clearLog: true
        )
        DecryptCompanionController.shared.statusTitle = "Decrypting…"
        log("Found embedded app: \(name)")
        let man = NSDictionary(contentsOf: embeddedPayloadRoot.appendingPathComponent("manifest.plist")) as? [String: Any]
        let snap = DecryptCompanionHandoff.readHostSnapshot(fromManifest: man)
        if let hint = snap["hostEmailHint"] as? String, !hint.isEmpty {
            log("Host session \(hint)")
        }

        // FairPlayed / foulplay: fairplayd resolves SC_Info on the *input* path.
        // Advanced source mode (host-stamped) can force live / stamped IPA / embed.
        let fpOpts = FairPlayAdvancedOptions.Resolved.from(snapshot: snap)
        let liveURL = DecryptCompanionHandoff.resolveLiveInstallURL(manifest: man)
        let stampedIPAURL = DecryptCompanionHandoff.resolveEncryptedIPAURL(manifest: man)
        var ipaUnpackRoot: URL?
        defer {
            if let ipaUnpackRoot {
                try? fm.removeItem(at: ipaUnpackRoot)
            }
        }

        func unpackStampedIPA(_ ipaURL: URL) throws -> URL {
            log("Using stamped encrypted IPA for FairPlay: \(ipaURL.path)")
            let unpack = fm.temporaryDirectory
                .appendingPathComponent("tl-ipa-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: unpack, withIntermediateDirectories: true)
            try fm.unzipItem(at: ipaURL, to: unpack)
            let payload = unpack.appendingPathComponent("Payload", isDirectory: true)
            let app = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" })
            guard let app else {
                throw DecryptError("Stamped encrypted IPA has no Payload/*.app — re-run Get from TetherLess.")
            }
            ipaUnpackRoot = unpack
            log("Unpacked encrypted IPA → \(app.lastPathComponent)")
            return app
        }

        // Always log advanced source + path diagnostics for EPERM triage (screenshots).
        log("Advanced FairPlay · source=\(fpOpts.sourceMode.title) · retries=\(fpOpts.retryRounds)")
        if let liveURL { log("Live path: \(liveURL.path)") }
        if let stampedIPAURL {
            log("Stamped IPA: \(stampedIPAURL.path)")
        } else {
            log("Stamped IPA: (none readable — check App Group / EncryptedSource.ipa)")
        }
        log("EmbeddedPayload: \(src.path)")

        var readRoot: URL
        switch fpOpts.sourceMode {
        case .liveInstall:
            guard let liveURL else {
                throw DecryptError(
                    "Advanced FairPlay is set to Live install only, but no live App Store path was stamped. Install \(name) from the App Store, re-run Get, or switch source mode to Automatic."
                )
            }
            readRoot = liveURL
            log("Using live App Store install for FairPlay: \(liveURL.path)")
        case .stampedIPA:
            guard let stampedIPAURL else {
                throw DecryptError(
                    "Advanced FairPlay is set to Stamped IPA only, but no encrypted IPA was stamped or bundled. Re-run Get from TetherLess."
                )
            }
            readRoot = try unpackStampedIPA(stampedIPAURL)
        case .embeddedPayload:
            readRoot = src
            log("Using EmbeddedPayload only (advanced) — FairPlay may EPERM without live licenses.")
        case .automatic:
            // Prefer live install (fairplayd-friendly), then full stamped/bundled IPA unpack
            // (complete Mach-O tree), and only then slim EmbeddedPayload.
            if let liveURL {
                readRoot = liveURL
                log("Using live App Store install for FairPlay: \(liveURL.path)")
            } else if let stampedIPAURL {
                readRoot = try unpackStampedIPA(stampedIPAURL)
            } else {
                readRoot = src
                log("No live install / stamped IPA — FairPlay will try EmbeddedPayload (often EPERM).")
                log("Re-run Get from TetherLess so EncryptedSource.ipa is bundled into the companion.")
            }
        }

        // Fail-closed DRM checks stay silent in the console (TetherlessiOS-style log).
        // Live App Store installs often refuse cryptid probes — fall back to embed audit for counts.
        var before = try FairPlayDecrypt.verifyApp(at: readRoot)
        if before.entries.isEmpty {
            before = try FairPlayDecrypt.verifyApp(at: src)
        }
        if before.entries.isEmpty {
            // Slim EmbeddedPayload may be empty when host sandbox couldn't copy Mach-Os;
            // EncryptedSource.ipa still carries the full IPA for FairPlay.
            let bundled = Bundle.main.bundleURL.appendingPathComponent(DecryptCompanionHandoff.bundledEncryptedIPAName)
            if let stampedIPAURL {
                log("No Mach-Os on live/embed audit — unpacking stamped encrypted IPA…")
                readRoot = try unpackStampedIPA(stampedIPAURL)
                before = try FairPlayDecrypt.verifyApp(at: readRoot)
            } else if fm.fileExists(atPath: bundled.path) {
                log("No Mach-Os on live/embed audit — unpacking bundled EncryptedSource.ipa…")
                readRoot = try unpackStampedIPA(bundled)
                before = try FairPlayDecrypt.verifyApp(at: readRoot)
            }
        }
        if before.entries.isEmpty {
            throw DecryptError(
                "No Mach-Os found (EmbeddedPayload empty and no EncryptedSource.ipa). Delete Tetherless Decrypt, re-run Get from TetherLess so EncryptedSource.ipa is bundled, then open the companion again."
            )
        }
        let usedLiveInstall = liveURL.map {
            readRoot.resolvingSymlinksInPath().standardizedFileURL
                == $0.resolvingSymlinksInPath().standardizedFileURL
        } ?? false
        if !usedLiveInstall,
           before.encrypted == 0 && before.unknown > 0 && before.clear == 0 && before.plain == 0 {
            throw DecryptError(
                "Couldn't inspect FairPlay cryptids on EmbeddedPayload (\(before.unknown) unknown). Re-run Get from TetherLess after updating, then open Tetherless Decrypt again."
            )
        }
        // Only fail-closed on slim EmbeddedPayload counts when EncryptedSource isn't available.
        // With EncryptedSource.ipa, FairPlay unpacks the full IPA (TestFlight 3/4 slim was OK).
        let hasBundledEncryptedSource = fm.fileExists(
            atPath: Bundle.main.bundleURL.appendingPathComponent(DecryptCompanionHandoff.bundledEncryptedIPAName).path
        )
        if !usedLiveInstall,
           !hasBundledEncryptedSource,
           let expected = expectedEncryptedCount(), expected > 0, before.encrypted < expected, before.unknown == 0 {
            throw DecryptError(
                "EmbeddedPayload is missing FairPlay binaries (\(before.encrypted) encrypted vs \(expected) in the full IPA). Re-run Get so EncryptedSource.ipa is bundled."
            )
        }

        let work = fm.temporaryDirectory.appendingPathComponent("tl-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        let destApp = payload.appendingPathComponent("\(name).app", isDirectory: true)
        try fm.createDirectory(at: destApp, withIntermediateDirectories: true)

        log("Copying app bundle…")
        // Seed Payload from EmbeddedPayload resources; Mach-Os are overwritten from readRoot.
        // When slim embed is empty (sandbox) but we unpacked EncryptedSource/stamped IPA,
        // copy resources from that full tree so the export IPA isn't a hollow shell.
        let seedRoot: URL = {
            let usedIPA = ipaUnpackRoot != nil
                && readRoot.path.hasPrefix((ipaUnpackRoot?.path ?? "") + "/")
            if usedIPA {
                let embedCount = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil))?.count ?? 0
                if embedCount <= 2 { return readRoot }
            }
            return src
        }()
        if seedRoot != src {
            log("Seeding export from unpacked encrypted IPA (EmbeddedPayload was sparse)…")
        }
        try copyTree(from: seedRoot, to: destApp)

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
            if keep {
                progress?(msg)
                Task { @MainActor in DecryptCompanionController.shared.appendLog(msg) }
            }
        }
        func runDecrypt(from root: URL) throws -> FairPlayDecryptReport {
            try FairPlayDecrypt.decryptMachOs(
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

        func epermGuidance(triedBundled: Bool) -> String {
            let bundled = Bundle.main.bundleURL.appendingPathComponent(DecryptCompanionHandoff.bundledEncryptedIPAName)
            let hasBundled = fm.fileExists(atPath: bundled.path)
            if !hasBundled {
                return "FairPlay EPERM on EmbeddedPayload — this Tetherless Decrypt build has no EncryptedSource.ipa. Update TetherLess, delete Tetherless Decrypt, re-run Get so the encrypted IPA is bundled, then open Tetherless Decrypt again. \(AppStoreDecryptGuide.failureHint)"
            }
            if triedBundled {
                return "FairPlay EPERM after unpacking EncryptedSource.ipa — install \(name) from the App Store on this iPhone (same Apple ID) so fairplayd has a live path, re-run Get, then open Tetherless Decrypt again. \(AppStoreDecryptGuide.failureHint)"
            }
            return "FairPlay EPERM on EmbeddedPayload — install \(name) from the App Store on this iPhone (same Apple ID), re-run Get from TetherLess so the live path is stamped, then open Tetherless Decrypt again. \(AppStoreDecryptGuide.failureHint)"
        }

        var report: FairPlayDecryptReport
        do {
            report = try runDecrypt(from: readRoot)
        } catch let fp as FairPlayDecryptError {
            switch fp {
            case .missingLicense:
                throw fp
            case .mainExecutableFailed(let detail)
                where FairPlayFailureClass.current(fromLogs: [detail]) == .licenseOrKeys:
                // Auto-retry once from bundled EncryptedSource.ipa when we started on EmbeddedPayload.
                let bundled = Bundle.main.bundleURL.appendingPathComponent(DecryptCompanionHandoff.bundledEncryptedIPAName)
                let usedEmbed = readRoot.resolvingSymlinksInPath().standardizedFileURL
                    == src.resolvingSymlinksInPath().standardizedFileURL
                if !usedLiveInstall, usedEmbed, fm.fileExists(atPath: bundled.path) {
                    log("EmbeddedPayload EPERM — retrying FairPlay from bundled EncryptedSource.ipa…")
                    try? fm.removeItem(at: destApp)
                    try fm.createDirectory(at: destApp, withIntermediateDirectories: true)
                    try copyTree(from: src, to: destApp)
                    do {
                        let unpacked = try unpackStampedIPA(bundled)
                        report = try runDecrypt(from: unpacked)
                    } catch {
                        throw FairPlayDecryptError.missingLicense(epermGuidance(triedBundled: true))
                    }
                } else if !usedLiveInstall {
                    throw FairPlayDecryptError.missingLicense(epermGuidance(triedBundled: false))
                } else {
                    throw FairPlayDecryptError.missingLicense(FairPlayFailureClass.licenseOrKeys.userMessage)
                }
            default:
                throw fp
            }
        } catch {
            if isLicenseEPERM(error) {
                let bundled = Bundle.main.bundleURL.appendingPathComponent(DecryptCompanionHandoff.bundledEncryptedIPAName)
                let usedEmbed = readRoot.resolvingSymlinksInPath().standardizedFileURL
                    == src.resolvingSymlinksInPath().standardizedFileURL
                if !usedLiveInstall, usedEmbed, fm.fileExists(atPath: bundled.path) {
                    log("EmbeddedPayload EPERM — retrying FairPlay from bundled EncryptedSource.ipa…")
                    try? fm.removeItem(at: destApp)
                    try fm.createDirectory(at: destApp, withIntermediateDirectories: true)
                    try copyTree(from: src, to: destApp)
                    do {
                        let unpacked = try unpackStampedIPA(bundled)
                        report = try runDecrypt(from: unpacked)
                    } catch {
                        throw FairPlayDecryptError.missingLicense(epermGuidance(triedBundled: true))
                    }
                } else if !usedLiveInstall {
                    throw FairPlayDecryptError.missingLicense(epermGuidance(triedBundled: false))
                } else {
                    throw FairPlayDecryptError.missingLicense(FairPlayFailureClass.licenseOrKeys.userMessage)
                }
            } else {
                throw error
            }
        }
        let decN = report.decrypted.count
        let plainN = report.plain.count
        log("Done: \(decN) decrypted, \(plainN) already plain.")

        if report.isPartial || !report.failed.isEmpty {
            let names = report.failed.prefix(6).joined(separator: ", ")
            throw FairPlayDecryptError.stillEncrypted(
                "Companion DRM check failed — \(report.failed.count) required binary(ies) still encrypted: \(names)\(report.failed.count > 6 ? "…" : ""). Full IPA decrypt refuses PARTIAL. \(AppStoreDecryptGuide.failureHint)"
            )
        }
        // Encrypted IPA path stamps fullIPACoverage — leftover soft-fails (appex etc.) are not OK.
        if report.fullIPACoverage, !report.softFailed.isEmpty {
            let names = report.softFailed.prefix(6).joined(separator: ", ")
            throw FairPlayDecryptError.stillEncrypted(
                "Full IPA decrypt left \(report.softFailed.count) Mach-O(s) uncleared: \(names)\(report.softFailed.count > 6 ? "…" : ""). \(AppStoreDecryptGuide.failureHint)"
            )
        }
        if before.encrypted > 0 && decN == 0 {
            throw FairPlayDecryptError.stillEncrypted(
                "DRM was present (\(before.encrypted) encrypted) but nothing was decrypted. \(AppStoreDecryptGuide.failureHint)"
            )
        }

        DecryptCompanionController.shared.statusTitle = "Done — saving automatically…"
        let afterCopy = try FairPlayDecrypt.verifyApp(at: destApp)
        try assertFullyClear(afterCopy, stage: "copied Payload")

        log("Packaging \(name)-decrypted.ipa…")
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
        let outIPA = outDir.appendingPathComponent("\(safeName)-decrypted.ipa")
        try? fm.removeItem(at: outIPA)

        let tmpZip = outIPA.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmpZip)
        try fm.zipItem(at: payload, to: tmpZip, shouldKeepParent: true, compressionMethod: .deflate)
        try fm.moveItem(at: tmpZip, to: outIPA)

        let ipaVerify = try FairPlayDecrypt.verifyIPA(at: outIPA)
        try assertFullyClear(ipaVerify, stage: "packaged IPA")

        DecryptCompanionController.shared.verifySummary = ipaVerify.summary
        DecryptCompanionController.shared.markFinished(url: outIPA, name: name)
        DecryptCompanionController.shared.statusTitle = "Done"
        log("Wrote \(safeName)-decrypted.ipa.")

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
            DecryptCompanionHandoff.openHostForClearIPAImport()
        }
        // Advanced: optionally drop the durable encrypted IPA after a clear export.
        if !fpOpts.keepEncryptedIPA {
            DecryptCompanionHandoff.purgeRetainedEncryptedIPA()
            log("Dropped stamped encrypted IPA (Keep encrypted IPA is off).")
        }
        return outIPA
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

    /// Best-effort icon from EmbeddedPayload (PNGs copied at package time).
    private static func loadEmbeddedAppIcon(at app: URL) -> UIImage? {
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

    // MARK: - Audit helpers

    private static func assertFullyClear(_ report: FairPlayVerifyReport, stage: String) throws {
        guard !report.entries.isEmpty else {
            throw DecryptError("DRM verify found no Mach-Os in \(stage).")
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

/// Root scene when the cloned binary is running as the companion app.
struct DecryptCompanionRoot: View {
    @ObservedObject private var companion = DecryptCompanionController.shared
    @State private var errorText: String?
    @State private var shareURL: URL?

    var body: some View {
        DecryptCompanionConsole(showsDismiss: false, shareURL: $shareURL)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.05, green: 0.07, blue: 0.12).ignoresSafeArea())
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
    }

    /// Memory / remap failures can't finish on-device — bounce to Decrypt site URL host.
    private static func shouldBounceToServer(_ text: String?) -> Bool {
        let t = (text ?? "").lowercased()
        return t.contains("enomem")
            || t.contains("not enough memory")
            || t.contains("mremap")
            || t.contains("out of memory")
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
