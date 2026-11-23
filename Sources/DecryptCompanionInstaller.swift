//
// Brand: Tetherless · https://tetherless.dev
//  DecryptCompanionInstaller.swift
//  Sign + install the companion “FastDecryptBot” app with the user’s Apple ID
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
        // Resolve target bid *before* clearing foreign stamps.
        let bid = DecryptCompanionHandoff.readEncryptedIPAPath()?.bundleID
            ?? Self.bundleIDHint(fromEncryptedIPAFileName: encryptedIPA)
            ?? ""
        DecryptCompanionHandoff.beginTargetWorkflow(bundleID: bid)
        // Re-stamp the encrypted IPA temp URL so FairPlay / companion can capture it.
        if FileManager.default.fileExists(atPath: encryptedIPA.path) {
            DecryptCompanionHandoff.publishEncryptedIPAPath(encryptedIPA.path, bundleID: bid)
            progress?("Stamped encrypted IPA for FairPlay: \(encryptedIPA.path)")
        }
        return try await installAndOpen(displayName: displayName, progress: progress) { bundleID, progress in
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
        // Publish before packaging so the companion can FairPlay-mremap this live path
        // even if open(2) of the FairPlay binary EPERMs under the host (Roblox).
        let info = NSDictionary(contentsOf: installedApp.appendingPathComponent("Info.plist")) as? [String: Any]
        let bid = (info?["CFBundleIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        DecryptCompanionHandoff.beginTargetWorkflow(bundleID: bid)
        if !bid.isEmpty {
            DecryptCompanionHandoff.publishLiveInstallPath(installedApp.path, bundleID: bid)
        }
        return try await installAndOpen(displayName: displayName, progress: progress) { bundleID, progress in
            try DecryptCompanionPackager.buildCompanionIPA(
                embeddingInstalledApp: installedApp,
                bundleID: bundleID,
                progress: progress
            )
        }
    }

    /// `retainEncryptedIPA` names files `bundleID_display.ipa` — recover bid without unzipping.
    private static func bundleIDHint(fromEncryptedIPAFileName ipa: URL) -> String? {
        let base = ipa.deletingPathExtension().lastPathComponent
        guard let under = base.firstIndex(of: "_") else { return nil }
        let prefix = String(base[..<under]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefix.contains("."), prefix != "app" else { return nil }
        return prefix
    }

    private static func installAndOpen(
        displayName: String,
        progress: ((String) -> Void)?,
        build: (_ bundleID: String, _ progress: ((String) -> Void)?) throws -> DecryptCompanionPackager.Package
    ) async throws -> String {
        // Step 1 — never package/open companion until Media & Purchases ack is on record.
        progress?("1/7 · Confirming FairPlay keys on this iPhone…")
        let keyEmail = try FairPlayKeyGate.confirmReadyForCompanion { msg in
            progress?("1/7 · \(msg)")
        }
        _ = keyEmail

        progress?("2/7 · Preparing signing certificate (Apple ID, then custom)…")
        let material = try await resolveCompanionSigningMaterial(progress: progress)

        let bundleID = try DecryptCompanionPackager.companionBundleID(forProvision: material.provision)
        UserDefaults.standard.set(bundleID, forKey: companionBundleIDKey)

        progress?("3/7 · Embedding \(displayName) (slim Mach-Os + SC_Info)…")
        let package = try build(bundleID, progress)
        defer { package.cleanupWorkDirectory() }
        let sizeMB = Double(package.approximateBytes) / 1_048_576.0
        progress?(String(format: "Companion package · %.0f MB", sizeMB))

        progress?("4/7 · Signing FastDecryptBot with \(material.name)…")
        var options = SignOptions()
        options.name = DecryptCompanionPackager.companionDisplayName
        options.bundleID = bundleID
        options.surgicalMode = false
        options.parallelSigning = false
        options.autoFixEntitlements = true
        // Seed from profile so scrubbers can strip host-only entitlements (groups/push/iCloud).
        if let xml = xmlPlistData(fromMobileProvision: material.provision),
           let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
           let ents = plist["Entitlements"] as? [String: Any],
           let data = try? PropertyListSerialization.data(fromPropertyList: ents, format: .xml, options: 0) {
            options.entitlementsPlistData = data
        }
        // Free/dev profiles rarely grant host App Groups — leaving them on → 0xe8008016.
        options.disableAppGroups = !Self.provisionAllowsAppGroup(
            material.provision,
            group: TetherlessBrand.appGroup
        )
        options.disablePush = true
        options.disableiCloud = true
        options.disableSiri = true
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

        progress?("5/7 · Installing on this iPhone…")
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
                    "Couldn't install FastDecryptBot (\(error.localizedDescription)). After install, open Settings › General › VPN & Device Management and Trust your Apple ID, then retry."
                )
            }
        }

        progress?("6/7 · Trust Apple ID under Settings › General › VPN & Device Management if asked…")
        progress?("7/7 · Opening FastDecryptBot…")

        // Host must not keep a fake companion sheet — the console UI is the separate IPA.
        DecryptCompanionController.shared.dismiss()

        // Give installd a beat, then hand off.
        try? await Task.sleep(nanoseconds: 800_000_000)
        let installedID = try smokeVerifyCompanionBundleID(
            provisionDerived: bundleID,
            signedEntry: entry.bundleID
        )
        let opened = await openCompanion(bundleID: installedID, embeddedName: package.embeddedAppName)
        if !opened {
            DecryptCompanionHandoff.markPendingOpen(
                bundleID: installedID,
                embeddedName: package.embeddedAppName
            )
            progress?(
                "Installed — Trust your Apple ID under Settings › General › VPN & Device Management, then return here (we’ll reopen FastDecryptBot)."
            )
            DecryptCompanionHandoff.openTrustSettings()
        } else {
            DecryptCompanionHandoff.clearPendingOpen()
            // Soft probe: scheme should resolve once Trust + install finished.
            if let probe = URL(string: "\(DecryptCompanionPackager.companionURLScheme)://"),
               !UIApplication.shared.canOpenURL(probe) {
                progress?("Companion opened — if FairPlay doesn’t start, Trust the Apple ID under VPN & Device Management.")
            }
        }
        return installedID
    }

    /// Post-install consistency check: provision ID, signed entry, and UserDefaults must agree.
    private static func smokeVerifyCompanionBundleID(
        provisionDerived: String,
        signedEntry: String
    ) throws -> String {
        let provision = provisionDerived.trimmingCharacters(in: .whitespacesAndNewlines)
        let signed = signedEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !signed.isEmpty else {
            throw DecryptError("Companion install finished without a bundle ID.")
        }
        if !provision.isEmpty, provision != signed {
            throw DecryptError(
                "Companion bundle ID mismatch (profile \(provision) vs signed \(signed)). Retry install."
            )
        }
        UserDefaults.standard.set(signed, forKey: companionBundleIDKey)
        let persisted = (UserDefaults.standard.string(forKey: companionBundleIDKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard persisted == signed else {
            throw DecryptError("Couldn't persist companion bundle ID for reopen.")
        }
        return signed
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

    /// Prefer free 7-day Apple ID cert; fall back to paid / imported .p12 + provision
    /// (same path when portal sign-in isn’t available yet).
    private static func resolveCompanionSigningMaterial(
        progress: ((String) -> Void)?
    ) async throws -> CertMaterial {
        var appleIDError: String?
        FreeAppleIDSigning.preferAppleIDSigningMethodIfPossible()
        do {
            _ = try await FreeAppleIDSigning.ensureDevelopmentCertificate()
            CertificateStore.shared.activatePreferredCertificate(forSigningMethod: "appleid")
            if let material = try? CertificateStore.shared.activeMaterial() {
                progress?("Using Apple ID certificate: \(material.name)")
                return material
            }
        } catch {
            appleIDError = error.localizedDescription
            progress?("Apple ID cert unavailable — trying custom certificate…")
        }

        CertificateStore.shared.activatePreferredCertificate(forSigningMethod: "saved")
        if let material = try? CertificateStore.shared.activeMaterial() {
            progress?("Using custom certificate: \(material.name)")
            return material
        }

        // Last resort: first non-expired imported cert.
        for cert in CertificateStore.shared.certificates {
            let info = CertificateStore.shared.cachedProfileInfo(for: cert)
            guard !info.isExpired else { continue }
            CertificateStore.shared.activeID = cert.id
            if let material = try? CertificateStore.shared.activeMaterial() {
                progress?("Using certificate: \(material.name)")
                return material
            }
        }

        var msg = "No signing certificate for FastDecryptBot. Sign in under Account to create a free 7-day Apple ID cert, or import a .p12 + mobileprovision under Account › Settings › Installation › Certificate."
        if let appleIDError, !appleIDError.isEmpty {
            msg += " (Apple ID: \(appleIDError))"
        }
        throw DecryptError(msg)
    }

    /// True when the provisioning profile grants the given App Group.
    private static func provisionAllowsAppGroup(_ provision: Data, group: String) -> Bool {
        guard let s = String(data: provision, encoding: .isoLatin1),
              let a = s.range(of: "<?xml"), let b = s.range(of: "</plist>") else { return false }
        let xml = String(s[a.lowerBound..<b.upperBound])
        guard let d = xml.data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any],
              let ents = plist["Entitlements"] as? [String: Any] else { return false }
        let groups = ents["com.apple.security.application-groups"] as? [String] ?? []
        return groups.contains(group)
    }
}
