//
// Brand: Tetherless · https://tetherless.dev
//  DecryptCompanionInstaller.swift
//  Sign + install the companion “Tetherless Decrypt” app with the user’s Apple ID
//  certificate (trust in Settings › General › VPN & Device Management on first run),
//  then open it so FairPlay runs inside the companion bundle (EmbeddedPayload).
//

import Foundation
import UIKit

@MainActor
enum DecryptCompanionInstaller {
    static let companionBundleIDKey = "tetherless.decrypt.companionBundleID"

    /// Full competition pipeline: embed encrypted IPA → sign companion → install → open.
    /// The FairPlay console UI runs only inside the installed companion IPA.
    @discardableResult
    static func installAndOpen(
        embedding encryptedIPA: URL,
        displayName: String,
        progress: ((String) -> Void)? = nil
    ) async throws -> String {
        try await installAndOpen(displayName: displayName, progress: progress) { bundleID, progress in
            try DecryptCompanionPackager.buildCompanionIPA(
                embedding: encryptedIPA,
                bundleID: bundleID,
                progress: progress
            )
        }
    }

    /// Same pipeline, embedding a live App Store install when no store IPA is on hand.
    @discardableResult
    static func installAndOpen(
        embeddingInstalledApp installedApp: URL,
        displayName: String,
        progress: ((String) -> Void)? = nil
    ) async throws -> String {
        try await installAndOpen(displayName: displayName, progress: progress) { bundleID, progress in
            try DecryptCompanionPackager.buildCompanionIPA(
                embeddingInstalledApp: installedApp,
                bundleID: bundleID,
                progress: progress
            )
        }
    }

    private static func installAndOpen(
        displayName: String,
        progress: ((String) -> Void)?,
        build: (_ bundleID: String, _ progress: ((String) -> Void)?) throws -> DecryptCompanionPackager.Package
    ) async throws -> String {
        progress?("Preparing your signing certificate, device, and App ID…")
        FreeAppleIDSigning.preferAppleIDSigningMethodIfPossible()
        _ = try await FreeAppleIDSigning.ensureDevelopmentCertificate()
        CertificateStore.shared.activatePreferredCertificate(forSigningMethod: "appleid")
        guard let material = try? CertificateStore.shared.activeMaterial() else {
            throw DecryptError(
                "No signing certificate for the companion app. Sign in under Account, then retry — a free development certificate is created automatically when possible."
            )
        }

        let bundleID = DecryptCompanionPackager.companionBundleID(forProvision: material.provision)
        UserDefaults.standard.set(bundleID, forKey: companionBundleIDKey)

        progress?("Building Tetherless Decrypt companion…")
        let package = try build(bundleID, progress)
        let sizeMB = Double(package.approximateBytes) / 1_048_576.0
        progress?(String(format: "Companion package · %.0f MB", sizeMB))

        progress?("Signing Tetherless Decrypt with your Apple ID…")
        var options = SignOptions()
        options.name = DecryptCompanionPackager.companionDisplayName
        options.bundleID = bundleID
        options.surgicalMode = false
        options.parallelSigning = false
        options.autoFixEntitlements = true
        options.disableAppGroups = false
        options.stripWatchApps = true
        options.stripExtensions = true // companion shell doesn't need host appexes
        options.removeURLSchemes = false

        let outcome = try await Signer.signDetached(
            ipaURL: package.ipaURL,
            material: material,
            options: options,
            onLog: nil
        )
        progress?("Signed \(DecryptCompanionPackager.companionDisplayName).")

        progress?("Uploading to iPhone…")
        let hold = "companion-\(UUID().uuidString)"
        if NativeInstaller.isSelected { BackgroundKeepAlive.shared.start(hold) }
        defer { BackgroundKeepAlive.shared.stop(hold) }

        let entry = try SignedStore.shared.add(
            outcome: outcome,
            icon: nil,
            certName: material.name
        )
        NativeInstaller.registerOriginal(package.ipaURL, forSigned: entry.ipaURL)

        do {
            if NativeInstaller.isSelected {
                try await NativeInstaller.shared.install(
                    ipaURL: entry.ipaURL,
                    bundleID: entry.bundleID,
                    name: entry.name,
                    version: entry.version
                )
            } else {
                try await OTAInstaller.shared.install(entry)
            }
        } catch {
            // Autopilot may flip method; retry once.
            if InstallAutopilot.fallbackToOTAIfNeeded(error: error) {
                try await OTAInstaller.shared.install(entry)
            } else {
                throw DecryptError(
                    "Couldn't install Tetherless Decrypt (\(error.localizedDescription)). After install, open Settings › General › VPN & Device Management and Trust your Apple ID, then retry."
                )
            }
        }

        progress?("Verifying…")
        progress?("Trust this Apple ID in Settings › General › VPN & Device Management if iOS asks.")
        progress?("Opening Tetherless Decrypt companion…")

        // Host must not keep a fake companion sheet — the console UI is the separate IPA.
        DecryptCompanionController.shared.dismiss()

        // Give installd a beat, then hand off.
        try? await Task.sleep(nanoseconds: 800_000_000)
        let opened = await openCompanion(bundleID: entry.bundleID, embeddedName: package.embeddedAppName)
        if !opened {
            progress?(
                "Installed — open “Tetherless Decrypt” from the Home Screen (Trust your Apple ID under Settings › General › VPN & Device Management if iOS asks)."
            )
        }
        return entry.bundleID
    }

    @discardableResult
    static func openCompanion(bundleID: String, embeddedName: String) async -> Bool {
        // Prefer the companion URL scheme — UIApplication.open reports real success.
        // LS openApplicationWithBundleID: does not return a reliable Bool.
        var comps = URLComponents()
        comps.scheme = DecryptCompanionPackager.companionURLScheme
        comps.host = "run"
        comps.queryItems = [
            URLQueryItem(name: "name", value: embeddedName),
            URLQueryItem(name: "bundle", value: bundleID),
        ]
        if let url = comps.url {
            if await UIApplication.shared.open(url) {
                return true
            }
        }
        // Best-effort LaunchServices kick — do not claim success from a void perform.
        openApplicationBestEffort(bundleID: bundleID)
        // Honest signal: scheme registered means companion is installed (Trust may still block).
        if let probe = URL(string: "\(DecryptCompanionPackager.companionURLScheme)://") {
            return UIApplication.shared.canOpenURL(probe)
        }
        return false
    }

    private static func openApplicationBestEffort(bundleID: String) {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return
        }
        let selDefault = NSSelectorFromString("defaultWorkspace")
        guard workspaceClass.responds(to: selDefault),
              let workspace = workspaceClass.perform(selDefault)?.takeUnretainedValue() as? NSObject else {
            return
        }
        let selOpen = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: selOpen) else { return }
        _ = workspace.perform(selOpen, with: bundleID)
    }
}
