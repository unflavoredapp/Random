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
    static func runEmbeddedDecrypt(progress: ((String) -> Void)? = nil) async throws -> URL {
        let fm = FileManager.default
        let log: (String) -> Void = { line in
            progress?(line)
            DecryptCompanionController.shared.appendLog(line)
        }

        guard let name = embeddedAppName() else {
            throw DecryptError("No EmbeddedPayload in Tetherless Decrypt — reinstall the companion from TetherLess.")
        }
        // Path traversal guard — only allow a single path component under EmbeddedPayload.
        guard !name.contains("/") && !name.contains("..") && !name.hasPrefix(".") else {
            throw DecryptError("Invalid EmbeddedPayload name.")
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
        _ = DecryptCompanionHandoff.readHostSnapshot(fromManifest: man)

        // Fail-closed DRM checks stay silent in the console (TetherlessiOS-style log).
        let before = try FairPlayDecrypt.verifyApp(at: src)
        if before.entries.isEmpty {
            throw DecryptError("EmbeddedPayload has no Mach-Os — companion package is incomplete. Re-run decrypt from TetherLess.")
        }
        if before.encrypted == 0 && before.unknown > 0 && before.clear == 0 && before.plain == 0 {
            throw DecryptError(
                "Couldn't inspect FairPlay cryptids on EmbeddedPayload (\(before.unknown) unknown). Re-run Get from TetherLess after updating, then open Tetherless Decrypt again."
            )
        }
        if let expected = expectedEncryptedCount(), expected > 0, before.encrypted < expected, before.unknown == 0 {
            throw DecryptError(
                "EmbeddedPayload is missing FairPlay binaries (\(before.encrypted) encrypted vs \(expected) in the full IPA). Re-run decrypt so the companion embeds every DRM Mach-O."
            )
        }

        let work = fm.temporaryDirectory.appendingPathComponent("tl-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        let destApp = payload.appendingPathComponent("\(name).app", isDirectory: true)
        try fm.createDirectory(at: destApp, withIntermediateDirectories: true)

        log("Copying app bundle…")
        try copyTree(from: src, to: destApp)

        // FairPlayed path: EmbeddedPayload first; live install is a silent optional heal.
        let progressBridge: @Sendable (String) -> Void = { msg in
            progress?(msg)
            Task { @MainActor in DecryptCompanionController.shared.appendLog(msg) }
        }
        let liveRead = Self.preferredLiveInstallURL(embeddedApp: src, manifest: man)
        let outcome = try FairPlaySelfHeal.healAndDecrypt(
            context: FairPlaySelfHeal.Context(
                readingFrom: src,
                writingTo: destApp,
                liveInstall: liveRead,
                embeddedOrIPA: src,
                maxRounds: 4,
                quietConsole: true,
                progress: progressBridge
            )
        )
        let report = outcome.report
        let decN = report.decrypted.count
        let plainN = report.plain.count
        log("Done: \(decN) decrypted, \(plainN) already plain.")

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

        DecryptCompanionController.shared.statusTitle = "Done — saving automatically…"
        let afterCopy = try FairPlayDecrypt.verifyApp(at: destApp)
        try assertFullyClear(afterCopy, stage: "copied Payload")

        log("Packaging \(name)-decrypted.ipa…")
        try stripLicenseArtifacts(in: destApp)

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
        return outIPA
    }

    // MARK: - Embedded metadata

    /// Resolve a live App Store install for fairplayd input when the same app is on-device.
    /// Prefers `hostLiveInstallPath` stamped by the host packager (manifest + App Group) —
    /// companion LS/MI lookups often miss apps the host can see via Pair / DeviceLibrary.
    private static func preferredLiveInstallURL(
        embeddedApp: URL,
        manifest: [String: Any]?
    ) -> URL? {
        // 1) Manifest stamp (baked into the companion IPA at package time).
        if let stamped = (manifest?["hostLiveInstallPath"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stamped.isEmpty,
           let live = Self.usableLiveInstall(at: URL(fileURLWithPath: stamped)) {
            return live
        }

        // 2) App Group / host snapshot — host may have refreshed the path after install.
        if let published = DecryptCompanionHandoff.readLiveInstallPath(),
           let live = Self.usableLiveInstall(at: URL(fileURLWithPath: published.path)) {
            return live
        }
        if let fromSnap = (DecryptCompanionHandoff.readHostSnapshot(fromManifest: manifest)["hostLiveInstallPath"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fromSnap.isEmpty,
           let live = Self.usableLiveInstall(at: URL(fileURLWithPath: fromSnap)) {
            return live
        }

        // 3) Best-effort LS/MI inside the companion (often sandboxed away).
        var candidates: [String] = []
        if let fromMan = (manifest?["bundleID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fromMan.isEmpty {
            candidates.append(fromMan)
        }
        if let publishedBid = DecryptCompanionHandoff.readLiveInstallPath()?.bundleID,
           !publishedBid.isEmpty {
            candidates.append(publishedBid)
        }
        let info = NSDictionary(contentsOf: embeddedApp.appendingPathComponent("Info.plist")) as? [String: Any]
        if let fromPlist = (info?["CFBundleIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fromPlist.isEmpty {
            candidates.append(fromPlist)
        }
        var seen = Set<String>()
        for bid in candidates where seen.insert(bid).inserted {
            guard let live = FairPlayDecrypt.installedAppURL(bundleID: bid),
                  let usable = Self.usableLiveInstall(at: live) else { continue }
            return usable
        }
        return nil
    }

    /// Live Store container with a main executable we can at least open (or fairplayd can).
    private static func usableLiveInstall(at url: URL) -> URL? {
        let live = url.resolvingSymlinksInPath().standardizedFileURL
        guard FairPlayDecrypt.isLiveAppStoreInstall(live) else { return nil }
        // Reject our own companion tree / EmbeddedPayload copies.
        let own = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let p = live.path
        if !own.isEmpty, p == own || p.hasPrefix(own.hasSuffix("/") ? own : own + "/") {
            return nil
        }
        if p.contains("/EmbeddedPayload/") { return nil }
        guard let main = FairPlayDecrypt.mainExecutableForEmbed(in: live) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: main.path, isDirectory: &isDir),
              !isDir.boolValue else { return nil }
        if FileManager.default.isReadableFile(atPath: main.path) { return live }
        // Host-stamped paths may fail isReadableFile under the companion sandbox even
        // when mremap_encrypted + fairplayd can still page the binary in.
        if (try? FileHandle(forReadingFrom: main)) != nil { return live }
        // Last resort: path exists as a live .app with a main binary — try it anyway.
        // Self-heal falls back to EmbeddedPayload if mremap EPERMs.
        return live
    }

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
