//
//  DecryptPipeline.swift
//  One-tap Decrypt → free Apple ID Sign → Install (Native or OTA autopilot).
//

import Foundation
import IDeviceSwift
import SwiftUI

@MainActor
final class DecryptPipeline: ObservableObject {
    static let shared = DecryptPipeline()

    enum Stage: Equatable {
        case idle
        case decrypting(String)
        case preparingCert
        case signing(String)
        case installing(String)
        case done(String)
        case failed(String)
    }

    @Published private(set) var stage: Stage = .idle
    @Published private(set) var busy = false

    var statusText: String {
        switch stage {
        case .idle: return ""
        case .decrypting(let s): return s
        case .preparingCert: return "Preparing free Apple ID certificate…"
        case .signing(let s): return s
        case .installing(let s): return s
        case .done(let s): return s
        case .failed(let s): return s
        }
    }

    private init() {}

    /// Full pipeline from a Store search result / owned app.
    func run(app: DecryptApp, version: String? = nil, externalVersionId: String? = nil) {
        guard !busy else { return }
        busy = true
        stage = .decrypting("Decrypting \(app.name)…")
        if !app.countryCode.isEmpty {
            AppleIDStore.shared.selectAccountMatching(countryCode: app.countryCode)
        }
        DecryptClient.shared.select(app)
        DecryptClient.shared.phase = .running
        DecryptClient.shared.message = "Pipeline: decrypt…"
        DecryptClient.shared.error = nil

        Task {
            defer { busy = false }
            do {
                _ = InstallAutopilot.apply()

                let deviceApp = DeviceApp(
                    bundleID: app.bundle.isEmpty ? app.id : app.bundle,
                    name: app.name,
                    version: app.version,
                    isAppStore: true
                )
                await DeviceDecryptService.shared.decryptOwnedStoreApp(
                    deviceApp,
                    storeURL: app.url,
                    version: version,
                    externalVersionId: externalVersionId
                )

                // Companion handoff is a successful terminal state — FairPlay finishes
                // in Tetherless Decrypt; there is no host-side clear IPA to sign.
                if DecryptClient.shared.phase == .handedOff {
                    let name = DecryptClient.shared.finishedName.isEmpty
                        ? app.name
                        : DecryptClient.shared.finishedName
                    stage = .done("Companion installed for \(name) — open Tetherless Decrypt to finish.")
                    if DecryptClient.shared.message.isEmpty {
                        DecryptClient.shared.message =
                            "Open Tetherless Decrypt — Trust your Apple ID under Settings › General › VPN & Device Management if iOS asks."
                    }
                    return
                }

                guard DecryptClient.shared.phase == .done, let ipa = DecryptClient.shared.finished else {
                    throw DecryptError(DecryptClient.shared.error ?? "Decrypt produced no IPA.")
                }
                SideloadIPACache.shared.remember(url: ipa, kind: .decrypted)

                let entry = try await signAndInstall(ipa: ipa, displayName: app.name)
                stage = .done("Installed \(entry.name)")
                DecryptClient.shared.phase = .done
                DecryptClient.shared.message = statusText
                DecryptClient.shared.finished = entry.ipaURL
                DecryptClient.shared.finishedName = entry.name
                AppNav.shared.goLibrary()
            } catch {
                let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                stage = .failed(text)
                DecryptClient.shared.phase = .failed
                DecryptClient.shared.error = text
                DecryptClient.shared.message = text
            }
        }
    }

    func runFinishedIPA(_ url: URL, name: String) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = InstallAutopilot.apply()
                let entry = try await signAndInstall(ipa: url, displayName: name)
                stage = .done("Installed \(entry.name)")
                AppNav.shared.goLibrary()
            } catch {
                stage = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func signAndInstall(ipa: URL, displayName: String) async throws -> SignedEntry {
        stage = .preparingCert
        DecryptClient.shared.message = "Pipeline: certificate…"
        FreeAppleIDSigning.preferAppleIDSigningMethodIfPossible()
        _ = try await FreeAppleIDSigning.ensureDevelopmentCertificate()
        CertificateStore.shared.activatePreferredCertificate(forSigningMethod: "appleid")
        guard let material = try? CertificateStore.shared.activeMaterial() else {
            throw DecryptError("No signing certificate. Open Settings › Store Access › Developer Portal › Create.")
        }

        stage = .signing("Signing \(displayName)…")
        DecryptClient.shared.message = "Pipeline: signing…"
        var options = SignOptions()
        options.surgicalMode = false
        options.parallelSigning = false
        let outcome = try await Signer.signDetached(
            ipaURL: ipa,
            material: material,
            options: options,
            onLog: nil
        )
        let entry = try SignedStore.shared.add(outcome: outcome, icon: nil, certName: material.name)
        NativeInstaller.registerOriginal(ipa, forSigned: entry.ipaURL)
        AppAutoUpdater.shared.recordInstalled(
            bundleID: entry.bundleID,
            name: entry.name,
            version: entry.version
        )
        SideloadIPACache.shared.remember(url: entry.ipaURL, kind: .signed)

        stage = .installing("Installing \(entry.name)…")
        DecryptClient.shared.message = "Pipeline: install…"
        let hold = "pipeline-\(UUID().uuidString)"
        if NativeInstaller.isSelected { BackgroundKeepAlive.shared.start(hold) }
        defer { BackgroundKeepAlive.shared.stop(hold) }

        // Prefer Native when selected + paired; otherwise OTA. Autopilot may flip on failure.
        do {
            if NativeInstaller.isSelected, DevicePairingStore.hasSavedPairing {
                try await NativeInstaller.shared.install(entry)
            } else {
                try await OTAInstaller.shared.install(entry)
            }
        } catch {
            if InstallAutopilot.fallbackToOTAIfNeeded(error: error) {
                try await OTAInstaller.shared.install(entry)
            } else if NativeInstaller.isSelected {
                // Native path failed without autopilot flip — try OTA once.
                try await OTAInstaller.shared.install(entry)
            } else {
                throw error
            }
        }
        return entry
    }
}
