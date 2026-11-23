//
// Brand: AppAssassin · https://fastdecrypt.ai
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
    static func ensureDevelopmentCertificate(forceRefresh: Bool = false) async throws -> Certificate {
        if !forceRefresh,
           let id = AppleIDStore.shared.preferredSigningCertificateID(),
           let existing = CertificateStore.shared.certificates.first(where: { $0.id == id }),
           AppleIDStore.shared.isLinkedAppleIDCertificate(existing),
           !(CertificateStore.shared.cachedProfileInfo(for: existing).isExpired) {
            CertificateStore.shared.activeID = existing.id
            preferAppleIDSigningMethodIfPossible()
            return existing
        }

        var auth = try await resolvePortalSession()
        // listTeams often 1200s on free accounts even with a valid GrandSlam session —
        // never abort Create here; fall back to the remembered team id and keep going.
        var team = try await resolveTeam(auth: auth)

        try await registerThisDeviceIfPossible(auth: auth, team: team)

        // SideSign: list portal certs; free accounts get one Development cert.
        // Match orphans by portal serial / portal id — never local Certificate UUIDs.
        // Always clear every listed cert on free tier up front (SideStore replace).
        let portalCerts = (try? await DeveloperPortalClient.shared.listCertificates(auth: auth, team: team)) ?? []
        if !portalCerts.isEmpty {
            try await revokePortalCertificates(portalCerts, auth: auth, team: team, requireSuccess: false)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }

        let created: (certPEM: Data, privateKeyPEM: Data, certificate: DevCertificate, csr: CSRBuilder.Result)
        created = try await {
            do {
                return try await createDevelopmentCertificateSideSignStyle(auth: auth, team: team)
            } catch {
                // Portal 1200 / session flakes: GrandSlam refresh, clear *all* Development
                // slots (SideStore replace), wait, then create again — up to 3 recovery rounds.
                guard isPortalAuthBlocked(error) || isPortalSlotError(error) else { throw error }
                var lastError: Error = error
                var workingAuth = auth
                var workingTeam = team
                for round in 1...3 {
                    do {
                        workingAuth = try await AppleIDStore.shared.refreshPortalSession()
                        workingTeam = (try? await resolveTeam(auth: workingAuth)) ?? workingTeam
                    } catch {
                        // Still try create with the previous portal session if refresh needs 2FA.
                        if case AppleAuthError.needsTwoFactor = error { throw error }
                        lastError = error
                    }
                    let again = (try? await DeveloperPortalClient.shared.listCertificates(
                        auth: workingAuth, team: workingTeam
                    )) ?? []
                    // Free tier: clear every listed Development cert so CSR can take the slot.
                    if !again.isEmpty {
                        try await revokePortalCertificates(
                            again, auth: workingAuth, team: workingTeam, requireSuccess: false
                        )
                    }
                    try? await Task.sleep(nanoseconds: UInt64(2_000_000_000 * round))
                    do {
                        let made = try await createDevelopmentCertificateSideSignStyle(
                            auth: workingAuth, team: workingTeam
                        )
                        auth = workingAuth
                        team = workingTeam
                        return made
                    } catch {
                        lastError = error
                    }
                }
                auth = workingAuth
                team = workingTeam
                throw AppleAuthError.message(
                    "Couldn't create a free 7-day certificate after clearing the portal slot. Sign out and back in under Account, then tap Create again — or import a custom .p12 + mobileprovision under Certificate."
                )
            }
        }()

        var appIDs = (try? await DeveloperPortalClient.shared.listAppIDs(auth: auth, team: team)) ?? []
        var appID = preferredWildcardAppID(from: appIDs)
        if appID == nil {
            let bid = "com.fastdecrypt.\(UUID().uuidString.prefix(8).lowercased()).*"
            do {
                appID = try await DeveloperPortalClient.shared.addAppID(
                    bundleID: bid,
                    name: "AppAssassin Free",
                    auth: auth,
                    team: team
                )
            } catch {
                // App ID create can also return 1200 on free accounts when quota is weird —
                // fall back to any existing wildcard / first App ID.
                appIDs = (try? await DeveloperPortalClient.shared.listAppIDs(auth: auth, team: team)) ?? []
                appID = preferredWildcardAppID(from: appIDs) ?? appIDs.first
                if appID == nil { throw error }
            }
            if let appID { appIDs = [appID] }
        }
        guard let appID else {
            throw AppleAuthError.message("Couldn't create an App ID for the free signing profile.")
        }
        let profileData = try await DeveloperPortalClient.shared.downloadDevelopmentProfile(
            appID: appID, auth: auth, team: team
        )
        // Retire previous linked free certs so preference can't stick on an expired p12.
        retirePreviousLinkedCertificates(keepingPortalSerial: created.certificate.serialNumber)
        let cert = try importCertPEM(
            created.certPEM,
            keyPEM: created.privateKeyPEM,
            name: created.certificate.name,
            provision: profileData,
            portalSerialNumber: created.certificate.serialNumber,
            portalCertificateID: created.certificate.id
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
            auth = try await AppleIDStore.shared.refreshPortalSession()
        }
        guard let session = auth else {
            throw AppleAuthError.message("Sign in under Account first (Developer Portal session required for the 7-day certificate).")
        }
        do {
            _ = try await DeveloperPortalClient.shared.listTeams(auth: session)
            return session
        } catch {
            if AppleIDStore.isPortalSessionExpired(error) || isPortalAuthBlocked(error) {
                let refreshed = try await AppleIDStore.shared.refreshPortalSession()
                // Re-probe — returning a session that still 1200s wastes the create path.
                do {
                    _ = try await DeveloperPortalClient.shared.listTeams(auth: refreshed)
                    return refreshed
                } catch {
                    // listTeams 1200 after refresh: still return the refreshed session so CSR
                    // + revoke path can run — some free accounts 1200 on listTeams only.
                    if isPortalAuthBlocked(error) { return refreshed }
                    throw error
                }
            }
            throw error
        }
    }

    private static func preferredTeam(from teams: [Team], session: AppleAuthSession) -> Team? {
        if let remembered = session.teamID,
           let match = teams.first(where: { $0.id == remembered }) {
            return match
        }
        if let free = teams.first(where: \.isFree) { return free }
        return teams.first
    }

    /// Resolve a Team without dying on portal 1200 from listTeams.
    private static func resolveTeam(auth: AppleAuthSession) async throws -> Team {
        do {
            let teams = try await DeveloperPortalClient.shared.listTeams(auth: auth)
            if let team = preferredTeam(from: teams, session: auth) {
                return team
            }
        } catch {
            guard isPortalAuthBlocked(error) else { throw error }
        }
        // Remembered free-team id from a prior successful portal login.
        let remembered = (auth.teamID ?? AppleIDStore.shared.activeAccount?.teamID)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !remembered.isEmpty else {
            throw AppleAuthError.message(
                "No development team for this Apple ID. Sign out and back in under Account, then tap Create again."
            )
        }
        return Team(id: remembered, name: "Personal Team", isFree: true)
    }

    private static func isPortalAuthBlocked(_ error: Error) -> Bool {
        if case AppleAuthError.portal(let code, _) = error {
            return code == 1100 || code == 1200 || code == -22406
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("1100")
            || text.contains("not allowed to perform")
            || text.contains("portal error 1200")
            || text.contains("(1200)")
    }

    private static func isPortalSlotError(_ error: Error) -> Bool {
        if case AppleAuthError.portal(let code, _) = error {
            return code == 35 || code == 7460 || code == 1200
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("7460")
            || text.contains("portal error 35")
            || text.contains("portal error 1200")
            || text.contains("(1200)")
    }

    private struct OwnedPortalKeys {
        var serials: Set<String>
        var portalIDs: Set<String>
    }

    private static func ownedPortalKeys() -> OwnedPortalKeys {
        let linked = Set(AppleIDStore.shared.activeAccount?.linkedCertificateIDs ?? [])
        var serials = Set<String>()
        var portalIDs = Set<String>()
        for cert in CertificateStore.shared.certificates where linked.contains(cert.id) {
            if let s = cert.portalSerialNumber, !s.isEmpty { serials.insert(s.uppercased()) }
            if let p = cert.portalCertificateID, !p.isEmpty { portalIDs.insert(p) }
        }
        return OwnedPortalKeys(serials: serials, portalIDs: portalIDs)
    }

    private static func ownsPortalCertificate(_ portal: DevCertificate, owned: OwnedPortalKeys) -> Bool {
        if !portal.serialNumber.isEmpty, owned.serials.contains(portal.serialNumber.uppercased()) {
            return true
        }
        if !portal.id.isEmpty, owned.portalIDs.contains(portal.id) {
            return true
        }
        return false
    }

    private static func revokePortalCertificates(
        _ certs: [DevCertificate],
        auth: AppleAuthSession,
        team: Team,
        requireSuccess: Bool
    ) async throws {
        var lastError: Error?
        for cert in certs {
            do {
                try await DeveloperPortalClient.shared.revokeCertificate(cert, auth: auth, team: team)
            } catch {
                lastError = error
            }
        }
        if requireSuccess, let lastError, !certs.isEmpty {
            throw lastError
        }
    }

    private static func registerThisDeviceIfPossible(auth: AppleAuthSession, team: Team) async throws {
        guard let udid = CertificateStore.knownUDID()
            ?? (try? DevicePairingStore.load())?.device_udid,
              !udid.isEmpty else {
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
            // Already registered, or free-tier "not allowed" on duplicate — continue to CSR.
            if case .portal(let code, _) = e, code == 35 || code == 1200 { return }
            throw e
        } catch {
            if isPortalAuthBlocked(error) { return }
            throw error
        }
    }

    /// CSR submit with SideSign replace semantics: on 35/7460/1200 revoke Development
    /// certs (or every listed cert on free tier), then create once more.
    private static func createDevelopmentCertificateSideSignStyle(
        auth: AppleAuthSession,
        team: Team
    ) async throws -> (certPEM: Data, privateKeyPEM: Data, certificate: DevCertificate, csr: CSRBuilder.Result) {
        let machineId = stableMachineID(from: auth)
        do {
            return try await DeveloperPortalClient.shared.createDevelopmentCertificate(
                machineName: UIDevice.current.name,
                machineId: machineId,
                auth: auth,
                team: team
            )
        } catch {
            guard isPortalSlotError(error) else { throw error }
            let existing = (try? await DeveloperPortalClient.shared.listCertificates(auth: auth, team: team)) ?? []
            // Free tier: clear the single Development slot. Prefer Development-looking names,
            // but if names are just the device ("iPhone") revoke everything listed.
            let toRevoke: [DevCertificate] = {
                if existing.count <= 1 { return existing }
                let filtered = existing.filter {
                    let n = $0.name.lowercased()
                    return n.contains("development") || n.contains("ios development") || n.contains("apple development")
                }
                return filtered.isEmpty ? existing : filtered
            }()
            try await revokePortalCertificates(toRevoke, auth: auth, team: team, requireSuccess: false)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            do {
                return try await DeveloperPortalClient.shared.createDevelopmentCertificate(
                    machineName: UIDevice.current.name,
                    machineId: machineId,
                    auth: auth,
                    team: team
                )
            } catch {
                throw AppleAuthError.message(
                    "Couldn't create a free 7-day development certificate after clearing the portal slot (\(error.localizedDescription)). Tap Create again, or import a custom .p12 + mobileprovision under Certificate — same flow as SideStore/SideSign."
                )
            }
        }
    }

    /// Stable CSR machine id (SideSign/AltStore) — random UUIDs clutter free portal slots.
    private static func stableMachineID(from auth: AppleAuthSession) -> String {
        let device = auth.anisette.deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !device.isEmpty { return device.uppercased() }
        if let saved = UserDefaults.standard.string(forKey: "tetherless.portal.machineId"), !saved.isEmpty {
            return saved
        }
        let fresh = UUID().uuidString.uppercased()
        UserDefaults.standard.set(fresh, forKey: "tetherless.portal.machineId")
        return fresh
    }

    private static func preferredWildcardAppID(from appIDs: [DevAppID]) -> DevAppID? {
        let wildcards = appIDs.filter {
            $0.bundleID == "*" || $0.bundleID.hasSuffix(".*")
        }
        if let branded = wildcards.first(where: {
            let b = $0.bundleID.lowercased()
            return b.contains("fastdecrypt") || b.contains("appassassin") || b.contains("tetherless")
        }) {
            return branded
        }
        return wildcards.first
    }

    private static func retirePreviousLinkedCertificates(keepingPortalSerial serial: String) {
        let linked = AppleIDStore.shared.activeAccount?.linkedCertificateIDs ?? []
        let keepSerial = serial.uppercased()
        for id in linked {
            guard let cert = CertificateStore.shared.certificates.first(where: { $0.id == id }) else {
                AppleIDStore.shared.unlinkCertificate(id)
                continue
            }
            if let s = cert.portalSerialNumber, !keepSerial.isEmpty, s.uppercased() == keepSerial {
                continue
            }
            // Drop expired / superseded free certs from the pool.
            if CertificateStore.shared.cachedProfileInfo(for: cert).isExpired
                || cert.portalSerialNumber != nil {
                CertificateStore.shared.delete(cert)
            }
        }
    }

    @discardableResult
    static func importCertPEM(
        _ certPEM: Data,
        keyPEM: Data,
        name: String,
        provision: Data,
        portalSerialNumber: String? = nil,
        portalCertificateID: String? = nil
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
            makeActive: true,
            locked: true,
            portalSerialNumber: portalSerialNumber,
            portalCertificateID: portalCertificateID
        )
    }
}
