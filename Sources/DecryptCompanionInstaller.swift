//
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
    @discardableResult
    static func installAndOpen(
        embedding encryptedIPA: URL,
        displayName: String,
        progress: ((String) -> Void)? = nil
    ) async throws -> String {
        progress?("Preparing your signing certificate, device, and App ID…")
        FreeAppleIDSigning.preferAppleIDSigningMethodIfPossible()
        _ = try await FreeAppleIDSigning.ensureDevelopmentCertificate()
        CertificateStore.shared.activatePreferredCertificate(forSigningMethod: "appleid")
        guard let material = try? CertificateStore.shared.activeMaterial() else {
            throw DecryptError(
                "No signing certificate for the companion app. Open Settings › Store Access, sign in with your Apple ID, then Create a development certificate."
            )
        }

        let bundleID = DecryptCompanionPackager.companionBundleID(forProvision: material.provision)
        UserDefaults.standard.set(bundleID, forKey: companionBundleIDKey)

        progress?("Building Tetherless Decrypt companion…")
        let package = try DecryptCompanionPackager.buildCompanionIPA(
            embedding: encryptedIPA,
            bundleID: bundleID,
            progress: progress
        )
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
        progress?("Open in Tetherless Decrypt…")

        // Give installd a beat, then hand off.
        try? await Task.sleep(nanoseconds: 800_000_000)
        let opened = await openCompanion(bundleID: entry.bundleID, embeddedName: package.embeddedAppName)
        if !opened {
            progress?("Installed — open “Tetherless Decrypt” from the Home Screen to finish.")
        }
        return entry.bundleID
    }

    @discardableResult
    static func openCompanion(bundleID: String, embeddedName: String) async -> Bool {
        // Prefer LaunchServices open by companion bundle id — the host also
        // registers tetherless-decrypt:// for in-app UI, so URL open can bounce
        // back into TetherLess instead of the installed companion.
        if openApplication(bundleID: bundleID) {
            return true
        }
        var comps = URLComponents()
        comps.scheme = DecryptCompanionPackager.companionURLScheme
        comps.host = "run"
        comps.queryItems = [
            URLQueryItem(name: "name", value: embeddedName),
            URLQueryItem(name: "bundle", value: bundleID),
        ]
        if let url = comps.url {
            return await UIApplication.shared.open(url)
        }
        return false
    }

    private static func openApplication(bundleID: String) -> Bool {
        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type else {
            return false
        }
        let selDefault = NSSelectorFromString("defaultWorkspace")
        guard workspaceClass.responds(to: selDefault),
              let workspace = workspaceClass.perform(selDefault)?.takeUnretainedValue() as? NSObject else {
            return false
        }
        let selOpen = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: selOpen) else { return false }
        _ = workspace.perform(selOpen, with: bundleID)
        return true
    }
}
