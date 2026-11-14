//
//  FreeAppleIDSigning.swift
//  Ensures a free Apple ID 7-day development certificate is created, imported,
//  linked, and selected for SigningSheet / SignQueue installs.
//

import Foundation
import UIKit

@MainActor
enum FreeAppleIDSigning {
    /// Prefer Apple ID signing whenever a Store Access account can use a free/dev cert.
    static func preferAppleIDSigningMethodIfPossible() {
        guard AppleIDStore.shared.activeAccount != nil else { return }
        UserDefaults.standard.set("appleid", forKey: "uzd_signing_method")
        AppleIDStore.shared.activatePreferredSigningCertificate()
        CertificateStore.shared.activatePreferredCertificate(forSigningMethod: "appleid")
    }

    /// Create/link a development certificate when missing, register this device, and activate it.
    @discardableResult
    static func ensureDevelopmentCertificate() async throws -> Certificate {
        if let id = AppleIDStore.shared.preferredSigningCertificateID(),
           let existing = CertificateStore.shared.certificates.first(where: { $0.id == id }) {
            CertificateStore.shared.activeID = existing.id
            preferAppleIDSigningMethodIfPossible()
            return existing
        }

        var auth = AppleIDStore.shared.portalSession()
        if auth == nil || AppleIDStore.shared.activeAccount == nil {
            throw AppleAuthError.message("Sign in under Settings › Store Access first.")
        }
        // Refresh stale portal sessions before creating a cert.
        do {
            _ = try await DeveloperPortalClient.shared.listTeams(auth: auth!)
        } catch {
            if AppleIDStore.isPortalSessionExpired(error) {
                auth = try await AppleIDStore.shared.refreshPortalSession()
            } else {
                throw error
            }
        }
        guard let auth else {
            throw AppleAuthError.message("Sign in under Settings › Store Access first.")
        }

        let teams = try await DeveloperPortalClient.shared.listTeams(auth: auth)
        guard let team = teams.first else {
            throw AppleAuthError.message("No developer team on this Apple ID.")
        }

        // Register this iPhone when we know the UDID (Pair / Certificates).
        if let udid = CertificateStore.knownUDID()
            ?? (try? DevicePairingStore.load())?.device_udid,
           !udid.isEmpty {
            CertificateStore.setKnownUDID(udid)
            do {
                _ = try await DeveloperPortalClient.shared.addDevice(
                    udid: udid,
                    name: UIDevice.current.name,
                    auth: auth,
                    team: team
                )
            } catch let e as AppleAuthError {
                if case .portal(35, _) = e { /* already registered */ }
                else { /* non-fatal for cert create */ }
            } catch {
                // Non-fatal — profile download may still succeed.
            }
        }

        let created = try await DeveloperPortalClient.shared.createDevelopmentCertificate(
            machineName: UIDevice.current.name,
            auth: auth,
            team: team
        )
        var appIDs = (try? await DeveloperPortalClient.shared.listAppIDs(auth: auth, team: team)) ?? []
        var appID = appIDs.first
        if appID == nil {
            let bid = "com.tetherless.\(UUID().uuidString.prefix(8).lowercased()).*"
            appID = try await DeveloperPortalClient.shared.addAppID(
                bundleID: bid,
                name: "TetherLess Free",
                auth: auth,
                team: team
            )
            if let appID { appIDs = [appID] }
        }
        guard let appID else {
            throw AppleAuthError.message("Couldn't create an App ID for the free signing profile.")
        }
        let profileData = try await DeveloperPortalClient.shared.downloadDevelopmentProfile(
            appID: appID, auth: auth, team: team
        )
        let cert = try importCertPEM(
            created.certPEM,
            keyPEM: created.privateKeyPEM,
            name: created.certificate.name,
            provision: profileData
        )
        AppleIDStore.shared.linkCertificate(cert.id)
        preferAppleIDSigningMethodIfPossible()
        return cert
    }

    @discardableResult
    static func importCertPEM(
        _ certPEM: Data,
        keyPEM: Data,
        name: String,
        provision: Data
    ) throws -> Certificate {
        let password = "tetherless"
        var outPtr: UnsafeMutablePointer<UInt8>?
        var outLen: Int = 0
        var errBuf = [CChar](repeating: 0, count: 256)
        let rc = certPEM.withUnsafeBytes { certBytes in
            keyPEM.withUnsafeBytes { keyBytes in
                tl_pkcs12_from_pem(
                    certBytes.bindMemory(to: UInt8.self).baseAddress,
                    certBytes.count,
                    keyBytes.bindMemory(to: UInt8.self).baseAddress,
                    keyBytes.count,
                    password,
                    &outPtr,
                    &outLen,
                    &errBuf,
                    errBuf.count
                )
            }
        }
        defer { if let outPtr { tl_pkcs12_free(outPtr) } }
        guard rc == 0, let outPtr, outLen > 0 else {
            let msg = String(cString: errBuf)
            throw AppleAuthError.message("PKCS#12 build failed: \(msg.isEmpty ? "unknown" : msg)")
        }
        let p12 = Data(bytes: outPtr, count: outLen)
        return try CertificateStore.shared.importPair(
            name: name,
            p12: p12,
            password: password,
            provision: provision,
            makeActive: true
        )
    }
}
