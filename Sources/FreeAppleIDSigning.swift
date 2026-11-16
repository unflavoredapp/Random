//
// Brand: Tetherless · https://tetherless.dev
//  FreeAppleIDSigning.swift
//  SideSign / SideStore-style free Apple ID 7-day development certificate:
//  GrandSlam portal session → list/revoke orphan portal certs → CSR create →
//  register device → wildcard App ID → development profile → import p12.
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
    /// Mirrors SideStore `CertificateProvisioningFlow`: fetch portal certs, replace orphans, then CSR.
    @discardableResult
    static func ensureDevelopmentCertificate() async throws -> Certificate {
        if let id = AppleIDStore.shared.preferredSigningCertificateID(),
           let existing = CertificateStore.shared.certificates.first(where: { $0.id == id }),
           !(CertificateStore.shared.cachedProfileInfo(for: existing).isExpired) {
            CertificateStore.shared.activeID = existing.id
            preferAppleIDSigningMethodIfPossible()
            return existing
        }

        let auth = try await resolvePortalSession()
        let teams = try await DeveloperPortalClient.shared.listTeams(auth: auth)
        guard let team = teams.first else {
            throw AppleAuthError.message("No development teams for this Apple ID.")
        }

        try await registerThisDeviceIfPossible(auth: auth, team: team)

        // SideSign: list portal certs first. Free accounts get one Development cert —
        // if Apple already has one we don't have a private key for, revoke then recreate.
        let portalCerts = (try? await DeveloperPortalClient.shared.listCertificates(auth: auth, team: team)) ?? []
        if !portalCerts.isEmpty {
            let linkedIDs = Set(AppleIDStore.shared.activeAccount?.linkedCertificateIDs ?? [])
            let localIDs = Set(CertificateStore.shared.certificates.map(\.id))
            let orphans = portalCerts.filter { !linkedIDs.contains($0.id) && !localIDs.contains($0.id) }
            if !orphans.isEmpty {
                for cert in orphans {
                    try? await DeveloperPortalClient.shared.revokeCertificate(cert, auth: auth, team: team)
                }
            }
        }

        let created = try await createDevelopmentCertificateSideSignStyle(auth: auth, team: team)

        var appIDs = (try? await DeveloperPortalClient.shared.listAppIDs(auth: auth, team: team)) ?? []
        // Prefer a wildcard App ID that can cover the companion `.decrypt` bundle ID.
        var appID = preferredWildcardAppID(from: appIDs)
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

    // MARK: - SideSign-style portal steps

    /// Store MZFinance login is not enough — Developer Portal needs GrandSlam / Xcode tokens.
    private static func resolvePortalSession() async throws -> AppleAuthSession {
        if AppleIDStore.shared.activeAccount == nil {
            throw AppleAuthError.message("Sign in under Account first.")
        }
        var auth = AppleIDStore.shared.portalSession()
        if auth == nil {
            // SideSign always establishes a Developer Services session from the Apple ID.
            auth = try await AppleIDStore.shared.refreshPortalSession()
        }
        guard let session = auth else {
            throw AppleAuthError.message("Sign in under Account first (Developer Portal session required for the 7-day certificate).")
        }
        // Probe with fresh anisette; renew GrandSlam on expiry / 1100 / 1200-ish auth failures.
        do {
            _ = try await DeveloperPortalClient.shared.listTeams(auth: session)
            return session
        } catch {
            if AppleIDStore.isPortalSessionExpired(error)
                || isPortalAuthBlocked(error) {
                return try await AppleIDStore.shared.refreshPortalSession()
            }
            throw error
        }
    }

    private static func isPortalAuthBlocked(_ error: Error) -> Bool {
        if case AppleAuthError.portal(let code, _) = error {
            // 1100 session; 1200 not allowed often clears after re-auth + revoke orphan certs.
            return code == 1100 || code == 1200 || code == -22406
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("1100") || text.contains("not allowed to perform")
    }

    private static func registerThisDeviceIfPossible(auth: AppleAuthSession, team: Team) async throws {
        guard let udid = CertificateStore.knownUDID()
            ?? (try? DevicePairingStore.load())?.device_udid,
              !udid.isEmpty else {
            // SideSign can still create the cert without UDID; profile download may lack this device.
            return
        }
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
            else { throw e }
        }
    }

    /// CSR submit with SideSign replace semantics: on 35/7460/1200 revoke portal Development
    /// certs we can't use, then create once more.
    private static func createDevelopmentCertificateSideSignStyle(
        auth: AppleAuthSession,
        team: Team
    ) async throws -> (certPEM: Data, privateKeyPEM: Data, certificate: DevCertificate, csr: CSRBuilder.Result) {
        do {
            return try await DeveloperPortalClient.shared.createDevelopmentCertificate(
                machineName: UIDevice.current.name,
                auth: auth,
                team: team
            )
        } catch let AppleAuthError.portal(code, _) where code == 7460 || code == 35 || code == 1200 {
            let existing = (try? await DeveloperPortalClient.shared.listCertificates(auth: auth, team: team)) ?? []
            for cert in existing {
                try? await DeveloperPortalClient.shared.revokeCertificate(cert, auth: auth, team: team)
            }
            // Brief pause so Apple's free-tier slot frees before the replacement CSR.
            try? await Task.sleep(nanoseconds: 800_000_000)
            do {
                return try await DeveloperPortalClient.shared.createDevelopmentCertificate(
                    machineName: UIDevice.current.name,
                    auth: auth,
                    team: team
                )
            } catch {
                throw AppleAuthError.message(
                    "Couldn't create a free 7-day development certificate after clearing the portal slot (\(error.localizedDescription)). Sign out and back in under Account, then retry — same flow as SideStore/SideSign."
                )
            }
        }
    }

    /// Prefer wildcard App IDs (`*` / `prefix.*`) so companion + host share one free profile.
    private static func preferredWildcardAppID(from appIDs: [DevAppID]) -> DevAppID? {
        let wildcards = appIDs.filter {
            $0.bundleID == "*" || $0.bundleID.hasSuffix(".*")
        }
        if let tetherless = wildcards.first(where: {
            $0.bundleID.localizedCaseInsensitiveContains("tetherless")
        }) {
            return tetherless
        }
        return wildcards.first
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
