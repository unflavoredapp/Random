//
// Brand: AppAssassin · https://fastdecrypt.ai
//  FreeAppleIDSigning.swift
//  SideSign / SideStore CertificateProvisioningFlow for free Apple ID 7-day
//  development certificates:
//    GrandSlam portal → list certs → reuse owned serial if private key present
//    → else replace (revoke iOS Development) → CSR submit → device + App ID
//    → development profile → import p12.
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

    /// SideSign-style capture: fetch portal certs, reuse when we still hold the key,
    /// otherwise revoke iOS Development slot(s) and CSR a fresh Development cert.
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
        var team = try await resolveTeam(auth: auth)

        try await registerThisDeviceIfPossible(auth: auth, team: team)

        // SideSign CertificateProvisioningFlow.fetchCertificate:
        // list → reuse owned → empty? request : replace → request.
        var portalCerts = (try? await DeveloperPortalClient.shared.listCertificates(auth: auth, team: team)) ?? []

        if !forceRefresh,
           let reused = tryReuseOwnedCertificate(matchingPortal: portalCerts) {
            CertificateStore.shared.activeID = reused.id
            preferAppleIDSigningMethodIfPossible()
            return reused
        }

        let created: (certPEM: Data, privateKeyPEM: Data, certificate: DevCertificate, csr: CSRBuilder.Result)
        created = try await {
            do {
                if portalCerts.isEmpty {
                    return try await requestCertificateSideSign(auth: auth, team: team)
                }
                return try await replaceCertificateSideSign(
                    portalCertificates: portalCerts,
                    auth: auth,
                    team: team
                )
            } catch {
                guard isPortalAuthBlocked(error) || isPortalSlotError(error) else { throw error }
                // SideSign handler `.retry` — refresh GrandSlam, clear slot, CSR again.
                var lastError: Error = error
                var workingAuth = auth
                var workingTeam = team
                for round in 1...3 {
                    do {
                        workingAuth = try await AppleIDStore.shared.refreshPortalSession()
                        workingTeam = (try? await resolveTeam(auth: workingAuth)) ?? workingTeam
                    } catch {
                        if case AppleAuthError.needsTwoFactor = error { throw error }
                        lastError = error
                    }
                    let again = (try? await DeveloperPortalClient.shared.listCertificates(
                        auth: workingAuth, team: workingTeam
                    )) ?? []
                    if !again.isEmpty {
                        try await revokePortalCertificates(
                            iosDevelopmentCertificates(in: again),
                            auth: workingAuth,
                            team: workingTeam,
                            requireSuccess: false
                        )
                    }
                    try? await Task.sleep(nanoseconds: UInt64(1_500_000_000 * round))
                    do {
                        let made = try await requestCertificateSideSign(
                            auth: workingAuth, team: workingTeam
                        )
                        auth = workingAuth
                        team = workingTeam
                        return made
                    } catch {
                        lastError = error
                    }
                }
                throw AppleAuthError.message(
                    "Couldn't capture a SideSign-style development certificate after clearing the portal slot (\(lastError.localizedDescription)). Sign out and back in under Account, then tap Create again — or import a custom .p12 + mobileprovision under Certificate."
                )
            }
        }()

        // Re-fetch so we pair the private key with the full portal X.509 (SideSign).
        let listed = (try? await DeveloperPortalClient.shared.listCertificates(auth: auth, team: team)) ?? []
        let portalMatch = listed.first {
            !$0.serialNumber.isEmpty
                && $0.serialNumber.caseInsensitiveCompare(created.certificate.serialNumber) == .orderedSame
        } ?? created.certificate

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

        let certPEM: Data = {
            if let raw = portalMatch.certificateData {
                return DeveloperPortalClient.certificatePEM(from: raw)
            }
            return created.certPEM
        }()

        retirePreviousLinkedCertificates(keepingPortalSerial: portalMatch.serialNumber)
        let cert = try importCertPEM(
            certPEM,
            keyPEM: created.privateKeyPEM,
            name: portalMatch.name.isEmpty ? created.certificate.name : portalMatch.name,
            provision: profileData,
            portalSerialNumber: portalMatch.serialNumber,
            portalCertificateID: portalMatch.id
        )
        AppleIDStore.shared.linkCertificate(cert.id)
        preferAppleIDSigningMethodIfPossible()
        return cert
    }

    // MARK: - SideSign CertificateProvisioningFlow steps

    /// SideSign `requestCertificate` — branded machineName + stable machineId CSR submit.
    private static func requestCertificateSideSign(
        auth: AppleAuthSession,
        team: Team
    ) async throws -> (certPEM: Data, privateKeyPEM: Data, certificate: DevCertificate, csr: CSRBuilder.Result) {
        let machineName = sideSignMachineName(team: team, auth: auth)
        let machineId = stableMachineID(from: auth)
        return try await DeveloperPortalClient.shared.createDevelopmentCertificate(
            machineName: machineName,
            machineId: machineId,
            auth: auth,
            team: team
        )
    }

    /// SideSign `replaceCertificate` — revoke iOS Development / iPhone Developer slots, then CSR.
    private static func replaceCertificateSideSign(
        portalCertificates: [DevCertificate],
        auth: AppleAuthSession,
        team: Team
    ) async throws -> (certPEM: Data, privateKeyPEM: Data, certificate: DevCertificate, csr: CSRBuilder.Result) {
        var toRevoke = iosDevelopmentCertificates(in: portalCertificates)
        // Free tier: one Development slot. If names are just the device ("iPhone"),
        // SideSign-style filter may be empty — clear every listed cert.
        if toRevoke.isEmpty, team.isFree {
            toRevoke = portalCertificates
        }
        if !toRevoke.isEmpty {
            try await revokePortalCertificates(
                toRevoke, auth: auth, team: team, requireSuccess: false
            )
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
        do {
            return try await requestCertificateSideSign(auth: auth, team: team)
        } catch {
            guard isPortalSlotError(error) else { throw error }
            // Slot still occupied — revoke again (SideSign retry) then CSR once more.
            let again = (try? await DeveloperPortalClient.shared.listCertificates(auth: auth, team: team)) ?? []
            let retryRevoke = iosDevelopmentCertificates(in: again)
            try await revokePortalCertificates(
                retryRevoke.isEmpty ? again : retryRevoke,
                auth: auth,
                team: team,
                requireSuccess: false
            )
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return try await requestCertificateSideSign(auth: auth, team: team)
        }
    }

    /// SideSign filter: `ios development` / `iphone developer` names.
    private static func iosDevelopmentCertificates(in certs: [DevCertificate]) -> [DevCertificate] {
        let filtered = certs.filter {
            let n = $0.name.lowercased()
            let m = ($0.machineName ?? "").lowercased()
            return n.contains("ios development")
                || n.contains("iphone developer")
                || n.contains("apple development")
                || n.contains("development")
                || m.contains("ios development")
                || m.contains("iphone developer")
        }
        return filtered.isEmpty ? certs : filtered
    }

    /// `"AppAssassin - {account}'s {device}"` — mirrors SideSign `"SideStore - {name}'s {device}"`.
    private static func sideSignMachineName(team: Team, auth: AppleAuthSession) -> String {
        let device = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let deviceLabel = device.isEmpty ? "iPhone" : device
        let email = AppleIDStore.shared.activeAccount?.email
            ?? auth.email
            ?? ""
        let account: String = {
            let e = email.trimmingCharacters(in: .whitespacesAndNewlines)
            if let at = e.firstIndex(of: "@") {
                let local = String(e[..<at])
                if !local.isEmpty { return local }
            }
            let teamName = team.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return teamName.isEmpty ? "Apple ID" : teamName
        }()
        return "AppAssassin - \(account)'s \(deviceLabel)"
    }

    /// Reuse a linked local p12 whose portal serial is still active (SideSign keychain hit).
    private static func tryReuseOwnedCertificate(matchingPortal portal: [DevCertificate]) -> Certificate? {
        guard !portal.isEmpty else { return nil }
        let portalSerials = Set(portal.map { $0.serialNumber.uppercased() }.filter { !$0.isEmpty })
        let linked = Set(AppleIDStore.shared.activeAccount?.linkedCertificateIDs ?? [])
        for cert in CertificateStore.shared.certificates where linked.contains(cert.id) {
            guard let serial = cert.portalSerialNumber?.uppercased(), !serial.isEmpty,
                  portalSerials.contains(serial) else { continue }
            guard !CertificateStore.shared.cachedProfileInfo(for: cert).isExpired else { continue }
            // Must still unpack as signing material (private key present).
            CertificateStore.shared.activeID = cert.id
            guard (try? CertificateStore.shared.activeMaterial()) != nil else { continue }
            return cert
        }
        return nil
    }

    // MARK: - Portal session / team

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
                do {
                    _ = try await DeveloperPortalClient.shared.listTeams(auth: refreshed)
                    return refreshed
                } catch {
                    // listTeams 1200 after refresh: still return session so CSR / revoke can run.
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

    private static func resolveTeam(auth: AppleAuthSession) async throws -> Team {
        do {
            let teams = try await DeveloperPortalClient.shared.listTeams(auth: auth)
            if let team = preferredTeam(from: teams, session: auth) {
                return team
            }
        } catch {
            guard isPortalAuthBlocked(error) else { throw error }
        }
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
            || text.contains("denied this free-certificate")
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
            || text.contains("denied this free-certificate")
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
            if case .portal(let code, _) = e, code == 35 || code == 1200 { return }
            throw e
        } catch {
            if isPortalAuthBlocked(error) { return }
            throw error
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
