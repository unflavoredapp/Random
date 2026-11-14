//
//  AppleIDAccountStore.swift
//  Multi-account Store Access + free-Apple-ID certificate linking.
//  Used by Settings › Store Access, Decrypt, SigningSheet, and Apple ID Manage.
//

import Foundation
import SwiftUI

struct AppleIDAccount: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var email: String
    var addedAt: Date
    /// Certificate IDs linked for free-Apple-ID signing with this account.
    var linkedCertificateIDs: [String] = []
    /// Friendly label (optional).
    var label: String = ""
    /// Local notes / revoked-slot bookkeeping (certificate IDs marked revoked on this device).
    var revokedCertificateIDs: [String] = []
    /// App ID bundle identifiers remembered for this Apple ID (from linked profiles + manual).
    var appIDs: [String] = []
    /// Device UDIDs associated with this account’s profiles.
    var deviceUDIDs: [String] = []
    /// Serialized AppleAuthSession for Developer Portal.
    var portalSessionJSON: Data? = nil
    /// Serialized StorefrontSession for silent purchase/download (ipatool-style).
    var storeSessionJSON: Data? = nil
    var teamID: String? = nil
    var teamName: String? = nil

    var displayName: String { label.isEmpty ? email : "\(label) · \(email)" }
    var statusLabel: String {
        if storeSessionJSON != nil {
            return "Store download ready"
        }
        if !linkedCertificateIDs.isEmpty {
            return "\(linkedCertificateIDs.count) linked cert\(linkedCertificateIDs.count == 1 ? "" : "s")"
        }
        return "Ready for Store downloads"
    }
}

typealias StoreAccount = AppleIDAccount

@MainActor
final class AppleIDStore: ObservableObject {
    static let shared = AppleIDStore()

    private static let accountsKey = "tetherless.appleid.accounts"
    private static let activeKey = "tetherless.appleid.active"
    private static let passwordPrefix = "tetherless.appleid.password."
    private static let legacyEmailKey = "tetherless.appleid.email"
    private static let legacyPasswordKey = "tetherless.appleid.password"
    private static let storeReadyKey = "tetherless.appleid.storeReady"

    enum AuthPhase: Equatable {
        case idle
        case authenticating
        case awaitingTwoFactor
        case verifying
        case preparing
    }

    enum Phase: Equatable {
        case signedOut
        case authenticating
        case needsCode
        case verifying
        case signedIn
        case preparing
    }

    @Published private(set) var accounts: [AppleIDAccount] = []
    @Published private(set) var activeAccountID: String?
    @Published var draftEmail = ""
    @Published var draftPassword = ""
    @Published var verificationCode = ""
    @Published private(set) var authPhase: AuthPhase = .idle
    @Published var lastError: String?
    @Published var statusMessage: String?
    @Published var presentedDisplayCode: String?
    @Published private(set) var storeReady = false
    /// True when the active 2FA challenge is SMS (text to trusted phone).
    @Published private(set) var twoFactorUsesSMS = false
    /// Obfuscated phone hint for SMS 2FA UI (e.g. ••••42).
    @Published private(set) var twoFactorPhoneHint: String?
    /// Last 2FA code — reused once for iTunes Store authenticate after GSA succeeds.
    private var pendingStoreAuthCode: String?

    var activeID: String? {
        get { activeAccountID }
        set { activeAccountID = newValue }
    }

    var activeAccount: AppleIDAccount? { accounts.first { $0.id == activeAccountID } }
    var email: String { activeAccount?.email ?? "" }
    var hasAnyAccount: Bool { !accounts.isEmpty }
    var isBusy: Bool {
        switch authPhase {
        case .authenticating, .verifying, .preparing: return true
        default: return false
        }
    }
    var isSignedIn: Bool { activeAccount != nil && storeReady }
    var phase: Phase {
        if accounts.isEmpty { return .signedOut }
        switch authPhase {
        case .authenticating: return .authenticating
        case .awaitingTwoFactor: return .needsCode
        case .verifying: return .verifying
        case .preparing: return .preparing
        case .idle: return storeReady ? .signedIn : .preparing
        }
    }

