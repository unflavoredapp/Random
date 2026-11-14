//
//  DecryptCompanionPackager.swift
//  Builds a real second app (“Tetherless Decrypt”) bundled from this process:
//  clone our executable + Frameworks, embed the encrypted target under
//  EmbeddedPayload/ (FairPlayed layout), zip → IPA. Main app then signs with
//  the user’s Apple ID cert, installs, and opens it — competition companion flow.
//

import Foundation
import UIKit
import ZIPFoundation

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
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("tl-companion-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { /* keep until caller finishes signing; cleaned by OS tmp */ }

        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        let app = payload.appendingPathComponent("\(companionDisplayName).app", isDirectory: true)
        try fm.createDirectory(at: app, withIntermediateDirectories: true)

        progress?("Preparing companion app shell…")
        try cloneHostApp(into: app, bundleID: bundleID, progress: progress)

        progress?("Extracting bundle…")
        let embedName = try embedEncryptedApp(from: encryptedIPA, into: app, progress: progress)

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
        // Explicit App ID — .decrypt sibling under the same prefix.
        if let lastDot = rest.lastIndex(of: ".") {
            return String(rest[..<lastDot]) + ".decrypt"
        }
        return rest + ".decrypt"
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
            "UILaunchScreen": [String: Any](),
            "UIRequiredDeviceCapabilities": ["arm64"],
            "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
            "CFBundleURLTypes": [[
                "CFBundleURLName": "dev.tetherless.decrypt",
                "CFBundleURLSchemes": [companionURLScheme, "tetherless"]
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
        let name = srcApp.deletingPathExtension().lastPathComponent
        progress?("Found embedded app: \(name)")

        let embedRoot = companionApp.appendingPathComponent("EmbeddedPayload", isDirectory: true)
        let dest = embedRoot.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: embedRoot, withIntermediateDirectories: true)
        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        // Full-IPA DRM inventory before slim — companion refuses if embed drops encrypted Mach-Os.
        progress?("Auditing FairPlay DRM on full IPA…")
        try? fm.removeItem(at: srcApp.appendingPathComponent("Watch"))
        let fullAudit = try FairPlayDecrypt.verifyApp(at: srcApp)
        progress?(
            "Full IPA · \(fullAudit.entries.count) Mach-O(s) · \(fullAudit.encrypted) encrypted · \(fullAudit.clear) clear"
        )
        for e in fullAudit.entries where e.isEncrypted {
            progress?("[DRM] \(e.path) · cryptid=\(e.cryptid)")
        }
        if fullAudit.entries.isEmpty {
            throw DecryptError("No Mach-Os in \(name).app — cannot build companion EmbeddedPayload.")
        }

        // Slim embed: Mach-Os + SC_Info + Info.plist (FairPlayed needs SINFs next to binaries;
        // full asset trees blow up the companion install — competition stayed ~hundreds of MB).
        progress?("Copying app bundle (Mach-Os + SC_Info)…")
        try copySlimAppTree(from: srcApp, to: dest, progress: progress)

        // FairPlayed: remove Watch — not decryptable on iPhone.
        try? fm.removeItem(at: dest.appendingPathComponent("Watch"))

        let staged = FairPlayDecrypt.replicateSinfs(in: dest)
        if staged > 0 {
            progress?("Replicated \(staged) nested SINF license(s)…")
        }

        // Ensure slim embed kept every encrypted Mach-O from the full IPA.
        let slimAudit = try FairPlayDecrypt.verifyApp(at: dest)
        progress?(
            "EmbeddedPayload · \(slimAudit.entries.count) Mach-O(s) · \(slimAudit.encrypted) encrypted"
        )
        if slimAudit.encrypted < fullAudit.encrypted {
            throw DecryptError(
                "Companion embed dropped FairPlay binaries (\(slimAudit.encrypted) encrypted vs \(fullAudit.encrypted) in full IPA). Aborting."
            )
        }
        if slimAudit.entries.count < fullAudit.entries.count {
            progress?(
                "Note: slim embed has \(slimAudit.entries.count)/\(fullAudit.entries.count) Mach-Os (extras were already clear / non-DRM)."
            )
        }

        // Seed manifest so companion can re-check expected DRM coverage at runtime.
        let meta: [String: Any] = [
            "name": name,
            "embeddedAt": ISO8601DateFormatter().string(from: Date()),
            "hostBundle": Bundle.main.bundleIdentifier ?? "",
            "machOs": fullAudit.entries.count,
            "encryptedMachOs": fullAudit.encrypted,
            "clearMachOs": fullAudit.clear,
            "plainMachOs": fullAudit.plain,
            "embeddedMachOs": slimAudit.entries.count,
            "embeddedEncryptedMachOs": slimAudit.encrypted,
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: meta, format: .xml, options: 0) {
            try? data.write(to: embedRoot.appendingPathComponent("manifest.plist"))
        }
        return name
    }

    private static func copySlimAppTree(from src: URL, to dest: URL, progress: ((String) -> Void)?) throws {
        let fm = FileManager.default
        // Always Info.plist
        let info = src.appendingPathComponent("Info.plist")
        if fm.fileExists(atPath: info.path) {
            try fm.copyItem(at: info, to: dest.appendingPathComponent("Info.plist"))
        }

        // Prefer every Mach-O `verifyApp` found (full DRM coverage), then fall back to
        // structured discovery if verify somehow returned empty.
        var machos: [URL] = []
        var seen = Set<String>()
        if let audit = try? FairPlayDecrypt.verifyApp(at: src) {
            for e in audit.entries {
                let file = src.appendingPathComponent(e.path)
                let key = file.standardizedFileURL.path
                guard !seen.contains(key), fm.fileExists(atPath: file.path) else { continue }
                seen.insert(key)
                machos.append(file)
            }
        }
        if machos.isEmpty {
            machos = (try? FairPlayDecrypt.collectMachOsForCompanion(under: src)) ?? []
        }
        progress?("Embedding \(machos.count) Mach-O file(s)…")
        for file in machos {
            let rel = relative(file, under: src)
            let out = dest.appendingPathComponent(rel)
            try fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: out)
            try fm.copyItem(at: file, to: out)
        }

        // Copy every SC_Info directory tree (main + nested).
        if let en = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let dir as URL in en where dir.lastPathComponent == "SC_Info" {
                let rel = relative(dir, under: src)
                let out = dest.appendingPathComponent(rel)
                try? fm.removeItem(at: out)
                try? fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.copyItem(at: dir, to: out)
            }
        }
    }

    private static func relative(_ file: URL, under root: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        if file.path.hasPrefix(prefix) { return String(file.path.dropFirst(prefix.count)) }
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

// Expose Mach-O discovery for the packager without making the whole FairPlay API public surface noisy.
extension FairPlayDecrypt {
    static func collectMachOsForCompanion(under root: URL) throws -> [URL] {
        // Reuse private collectMachOs via a thin wrapper by calling decrypt path helpers.
        // We duplicate the structured walk here to avoid changing access control on collectMachOs.
        let fm = FileManager.default
        var out: [URL] = []
        var seen = Set<String>()

        func consider(_ url: URL?) {
            guard let url else { return }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return }
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return }
            let ok = url.path.withCString { fp_is_macho($0) }
            guard ok else { return }
            seen.insert(path)
            out.append(url)
        }

        func exe(in bundle: URL) -> URL? {
            let info = NSDictionary(contentsOf: bundle.appendingPathComponent("Info.plist")) as? [String: Any]
            let name = (info?["CFBundleExecutable"] as? String)
                ?? bundle.deletingPathExtension().lastPathComponent
            let url = bundle.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }
            return url
        }

        func frameworks(in container: URL, depth: Int = 0) {
            guard depth < 4 else { return }
            let dir = container.appendingPathComponent("Frameworks", isDirectory: true)
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            for item in items {
                let ext = item.pathExtension.lowercased()
                if ext == "framework" {
                    consider(exe(in: item))
                    frameworks(in: item, depth: depth + 1)
                } else if ext == "dylib" {
                    consider(item)
                }
            }
        }

        consider(exe(in: root))
        frameworks(in: root)
        for folder in ["PlugIns", "Extensions"] {
            let dir = root.appendingPathComponent(folder, isDirectory: true)
            if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for item in items where item.pathExtension.lowercased() == "appex" {
                    consider(exe(in: item))
                    frameworks(in: item)
                }
            }
        }
        // Skip Watch + App Clips — same hang/soft policy as FairPlayDecrypt.collectMachOs.
        return out
    }
}
