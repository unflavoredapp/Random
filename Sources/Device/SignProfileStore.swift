//
//  SignProfileStore.swift
//  Remembers the signing options each app was signed with, so auto-updates are
//  signed exactly the same way: same bundle ID (even a randomized one), name,
//  icon, injected dylibs, entitlement edits and strip/patch toggles.
//
//  Not carried over: binary patches, the Mcrypted data blob and the AVX512
//  manifest — those are tied to one specific binary and would corrupt a new build.
//

import Foundation

struct SignProfile: Codable, Equatable {
    var signedBundleID: String      // bundle ID the app was installed with (what the update must reuse)
    var sourceBundleID: String      // bundle ID inside the original IPA (what the sources list)
    var sourceVersion: String       // version of the IPA that was signed
    var name: String?
    var iconPNG: Data?
    var dylibs: [Dylib] = []
    var injectPath = "@executable_path"
    var injectFolder = "/"
    var removeDylibs: [String] = []
    var plistSet: [String: String] = [:]
    var entitlementsPlistData: Data?
    var forceMinIOS: String?
    var disableFileSharing = false, forcePortrait = false, skipIPad = false, disableATS = false
    var stripSCInfo = false, stripPrivacyManifests = false, stripWatchApps = false, stripExtensions = false
    var removeURLSchemes = false, stripBitcode = false, stripDebugSymbols = false
    var autoFixEntitlements = false, disablePush = false, disableAppGroups = false
    var disableiCloud = false, disableSiri = false, disableBackgroundModes = false
    var skipEmbeddedProvision = false
    var surgicalMode = true, parallelSigning = true

    struct Dylib: Codable, Equatable { var relPath: String; var weak: Bool }
}

@MainActor
final class SignProfileStore {
    static let shared = SignProfileStore()
    private let indexURL = AppPaths.dir("sign-profiles").appendingPathComponent("index.json")
    private var profiles: [String: SignProfile] = [:]   // keyed by signedBundleID

    private init() {
        if let d = try? Data(contentsOf: indexURL),
           let p = try? JSONDecoder().decode([String: SignProfile].self, from: d) { profiles = p }
    }

    func profile(forSigned bundleID: String) -> SignProfile? { profiles[bundleID] }

    func setSourceVersion(_ version: String, forSigned bundleID: String) {
        guard var p = profiles[bundleID] else { return }
        p.sourceVersion = version
        profiles[bundleID] = p
        persist()
    }

    /// Call right after a successful sign with the exact options used.
    func save(options o: SignOptions, signedBundleID: String, sourceBundleID: String, sourceVersion: String) {
        let folder = AppPaths.dir("sign-profiles").appendingPathComponent(Self.safe(signedBundleID), isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var dylibs: [SignProfile.Dylib] = []
        for (i, d) in o.injectDylibs.enumerated() {
            let rel = "\(Self.safe(signedBundleID))/\(i)-\(d.url.lastPathComponent)"
            let dest = AppPaths.dir("sign-profiles").appendingPathComponent(rel)
            if (try? FileManager.default.copyItem(at: d.url, to: dest)) != nil { dylibs.append(.init(relPath: rel, weak: d.weak)) }
        }
        var p = SignProfile(signedBundleID: signedBundleID, sourceBundleID: sourceBundleID, sourceVersion: sourceVersion,
                            name: o.name, iconPNG: o.iconPNG, dylibs: dylibs)
        p.injectPath = o.injectPath; p.injectFolder = o.injectFolder; p.removeDylibs = o.removeDylibs
        p.plistSet = o.plistSet; p.entitlementsPlistData = o.entitlementsPlistData; p.forceMinIOS = o.forceMinIOS
        p.disableFileSharing = o.disableFileSharing; p.forcePortrait = o.forcePortrait
        p.skipIPad = o.skipIPad; p.disableATS = o.disableATS
        p.stripSCInfo = o.stripSCInfo; p.stripPrivacyManifests = o.stripPrivacyManifests
        p.stripWatchApps = o.stripWatchApps; p.stripExtensions = o.stripExtensions
        p.removeURLSchemes = o.removeURLSchemes; p.stripBitcode = o.stripBitcode; p.stripDebugSymbols = o.stripDebugSymbols
        p.autoFixEntitlements = o.autoFixEntitlements; p.disablePush = o.disablePush
        p.disableAppGroups = o.disableAppGroups; p.disableiCloud = o.disableiCloud
        p.disableSiri = o.disableSiri; p.disableBackgroundModes = o.disableBackgroundModes
        p.skipEmbeddedProvision = o.skipEmbeddedProvision
        p.surgicalMode = o.surgicalMode; p.parallelSigning = o.parallelSigning
        profiles[signedBundleID] = p
        persist()
    }

    /// Options for re-signing a newer build of the same app.
    func options(for p: SignProfile, newVersion: String, fallbackName: String) -> SignOptions {
        var o = SignOptions()
        o.name = p.name ?? fallbackName
        o.bundleID = p.signedBundleID          // reuse exactly — a new random suffix would install as a different app
        o.version = newVersion
        o.iconPNG = p.iconPNG
        o.injectDylibs = p.dylibs.compactMap {
            let url = AppPaths.dir("sign-profiles").appendingPathComponent($0.relPath)
            return FileManager.default.fileExists(atPath: url.path) ? (url, $0.weak) : nil
        }
        o.injectPath = p.injectPath; o.injectFolder = p.injectFolder; o.removeDylibs = p.removeDylibs
        o.plistSet = p.plistSet; o.entitlementsPlistData = p.entitlementsPlistData; o.forceMinIOS = p.forceMinIOS
        o.disableFileSharing = p.disableFileSharing; o.forcePortrait = p.forcePortrait
        o.skipIPad = p.skipIPad; o.disableATS = p.disableATS
        o.stripSCInfo = p.stripSCInfo; o.stripPrivacyManifests = p.stripPrivacyManifests
        o.stripWatchApps = p.stripWatchApps; o.stripExtensions = p.stripExtensions
        o.removeURLSchemes = p.removeURLSchemes; o.stripBitcode = p.stripBitcode; o.stripDebugSymbols = p.stripDebugSymbols
        o.autoFixEntitlements = p.autoFixEntitlements; o.disablePush = p.disablePush
        o.disableAppGroups = p.disableAppGroups; o.disableiCloud = p.disableiCloud
        o.disableSiri = p.disableSiri; o.disableBackgroundModes = p.disableBackgroundModes
        o.skipEmbeddedProvision = p.skipEmbeddedProvision
        o.surgicalMode = p.surgicalMode; o.parallelSigning = p.parallelSigning
        return o
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(profiles) { try? d.write(to: indexURL) }
    }

    private static func safe(_ s: String) -> String {
        s.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
    }
}
