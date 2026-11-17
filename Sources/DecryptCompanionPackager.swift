//
// Brand: Tetherless · https://tetherless.dev
//  DecryptCompanionPackager.swift
//  Builds a real second app (“Tetherless Decrypt”) bundled from this process:
//  clone our executable + Frameworks, embed the encrypted target under
//  EmbeddedPayload/ (FairPlayed layout), zip → IPA. Main app then signs with
//  the user’s Apple ID cert, installs, and opens it — competition companion flow.
//

import Foundation
import UIKit
import ZIPFoundation

/// Companion packaging runs on the main actor (called from `DecryptCompanionInstaller`)
/// so host FairPlay-ack snapshots can read `AppStoreDecryptGuide` safely.
@MainActor
enum DecryptCompanionPackager {
    static let companionBundleIDFallback = "dev.tetherless.decrypt"
    static let companionDisplayName = "Tetherless Decrypt"
    static let companionURLScheme = "tetherless-decrypt"

    struct Package: Sendable {
        let ipaURL: URL
        let bundleID: String
        let displayName: String
        let embeddedAppName: String
        let approximateBytes: Int64
    }

    /// Build an unsigned companion IPA ready for SignEngine.
    /// - Parameters:
    ///   - encryptedIPA: App Store IPA (or any FairPlay-encrypted IPA) to embed.
    ///   - bundleID: Must match the signing profile (wildcard-friendly).
    static func buildCompanionIPA(
        embedding encryptedIPA: URL,
        bundleID: String,
        progress: ((String) -> Void)? = nil
    ) throws -> Package {
        try buildCompanionIPA(bundleID: bundleID, progress: progress) { app, progress in
            progress?("Extracting bundle…")
            return try embedEncryptedApp(from: encryptedIPA, into: app, progress: progress)
        }
    }

    /// Same companion shell, embedding a live App Store install (Mach-Os + SC_Info)
    /// when a store IPA isn’t available yet.
    static func buildCompanionIPA(
        embeddingInstalledApp installedApp: URL,
        bundleID: String,
        progress: ((String) -> Void)? = nil
    ) throws -> Package {
        try buildCompanionIPA(bundleID: bundleID, progress: progress) { app, progress in
            progress?("Embedding installed app…")
            return try embedInstalledApp(from: installedApp, into: app, progress: progress)
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
        let ipa = work.appendingPathComponent("TetherlessDecrypt-unsigned.ipa")
        try? fm.removeItem(at: ipa)
        try fm.zipItem(at: payload, to: ipa, shouldKeepParent: true, compressionMethod: .deflate)

        let attrs = try fm.attributesOfItem(atPath: ipa.path)
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        return Package(
            ipaURL: ipa,
            bundleID: bundleID,
            displayName: companionDisplayName,
            embeddedAppName: embedName,
            approximateBytes: bytes
        )
    }

    /// Pick a companion bundle ID that fits the active provisioning profile.
    static func companionBundleID(forProvision provision: Data) -> String {
        guard let xml = provisionPlistXML(provision),
              let plist = try? PropertyListSerialization.propertyList(from: xml, options: [], format: nil) as? [String: Any],
              let ents = plist["Entitlements"] as? [String: Any],
              let appID = ents["application-identifier"] as? String else {
            return companionBundleIDFallback
        }
        // TEAMID.*              → hostBundle.decrypt (free Apple ID wildcard)
        // TEAMID.com.example.*  → com.example.decrypt
        // TEAMID.com.example.app → com.example.decrypt (sibling)
        let parts = appID.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return companionBundleIDFallback }
        let rest = parts[1]
        let host = Bundle.main.bundleIdentifier ?? companionBundleIDFallback
        let hostDecrypt: String = {
            if host.hasSuffix(".decrypt") { return host }
            return host + ".decrypt"
        }()
        if rest == "*" || rest == ".*" {
            return hostDecrypt
        }
        if rest.hasSuffix(".*") {
            let prefix = String(rest.dropLast(2))
            return prefix.isEmpty ? hostDecrypt : prefix + ".decrypt"
        }
        if rest.contains("*") {
            let replaced = rest.replacingOccurrences(of: "*", with: "decrypt")
            return replaced.isEmpty ? hostDecrypt : replaced
        }
        // Explicit App ID — must use the profile’s exact bundle ID.
        // Inventing a `.decrypt` sibling causes installd 0xe8008016 (invalid entitlements).
        return rest
    }

    // MARK: - Host clone

