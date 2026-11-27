//
// Brand: Tetherless · https://tetherless.dev
//  DecryptCompanionPackager.swift
//  Builds a real second app (“FastDecryptBot”) bundled from this process:
//  prefer embedded DecryptHelper.app Mach-O (lean FairPlay shell); fall back to
//  cloning the host executable + Frameworks. Embed the encrypted target under
//  EmbeddedPayload/ (FairPlayed layout), zip → IPA. Main app then signs with
//  the user’s Apple ID cert (free 7-day or paid), installs, and opens it.
//

import Foundation
import UIKit
import ZIPFoundation

/// Companion packaging runs on the main actor (called from `DecryptCompanionInstaller`)
/// so host FairPlay-ack snapshots can read `AppStoreDecryptGuide` safely.
@MainActor
enum DecryptCompanionPackager {
    static let companionBundleIDFallback = DecryptCompanionIdentity.companionBundleIDFallback
    static let companionDisplayName = DecryptCompanionIdentity.companionDisplayName
    /// Primary URL scheme for opening the companion. Legacy schemes still accepted by the host.
    static let companionURLScheme = DecryptCompanionIdentity.companionURLScheme
    static let companionIconAsset = DecryptCompanionIdentity.companionIconAsset

    struct Package: Sendable {
        let ipaURL: URL
        let bundleID: String
        let displayName: String
        let embeddedAppName: String
        let approximateBytes: Int64
        /// Temporary `tl-companion-*` workspace that owns `ipaURL`. Caller must
        /// `cleanupWorkDirectory()` after `Signer.signDetached` finishes (success or failure).
        let workDirectory: URL

        /// Remove the packaging workspace (unsigned IPA + Payload extract). Safe to call twice.
        func cleanupWorkDirectory() {
            try? FileManager.default.removeItem(at: workDirectory)
        }
    }

    /// Build an unsigned companion IPA ready for SignEngine.
    /// - Parameters:
    ///   - encryptedIPA: App Store IPA (or any FairPlay-encrypted IPA) to embed.
    ///   - bundleID: Must match the signing profile (wildcard-friendly).
    ///   - targetBundleID: Known Store target bid (Search / ticket / IPA peek) when
    ///     EmbeddedPayload Info.plist is missing or unreadable under sandbox.
    static func buildCompanionIPA(
        embedding encryptedIPA: URL,
        bundleID: String,
        targetBundleID: String? = nil,
        progress: ((String) -> Void)? = nil
    ) throws -> Package {
        try buildCompanionIPA(bundleID: bundleID, progress: progress) { app, progress in
            progress?("Extracting bundle…")
            return try embedEncryptedApp(
                from: encryptedIPA,
                into: app,
                knownBundleID: targetBundleID,
                progress: progress
            )
        }
    }

    /// Same companion shell, embedding a live App Store install (Mach-Os + SC_Info)
    /// when a store IPA isn’t available yet.
    static func buildCompanionIPA(
        embeddingInstalledApp installedApp: URL,
        bundleID: String,
        targetBundleID: String? = nil,
        progress: ((String) -> Void)? = nil
    ) throws -> Package {
        try buildCompanionIPA(bundleID: bundleID, progress: progress) { app, progress in
            progress?("Embedding installed app…")
            return try embedInstalledApp(
                from: installedApp,
                into: app,
                knownBundleID: targetBundleID,
                progress: progress
            )
        }
    }