    private init() {
        load()
        migrateLegacyIfNeeded()
        storeReady = UserDefaults.standard.bool(forKey: Self.storeReadyKey)
        if let active = activeAccount {
            draftEmail = active.email
            if !storeReady {
                authPhase = .preparing
                Task { await finishPreparing() }
            } else {
                authPhase = .idle
            }
        }
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.accountsKey),
              let list = try? JSONDecoder().decode([AppleIDAccount].self, from: data) else { return }
        accounts = list
        activeAccountID = UserDefaults.standard.string(forKey: Self.activeKey) ?? list.first?.id
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
        }
        UserDefaults.standard.set(activeAccountID, forKey: Self.activeKey)
        UserDefaults.standard.set(activeAccount?.email ?? "", forKey: "tetherless.appleid.activeEmailCache")
    }

    private func migrateLegacyIfNeeded() {
        guard accounts.isEmpty, let email = Keychain.get(Self.legacyEmailKey), !email.isEmpty else { return }
        let id = UUID().uuidString
        accounts = [AppleIDAccount(id: id, email: email, addedAt: Date())]
        activeAccountID = id
        if let pw = Keychain.getSecret(Self.legacyPasswordKey), !pw.isEmpty {
            _ = Keychain.setSecret(Self.passwordPrefix + id, pw)
        }
        storeReady = true
        UserDefaults.standard.set(true, forKey: Self.storeReadyKey)
        save()
    }

    // MARK: Auth — Settings / Decrypt API

    func signIn(email: String, password: String) async {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let p = password
        guard e.contains("@"), e.contains("."), !p.isEmpty else {
            lastError = "Enter a valid Apple ID email and password."
            return
        }
        lastError = nil
        statusMessage = nil
        draftEmail = e
        authPhase = .authenticating
        _ = Keychain.setSecret(Self.passwordPrefix + "pending", p)
        do {
            let session = try await GSAAuthClient.shared.authenticate(email: e, password: p)
            await finishRealSignIn(session: session, password: p)
        } catch AppleAuthError.needsTwoFactor {
            refreshTwoFactorChannelFromGSA()
            withAnimation(.snappy) { authPhase = .awaitingTwoFactor }
            statusMessage = twoFactorPromptMessage()
            lastError = nil
        } catch {
            authPhase = .idle
            lastError = error.localizedDescription
            Keychain.deleteSecret(Self.passwordPrefix + "pending")
            pendingStoreAuthCode = nil
            GSAAuthClient.shared.cancel()
        }
    }

    /// Legacy no-arg sign-in using draft fields.
    func signIn() {
        Task { await signIn(email: draftEmail, password: draftPassword) }
        draftPassword = ""
    }

    func submitTwoFactor(code: String) async {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else {
            lastError = "Enter the 6-digit verification code."
            return
        }
        lastError = nil
        authPhase = .verifying
        pendingStoreAuthCode = digits
        do {
            let session = try await GSAAuthClient.shared.submitTwoFactor(code: digits)
            let pw = Keychain.getSecret(Self.passwordPrefix + "pending") ?? ""
            await finishRealSignIn(session: session, password: pw)
        } catch {
            authPhase = .awaitingTwoFactor
            lastError = error.localizedDescription
        }
    }

    /// Texts a code to the Apple ID’s trusted phone (SMS). Prefer this when no other Apple device is nearby.
    func requestSMSCode() async {
        lastError = nil
        authPhase = .verifying
        do {
            let hint = try await GSAAuthClient.shared.requestSMSCode()
            refreshTwoFactorChannelFromGSA()
            authPhase = .awaitingTwoFactor
            if hint.isEmpty {
                statusMessage = "A text message with a code was sent to your trusted phone number."
            } else {
                statusMessage = "A text message with a code was sent to \(hint)."
            }
        } catch {
            refreshTwoFactorChannelFromGSA()
            authPhase = .awaitingTwoFactor
            lastError = error.localizedDescription
            statusMessage = twoFactorPromptMessage()
        }
    }

    var isSMSTwoFactor: Bool { twoFactorUsesSMS }

    private func refreshTwoFactorChannelFromGSA() {
        let gsa = GSAAuthClient.shared
        if case .sms = gsa.twoFactorChannel {
            twoFactorUsesSMS = true
        } else {
            twoFactorUsesSMS = false
        }
        twoFactorPhoneHint = gsa.twoFactorPhoneHint
    }

    private func twoFactorPromptMessage() -> String {
        if twoFactorUsesSMS {
            if let hint = twoFactorPhoneHint, !hint.isEmpty {
                return "Enter the 6-digit code texted to \(hint)."
            }
            return "Enter the 6-digit code texted to your phone."
        }
        return GSAAuthClient.shared.twoFactorCodeAlreadySent
            ? "Apple already sent a code to your trusted devices — enter it below. Or tap Text me a code."
            : "Enter the 6-digit code from a trusted Apple device, or tap Text me a code."
    }

    func submitVerificationCode() {
        Task { await submitTwoFactor(code: verificationCode) }
    }

    func cancelTwoFactor() {
        GSAAuthClient.shared.cancel()
        Keychain.deleteSecret(Self.passwordPrefix + "pending")
        pendingStoreAuthCode = nil
        authPhase = accounts.isEmpty ? .idle : .idle
        lastError = nil
        statusMessage = nil
        twoFactorUsesSMS = false
        twoFactorPhoneHint = nil
        verificationCode = ""
        if accounts.isEmpty {
            draftEmail = ""
        } else {
            draftEmail = activeAccount?.email ?? ""
        }
    }

    func selectAccount(id: String) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        activeAccountID = id
        draftEmail = accounts.first { $0.id == id }?.email ?? ""
        storeReady = true
        UserDefaults.standard.set(true, forKey: Self.storeReadyKey)
        authPhase = .idle
        save()
        statusMessage = "Switched to \(email)."
        lastError = nil
        activatePreferredSigningCertificate()
    }

    func switchTo(id: String) { selectAccount(id: id) }

    func removeAccount(id: String) {
        Keychain.deleteSecret(Self.passwordPrefix + id)
        accounts.removeAll { $0.id == id }
        if activeAccountID == id {
            activeAccountID = accounts.first?.id
        }
        save()
        if let next = activeAccount {
            draftEmail = next.email
            authPhase = .idle
            storeReady = true
        } else {
            signOutAll()
        }
    }

    func signOut() { signOutActive() }

    func signOutActive() {
        guard let id = activeAccountID else { signOutAll(); return }
        removeAccount(id: id)
    }

    func signOutAll() {
        for a in accounts { Keychain.deleteSecret(Self.passwordPrefix + a.id) }
        accounts = []
        activeAccountID = nil
        draftEmail = ""
        draftPassword = ""
        verificationCode = ""
        storeReady = false
        statusMessage = nil
        lastError = nil
        presentedDisplayCode = nil
        twoFactorUsesSMS = false
        twoFactorPhoneHint = nil
        authPhase = .idle
        UserDefaults.standard.set(false, forKey: Self.storeReadyKey)
        save()
        _ = Keychain.set(Self.legacyEmailKey, "")
        Keychain.deleteSecret(Self.legacyPasswordKey)
    }

    func presentTrustedDeviceCode() {
        // Real codes are pushed by Apple to trusted devices — nothing to display locally.
        presentedDisplayCode = nil
        statusMessage = twoFactorPromptMessage()
    }

    func dismissDisplayedCode() { presentedDisplayCode = nil }

    // MARK: Free Apple ID ↔ certificate linking

    func linkCertificate(_ certID: String, toAccountID accountID: String? = nil) {
        let aid = accountID ?? activeAccountID
        guard let aid, let idx = accounts.firstIndex(where: { $0.id == aid }) else { return }
        if !accounts[idx].linkedCertificateIDs.contains(certID) {
            accounts[idx].linkedCertificateIDs.append(certID)
        }
        accounts[idx].revokedCertificateIDs.removeAll { $0 == certID }
        if let cert = CertificateStore.shared.certificates.first(where: { $0.id == certID }) {
            let info = CertificateStore.shared.cachedProfileInfo(for: cert)
            mergeProfileInfo(info, into: idx)
        }
        save()
        UserDefaults.standard.set("appleid", forKey: "uzd_signing_method")
        statusMessage = "Linked certificate for free Apple ID signing."
        lastError = nil
    }

    func unlinkCertificate(_ certID: String, fromAccountID accountID: String? = nil) {
        let aid = accountID ?? activeAccountID
        guard let aid, let idx = accounts.firstIndex(where: { $0.id == aid }) else { return }
        accounts[idx].linkedCertificateIDs.removeAll { $0 == certID }
        save()
    }

    /// Locally revoke a linked certificate slot (frees the link; removes cert from signing pool for this Apple ID).
    func revokeCertificate(_ certID: String, fromAccountID accountID: String? = nil) {
        let aid = accountID ?? activeAccountID
        guard let aid, let idx = accounts.firstIndex(where: { $0.id == aid }) else { return }
        accounts[idx].linkedCertificateIDs.removeAll { $0 == certID }
        if !accounts[idx].revokedCertificateIDs.contains(certID) {
            accounts[idx].revokedCertificateIDs.append(certID)
        }
        save()
        if CertificateStore.shared.activeID == certID {
            CertificateStore.shared.activeID = accounts[idx].linkedCertificateIDs.first
                ?? CertificateStore.shared.certificates.first(where: { $0.id != certID })?.id
        }
        statusMessage = "Certificate revoked for this Apple ID — slot freed for a new cert."
    }

    func addAppID(_ bundleID: String, toAccountID accountID: String? = nil) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let aid = accountID ?? activeAccountID
        guard let aid, let idx = accounts.firstIndex(where: { $0.id == aid }) else { return }
        if !accounts[idx].appIDs.contains(trimmed) {
            accounts[idx].appIDs.append(trimmed)
            save()
        }
    }

    func removeAppID(_ bundleID: String, fromAccountID accountID: String? = nil) {
        let aid = accountID ?? activeAccountID
        guard let aid, let idx = accounts.firstIndex(where: { $0.id == aid }) else { return }
        accounts[idx].appIDs.removeAll { $0 == bundleID }
        save()
    }

    func addDeviceUDID(_ udid: String, toAccountID accountID: String? = nil) {
        let trimmed = udid.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return }
        let aid = accountID ?? activeAccountID
        guard let aid, let idx = accounts.firstIndex(where: { $0.id == aid }) else { return }
        if !accounts[idx].deviceUDIDs.contains(trimmed) {
            accounts[idx].deviceUDIDs.append(trimmed)
            save()
        }
    }

    func removeDeviceUDID(_ udid: String, fromAccountID accountID: String? = nil) {
        let aid = accountID ?? activeAccountID
        guard let aid, let idx = accounts.firstIndex(where: { $0.id == aid }) else { return }
        accounts[idx].deviceUDIDs.removeAll { $0.caseInsensitiveCompare(udid) == .orderedSame }
        save()
    }

    /// Prefer a certificate linked to the active Store account; else the active cert if it looks like a free/dev profile.
    func preferredSigningCertificateID() -> String? {
        if let linked = activeAccount?.linkedCertificateIDs.first,
           CertificateStore.shared.certificates.contains(where: { $0.id == linked }) {
            return linked
        }
        if let active = CertificateStore.shared.active {
            let info = CertificateStore.shared.cachedProfileInfo(for: active)
            if !info.udids.isEmpty { return active.id }
        }
        return CertificateStore.shared.activeID
    }

    func portalSession() -> AppleAuthSession? {
        guard let data = activeAccount?.portalSessionJSON else { return nil }
        return try? JSONDecoder().decode(AppleAuthSession.self, from: data)
    }

    /// iTunes Store session for silent purchase/download.
    func storefrontSession() -> StorefrontSession? {
        guard let data = activeAccount?.storeSessionJSON else { return nil }
        return try? JSONDecoder().decode(StorefrontSession.self, from: data)
    }

    /// Ensure a usable storefront session (re-auth with saved password if needed).
    func ensureStorefrontSession() async throws -> StorefrontSession {
        if let existing = storefrontSession(), existing.isUsable {
            return existing
        }
        guard let email = activeAccount?.email, !email.isEmpty else {
            throw AppStoreClientError.message("Sign in under Store Access first.")
        }
        guard let password = Keychain.getSecret(Self.passwordPrefix + (activeAccountID ?? "")), !password.isEmpty else {
            throw AppStoreClientError.message("Missing Apple ID password — sign in again under Store Access.")
        }
        let session = try await AppStoreClient.shared.authenticate(
            email: email,
            password: password,
            authCode: pendingStoreAuthCode
        )
        pendingStoreAuthCode = nil
        persistStoreSession(session)
        return session
    }

    private func persistStoreSession(_ store: StorefrontSession) {
        guard let idx = accounts.firstIndex(where: { $0.email.caseInsensitiveCompare(store.email) == .orderedSame })
                ?? accounts.firstIndex(where: { $0.id == activeAccountID }) else { return }
        accounts[idx].storeSessionJSON = try? JSONEncoder().encode(store)
        save()
    }

    func activatePreferredSigningCertificate() {
        if let id = preferredSigningCertificateID() {
            CertificateStore.shared.activeID = id
        }
    }

    /// Pull App IDs / devices from every linked (or all) certificates into the active account.
    func syncProfileMetadataFromCertificates() {
        guard let aid = activeAccountID, let idx = accounts.firstIndex(where: { $0.id == aid }) else { return }
        let certs: [Certificate]
        if accounts[idx].linkedCertificateIDs.isEmpty {
            certs = CertificateStore.shared.certificates
        } else {
            certs = CertificateStore.shared.certificates.filter { accounts[idx].linkedCertificateIDs.contains($0.id) }
        }
        for cert in certs {
            mergeProfileInfo(CertificateStore.shared.cachedProfileInfo(for: cert), into: idx)
        }
        if let known = CertificateStore.knownUDID(), !accounts[idx].deviceUDIDs.contains(where: { $0.caseInsensitiveCompare(known) == .orderedSame }) {
            accounts[idx].deviceUDIDs.append(known.uppercased())
        }
        save()
    }

    private func mergeProfileInfo(_ info: ProfileInfo, into idx: Int) {
        if let name = info.name, !name.isEmpty {
            // Profile name often mirrors the App ID / team name — keep as a remembered App ID hint when it looks like a bundle id.
            if name.contains("."), !accounts[idx].appIDs.contains(name) {
                accounts[idx].appIDs.append(name)
            }
        }
        for u in info.udids {
            let up = u.uppercased()
            if !accounts[idx].deviceUDIDs.contains(where: { $0.caseInsensitiveCompare(up) == .orderedSame }) {
                accounts[idx].deviceUDIDs.append(up)
            }
        }
    }

    /// Persist a live GrandSlam session as a Store account (no simulated delay auth).
    private func finishRealSignIn(session: AppleAuthSession, password: String) async {
        authPhase = .preparing
        statusMessage = "Fetching developer team…"
        var session = session
        // Attach first Developer Portal team when available (free or paid).
        if let teams = try? await DeveloperPortalClient.shared.listTeams(auth: session),
           let team = teams.first {
            session.teamID = team.id
            session.teamName = team.name
            session.isFreeTeam = team.isFree
        }

        let email = session.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sessionJSON = try? JSONEncoder().encode(session)

        if let idx = accounts.firstIndex(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) {
            accounts[idx].portalSessionJSON = sessionJSON
            accounts[idx].teamID = session.teamID
            accounts[idx].teamName = session.teamName
            activeAccountID = accounts[idx].id
            _ = Keychain.setSecret(Self.passwordPrefix + accounts[idx].id, password)
        } else {
            let id = UUID().uuidString
            var account = AppleIDAccount(id: id, email: email, addedAt: Date())
            account.portalSessionJSON = sessionJSON
            account.teamID = session.teamID
            account.teamName = session.teamName
            accounts.append(account)
            activeAccountID = id
            _ = Keychain.setSecret(Self.passwordPrefix + id, password)
        }

        Keychain.deleteSecret(Self.passwordPrefix + "pending")
        draftEmail = email
        draftPassword = ""
        verificationCode = ""
        twoFactorUsesSMS = false
        twoFactorPhoneHint = nil
        lastError = nil

        // Also establish iTunes Store passwordToken for silent purchase/download.
        statusMessage = "Connecting App Store download session…"
        do {
            let store = try await AppStoreClient.shared.authenticate(
                email: email,
                password: password,
                authCode: pendingStoreAuthCode
            )
            persistStoreSession(store)
            statusMessage = session.teamName.map { "Signed in · \($0) · silent download ready" }
                ?? "Signed in · silent download ready"
        } catch AppStoreClientError.needsTwoFactor {
            statusMessage = session.teamName.map { "Signed in · \($0)" } ?? "Signed in"
            // Store download will prompt/re-auth on first silent decrypt if needed.
        } catch {
            statusMessage = session.teamName.map { "Signed in · \($0)" } ?? "Signed in"
            // Non-fatal — portal auth still works; silent download retries later.
        }
        pendingStoreAuthCode = nil

        save()
        activatePreferredSigningCertificate()
        await finishPreparing()
    }

    private func finishPreparing() async {
        storeReady = true
        UserDefaults.standard.set(true, forKey: Self.storeReadyKey)
        withAnimation(.snappy) { authPhase = .idle }
    }
}