    private static func cloneHostApp(
        into destApp: URL,
        bundleID: String,
        progress: ((String) -> Void)?
    ) throws {
        let fm = FileManager.default
        let host = Bundle.main

        guard let exeURL = host.executableURL else {
            throw DecryptError("Couldn't locate TetherLess executable to clone into the companion.")
        }
        let exeName = exeURL.lastPathComponent
        progress?("Cloning TetherLess binary into companion…")
        try fm.copyItem(at: exeURL, to: destApp.appendingPathComponent(exeName))

        // Shared Frameworks the host links (SwiftUI / third-party SPM dylibs live here).
        if let fw = host.privateFrameworksURL ?? host.url(forResource: "Frameworks", withExtension: nil),
           fm.fileExists(atPath: fw.path) {
            progress?("Copying Frameworks into companion…")
            let destFW = destApp.appendingPathComponent("Frameworks", isDirectory: true)
            try? fm.createDirectory(at: destFW, withIntermediateDirectories: true)
            if let items = try? fm.contentsOfDirectory(at: fw, includingPropertiesForKeys: nil) {
                for item in items {
                    let out = destFW.appendingPathComponent(item.lastPathComponent)
                    try? fm.removeItem(at: out)
                    try? fm.copyItem(at: item, to: out)
                }
            }
        }
        // Also try Bundle.main.bundleURL/Frameworks (common layout).
        let hostFW = host.bundleURL.appendingPathComponent("Frameworks", isDirectory: true)
        if fm.fileExists(atPath: hostFW.path) {
            let destFW = destApp.appendingPathComponent("Frameworks", isDirectory: true)
            try? fm.createDirectory(at: destFW, withIntermediateDirectories: true)
            if let items = try? fm.contentsOfDirectory(at: hostFW, includingPropertiesForKeys: nil) {
                for item in items {
                    let out = destFW.appendingPathComponent(item.lastPathComponent)
                    if !fm.fileExists(atPath: out.path) {
                        try? fm.copyItem(at: item, to: out)
                    }
                }
            }
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
            // Only the companion owns tetherless-decrypt:// — host must not register
            // that scheme or iOS may reopen TetherLess instead of this IPA.
            "CFBundleURLTypes": [[
                "CFBundleURLName": "dev.tetherless.decrypt",
                "CFBundleURLSchemes": [companionURLScheme]
            ]],
            // Marker so runtime knows this install is the companion role.
            "TLCompanionRole": true,
            "TLCompanionHostBundle": host.bundleIdentifier ?? "dev.tetherless.app",
        ]
        let infoURL = destApp.appendingPathComponent("Info.plist")
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try data.write(to: infoURL, options: .atomic)

        // PkgInfo keeps some installd paths happy.
        try Data("APPL????".utf8).write(to: destApp.appendingPathComponent("PkgInfo"), options: .atomic)

        // Best-effort icon so SpringBoard isn’t a blank tile.
        for name in ["AppIcon60x60@2x.png", "AppIcon76x76@2x~ipad.png", "iTunesArtwork", "iTunesArtwork@2x"] {
            let src = host.bundleURL.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                try? fm.copyItem(at: src, to: destApp.appendingPathComponent(name))
            }
        }
        for folder in ["Assets.car", "Base.lproj"] {
            let src = host.bundleURL.appendingPathComponent(folder)
            if fm.fileExists(atPath: src.path) {
                let out = destApp.appendingPathComponent(folder)
                try? fm.removeItem(at: out)
                try? fm.copyItem(at: src, to: out)
            }
        }
    }

    // MARK: - FairPlayed EmbeddedPayload

    /// Stage encrypted app under EmbeddedPayload/<Name>/ (no .app suffix), strip Watch,
    /// replicate SINFs — same contract as FairPlayed `embed_ipa.sh`.
    @discardableResult
    private static func embedEncryptedApp(
        from ipa: URL,
        into companionApp: URL,
        progress: ((String) -> Void)?
    ) throws -> String {
        let fm = FileManager.default
        let extract = companionApp.deletingLastPathComponent()
            .appendingPathComponent("embed-src-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: extract, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extract) }

        try fm.unzipItem(at: ipa, to: extract)
        let payload = extract.appendingPathComponent("Payload", isDirectory: true)
        guard let srcApp = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw DecryptError("No Payload/*.app in the encrypted IPA to embed.")
        }
        // Free Apple ID certs strip App Groups — host Documents stamps are invisible to the
        // companion (Roblox/CARROT/TestFlight EPERM screenshots). Always embed the IPA.
        try Self.bundleEncryptedSourceIPA(ipa, into: companionApp, progress: progress)
        return try stageEmbeddedPayload(from: srcApp, into: companionApp, sourceLabel: "full IPA", progress: progress)
    }

    /// Copy the Store IPA into the companion `.app` as `EncryptedSource.ipa` (required when App Group is stripped).
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
                "Couldn't bundle EncryptedSource.ipa for FairPlay (\(error.localizedDescription)). Free certs can't use App Group stamps — re-run Get with enough free storage."
            )
        }
        let bytes = (try? fm.attributesOfItem(atPath: bundled.path)[.size] as? Int64) ?? 0
        guard bytes > 1_000_000 else {
            throw DecryptError("EncryptedSource.ipa is too small (\(bytes) bytes) — Store download looks incomplete. Retry Get.")
        }
        progress?(
            "Bundled EncryptedSource.ipa for FairPlay (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))) — companion can unpack without App Group."
        )
    }

    /// Slim-embed a live `/Bundle/Application/…/*.app` install into EmbeddedPayload.
    @discardableResult
    private static func embedInstalledApp(
        from installedApp: URL,
        into companionApp: URL,
        progress: ((String) -> Void)?
    ) throws -> String {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: installedApp.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw DecryptError("Installed app path missing: \(installedApp.lastPathComponent).")
        }
        // Live-install embed still needs EncryptedSource.ipa when App Group is stripped.
        if let stamped = DecryptCompanionHandoff.readEncryptedIPAPath() {
            let src = URL(fileURLWithPath: stamped.path)
            if FileManager.default.fileExists(atPath: src.path) {
                try? Self.bundleEncryptedSourceIPA(src, into: companionApp, progress: progress)
            }
        }
        return try stageEmbeddedPayload(
            from: installedApp,
            into: companionApp,
            sourceLabel: "install path",
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

        try? fm.removeItem(at: srcApp.appendingPathComponent("Watch"))

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

        // Audit the copied EmbeddedPayload (safe — not the live install container).
        let slimAudit = try FairPlayDecrypt.verifyApp(at: dest)
        progress?(
            "EmbeddedPayload · \(slimAudit.entries.count) Mach-O(s) · \(slimAudit.encrypted) encrypted"
        )
        if slimAudit.entries.isEmpty {
            throw DecryptError("No Mach-Os in \(name).app — cannot build companion EmbeddedPayload.")
        }
        if let expected = sourceEncrypted, slimAudit.encrypted < expected {
            throw DecryptError(
                "Companion embed dropped FairPlay binaries (\(slimAudit.encrypted) encrypted vs \(expected) in \(sourceLabel)). Aborting."
            )
        }
        if let expectedCount = sourceMachOCount, slimAudit.entries.count < expectedCount {
            // Encrypted IPA full decrypt needs every Mach-O in EmbeddedPayload — don't
            // silently ship a slim tree that will produce a fake PARTIAL later.
            if !liveInstall, slimAudit.encrypted > 0 {
                throw DecryptError(
                    "Companion embed dropped Mach-Os (\(slimAudit.entries.count)/\(expectedCount) from \(sourceLabel)). Re-run Get so the full encrypted IPA is stamped."
                )
            }
            progress?(
                "Note: slim embed has \(slimAudit.entries.count)/\(expectedCount) Mach-Os (extras were already clear / non-DRM)."
            )
        }

        let embeddedBundleID: String? = {
            let info = NSDictionary(contentsOf: dest.appendingPathComponent("Info.plist")) as? [String: Any]
            let raw = (info?["CFBundleIdentifier"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty == false) ? raw : nil
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
        if let embeddedBundleID, !embeddedBundleID.isEmpty {
            meta["bundleID"] = embeddedBundleID
            // Companion sandbox often cannot LS/MI-lookup other apps. Host resolves the
            // live Store path (Pair / LaunchServices) and stamps it into the manifest so
            // FairPlay mremap can read from a path fairplayd accepts (Roblox EPERM).
            if let live = Self.resolveLiveInstallURL(bundleID: embeddedBundleID, preferring: liveInstall ? srcApp : nil) {
                meta["hostLiveInstallPath"] = live.path
                progress?("Stamped live install for FairPlay: \(live.path)")
                // Also publish via App Group so the companion can recover the path if
                // LS/MI still can't see the app at decrypt time (Roblox mremap EPERM).
                DecryptCompanionHandoff.publishLiveInstallPath(live.path, bundleID: embeddedBundleID)
            } else {
                progress?(
                    "No live App Store install for \(embeddedBundleID) — FairPlay will use stamped encrypted IPA / EmbeddedPayload."
                )
                DecryptCompanionHandoff.clearLiveInstallPath()
            }
        }
        // Prefer App Group stamp; always record bundled EncryptedSource.ipa when present.
        let bundledIPA = companionApp.appendingPathComponent(DecryptCompanionHandoff.bundledEncryptedIPAName)
        if FileManager.default.fileExists(atPath: bundledIPA.path) {
            meta["bundledEncryptedIPA"] = DecryptCompanionHandoff.bundledEncryptedIPAName
            progress?("Companion carries \(DecryptCompanionHandoff.bundledEncryptedIPAName) for FairPlay unpack")
        }
        if let enc = DecryptCompanionHandoff.readEncryptedIPAPath() {
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
        for (k, v) in DecryptCompanionHandoff.hostSnapshot() {
            meta[k] = v
        }
        DecryptCompanionHandoff.publishHostSnapshot()
        if let data = try? PropertyListSerialization.data(fromPropertyList: meta, format: .xml, options: 0) {
            try? data.write(to: embedRoot.appendingPathComponent("manifest.plist"))
        }
        return name
    }

    /// Host-side live install resolution (DeviceLibrary + FairPlayDecrypt lookup).
    private static func resolveLiveInstallURL(bundleID: String, preferring preferred: URL?) -> URL? {
        if let preferred, isLiveAppStoreInstall(preferred),
           Self.liveMainExecutableStampable(at: preferred) {
            return preferred.resolvingSymlinksInPath().standardizedFileURL
        }
        let known = DeviceLibrary.shared.apps.first(where: { $0.bundleID == bundleID })?.installPath
        guard let live = FairPlayDecrypt.installedAppURL(bundleID: bundleID, knownPath: known),
              isLiveAppStoreInstall(live),
              Self.liveMainExecutableStampable(at: live) else {
            return nil
        }
        return live.resolvingSymlinksInPath().standardizedFileURL
    }

    /// True when a live Store `.app` has a main executable on disk worth stamping for
    /// companion FairPlay. Do **not** require `isReadableFile` / `FileHandle` open —
    /// FairPlay binaries often EPERM on open(2) under a sideloaded host even when
    /// fairplayd can still mremap them (Roblox). The companion already treats existence
    /// as enough and falls back to EmbeddedPayload if mremap fails.
    private static func liveMainExecutableStampable(at app: URL) -> Bool {
        guard let main = FairPlayDecrypt.mainExecutableForEmbed(in: app) else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: main.path, isDirectory: &isDir)
            && !isDir.boolValue
    }

    /// True when `app` is still under the system App Store container (not a temp Payload
    /// or companion EmbeddedPayload). Shared rules live on FairPlayDecrypt.
    private static func isLiveAppStoreInstall(_ app: URL) -> Bool {
        FairPlayDecrypt.isLiveAppStoreInstall(app)
    }

    private static func copySlimAppTree(from src: URL, to dest: URL, progress: ((String) -> Void)?) throws {
        let fm = FileManager.default
        // Always Info.plist
        let info = src.appendingPathComponent("Info.plist")
        if fm.fileExists(atPath: info.path) {
            try fm.copyItem(at: info, to: dest.appendingPathComponent("Info.plist"))
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
        guard !machos.isEmpty else {
            throw DecryptError("No Mach-Os found under \(src.lastPathComponent) for companion embed.")
        }
        progress?("Embedding \(machos.count) Mach-O file(s)…")
        var copied = 0
        var skipped: [String] = []
        for file in machos {
            let rel = relative(file, under: src)
            let safeRel = rel.isEmpty ? file.lastPathComponent : rel
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
            let sample = skipped.prefix(4).joined(separator: ", ")
            throw DecryptError(
                "Slim embed copied 0 Mach-Os from \(src.lastPathComponent)\(sample.isEmpty ? "" : " (skipped: \(sample))"). Refusing empty EmbeddedPayload."
            )
        }

        // Copy every SC_Info directory tree (main + nested).
        if let en = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let dir as URL in en where dir.lastPathComponent == "SC_Info" {
                let rel = relative(dir, under: src)
                guard let out = FairPlayDecrypt.secureChildURL(root: dest, relative: rel) else { continue }
                try? fm.removeItem(at: out)
                try? fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: dir, to: out)
            }
        }

        // App icon PNGs so the companion console can show the target (not a placeholder).
        try copyAppIcons(from: src, to: dest)
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

    private static func relative(_ file: URL, under root: URL) -> String {
        // Resolve symlinks so live `/var/containers` vs `/private/var/containers` still yields a relative path.
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix(prefix) {
            let rel = String(path.dropFirst(prefix.count))
            // Refuse escapes — never stage files outside the source .app.
            if rel.contains("..") { return file.lastPathComponent }
            return rel
        }
        // Last resort: rebuild relative path from lastPathComponent chain when prefixes disagree.
        if path.hasSuffix("/" + file.lastPathComponent) || path.hasSuffix(file.lastPathComponent) {
            return file.lastPathComponent
        }
        return file.lastPathComponent
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
