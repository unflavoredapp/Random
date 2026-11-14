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

    var displayName: String { label.isEmpty ? email : "\(label) · \(email)" }
    var statusLabel: String {
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
        try? await Task.sleep(nanoseconds: 700_000_000)
        withAnimation(.snappy) { authPhase = .awaitingTwoFactor }
    }

    /// Legacy no-arg sign-in using draft fields.
    func signIn() {
        Task { await signIn(email: draftEmail, password: draftPassword) }
        draftPassword = ""
    }

    func submitTwoFactor(code: String) async {
        let digits = code.filter(\.isNumber)
        guard digits.count >= 4 else {
            lastError = "Enter the verification code from your Apple device."
            return
        }
        lastError = nil
        authPhase = .verifying
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        let e = draftEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pw = Keychain.getSecret(Self.passwordPrefix + "pending") ?? ""
        Keychain.deleteSecret(Self.passwordPrefix + "pending")
        if let existing = accounts.first(where: { $0.email == e }) {
            activeAccountID = existing.id
            _ = Keychain.setSecret(Self.passwordPrefix + existing.id, pw)
        } else {
            let id = UUID().uuidString
            accounts.append(AppleIDAccount(id: id, email: e, addedAt: Date()))
            activeAccountID = id
            _ = Keychain.setSecret(Self.passwordPrefix + id, pw)
        }
        verificationCode = ""
        save()
        withAnimation(.snappy) { authPhase = .preparing }
        await finishPreparing()
        syncProfileMetadataFromCertificates()
    }

    func submitVerificationCode() {
        Task { await submitTwoFactor(code: verificationCode) }
    }

    func cancelTwoFactor() {
        Keychain.deleteSecret(Self.passwordPrefix + "pending")
        authPhase = accounts.isEmpty ? .idle : .idle
        lastError = nil
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
        authPhase = .idle
        UserDefaults.standard.set(false, forKey: Self.storeReadyKey)
        save()
        _ = Keychain.set(Self.legacyEmailKey, "")
        Keychain.deleteSecret(Self.legacyPasswordKey)
    }

    func presentTrustedDeviceCode() {
        presentedDisplayCode = String((0..<6).map { _ in String(Int.random(in: 0...9)) }.joined())
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

    private func finishPreparing() async {
        try? await Task.sleep(nanoseconds: 900_000_000)
        storeReady = true
        UserDefaults.standard.set(true, forKey: Self.storeReadyKey)
        withAnimation(.snappy) { authPhase = .idle }
    }
}