    private static func buildCompanionIPA(
        bundleID: String,
        progress: ((String) -> Void)?,
        embed: (_ companionApp: URL, _ progress: ((String) -> Void)?) throws -> String
    ) throws -> Package {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("tl-companion-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        let app = payload.appendingPathComponent("\(companionDisplayName).app", isDirectory: true)
        try fm.createDirectory(at: app, withIntermediateDirectories: true)

        progress?("Preparing companion app shell…")
        try cloneHostApp(into: app, bundleID: bundleID, progress: progress)

        let embedName = try embed(app, progress)

        progress?("Packaging companion IPA…")
        let ipa = work.appendingPathComponent("FastDecryptBot-unsigned.ipa")
        try? fm.removeItem(at: ipa)
        try fm.zipItem(at: payload, to: ipa, shouldKeepParent: true, compressionMethod: .deflate)

        let attrs = try fm.attributesOfItem(atPath: ipa.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return Package(
            ipaURL: ipa,
            bundleID: bundleID,
            displayName: companionDisplayName,
            embeddedAppName: embedName,
            approximateBytes: bytes,
            workDirectory: work
        )
    }

    /// Pick a companion bundle ID that fits the active provisioning profile.
    /// - Throws when an explicit profile would force the companion to share the host’s bundle ID
    ///   (install would replace AppAssassin).
    static func companionBundleID(forProvision provision: Data) throws -> String {
        let host = (Bundle.main.bundleIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String
        if let xml = provisionPlistXML(provision),
           let plist = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil) as? [String: Any],
           let ents = plist["Entitlements"] as? [String: Any],
           let appID = ents["application-identifier"] as? String {
            // TEAMID.*              → hostBundle.decrypt (free Apple ID wildcard)
            // TEAMID.com.example.*  → com.example.decrypt
            // TEAMID.com.example.app → exact App ID (must not equal host)
            let parts = appID.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                resolved = companionBundleIDFallback
                try assertCompanionBundleIDDistinct(resolved, host: host)
                return resolved
            }
            let rest = parts[1]
            let hostDecrypt: String = {
                if host.hasSuffix(".decrypt") { return host.isEmpty ? companionBundleIDFallback : host }
                return host.isEmpty ? companionBundleIDFallback : host + ".decrypt"
            }()
            if rest == "*" || rest == ".*" {
                resolved = hostDecrypt
            } else if rest.hasSuffix(".*") {
                let prefix = String(rest.dropLast(2))
                resolved = prefix.isEmpty ? hostDecrypt : prefix + ".decrypt"
            } else if rest.contains("*") {
                let replaced = rest.replacingOccurrences(of: "*", with: "decrypt")
                resolved = replaced.isEmpty ? hostDecrypt : replaced
            } else {
                // Explicit App ID — must use the profile’s exact bundle ID.
                // Inventing a `.decrypt` sibling causes installd 0xe8008016 (invalid entitlements).
                resolved = rest
            }
        } else {
            resolved = companionBundleIDFallback
        }
        try assertCompanionBundleIDDistinct(resolved, host: host)
        return resolved
    }

    /// Refuse to package a companion that would collide with the running host app.
    private static func assertCompanionBundleIDDistinct(_ bundleID: String, host: String) throws {
        let companion = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostID = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !companion.isEmpty else {
            throw DecryptError("Companion provisioning profile did not yield a bundle ID.")
        }
        if !hostID.isEmpty, companion.caseInsensitiveCompare(hostID) == .orderedSame {
            throw DecryptError(
                "Companion provisioning profile uses the host app’s bundle ID (\(hostID)). A separate companion App ID / wildcard profile is required so FastDecryptBot doesn’t replace AppAssassin."
            )
        }
    }

    // MARK: - Lean DecryptHelper shell

    /// Prefer the embedded `DecryptHelper.app` Mach-O (~2 MB FairPlay shell). Fall back to
    /// cloning the host executable only when the helper was stripped from the IPA.
    private static func resolveHelperExecutable() throws -> (url: URL, name: String, isLeanHelper: Bool) {
        let fm = FileManager.default
        let helperName = DecryptCompanionIdentity.helperProductName
        if let helperApp = Bundle.main.url(forResource: helperName, withExtension: "app") {
            let infoURL = helperApp.appendingPathComponent("Info.plist")
            let exeName: String = {
                if let dict = NSDictionary(contentsOf: infoURL) as? [String: Any],
                   let name = dict["CFBundleExecutable"] as? String,
                   !name.isEmpty {
                    return name
                }
                return helperName
            }()
            let exe = helperApp.appendingPathComponent(exeName)
            if fm.isExecutableFile(atPath: exe.path) {
                return (exe, exeName, true)
            }
        }
        // Also accept a bare Mach-O dropped next to Resources (older embed layouts).
        if let bare = Bundle.main.url(forResource: helperName, withExtension: nil),
           fm.isExecutableFile(atPath: bare.path) {
            return (bare, helperName, true)
        }
        guard let hostExe = Bundle.main.executableURL else {
            throw DecryptError("Couldn't locate DecryptHelper or host executable for FastDecryptBot.")
        }
        return (hostExe, hostExe.lastPathComponent, false)
    }

    private static func cloneHostApp(
        into destApp: URL,
        bundleID: String,
        progress: ((String) -> Void)?
    ) throws {
        let fm = FileManager.default
        let host = Bundle.main

        let resolved = try resolveHelperExecutable()
        let exeURL = resolved.url
        let exeName = resolved.name
        let shellTier = resolved.isLeanHelper
            ? DecryptCompanionIdentity.helperModeLean
            : DecryptCompanionIdentity.helperModeHostFallback
        if resolved.isLeanHelper {
            progress?("shell=lean DecryptHelper (subordinate FairPlay worker)")
        } else {
            progress?("shell=host-fallback (~45 MB) — DecryptHelper.app missing from host IPA")
        }
        try fm.copyItem(at: exeURL, to: destApp.appendingPathComponent(exeName))

        // Lean DecryptHelper is statically linked (ZIPFoundation only) — skip host Frameworks.
        // Host-fallback still needs OpenSSL / whatever the fat Mach-O links.
        if !resolved.isLeanHelper {
            try copyLeanFrameworks(from: host, into: destApp, progress: progress)
        } else {
            progress?("DecryptHelper — no host Frameworks (lean shell)")
        }

        // Minimal Info.plist — companion identity + URL scheme for handoff.
        let info: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": companionDisplayName,
            "CFBundleExecutable": exeName,
            "CFBundleIdentifier": bundleID,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": companionDisplayName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": (host.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0",
            "CFBundleVersion": (host.infoDictionary?["CFBundleVersion"] as? String) ?? "1",
            "LSRequiresIPhoneOS": true,
            "MinimumOSVersion": (host.infoDictionary?["MinimumOSVersion"] as? String)
                ?? (host.infoDictionary?["LSMinimumSystemVersion"] as? String)
                ?? "15.0",
            // Full-screen phone app — empty launch dict + missing RequiresFullScreen
            // letterboxed the console as a floating card under the “← TetherLess” banner.
            "UILaunchScreen": [
                "UIColorName": "LaunchBackground"
            ] as [String: Any],
            "UIRequiresFullScreen": true,
            "UIStatusBarStyle": "UIStatusBarStyleLightContent",
            "UIViewControllerBasedStatusBarAppearance": true,
            "UIRequiredDeviceCapabilities": ["arm64"],
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
            "CFBundleIcons": [
                "CFBundlePrimaryIcon": [
                    "CFBundleIconFiles": ["AppIcon60x60"],
                    "CFBundleIconName": "AppIcon"
                ]
            ],
            // Companion owns fastdecryptbot:// (plus legacy schemes). Host must not
            // register these or iOS may reopen AppAssassin instead of this IPA.
            "CFBundleURLTypes": [[
                "CFBundleURLName": "bot.fastdecrypt.decrypt",
                "CFBundleURLSchemes": [companionURLScheme, "appassassin-decrypt", "tetherless-decrypt"]
            ]],
            "LSApplicationQueriesSchemes": ["appassassin", "tetherless"],
            // Marker so runtime knows this install is the companion role.
            "TLCompanionRole": true,
            "TLCompanionHostBundle": host.bundleIdentifier ?? TetherlessBrand.bundleID,
            "TLDecryptHelper": resolved.isLeanHelper,
            DecryptCompanionIdentity.helperModeKey: shellTier,
            "TLDecryptHelperSource": exeName,
            // Companion is the subordinate FairPlay process (installed app, not XPC).
            "TLDecryptHelperProcess": "installed-companion",
        ]
        let infoURL = destApp.appendingPathComponent("Info.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try data.write(to: infoURL, options: .atomic)

        // PkgInfo keeps some installd paths happy.
        try Data("APPL????".utf8).write(to: destApp.appendingPathComponent("PkgInfo"), options: .atomic)

        // FastDecryptBot icon (not the host AppAssassin tile). Skip host Assets.car —
        // that catalog is tens of MB and only serves the host UI, not FairPlay.
        writeCompanionIcons(into: destApp)
    }

    /// Copy Frameworks the cloned host binary needs, skipping nested *.bundle resource
    /// trees that inflate the companion without helping mremap.
    private static func copyLeanFrameworks(
        from host: Bundle,
        into destApp: URL,
        progress: ((String) -> Void)?
    ) throws {
        let fm = FileManager.default
        let destFW = destApp.appendingPathComponent("Frameworks", isDirectory: true)
        try? fm.createDirectory(at: destFW, withIntermediateDirectories: true)

        var sources: [URL] = []
        if let fw = host.privateFrameworksURL ?? host.url(forResource: "Frameworks", withExtension: nil),
           fm.fileExists(atPath: fw.path) {
            sources.append(fw)
        }
        let hostFW = host.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        if fm.fileExists(atPath: hostFW.path) {
            sources.append(hostFW)
        }

        var copied = 0
        var skippedBundles = 0
        var failedFrameworks: [String] = []
        for fwRoot in sources {
            guard let items = try? fm.contentsOfDirectory(at: fwRoot, includingPropertiesForKeys: nil) else {
                continue
            }
            for item in items {
                let name = item.lastPathComponent
                // Skip loose resource-only bundles dumped next to frameworks.
                if name.hasSuffix(".bundle") || name.hasSuffix(".momd") || name == "Assets.car" {
                    skippedBundles += 1
                    continue
                }
                let out = destFW.appendingPathComponent(name)
                if fm.fileExists(atPath: out.path) { continue }
                do {
                    try fm.copyItem(at: item, to: out)
                    copied += 1
                } catch {
                    progress?(
                        "Framework copy failed for \(name): \(error.localizedDescription)"
                    )
                    if name.hasSuffix(".framework") {
                        failedFrameworks.append(name)
                    }
                }
            }
        }
        progress?(
            "Lean Frameworks: \(copied) copied"
                + (skippedBundles > 0 ? ", \(skippedBundles) resource bundles skipped" : "")
                + (failedFrameworks.isEmpty ? "" : ", \(failedFrameworks.count) failed")
        )
        if !failedFrameworks.isEmpty {
            throw DecryptError(
                "Required Frameworks failed to copy into FastDecryptBot: \(failedFrameworks.joined(separator: ", ")). Reinstall AppAssassin / re-run Get."
            )
        }
    }

    // MARK: - FairPlayed EmbeddedPayload

    /// Stage encrypted app under EmbeddedPayload/<Name>/ (no .app suffix), strip Watch,
    /// replicate SINFs — same contract as FairPlayed `embed_ipa.sh`.
    @discardableResult
    private static func embedEncryptedApp(
        from ipa: URL,
        into companionApp: URL,
        knownBundleID: String? = nil,
        progress: ((String) -> Void)?
    ) throws -> String {
        let fm = FileManager.default
        let extract = companionApp.deletingLastPathComponent()
            .appendingPathComponent("embed-src-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: extract, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extract) }

        var ipaSinfN = IPadnIPAPackager.countSinfs(inIPA: ipa)
        let sidecar = IPadnIPAPackager.readSinfSidecar(nextTo: ipa)
        progress?("Store IPA licenses · \(ipaSinfN) .sinf in archive"
            + (sidecar.isEmpty ? "" : " · \(sidecar.count) sidecar"))
        if ipaSinfN == 0, !sidecar.isEmpty {
            progress?("Re-injecting \(sidecar.count) sidecar FairPlay license(s) into Store IPA…")
            try IPadnIPAPackager.injectSinfs(sidecar, intoIPA: ipa)
            ipaSinfN = IPadnIPAPackager.countSinfs(inIPA: ipa)
        }
        if ipaSinfN == 0, sidecar.isEmpty {
            throw DecryptError(
                "Store IPA has no SC_Info/.sinf licenses. Delete the Failed/Completed job, turn off Airplane Mode, re-run Get so songList sinfs are injected, then retry."
            )
        }
        try fm.unzipItem(at: ipa, to: extract)
        let payload = extract.appendingPathComponent("Payload", isDirectory: true)
        guard let srcApp = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw DecryptError("No Payload/*.app in the encrypted IPA to embed.")
        }
        // ZIPFoundation unzip can drop update-mode entries — re-extract / apply sidecar.
        if Self.countSinfs(under: srcApp) == 0 {
            if ipaSinfN > 0 {
                progress?("Unzip left 0 .sinf — extracting SC_Info entries from IPA zip…")
                do {
                    try Self.extractSCInfoEntries(fromIPA: ipa, intoApp: srcApp, progress: progress)
                } catch {
                    progress?("IPA zip extract failed (\(error.localizedDescription)) — trying sidecar…")
                }
            }
            if Self.countSinfs(under: srcApp) == 0, !sidecar.isEmpty {
                progress?("Applying \(sidecar.count) sidecar FairPlay license(s) to unzipped app…")
                try IPadnIPAPackager.applySinfs(sidecar, toApp: srcApp)
            }
            if Self.countSinfs(under: srcApp) == 0 {
                throw DecryptError(
                    "Store IPA licenses could not be staged into EmbeddedPayload. Delete the job, turn off Airplane Mode, and re-run Get."
                )
            }
        }
        // Free Apple ID certs strip App Groups — host Documents stamps are invisible to the
        // companion (Roblox/CARROT/TestFlight EPERM screenshots). Always embed the IPA.
        try Self.bundleEncryptedSourceIPA(ipa, into: companionApp, progress: progress)
        let hinted = (knownBundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let peeked = hinted.isEmpty ? IPadnIPAPackager.bundleID(fromIPA: ipa) : hinted
        return try stageEmbeddedPayload(
            from: srcApp,
            into: companionApp,
            sourceLabel: "full IPA",
            knownBundleID: peeked,
            progress: progress
        )
    }

    /// Copy the Store IPA into the companion `.app` as `EncryptedSource.ipa` for packaging /
    /// audit only — FairPlay mremap always uses the live App Store install path.
    private static func bundleEncryptedSourceIPA(
        _ ipa: URL,
        into companionApp: URL,
        progress: ((String) -> Void)?
    ) throws {
        let fm = FileManager.default
        let bundled = companionApp.appendingPathComponent(DecryptCompanionHandoff.bundledEncryptedIPAName)
        try? fm.removeItem(at: bundled)
        do {
            try fm.copyItem(at: ipa, to: bundled)
        } catch {
            throw DecryptError(
                "Couldn't bundle EncryptedSource.ipa for packaging (\(error.localizedDescription)). Free storage and retry Get."
            )
        }
        let bytes = (try? fm.attributesOfItem(atPath: bundled.path)[.size] as? Int64) ?? 0
        guard bytes > 1_000_000 else {
            throw DecryptError("EncryptedSource.ipa is too small (\(bytes) bytes) — Store download looks incomplete. Retry Get.")
        }
        progress?(
            "Bundled EncryptedSource.ipa for packaging (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))) — FairPlay remaps from EmbeddedPayload (FairPlayed)."
        )
    }

    /// Slim-embed a live `/Bundle/Application/…/*.app` install into EmbeddedPayload.
    /// Prefer a stamped Store IPA when available — live installs often refuse SC_Info
    /// reads from a sideloaded host, and FairPlayed remmap needs SC_Info beside binaries.
    @discardableResult
    private static func embedInstalledApp(
        from installedApp: URL,
        into companionApp: URL,
        knownBundleID: String? = nil,
        progress: ((String) -> Void)?
    ) throws -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: installedApp.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw DecryptError("Installed app path missing: \(installedApp.lastPathComponent).")
        }
        let installedInfo = NSDictionary(
            contentsOf: installedApp.appendingPathComponent("Info.plist")
        ) as? [String: Any]
        let installedBid = (installedInfo?["CFBundleIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (knownBundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Prefer IPA → EmbeddedPayload (readable SC_Info). Live slim-embed often ships
        // Mach-Os without licenses → companion remmap EPERM that looks like “keys”.
        if let stamped = DecryptCompanionHandoff.readEncryptedIPAPath(
            matchingBundleID: installedBid.isEmpty ? nil : installedBid
        ) {
            let src = URL(fileURLWithPath: stamped.path)
            if FileManager.default.fileExists(atPath: src.path) {
                progress?(
                    "Live install embed → switching to stamped Store IPA for EmbeddedPayload + SC_Info…"
                )
                return try embedEncryptedApp(
                    from: src,
                    into: companionApp,
                    knownBundleID: installedBid.isEmpty ? knownBundleID : installedBid,
                    progress: progress
                )
            }
        } else if !installedBid.isEmpty {
            progress?(
                "No stamped Store IPA for \(installedBid) — slim-embedding live install (SC_Info may be unreadable)."
            )
        }
        return try stageEmbeddedPayload(
            from: installedApp,
            into: companionApp,
            sourceLabel: "install path",
            knownBundleID: installedBid.isEmpty ? knownBundleID : installedBid,
            progress: progress
        )
    }

    /// Shared FairPlayed-style EmbeddedPayload staging from any `.app` tree.
    ///
    /// Never call `verifyApp` on a live App Store install path — `fp_max_cryptid` /
    /// `fp_describe_cryptids` can hang the host forever. Collect Mach-Os with the
    /// timeout-safe walker, slim-copy, then audit the **copied** EmbeddedPayload.
    /// Full DRM verification + decrypt runs inside the companion IPA.
    private static func stageEmbeddedPayload(
        from srcApp: URL,
        into companionApp: URL,
        sourceLabel: String,
        knownBundleID: String? = nil,
        progress: ((String) -> Void)?
    ) throws -> String {
        let fm = FileManager.default
        let name = srcApp.deletingPathExtension().lastPathComponent
        progress?("Found \(name).app")

        let embedRoot = companionApp.appendingPathComponent("EmbeddedPayload", isDirectory: true)
        let dest = embedRoot.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: embedRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        // Never mutate the source application (live App Store installs share this path).
        // Remove Watch only from the staged EmbeddedPayload below.

        // Live installs + any path labeled "install path" must never call verifyApp on
        // the source tree — cryptid probes hang the host (Cake Wallet / TestFlight).
        // Companion audits the copied EmbeddedPayload instead.
        let liveInstall = sourceLabel == "install path" || isLiveAppStoreInstall(srcApp)
        var sourceEncrypted: Int?
        var sourceMachOCount: Int?
        var sourceClear = 0
        var sourcePlain = 0
        if liveInstall {
            progress?("Skipping host DRM audit on install path — companion will verify…")
        } else {
            progress?("Auditing FairPlay DRM on \(sourceLabel)…")
            let fullAudit = try FairPlayDecrypt.verifyApp(at: srcApp)
            sourceEncrypted = fullAudit.encrypted
            sourceMachOCount = fullAudit.entries.count
            sourceClear = fullAudit.clear
            sourcePlain = fullAudit.plain
            progress?(
                "\(sourceLabel) · \(fullAudit.entries.count) Mach-O(s) · \(fullAudit.encrypted) encrypted · \(fullAudit.clear) clear"
            )
            for e in fullAudit.entries where e.isEncrypted {
                progress?("[DRM] \(e.path) · cryptid=\(e.cryptid)")
            }
            if fullAudit.entries.isEmpty {
                throw DecryptError("No Mach-Os in \(name).app — cannot build companion EmbeddedPayload.")
            }
        }

        // Slim embed: Mach-Os + SC_Info + Info.plist (FairPlayed needs SINFs next to binaries;
        // full asset trees blow up the companion install — competition stayed ~hundreds of MB).
        progress?("Copying app bundle (Mach-Os + SC_Info)…")
        try copySlimAppTree(from: srcApp, to: dest, progress: progress)

        // FairPlayed: remove Watch — not decryptable on iPhone.
        try? fm.removeItem(at: dest.appendingPathComponent("Watch"))

        // FairPlayed embed_ipa.sh: Manifest SinfReplicationPaths + buddy3 per-binary SINFs.
        var staged = FairPlayDecrypt.replicateSinfs(in: dest)
        if let bins = try? FairPlayDecrypt.collectMachOsForCompanion(under: dest) {
            staged += FairPlayDecrypt.stageSinfsForEncryptedBinaries(bins, in: dest)
        }
        if staged > 0 {
            progress?("Staged \(staged) SINF license(s) on EmbeddedPayload…")
        }

        // FairPlayed: remmap reads SC_Info next to EmbeddedPayload binaries. Shipping a
        // companion without licenses produces mremap EPERM that looks like “keys missing”.
        var sinfCount = Self.countSinfs(under: dest)
        // Slim copy sometimes skips SC_Info even when src has licenses — force file-by-file.
        if sinfCount == 0, Self.countSinfs(under: srcApp) > 0 {
            progress?("Slim SC_Info copy missed licenses — forcing .sinf file copy…")
            try? Self.forceCopySinfs(from: srcApp, to: dest, progress: progress)
            sinfCount = Self.countSinfs(under: dest)
        }
        if sinfCount == 0 {
            // Sidecar next to stamped / bundled Store IPA.
            let companionRoot = dest.deletingLastPathComponent().deletingLastPathComponent()
            let sidecarCandidates: [URL] = {
                var urls: [URL] = []
                if let stamped = DecryptCompanionHandoff.readEncryptedIPAPath(
                    matchingBundleID: (knownBundleID ?? "").isEmpty ? nil : knownBundleID
                ) {
                    urls.append(URL(fileURLWithPath: stamped.path))
                }
                let bundled = companionRoot.appendingPathComponent(DecryptCompanionHandoff.bundledEncryptedIPAName)
                if FileManager.default.fileExists(atPath: bundled.path) {
                    urls.append(bundled)
                }
                return urls
            }()
            for ipaURL in sidecarCandidates {
                let blobs = IPadnIPAPackager.readSinfSidecar(nextTo: ipaURL)
                guard !blobs.isEmpty else { continue }
                progress?("Applying \(blobs.count) sidecar FairPlay license(s) onto EmbeddedPayload…")
                try? IPadnIPAPackager.applySinfs(blobs, toApp: dest)
                sinfCount = Self.countSinfs(under: dest)
                if sinfCount > 0 { break }
            }
        }
        if sinfCount == 0 {
            // Last chance: copy readable SC_Info from the live Store install.
            var bidHint = (knownBundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if bidHint.isEmpty {
                let destInfo = NSDictionary(contentsOf: dest.appendingPathComponent("Info.plist")) as? [String: Any]
                bidHint = (destInfo?["CFBundleIdentifier"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            if let live = Self.resolveLiveInstallURL(
                bundleID: bidHint,
                preferring: liveInstall ? srcApp : nil
            ) {
                progress?("Seeding SC_Info from live install \(live.lastPathComponent)…")
                try? Self.copySCInfoTrees(from: live, to: dest, progress: progress)
                try? Self.forceCopySinfs(from: live, to: dest, progress: progress)
                var stagedLive = FairPlayDecrypt.replicateSinfs(in: dest)
                if let bins = try? FairPlayDecrypt.collectMachOsForCompanion(under: dest) {
                    stagedLive += FairPlayDecrypt.stageSinfsForEncryptedBinaries(bins, in: dest)
                }
                if stagedLive > 0 {
                    progress?("Staged \(stagedLive) SINF license(s) from live install…")
                }
                sinfCount = Self.countSinfs(under: dest)
            }
        }
        progress?("EmbeddedPayload SC_Info · \(sinfCount) .sinf file(s)")
        if sinfCount == 0 {
            throw DecryptError(
                "EmbeddedPayload has Mach-Os but no SC_Info/.sinf licenses for \(name). "
                    + "Delete the Failed job, turn off Airplane Mode, re-run Get so progress shows "
                    + "“IPA has N .sinf”, then retry — do not open FastDecryptBot until N > 0."
            )
        }

        // Audit the copied EmbeddedPayload (safe — not the live install container).
        let slimAudit = try FairPlayDecrypt.verifyApp(at: dest)
        progress?(
            "EmbeddedPayload · \(slimAudit.entries.count) Mach-O(s) · \(slimAudit.encrypted) encrypted"
        )
        let bundledIPA = companionApp.appendingPathComponent(DecryptCompanionHandoff.bundledEncryptedIPAName)
        let hasEncryptedSource = fm.fileExists(atPath: bundledIPA.path)
            && ((try? fm.attributesOfItem(atPath: bundledIPA.path)[.size] as? Int64) ?? 0) > 1_000_000

        if slimAudit.entries.isEmpty {
            // Cannot remmap without Mach-Os in EmbeddedPayload (live open often EPERM).
            if hasEncryptedSource {
                throw DecryptError(
                    "EmbeddedPayload has no Mach-Os after slim embed. EncryptedSource.ipa is present — "
                        + "re-run Get so the Store IPA is unpacked into EmbeddedPayload (not live-install-only)."
                )
            }
            throw DecryptError("No Mach-Os in \(name).app — cannot build companion EmbeddedPayload.")
        }
        if let expected = sourceEncrypted, slimAudit.encrypted < expected {
            progress?(
                "Slim embed has \(slimAudit.encrypted)/\(expected) encrypted Mach-Os — re-Get from full Store IPA if remmap EPERM."
            )
        }
        if let expectedCount = sourceMachOCount, slimAudit.entries.count < expectedCount {
            progress?(
                "Note: slim embed has \(slimAudit.entries.count)/\(expectedCount) Mach-Os from \(sourceLabel) (live install is the FairPlay path)."
            )
        }

        // Prefer dest Info.plist, then source tree, then known/handoff stamps / IPA peek.
        let embeddedBundleID: String = {
            if let info = NSDictionary(contentsOf: dest.appendingPathComponent("Info.plist")) as? [String: Any],
               let b = (info["CFBundleIdentifier"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !b.isEmpty {
                return b
            }
            if let info = NSDictionary(contentsOf: srcApp.appendingPathComponent("Info.plist")) as? [String: Any],
               let b = (info["CFBundleIdentifier"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !b.isEmpty {
                return b
            }
            let known = (knownBundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !known.isEmpty { return known }
            // Prefer encrypted-IPA stamp / IPA peek over a prior live stamp (avoids wrong-app bid).
            if let stamped = DecryptCompanionHandoff.readEncryptedIPAPath()?.bundleID, !stamped.isEmpty {
                return stamped
            }
            if hasEncryptedSource, let fromIPA = IPadnIPAPackager.bundleID(fromIPA: bundledIPA) {
                return fromIPA
            }
            if let stamp = DecryptCompanionHandoff.readTargetStamp(), !stamp.bundleID.isEmpty {
                return stamp.bundleID
            }
            if let stamped = DecryptCompanionHandoff.readLiveInstallPath()?.bundleID, !stamped.isEmpty {
                return stamped
            }
            return ""
        }()
        var meta: [String: Any] = [
            "name": name,
            "embeddedAt": ISO8601DateFormatter().string(from: Date()),
            "hostBundle": Bundle.main.bundleIdentifier ?? "",
            "source": sourceLabel,
            "machOs": sourceMachOCount ?? slimAudit.entries.count,
            "encryptedMachOs": sourceEncrypted ?? slimAudit.encrypted,
            "clearMachOs": sourceEncrypted == nil ? slimAudit.clear : sourceClear,
            "plainMachOs": sourceEncrypted == nil ? slimAudit.plain : sourcePlain,
            "embeddedMachOs": slimAudit.entries.count,
            "embeddedEncryptedMachOs": slimAudit.encrypted,
            "hostSkippedLiveAudit": liveInstall,
            "slimEmbed": true,
        ]
        guard !embeddedBundleID.isEmpty else {
            throw DecryptError(
                "Couldn't determine bundle ID for \(name). Re-run Get so EmbeddedPayload / Store IPA include Info.plist."
            )
        }
        // Sandbox often hides live-install Info.plist — seed a minimal one so companion
        // console / manifest always have CFBundleIdentifier.
        ensureEmbeddedInfoPlist(
            at: dest,
            bundleID: embeddedBundleID,
            displayName: name,
            srcApp: srcApp,
            progress: progress
        )
        meta["bundleID"] = embeddedBundleID
        // FairPlayed: companion remaps from EmbeddedPayload (own bundle + SC_Info).
        // Live Store path is an optional ownership/diagnostics stamp — never required
        // for packaging (sideloaded helpers often cannot open live Mach-Os anyway).
        if let live = Self.resolveLiveInstallURL(bundleID: embeddedBundleID, preferring: liveInstall ? srcApp : nil) {
            meta["hostLiveInstallPath"] = live.path
            progress?("Live install path (hint): \(live.path)")
            DecryptCompanionHandoff.publishLiveInstallPath(live.path, bundleID: embeddedBundleID)
        } else if let stamped = DecryptCompanionHandoff.readLiveInstallPath(matchingBundleID: embeddedBundleID),
                  FairPlayDecrypt.isLiveAppStoreInstall(URL(fileURLWithPath: stamped.path)) {
            meta["hostLiveInstallPath"] = stamped.path
            progress?("Live install path (kept stamp): \(stamped.path)")
        } else {
            if let stale = DecryptCompanionHandoff.readLiveInstallPath(),
               !DecryptCompanionHandoff.bundleIDsMatch(stale.bundleID, embeddedBundleID) {
                DecryptCompanionHandoff.clearLiveInstallPath()
            }
            progress?(
                "No live App Store path for \(embeddedBundleID) — OK. FairPlay uses EmbeddedPayload (Developer Mode · iOS 17.4+)."
            )
        }
        // Preflight identity pack — helper paints instantly; never embeds FairPlay key blobs.
        let companionRoot = companionApp
        if FileManager.default.fileExists(
            atPath: companionRoot.appendingPathComponent(DecryptCompanionIdentity.targetIconFileName).path
        ) {
            meta["targetIconRelPath"] = DecryptCompanionIdentity.targetIconFileName
        }
        if let main = FairPlayDecrypt.mainExecutableForEmbed(in: dest) {
            let crypt = FairPlayJetsam.largestCryptsize(of: main.path)
            if crypt > 0 {
                meta["largestCryptsize"] = crypt
                progress?(String(format: "Preflight · largest crypt %.1f MB", Double(crypt) / (1024 * 1024)))
            }
        }
        // Prefer App Group stamp; always record bundled EncryptedSource.ipa when present.
        if hasEncryptedSource {
            meta["bundledEncryptedIPA"] = DecryptCompanionHandoff.bundledEncryptedIPAName
            progress?("Companion carries \(DecryptCompanionHandoff.bundledEncryptedIPAName) for FairPlay unpack")
        }
        if let enc = DecryptCompanionHandoff.readEncryptedIPAPath(matchingBundleID: embeddedBundleID) {
            meta["hostEncryptedIPAPath"] = enc.path
            progress?("Stamped encrypted IPA for FairPlay: \(enc.path)")
            if !DecryptCompanionHandoff.encryptedIPADirectoryIsShared {
                progress?(
                    "Warning: encrypted IPA is outside App Group — companion will use bundled EncryptedSource.ipa / EmbeddedPayload."
                )
            }
        } else if FileManager.default.fileExists(atPath: bundledIPA.path) {
            meta["hostEncryptedIPAPath"] = bundledIPA.path
        }
        let fpOpts = FairPlayAdvancedOptions.Resolved.current
        for (k, v) in fpOpts.snapshotFields() {
            meta[k] = v
        }
        if fpOpts.pathDiagnostics {
            progress?("Advanced FairPlay · \(fpOpts.sourceMode.title) · retries \(fpOpts.retryRounds)")
        }
        // Host readiness only — never passwords / PET / store session JSON.
        // Apply snapshot first, then force this run's bid + live path so a stale
        // App Group snap cannot overwrite the target we just packaged.
        let packagedLivePath = (meta["hostLiveInstallPath"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for (k, v) in DecryptCompanionHandoff.hostSnapshot() {
            meta[k] = v
        }
        meta["bundleID"] = embeddedBundleID
        if !packagedLivePath.isEmpty {
            meta["hostLiveInstallPath"] = packagedLivePath
        } else if let stamped = DecryptCompanionHandoff.readLiveInstallPath(matchingBundleID: embeddedBundleID) {
            meta["hostLiveInstallPath"] = stamped.path
        }
        DecryptCompanionHandoff.publishHostSnapshot()
        // Never serialize FairPlay key blobs / passwords into the companion.
        DecryptCompanionHandoff.stripForbiddenSecrets(&meta)
        meta["secrets"] = false
        let manifestURL = embedRoot.appendingPathComponent("manifest.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: meta, format: .xml, options: 0)
        try data.write(to: manifestURL, options: .atomic)
        progress?("Wrote EmbeddedPayload/manifest.plist for \(embeddedBundleID)")
        return name
    }

    /// Host-side live install resolution (DeviceLibrary + FairPlayDecrypt lookup).
    ///
    /// Do **not** require `fileExists` on the FairPlay main binary — sideloaded hosts
    /// often lie / EPERM while fairplayd can still mremap (Roblox). Match KeyGate /
    /// companion stamp trust: live-shaped path is enough.
    private static func resolveLiveInstallURL(bundleID: String, preferring preferred: URL?) -> URL? {
        if let preferred, isLiveAppStoreInstall(preferred) {
            return preferred.resolvingSymlinksInPath().standardizedFileURL
        }
        // Nudge Installed when Native is selected — Installer/KeyGate usually refreshed
        // already; this covers packaging paths that skip the async gate refresh.
        DeviceLibrary.shared.refreshIfStale()
        let known = DeviceLibrary.shared.apps.first {
            $0.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame
        }?.installPath
        // Prefer a stamped matching path before LS/MI (sandbox may hide fileExists).
        if let stamped = DecryptCompanionHandoff.readLiveInstallPath(matchingBundleID: bundleID),
           isLiveAppStoreInstall(URL(fileURLWithPath: stamped.path)) {
            return URL(fileURLWithPath: stamped.path).resolvingSymlinksInPath().standardizedFileURL
        }
        guard let live = FairPlayDecrypt.installedAppURL(bundleID: bundleID, knownPath: known),
              isLiveAppStoreInstall(live) else {
            return nil
        }
        return live.resolvingSymlinksInPath().standardizedFileURL
    }

    /// True when `app` is still under the system App Store container (not a temp Payload
    /// or companion EmbeddedPayload). Shared rules live on FairPlayDecrypt.
    private static func isLiveAppStoreInstall(_ app: URL) -> Bool {
        FairPlayDecrypt.isLiveAppStoreInstall(app)
    }

    /// Write a minimal Info.plist into EmbeddedPayload when the live/Store source
    /// hid CFBundleIdentifier (sandbox) but host already resolved the bid.
    private static func ensureEmbeddedInfoPlist(
        at dest: URL,
        bundleID: String,
        displayName: String,
        srcApp: URL,
        progress: ((String) -> Void)?
    ) {
        let fm = FileManager.default
        let destInfo = dest.appendingPathComponent("Info.plist")
        if let existing = NSDictionary(contentsOf: destInfo) as? [String: Any],
           let bid = (existing["CFBundleIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !bid.isEmpty {
            return
        }
        var dict: [String: Any] = [:]
        if let src = NSDictionary(contentsOf: srcApp.appendingPathComponent("Info.plist")) as? [String: Any] {
            dict = src
        } else if let data = try? Data(contentsOf: destInfo),
                  let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            dict = parsed
        }
        dict["CFBundleIdentifier"] = bundleID
        let existingDisplay = (dict["CFBundleDisplayName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if existingDisplay.isEmpty, !displayName.isEmpty {
            dict["CFBundleDisplayName"] = displayName
        }
        let existingName = (dict["CFBundleName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if existingName.isEmpty, !displayName.isEmpty {
            dict["CFBundleName"] = displayName
        }
        if dict["CFBundleExecutable"] == nil,
           let main = FairPlayDecrypt.mainExecutableForEmbed(in: dest)
            ?? FairPlayDecrypt.mainExecutableForEmbed(in: srcApp) {
            dict["CFBundleExecutable"] = main.lastPathComponent
        }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else {
            return
        }
        try? data.write(to: destInfo, options: .atomic)
        progress?("Seeded EmbeddedPayload Info.plist with \(bundleID)")
    }

    private static func copySlimAppTree(from src: URL, to dest: URL, progress: ((String) -> Void)?) throws {
        let fm = FileManager.default
        // Always Info.plist
        let info = src.appendingPathComponent("Info.plist")
        if fm.fileExists(atPath: info.path) {
            do {
                try fm.copyItem(at: info, to: dest.appendingPathComponent("Info.plist"))
            } catch {
                progress?("Info.plist copy failed: \(error.localizedDescription)")
            }
        } else {
            progress?("Info.plist missing under \(src.lastPathComponent) — will seed from known bundle ID if available")
        }

        // Timeout-safe Mach-O discovery only — never verifyApp on live installs
        // (cryptid probes hang). Companion audits the EmbeddedPayload copy.
        var machos = try FairPlayDecrypt.collectMachOsForCompanion(under: src)
        // Drop known non-binaries that extensionless-root trust may have pulled in (PkgInfo).
        machos = machos.filter { !Self.nonMachOEmbedBasenames.contains($0.lastPathComponent) }
        // Unity / odd shells (e.g. factory.app → executable `factory`) — never leave
        // EmbeddedPayload without the main binary even if magic probing missed it.
        if let main = FairPlayDecrypt.mainExecutableForEmbed(in: src),
           !machos.contains(where: { $0.standardizedFileURL.path == main.standardizedFileURL.path }) {
            machos.insert(main, at: 0)
            progress?("Force-including main executable \(main.lastPathComponent)…")
        }
        if machos.isEmpty {
            progress?(
                "No Mach-Os visible under \(src.lastPathComponent) for slim embed — FairPlay will use the live App Store install."
            )
        } else {
            progress?("Embedding \(machos.count) Mach-O file(s)…")
        }
        var copied = 0
        var skipped: [String] = []
        for file in machos {
            guard let safeRel = relativePath(file, under: src) else {
                skipped.append(file.lastPathComponent)
                progress?("Skipped Mach-O with unresolvable relative path: \(file.lastPathComponent)")
                continue
            }
            let out: URL
            if let secured = FairPlayDecrypt.secureChildURL(root: dest, relative: safeRel) {
                out = secured
            } else if isSafeRelativeEmbedPath(safeRel) {
                // Fallback when symlink-canonicalization disagrees — still refuse `..`.
                out = FairPlayDecrypt.appendingRelativePath(root: dest, relative: safeRel)
                progress?("Embed path fallback for \(safeRel)")
            } else {
                skipped.append(safeRel)
                progress?("Skipped unsafe Mach-O path: \(safeRel)")
                continue
            }
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: out)
            do {
                try fm.copyItem(at: file, to: out)
                copied += 1
            } catch {
                skipped.append(safeRel)
                progress?("Embed copy failed for \(safeRel): \(error.localizedDescription)")
            }
        }
        if copied == 0 {
            // Live-install sandbox often can't copy foreign FairPlay binaries (Flutter
            // Runner.app → skipped Runner/App/Flutter). FairPlay mremaps the *live*
            // Store path — empty EmbeddedPayload is OK when src is that live install
            // or EncryptedSource.ipa is bundled for packaging identity.
            let companionApp = dest.deletingLastPathComponent().deletingLastPathComponent()
            let encryptedSource = companionApp.appendingPathComponent(DecryptCompanionHandoff.bundledEncryptedIPAName)
            let hasSource = fm.fileExists(atPath: encryptedSource.path)
            let live = isLiveAppStoreInstall(src)
            let sample = skipped.prefix(4).joined(separator: ", ")
            if hasSource {
                throw DecryptError(
                    "Slim embed copied 0 Mach-Os\(sample.isEmpty ? "" : " (skipped: \(sample))") but EncryptedSource.ipa is present — unpack the Store IPA into EmbeddedPayload instead of a live-only embed."
                )
            }
            if live {
                throw DecryptError(
                    "Slim embed copied 0 Mach-Os from live \(src.lastPathComponent)\(sample.isEmpty ? "" : " (skipped: \(sample))"). Re-run Get so a Store IPA is downloaded and embedded with SC_Info."
                )
            }
            throw DecryptError(
                "Slim embed copied 0 Mach-Os from \(src.lastPathComponent)\(sample.isEmpty ? "" : " (skipped: \(sample))"). Retry Get from Search so the Store IPA fills EmbeddedPayload."
            )
        }

        // Copy every SC_Info directory tree (main + nested) — report completeness.
        var scDiscovered = 0
        var scCopied = 0
        var scFailed: [String] = []
        if let en = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let dir as URL in en where dir.lastPathComponent == "SC_Info" {
                scDiscovered += 1
                guard let rel = relativePath(dir, under: src) else {
                    scFailed.append(dir.path)
                    progress?("SC_Info path unresolvable under \(src.lastPathComponent)")
                    continue
                }
                let out: URL
                if let secured = FairPlayDecrypt.secureChildURL(root: dest, relative: rel) {
                    out = secured
                } else if isSafeRelativeEmbedPath(rel) {
                    out = FairPlayDecrypt.appendingRelativePath(root: dest, relative: rel)
                } else {
                    scFailed.append(rel)
                    progress?("SC_Info rejected unsafe path: \(rel)")
                    continue
                }
                do {
                    try? fm.removeItem(at: out)
                    try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: dir, to: out)
                    scCopied += 1
                } catch {
                    // Directory copyItem often EPERM on live installs — copy .sinf files by Data.
                    progress?("SC_Info tree copy failed for \(rel) — trying file-by-file…")
                    let before = countSinfs(under: dest)
                    try? forceCopySinfs(from: src, to: dest, progress: nil)
                    if countSinfs(under: dest) > before {
                        scCopied += 1
                    } else {
                        scFailed.append(rel)
                        progress?("SC_Info copy failed for \(rel): \(error.localizedDescription)")
                    }
                }
            }
        }
        if scDiscovered > 0 {
            progress?(
                "SC_Info: \(scCopied)/\(scDiscovered) copied"
                    + (scFailed.isEmpty ? "" : ", \(scFailed.count) failed")
            )
        }
        if countSinfs(under: dest) == 0, countSinfs(under: src) > 0 {
            try? forceCopySinfs(from: src, to: dest, progress: progress)
        }
        // Main executable license material — diagnostic only (don’t abort on nested misses).
        if let main = FairPlayDecrypt.mainExecutableForEmbed(in: src) {
            let mainSC = main.deletingLastPathComponent().appendingPathComponent("SC_Info", isDirectory: true)
            let stagedSC = dest.appendingPathComponent("SC_Info", isDirectory: true)
            if fm.fileExists(atPath: mainSC.path), !fm.fileExists(atPath: stagedSC.path) {
                progress?("Warning: main executable SC_Info missing from EmbeddedPayload after copy.")
            }
        }

        // App icon PNGs so the companion console can show the target (not a placeholder).
        try copyAppIcons(from: src, to: dest)
        // Stamp TargetIcon.png at companion .app root for the target app card (not the top bar).
        writeTargetIcon(from: dest, into: companionAppRoot(fromEmbeddedDest: dest), progress: progress)
    }

    /// `dest` is EmbeddedPayload/<Name>/ → companion .app is two levels up.
    private static func companionAppRoot(fromEmbeddedDest dest: URL) -> URL {
        dest.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Count `.sinf` licenses under an EmbeddedPayload app tree (main + nested).
    private static func countSinfs(under root: URL) -> Int {
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

    /// Pull `SC_Info/**` (and any loose `.sinf`) out of the IPA zip into an unzipped `.app`.
    /// Used when ZIPFoundation `unzipItem` drops licenses that were added via Archive `.update`.
    private static func extractSCInfoEntries(
        fromIPA ipa: URL,
        intoApp app: URL,
        progress: ((String) -> Void)?
    ) throws {
        guard let archive = try? Archive(url: ipa, accessMode: .read) else {
            throw DecryptError("Couldn't reopen Store IPA to extract SC_Info.")
        }
        let fm = FileManager.default
        let appName = app.lastPathComponent
        let prefix = "Payload/\(appName)/"
        var wrote = 0
        for entry in archive {
            let path = IPadnIPAPackager.normalizeIPAEntryPath(entry.path)
            guard path.hasPrefix(prefix) else { continue }
            let rel = String(path.dropFirst(prefix.count))
            let lower = rel.lowercased()
            let isSinf = lower.hasSuffix(".sinf")
            let isSCInfo = lower == "sc_info" || lower.hasPrefix("sc_info/")
                || lower.contains("/sc_info/")
            guard isSinf || isSCInfo else { continue }
            if path.contains("/Watch/") { continue }
            guard let dest = FairPlayDecrypt.secureChildURL(root: app, relative: rel)
                ?? (isSafeRelativeEmbedPath(rel)
                    ? FairPlayDecrypt.appendingRelativePath(root: app, relative: rel)
                    : nil) else { continue }
            if entry.type == .directory {
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            try data.write(to: dest, options: .atomic)
            if isSinf { wrote += 1 }
        }
        progress?("Extracted \(wrote) .sinf from IPA zip into \(appName)")
        guard wrote > 0 else {
            throw DecryptError(
                "Store IPA archive lists licenses but none could be extracted into EmbeddedPayload. Retry Get."
            )
        }
    }

    /// Copy every `SC_Info` directory tree from one app root into another.
    private static func copySCInfoTrees(from src: URL, to dest: URL, progress: ((String) -> Void)?) throws {
        let fm = FileManager.default
        var copied = 0
        guard let en = fm.enumerator(
            at: src,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for case let dir as URL in en where dir.lastPathComponent == "SC_Info" {
            guard let rel = relativePath(dir, under: src) else { continue }
            let out: URL
            if let secured = FairPlayDecrypt.secureChildURL(root: dest, relative: rel) {
                out = secured
            } else if isSafeRelativeEmbedPath(rel) {
                out = FairPlayDecrypt.appendingRelativePath(root: dest, relative: rel)
            } else {
                continue
            }
            do {
                try? fm.removeItem(at: out)
                try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: dir, to: out)
                copied += 1
            } catch {
                progress?("SC_Info seed failed for \(rel): \(error.localizedDescription)")
            }
        }
        if copied > 0 {
            progress?("SC_Info: seeded \(copied) tree(s) from live install")
        }
    }

    /// Read each `.sinf` as Data and write into `dest` — survives copyItem EPERM on live installs.
    private static func forceCopySinfs(
        from src: URL,
        to dest: URL,
        progress: ((String) -> Void)?
    ) throws {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: src,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var wrote = 0
        for case let url as URL in en where url.pathExtension.lowercased() == "sinf" {
            if url.path.contains("/Watch/") { continue }
            guard let rel = relativePath(url, under: src) else { continue }
            let out: URL
            if let secured = FairPlayDecrypt.secureChildURL(root: dest, relative: rel) {
                out = secured
            } else if isSafeRelativeEmbedPath(rel) {
                out = FairPlayDecrypt.appendingRelativePath(root: dest, relative: rel)
            } else {
                continue
            }
            do {
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard !data.isEmpty else { continue }
                try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: out, options: .atomic)
                wrote += 1
            } catch {
                progress?("Force .sinf copy failed for \(rel): \(error.localizedDescription)")
            }
        }
        if wrote > 0 {
            progress?("Force-copied \(wrote) .sinf file(s)")
        }
    }

    /// Best target icon → `TargetIcon.png` on the companion shell (identity pack).
    private static func writeTargetIcon(
        from embeddedApp: URL,
        into companionApp: URL,
        progress: ((String) -> Void)?
    ) {
        let fm = FileManager.default
        let out = companionApp.appendingPathComponent(DecryptCompanionIdentity.targetIconFileName)
        try? fm.removeItem(at: out)
        let pngs = (try? fm.contentsOfDirectory(at: embeddedApp, includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension.lowercased() == "png" } ?? []
        let iconish = pngs.filter {
            $0.lastPathComponent.localizedCaseInsensitiveContains("AppIcon")
                || $0.lastPathComponent.localizedCaseInsensitiveContains("Icon")
        }
        let pool = iconish.isEmpty ? pngs : iconish
        guard let best = pool.max(by: {
            ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }), let img = UIImage(contentsOfFile: best.path),
              let data = resizedPNG(img, side: 120) else {
            return
        }
        try? data.write(to: out, options: .atomic)
        progress?("Identity pack · \(DecryptCompanionIdentity.targetIconFileName)")
    }

    /// Stamp FastDecryptBot home-screen / Settings icons into the companion `.app`.
    private static func writeCompanionIcons(into destApp: URL) {
        let fm = FileManager.default
        guard let source = UIImage(named: companionIconAsset)
            ?? UIImage(named: TetherlessBrand.appIconAsset)
            ?? TetherlessBrand.appIconImage() else {
            return
        }
        let specs: [(name: String, side: CGFloat)] = [
            ("AppIcon60x60@2x.png", 120),
            ("AppIcon60x60@3x.png", 180),
            ("AppIcon76x76@2x~ipad.png", 152),
            ("iTunesArtwork@2x", 1024),
            ("iTunesArtwork", 512),
        ]
        for spec in specs {
            let out = destApp.appendingPathComponent(spec.name)
            try? fm.removeItem(at: out)
            guard let png = resizedPNG(source, side: spec.side) else { continue }
            try? png.write(to: out, options: .atomic)
        }
    }

    private static func resizedPNG(_ image: UIImage, side: CGFloat) -> Data? {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return rendered.pngData()
    }

    private static func copyAppIcons(from src: URL, to dest: URL) throws {
        let fm = FileManager.default
        let info = NSDictionary(contentsOf: src.appendingPathComponent("Info.plist"))
        var names: [String] = []
        if let icons = info?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: files)
        }
        names.append(contentsOf: [
            "AppIcon60x60@2x", "AppIcon60x60@3x", "AppIcon76x76@2x~ipad",
            "iTunesArtwork", "iTunesArtwork@2x", "Icon", "Icon@2x", "Icon-60", "Icon-60@2x", "Icon-60@3x"
        ])
        let pngs = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "png" } ?? []
        var copied = Set<String>()
        for base in names {
            for hit in pngs where hit.deletingPathExtension().lastPathComponent.hasPrefix(base)
                || hit.lastPathComponent.hasPrefix(base) {
                let key = hit.lastPathComponent
                guard copied.insert(key).inserted else { continue }
                let out = dest.appendingPathComponent(key)
                try? fm.removeItem(at: out)
                try? fm.copyItem(at: hit, to: out)
            }
        }
        // Largest AppIcon* / Icon* leftover if plist names missed.
        if copied.isEmpty {
            let iconish = pngs.filter {
                $0.lastPathComponent.localizedCaseInsensitiveContains("AppIcon")
                    || $0.lastPathComponent.localizedCaseInsensitiveContains("Icon")
            }
            if let largest = iconish.max(by: {
                ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    < ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }) {
                let out = dest.appendingPathComponent(largest.lastPathComponent)
                try? fm.copyItem(at: largest, to: out)
            }
        }
    }

    /// Basenames that live at the .app root without an extension but are not Mach-O.
    private static let nonMachOEmbedBasenames: Set<String> = [
        "PkgInfo", "iTunesMetadata", "embedded", "CodeResources"
    ]

    private static func isSafeRelativeEmbedPath(_ rel: String) -> Bool {
        let trimmed = rel.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("/") || trimmed.contains("\0") { return false }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        return !parts.isEmpty && !parts.contains("..") && !parts.contains(".")
    }

    /// Relative path of `file` under `root`, or `nil` when prefixes disagree / escape.
    /// Never flattens to `lastPathComponent` — that can collide nested Frameworks binaries.
    private static func relativePath(_ file: URL, under root: URL) -> String? {
        // Resolve symlinks so live `/var/containers` vs `/private/var/containers` still yields a relative path.
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return nil }
        let rel = String(path.dropFirst(prefix.count))
        // Refuse escapes — never stage files outside the source .app.
        guard !rel.isEmpty, isSafeRelativeEmbedPath(rel) else { return nil }
        return rel
    }

    private static func provisionPlistXML(_ data: Data) -> Data? {
        // .mobileprovision is CMS; plist sits between XML markers.
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return nil }
        guard let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>") else { return nil }
        return Data(text[start.lowerBound..<end.upperBound].utf8)
    }
}

// Companion slim-embed reuses the same Mach-O walk as decrypt (Flutter Runner trust,
// live-install open-fail handling). Do not reintroduce a separate `fp_is_macho` filter.
extension FairPlayDecrypt {
    static func collectMachOsForCompanion(under root: URL) throws -> [URL] {
        try collectMachOs(under: root, progress: nil)
    }

    /// Public hook for slim-embed — CFBundleExecutable (Unity `factory`, Flutter `Runner`, …).
    static func mainExecutableForEmbed(in app: URL) -> URL? {
        mainExecutableURL(in: app)
    }
}
