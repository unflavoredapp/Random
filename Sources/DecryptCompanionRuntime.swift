//
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
    static func runEmbeddedDecrypt(progress: ((String) -> Void)? = nil) async throws -> URL {
        let fm = FileManager.default
        let log: (String) -> Void = { line in
            progress?(line)
            DecryptCompanionController.shared.appendLog(line)
        }

        guard let name = embeddedAppName() else {
            throw DecryptError("No EmbeddedPayload in Tetherless Decrypt — reinstall the companion from TetherLess.")
        }
        let src = embeddedPayloadRoot.appendingPathComponent(name, isDirectory: true)
        guard fm.fileExists(atPath: src.path) else {
            throw DecryptError("EmbeddedPayload/\(name) missing.")
        }

        DecryptCompanionController.shared.present(name: name, clearLog: true)
        DecryptCompanionController.shared.statusTitle = "Auditing DRM…"
        log("Found embedded app: \(name)")

        // 1) Pre-decrypt audit — prove FairPlay DRM is present on the embedded IPA tree.
        log("DRM audit (before): scanning EmbeddedPayload Mach-Os…")
        let before = try FairPlayDecrypt.verifyApp(at: src)
        logAudit(before, prefix: "BEFORE", log: log)
        if before.entries.isEmpty {
            throw DecryptError("EmbeddedPayload has no Mach-Os — companion package is incomplete. Re-run decrypt from TetherLess.")
        }
        if let expected = expectedEncryptedCount(), expected > 0, before.encrypted < expected {
            throw DecryptError(
                "EmbeddedPayload is missing FairPlay binaries (\(before.encrypted) encrypted vs \(expected) in the full IPA). Re-run decrypt so the companion embeds every DRM Mach-O."
            )
        }
        if before.encrypted == 0 {
            log("WARNING: no cryptid≠0 Mach-Os in EmbeddedPayload — IPA may already be clear, or embed missed DRM binaries.")
        } else {
            log("DRM confirmed: \(before.encrypted) encrypted Mach-O(s) to clear.")
        }

        let work = fm.temporaryDirectory.appendingPathComponent("tl-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        let destApp = payload.appendingPathComponent("\(name).app", isDirectory: true)
        try fm.createDirectory(at: destApp, withIntermediateDirectories: true)

        log("Copying app bundle…")
        try copyTree(from: src, to: destApp)

        // 2) Decrypt FROM embedded (fairplayd reads SC_Info beside binaries) INTO writable copy.
        DecryptCompanionController.shared.statusTitle = "Decrypting…"
        let report = try FairPlayDecrypt.decryptMachOs(
            readingFrom: src,
            writingTo: destApp
        ) { msg in
            progress?(msg)
            Task { @MainActor in DecryptCompanionController.shared.appendLog(msg) }
        }
        let decN = report.decrypted.count
        let plainN = report.plain.count
        log("Done: \(decN) decrypted, \(plainN) already plain.")

        // Companion refuses PARTIAL success — “real DRM” means required Mach-Os cleared.
        if report.isPartial || !report.failed.isEmpty {
            let names = report.failed.prefix(6).joined(separator: ", ")
            throw FairPlayDecryptError.stillEncrypted(
                "Companion DRM check failed — \(report.failed.count) required binary(ies) still encrypted: \(names)\(report.failed.count > 6 ? "…" : ""). \(AppStoreDecryptGuide.failureHint)"
            )
        }
        if before.encrypted > 0 && decN == 0 {
            throw FairPlayDecryptError.stillEncrypted(
                "DRM was present (\(before.encrypted) encrypted) but nothing was decrypted. \(AppStoreDecryptGuide.failureHint)"
            )
        }

        // 3) Post-decrypt audit on the writable Payload tree (before packaging).
        DecryptCompanionController.shared.statusTitle = "Verifying…"
        log("DRM audit (after decrypt): verifying copied Payload…")
        let afterCopy = try FairPlayDecrypt.verifyApp(at: destApp)
        logAudit(afterCopy, prefix: "AFTER", log: log)
        try assertFullyClear(afterCopy, stage: "copied Payload")

        // 4) Strip SC_Info / license crumbs, zip clear IPA.
        log("Packaging \(name)-decrypted.ipa…")
        try stripLicenseArtifacts(in: destApp)

        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let outDir = docs.appendingPathComponent("Decrypted", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outIPA = outDir.appendingPathComponent("\(name)-decrypted.ipa")
        try? fm.removeItem(at: outIPA)

        let tmpZip = outIPA.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmpZip)
        try fm.zipItem(at: payload, to: tmpZip, shouldKeepParent: true, compressionMethod: .deflate)
        try fm.moveItem(at: tmpZip, to: outIPA)

        // 5) Double-check the packaged IPA itself (FairPlayed verify_ipa.sh).
        log("DRM audit (packaged IPA): unpacking and verifying every Mach-O…")
        let ipaVerify = try FairPlayDecrypt.verifyIPA(at: outIPA)
        logAudit(ipaVerify, prefix: "IPA", log: log)
        try assertFullyClear(ipaVerify, stage: "packaged IPA")

        if before.encrypted > 0 {
            log("VERIFY OK: cleared \(before.encrypted) FairPlay Mach-O(s) · \(ipaVerify.summary)")
        } else {
            log("VERIFY OK: IPA already clear · \(ipaVerify.summary)")
        }

        DecryptCompanionController.shared.verifySummary = ipaVerify.summary
        DecryptCompanionController.shared.markFinished(url: outIPA, name: name)
        log("IPA is in this companion’s Documents/Decrypted. Use Share to save or AirDrop.")
        return outIPA
    }

    // MARK: - Audit helpers

    private static func logAudit(_ report: FairPlayVerifyReport, prefix: String, log: (String) -> Void) {
        log("[\(prefix)] \(report.summary) · \(report.entries.count) Mach-O(s)")
        for e in report.entries where e.isEncrypted {
            let detail = e.detail.isEmpty ? "cryptid=\(e.cryptid)" : e.detail
            log("[\(prefix) DRM] \(e.path) · \(detail)")
        }
        if prefix == "AFTER" || prefix == "IPA" {
            for e in report.entries where !e.isEncrypted && e.cryptid == 0 {
                // Keep the log readable — only first wave of clears when many.
                if report.clear + report.plain <= 40 || e.path.split(separator: "/").count <= 2 {
                    log("[\(prefix) CLEAR] \(e.path) · cryptid=0")
                }
            }
        }
    }

    private static func assertFullyClear(_ report: FairPlayVerifyReport, stage: String) throws {
        guard !report.entries.isEmpty else {
            throw DecryptError("DRM verify found no Mach-Os in \(stage).")
        }
        guard report.encrypted == 0 else {
            let names = report.entries.filter(\.isEncrypted).prefix(6).map(\.path).joined(separator: ", ")
            throw FairPlayDecryptError.stillEncrypted(
                "DRM verify failed on \(stage): \(report.encrypted) Mach-O(s) still encrypted (\(names)\(report.encrypted > 6 ? "…" : "")). \(AppStoreDecryptGuide.failureHint)"
            )
        }
    }

    private static func copyTree(from src: URL, to destApp: URL) throws {
        let fm = FileManager.default
        if let en = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let item as URL in en {
                let vals = try? item.resourceValues(forKeys: [.isDirectoryKey])
                let prefix = src.path.hasSuffix("/") ? src.path : src.path + "/"
                let rel = item.path.hasPrefix(prefix) ? String(item.path.dropFirst(prefix.count)) : item.lastPathComponent
                let out = destApp.appendingPathComponent(rel)
                if vals?.isDirectory == true {
                    try? fm.createDirectory(at: out, withIntermediateDirectories: true)
                } else {
                    try? fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: out)
                    try? fm.copyItem(at: item, to: out)
                }
            }
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
            .task {
                do {
                    let url = try await DecryptCompanionRuntime.runEmbeddedDecrypt()
                    shareURL = url
                } catch {
                    errorText = error.localizedDescription
                    companion.markFailed(error.localizedDescription)
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
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}
