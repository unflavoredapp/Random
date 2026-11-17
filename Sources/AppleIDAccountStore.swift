//
// Brand: Tetherless · https://tetherless.dev
//  AppleIDAccountStore.swift
//  Multi-account Store Access + free-Apple-ID certificate linking.
//  Used by Account (iPadn store), Decrypt, SigningSheet, and Apple ID Manage.
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
    /// Keychain mirror so accounts + store tokens survive UserDefaults wipes / reinstalls of prefs.
    private static let accountsBackupKey = "tetherless.appleid.accounts.backup"
    private static let activeBackupKey = "tetherless.appleid.active.backup"
    private static let storeSessionPrefix = "tetherless.appleid.storesession."
    /// Short-lived GrandSlam PET for Retry Store unlock (same sign-in window).
    private static let petPrefix = "tetherless.appleid.pet."
    /// When the PET was last minted — Apple PETs die in minutes; past this we skip PET remint.
    private static let petMintedAtPrefix = "tetherless.appleid.petMintedAt."
    /// PET is typically only good for a few minutes after Allow / GSA.
    private static let petUsefulLifetime: TimeInterval = 4 * 60

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
    /// True while MZFinance authenticate runs after Apple ID sign-in (Settings spinner).
    @Published private(set) var storeConnecting = false
    /// True when the active 2FA challenge is SMS (text to trusted phone).
    @Published private(set) var twoFactorUsesSMS = false
    /// Obfuscated phone hint for SMS 2FA UI (e.g. ••••42).
    @Published private(set) var twoFactorPhoneHint: String?
    /// True after App Store auth asked for a 6-digit code (Decrypt shows inline entry).
    @Published private(set) var storeNeedsVerification = false
    /// Last 2FA code — reused once for iTunes Store authenticate after GSA succeeds.
    private var pendingStoreAuthCode: String?
    /// Store session minted with the same sign-in 2FA *before* GrandSlam consumes the code.
    private var pendingStoreSession: StorefrontSession?
    /// Soft flag: next ensure should re-auth without wiping the persisted store token first.
    private var storefrontNeedsRefresh = false

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
    /// Account presence = signed in. `storeReady` only gates the preparing spinner, not logout.
    var isSignedIn: Bool { activeAccount != nil }
    var phase: Phase {
        if accounts.isEmpty { return .signedOut }
        switch authPhase {
        case .authenticating: return .authenticating
        case .awaitingTwoFactor: return .needsCode
        case .verifying: return .verifying
        case .preparing: return .preparing
        case .idle: return .signedIn
        }
    }

    private init() {
        load()
        migrateLegacyIfNeeded()
        restoreStoreSessionsFromKeychain()
        // Persist "signed in" whenever we have an account — never force a login wall on launch.
        if activeAccount != nil {
            storeReady = true
            UserDefaults.standard.set(true, forKey: Self.storeReadyKey)
            draftEmail = activeAccount?.email ?? ""
            authPhase = .idle
            // Quietly refresh aged store tokens in the background — never clears the Apple ID.
            Task { await quietlyRefreshStorefrontIfNeeded() }
        } else {
            storeReady = UserDefaults.standard.bool(forKey: Self.storeReadyKey)
        }
    }

    // MARK: Persistence

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
           let list = try? JSONDecoder().decode([AppleIDAccount].self, from: data),
           !list.isEmpty {
            accounts = list
            activeAccountID = UserDefaults.standard.string(forKey: Self.activeKey) ?? list.first?.id
            return
        }
        // UserDefaults empty — recover from Keychain mirror (prefs wipe / OS cleanup).
        if let data = Keychain.getSessionData(Self.accountsBackupKey),
           let list = try? JSONDecoder().decode([AppleIDAccount].self, from: data),
           !list.isEmpty {
            accounts = list
            activeAccountID = Keychain.getSessionSecret(Self.activeBackupKey) ?? list.first?.id
            // Write back to UserDefaults so the rest of the app keeps working.
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
            _ = Keychain.setSessionData(Self.accountsBackupKey, data)
        }
        UserDefaults.standard.set(activeAccountID, forKey: Self.activeKey)
        if let id = activeAccountID {
            _ = Keychain.setSessionSecret(Self.activeBackupKey, id)
        } else {
            Keychain.deleteSessionSecret(Self.activeBackupKey)
        }
        UserDefaults.standard.set(activeAccount?.email ?? "", forKey: "tetherless.appleid.activeEmailCache")
        mirrorActiveStoreSessionToKeychain()
    }

    private func restoreStoreSessionsFromKeychain() {
        var restored = false
        for i in accounts.indices {
            if accounts[i].storeSessionJSON == nil,
               let data = Keychain.getSessionData(Self.storeSessionPrefix + accounts[i].id),
               !data.isEmpty {
                accounts[i].storeSessionJSON = data
                restored = true
            }
        }
        if restored { save() }
    }

    private func mirrorActiveStoreSessionToKeychain() {
        guard let account = activeAccount else { return }
        if let data = account.storeSessionJSON, !data.isEmpty {
            _ = Keychain.setSessionData(Self.storeSessionPrefix + account.id, data)
        }
    }

    private func migrateLegacyIfNeeded() {
        guard accounts.isEmpty, let email = Keychain.get(Self.legacyEmailKey), !email.isEmpty else { return }
        let id = UUID().uuidString
        accounts = [AppleIDAccount(id: id, email: email, addedAt: Date())]
        activeAccountID = id
        if let pw = Keychain.getSecret(Self.legacyPasswordKey) ?? Keychain.getSessionSecret(Self.legacyPasswordKey),
           !pw.isEmpty {
            _ = Keychain.setSessionSecret(Self.passwordPrefix + id, pw)
        }
        storeReady = true
        UserDefaults.standard.set(true, forKey: Self.storeReadyKey)
        save()
    }

    /// Read Apple ID password with AfterFirstUnlock accessibility; migrate older WhenUnlocked items.
    private func passwordForAccount(id: String) -> String? {
        let key = Self.passwordPrefix + id
        if let pw = Keychain.getSessionSecret(key), !pw.isEmpty {
            // Re-write under AfterFirstUnlock so cold-launch / lock-screen refresh still works.
            _ = Keychain.setSessionSecret(key, pw)
            return pw
        }
        if let pw = Keychain.getSecret(key), !pw.isEmpty {
            _ = Keychain.setSessionSecret(key, pw)
            return pw
        }
        return nil
    }

    /// Remint in the background when the token is missing or older than this (PET keeps 2FA quiet).
    private static let storeSessionMaxAge: TimeInterval = 12 * 60 * 60

    /// Background: refresh missing / aged store tokens without bouncing the user to Sign In.
    private func quietlyRefreshStorefrontIfNeeded() async {
        guard activeAccount != nil else { return }
        if let existing = storefrontSession(), existing.isUsable {
            if !existing.isAged(maxAge: Self.storeSessionMaxAge) { return }
            // Aged but structurally usable — soft remint; keep prior if remint soft-fails.
            storefrontNeedsRefresh = true
            _ = try? await ensureStorefrontSession(forceRefresh: true)
            return
        }
        await reconnectStoreSessionIfNeeded()
    }

    /// Warm anisette + SAP + store session before Decrypt / Retry so the first download isn't cold.
    /// Does **not** remint solely because the token is aged — that flapped green Store Access
    /// into HTTP 404 during test downloads. Age remint stays in `quietlyRefreshStorefrontIfNeeded`.
    @discardableResult
    func reinforceStoreConnection(forceRemint: Bool = false) async -> StorefrontSession? {
        sanitizeStoreIdentityForAccountAPIs()
        async let warmAnisette: Void = AnisetteClient.shared.prefetchIfNeeded()
        async let warmSAP: Void = SAPSigner.warm()
        _ = await (warmAnisette, warmSAP)

        let prior = storefrontSession()
        if !forceRemint, !storefrontNeedsRefresh, let prior, prior.isUsable {
            clearStaleStoreErrorIfSessionUsable()
            return prior
        }
        let refresh = forceRemint || storefrontNeedsRefresh || prior?.isUsable != true
        do {
            let session = try await ensureStorefrontSession(forceRefresh: refresh)
            clearStaleStoreErrorIfSessionUsable()
            return session
        } catch {
            // Never soft-restore a prior token after an explicit remint/refresh failure —
            // that left Settings green while downloads kept 403'ing.
            if forceRemint || storefrontNeedsRefresh { return nil }
            if let prior, prior.isUsable { return prior }
            return nil
        }
    }

    /// True when Settings shows the green “Signed in for Store access” seal.
    var hasStoreDownloadSession: Bool {
        storefrontSession()?.isUsable == true
    }

    /// Settings: finish “Signed in for Store access” using the saved Apple ID password (same session).
    /// - Parameter force: Re-mint even when a structurally “usable” token exists (dead tokens 204 Owned).
    func reconnectStoreSessionIfNeeded(force: Bool = false) async {
        guard activeAccount != nil else { return }
        if !force, !storefrontNeedsRefresh, let existing = storefrontSession(), existing.isUsable {
            storeNeedsVerification = false
            storeConnecting = false
            // Keep the edge warm without blocking Settings chrome.
            Task { await reinforceStoreConnection(forceRemint: false) }
            return
        }
        guard !storeConnecting else { return }
        guard let email = activeAccount?.email, !email.isEmpty,
              let aid = activeAccountID,
              let password = passwordForAccount(id: aid), !password.isEmpty else {
            storeNeedsVerification = true
            return
        }
        // Never wipe a usable token before remint succeeds — snapshot + restore on failure.
        let previous = storefrontSession()
        if force {
            sanitizeStoreIdentityForAccountAPIs()
            await AnisetteClient.shared.invalidate(resetProvisioning: false)
            SAPSigner.invalidateCache()
            storefrontNeedsRefresh = true
        }
        // Keep Allow/SMS digits when Retrying — PET alone often still needs that code.
        await connectStoreSession(
            email: email,
            password: password,
            authCode: pendingStoreAuthCode,
            prefetched: nil,
            pet: storedPET(),
            teamName: activeAccount?.teamName
        )
        if storefrontSession()?.isUsable != true, let previous, previous.isUsable {
            persistStoreSession(previous)
            storeNeedsVerification = false
            lastError = nil
        }
    }

    /// Drop a dead passwordToken so Retry / Owned can re-mint (keeps Apple ID signed in).
    func clearPersistedStoreSession() {
        guard let aid = activeAccountID,
              let idx = accounts.firstIndex(where: { $0.id == aid }) else { return }
        accounts[idx].storeSessionJSON = nil
        _ = Keychain.setSessionData(Self.storeSessionPrefix + aid, Data())
        storefrontNeedsRefresh = true
        save()
    }

    /// Account APIs (authenticate / Owned) use real-device identity only — wipe any leftover Store spoof.
    func sanitizeStoreIdentityForAccountAPIs() {
        StoreDeviceSpoof.clearPersistedSpoof()
    }

    // MARK: Auth — Settings / Decrypt API

    /// Primary Store Access path — iPadn MZFinance login (bag.xml + WASM/Anisette proof).
    /// Throws `AppStoreClientError.needsTwoFactor` so `IPadnLoginView` can show the code step.
    func signInViaIPadnStore(email: String, password: String, code: String = "") async throws {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let p = password
        let digits = code.filter(\.isNumber)
        guard !e.isEmpty, !p.isEmpty else {
            throw AppStoreClientError.message("Enter your Apple ID and password.")
        }
        // Phone Apple IDs are valid in iPadn; email still preferred but not required.
        lastError = nil
        statusMessage = digits.isEmpty ? "Signing in with Store login…" : "Verifying with Apple…"
        draftEmail = e
        authPhase = digits.isEmpty ? .authenticating : .verifying
        _ = Keychain.setSessionSecret(Self.passwordPrefix + "pending", p)
        do {
            let storeSession = try await IPadnStoreLogin.authenticate(
                email: e,
                password: p,
                authCode: digits
            )
            guard storeSession.isUsable else {
                throw AppStoreClientError.message("Apple returned an incomplete Store session. Try again.")
            }
            await finishRealSignInWithStoreOnly(email: e, password: p, store: storeSession)
            // Best-effort portal (signing) session — never undo a good Store login.
            Task { await self.attemptPortalAfterIPadnStore(email: e, password: p) }
        } catch AppStoreClientError.needsTwoFactor {
            withAnimation(.snappy) { authPhase = .awaitingTwoFactor }
            statusMessage = "Allow this sign-in on a trusted device, then enter the 6-digit code."
            lastError = nil
            // MZFinance asks for a code but does not fire the Allow push — deliver it once via GSA
            // as a MacBook so the map Allow overlays this iPhone (not “other trusted devices only”).
            await deliverAllowPushForStoreCode(force: false)
            throw AppStoreClientError.needsTwoFactor
        } catch let err as IPadnAppleLoginError {
            switch err {
            case .verificationRequired:
                withAnimation(.snappy) { authPhase = .awaitingTwoFactor }
                statusMessage = err.localizedDescription
                lastError = nil
                await deliverAllowPushForStoreCode(force: false)
                throw AppStoreClientError.needsTwoFactor
            case .verificationRejected:
                authPhase = .awaitingTwoFactor
                lastError = err.localizedDescription
                throw AppStoreClientError.message(err.localizedDescription)
            }
        } catch is CancellationError {
            authPhase = verifyingOrAwaiting ? authPhase : .idle
            throw CancellationError()
        } catch {
            authPhase = .idle
            lastError = error.localizedDescription
            throw error
        }
    }

    private var verifyingOrAwaiting: Bool {
        authPhase == .verifying || authPhase == .awaitingTwoFactor
    }

    /// Optional GrandSlam portal after Store is already green (signing certs / manage).
    private func attemptPortalAfterIPadnStore(email: String, password: String) async {
        do {
            let portal = try await GSAAuthClient.shared.authenticate(email: email, password: password)
            if let idx = accounts.firstIndex(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) {
                accounts[idx].portalSessionJSON = try? JSONEncoder().encode(portal)
                accounts[idx].teamID = portal.teamID
                accounts[idx].teamName = portal.teamName
                save()
            }
        } catch AppleAuthError.needsTwoFactor {
            // Keep the GSA challenge alive so IPadnLoginView can finish portal tokens
            // for free signing. Cancelling here left store login without portal session.
            refreshTwoFactorChannelFromGSA()
            withAnimation(.snappy) { authPhase = .awaitingTwoFactor }
            statusMessage = "Store ready — enter the 6-digit code if prompted (signing)."
            lastError = nil
        } catch {
            // Non-fatal for downloads — portal tokens can finish on the next Account sign-in.
        }
    }

    /// Password held for the in-flight Store / portal 2FA (or the active account secret).
    /// Used when `IPadnLoginView` is re-presented after Allow and local `@State` was wiped.
    func pendingSignInPassword() -> String? {
        if let pending = Keychain.getSessionSecret(Self.passwordPrefix + "pending"), !pending.isEmpty {
            return pending
        }
        if let pending = Keychain.getSecret(Self.passwordPrefix + "pending"), !pending.isEmpty {
            return pending
        }
        if let account = activeAccount, let saved = passwordForAccount(id: account.id), !saved.isEmpty {
            return saved
        }
        return nil
    }

    /// Explicit Cancel on the login sheet — drop pending 2FA UI without wiping the account.
    func clearPendingTwoFactorUI() {
        if authPhase == .awaitingTwoFactor || authPhase == .verifying {
            authPhase = .idle
        }
        storeNeedsVerification = false
        statusMessage = nil
        GSAAuthClient.shared.cancel()
    }

    func signIn(email: String, password: String) async {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let p = password
        guard !e.isEmpty, !p.isEmpty else {
            lastError = "Enter a valid Apple ID and password."
            return
        }
        // Prefer iPadn Store login (same as LoginView) so downloads don't fail after GSA-only trust.
        do {
            try await signInViaIPadnStore(email: e, password: p, code: "")
            return
        } catch AppStoreClientError.needsTwoFactor {
            // Keep awaitingTwoFactor — Settings twoFactorBlock / IPadnLoginView continue.
            return
        } catch {
            // Fall through to legacy GSA when MZFinance is unreachable.
            lastError = nil
            statusMessage = "Store login unavailable — trying Apple ID sign-in…"
        }

        lastError = nil
        statusMessage = nil
        draftEmail = e
        authPhase = .authenticating
        _ = Keychain.setSessionSecret(Self.passwordPrefix + "pending", p)
        do {
            let session = try await GSAAuthClient.shared.authenticate(email: e, password: p)
            await finishRealSignIn(session: session, password: p)
        } catch AppleAuthError.needsTwoFactor {
            refreshTwoFactorChannelFromGSA()
            withAnimation(.snappy) { authPhase = .awaitingTwoFactor }
            // GSAAuthClient already fired the Mac trusteddevice GET (Allow + code sheets).
            // Don't request again here — a second GET can invalidate the on-screen code.
            statusMessage = twoFactorPromptMessage()
            lastError = nil
        } catch {
            authPhase = .idle
            lastError = error.localizedDescription
            Keychain.deleteSessionSecret(Self.passwordPrefix + "pending")
            pendingStoreAuthCode = nil
            pendingStoreSession = nil
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
        pendingStoreSession = nil

        var pw = Keychain.getSessionSecret(Self.passwordPrefix + "pending")
            ?? Keychain.getSecret(Self.passwordPrefix + "pending")
            ?? ""
        var email = draftEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Already signed in (Store unlock / portal after Allow): use the active account secret.
        // Phone Apple IDs are valid — do not require `@`.
        if pw.isEmpty || email.isEmpty,
           let account = activeAccount,
           let saved = passwordForAccount(id: account.id), !saved.isEmpty {
            email = account.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            pw = saved
        }

        guard !pw.isEmpty, !email.isEmpty else {
            lastError = "Missing Apple ID password for Store unlock. Cancel, then Sign In again so Store can piggyback the first trust."
            statusMessage = twoFactorPromptMessage()
            authPhase = .awaitingTwoFactor
            return
        }

        let gsaPending = GSAAuthClient.shared.hasPendingTwoFactor

        // Allow digits are delivered by GSA push but must hit MZFinance first (password+code).
        // Submitting GSA first burns the one-time code so Store then says invalid — that was
        // the “second try Allow appears, code already invalid” failure mode.
        statusMessage = "Unlocking Store with verification code…"
        do {
            try await signInViaIPadnStore(email: email, password: pw, code: digits)
            await finishOrClearPendingGSA(code: digits)
            return
        } catch AppStoreClientError.needsTwoFactor {
            lastError = "That code didn’t unlock Store. Tap Send again for a fresh Allow sheet, then enter the new code."
            authPhase = .awaitingTwoFactor
            statusMessage = "Allow this sign-in on a trusted device, then enter the 6-digit code."
            return
        } catch {
            // Direct MZFinance retry before involving GrandSlam.
            do {
                let store = try await authenticateStoreWithRetries(
                    email: email,
                    password: pw,
                    authCode: digits
                )
                await finishRealSignInWithStoreOnly(email: email, password: pw, store: store)
                await finishOrClearPendingGSA(code: digits)
                return
            } catch AppStoreClientError.needsTwoFactor {
                lastError = "That code didn’t unlock Store. Tap Send again for a fresh Allow sheet, then enter the new code."
                authPhase = .awaitingTwoFactor
                statusMessage = "Allow this sign-in on a trusted device, then enter the 6-digit code."
                return
            } catch {
                if !gsaPending {
                    lastError = error.localizedDescription
                        + " Tap Send again for a fresh Allow sheet, or Sign Out / Sign In."
                    authPhase = .awaitingTwoFactor
                    statusMessage = "Allow this sign-in on a trusted device, then enter the 6-digit code."
                    return
                }
                // Fall through to portal GSA when Store rejected for a non-2FA reason.
            }
        }

        guard gsaPending else { return }

        // Portal / GrandSlam only — Store already failed above.
        statusMessage = "Finishing Apple ID trust…"
        do {
            let session = try await GSAAuthClient.shared.submitTwoFactor(code: digits)
            await finishRealSignIn(session: session, password: pw)
        } catch {
            lastError = error.localizedDescription
                + " Tap Send again for a fresh Allow sheet, or Sign Out / Sign In."
            statusMessage = twoFactorPromptMessage()
            authPhase = .awaitingTwoFactor
        }
    }

    /// Fire trusted-device Allow once so the in-app code field has digits to enter.
    /// MZFinance `needsTwoFactor` does not send the system Allow sheet by itself.
    private func deliverAllowPushForStoreCode(force: Bool) async {
        // Reset a stuck iPhone AuthKit identity and re-push as MacBook when needed —
        // otherwise Apple never shows the location Allow on this phone.
        let resetFromiPhone = AuthClientSpoof.ensureMacBookForAllowOverlay()
        await requestTrustedDevicePush(forStoreUnlock: false, force: force || resetFromiPhone)
        if authPhase != .awaitingTwoFactor, authPhase != .verifying {
            withAnimation(.snappy) { authPhase = .awaitingTwoFactor }
        }
        if statusMessage?.isEmpty != false {
            statusMessage = twoFactorPromptMessage()
        }
    }

    /// Persist Apple ID + store when portal 2FA fails but MZFinance already accepted the same trust.
    private func finishRealSignInWithStoreOnly(
        email: String,
        password: String,
        store: StorefrontSession
    ) async {
        authPhase = .preparing
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let idx = accounts.firstIndex(where: { $0.email.caseInsensitiveCompare(e) == .orderedSame }) {
            activeAccountID = accounts[idx].id
            _ = Keychain.setSessionSecret(Self.passwordPrefix + accounts[idx].id, password)
        } else {
            let id = UUID().uuidString
            accounts.append(AppleIDAccount(id: id, email: e, addedAt: Date()))
            activeAccountID = id
            _ = Keychain.setSessionSecret(Self.passwordPrefix + id, password)
        }
        Keychain.deleteSessionSecret(Self.passwordPrefix + "pending")
        draftEmail = e
        draftPassword = ""
        verificationCode = ""
        twoFactorUsesSMS = false
        twoFactorPhoneHint = nil
        storeReady = true
        UserDefaults.standard.set(true, forKey: Self.storeReadyKey)
        persistStoreSession(store)
        storeNeedsVerification = false
        pendingStoreAuthCode = nil
        pendingStoreSession = nil
        statusMessage = "Signed in · free & purchased downloads ready"
        save()
        activatePreferredSigningCertificate()
        await finishPreparing()
    }

    /// Texts a code to the Apple ID’s trusted phone (SMS). Prefer this when no other Apple device is nearby.
    /// Opens a fresh GSA 2FA challenge first when none is pending (Store Access “Text me a code”).
    /// - Parameter forStoreUnlock: When true (Store Access resend), skip Mac Allow push so MZFinance
    ///   can still accept the texted digits.
    func requestSMSCode(forStoreUnlock: Bool = false) async {
        lastError = nil
        authPhase = .verifying
        statusMessage = "Requesting a text message…"
        let gsa = GSAAuthClient.shared
        let hadPending = gsa.hasPendingTwoFactor
        do {
            if !hadPending {
                do {
                    try await openGSATwoFactorChallenge(forStoreSMS: forStoreUnlock)
                    // Rare: Apple didn’t ask for 2FA — refresh store session instead of SMS.
                    storefrontNeedsRefresh = true
                    if let session = try? await ensureStorefrontSession(forceRefresh: true), session.isUsable {
                        storeNeedsVerification = false
                        authPhase = .idle
                        statusMessage = "Store access ready — free & purchased downloads unlocked"
                        return
                    }
                } catch AppleAuthError.needsTwoFactor {
                    // Pending DSID / idms / anisette are live — fall through to SMS.
                }
            }
            guard gsa.hasPendingTwoFactor else {
                throw AppleAuthError.missingPendingAuth
            }
            // authenticateOnce may already have texted once while opening the challenge —
            // don't double-send on the same tap. Explicit resend (hadPending) always texts again.
            if !hadPending, case .sms = gsa.twoFactorChannel, gsa.twoFactorCodeAlreadySent {
                refreshTwoFactorChannelFromGSA()
                authPhase = .awaitingTwoFactor
                storeNeedsVerification = true
                applySMSSentStatus(hint: gsa.twoFactorPhoneHint)
                return
            }
            let hint = try await gsa.requestSMSCode()
            refreshTwoFactorChannelFromGSA()
            authPhase = .awaitingTwoFactor
            storeNeedsVerification = true
            applySMSSentStatus(hint: hint.isEmpty ? nil : hint)
        } catch {
            refreshTwoFactorChannelFromGSA()
            authPhase = gsa.hasPendingTwoFactor ? .awaitingTwoFactor : .idle
            storeNeedsVerification = true
            lastError = error.localizedDescription
            statusMessage = "Couldn't text a code (\(error.localizedDescription)). Try again in a moment."
        }
    }

    private func applySMSSentStatus(hint: String?) {
        let cleaned = (hint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // GSA phone id is often `"1"` — never show that as the destination.
        if !cleaned.isEmpty, !(cleaned.allSatisfy(\.isNumber) && cleaned.count <= 3) {
            statusMessage = "A text message with a code was sent to \(cleaned). Enter it below."
        } else {
            statusMessage = "A text message with a code was sent to your trusted phone number. Enter it below."
        }
    }

    /// Re-run GrandSlam password SRP so Apple opens a 2FA challenge (pending DSID/idms for SMS).
    /// - Parameter forStoreSMS: Skip Mac trusted-device push so the texted code stays usable for MZFinance.
    private func openGSATwoFactorChallenge(forStoreSMS: Bool = false) async throws {
        guard let account = activeAccount else {
            throw AppleAuthError.message("Sign in under Account first.")
        }
        guard let password = passwordForAccount(id: account.id), !password.isEmpty else {
            throw AppleAuthError.message("Missing Apple ID password — sign out and sign in again under Account.")
        }
        _ = try await GSAAuthClient.shared.authenticate(
            email: account.email,
            password: password,
            requestTrustedDevicePush: !forStoreSMS
        )
    }

    var isSMSTwoFactor: Bool { twoFactorUsesSMS }

    private func refreshTwoFactorChannelFromGSA() {
        let gsa = GSAAuthClient.shared
        if case .sms = gsa.twoFactorChannel {
            twoFactorUsesSMS = true
        } else {
            twoFactorUsesSMS = false
        }
        let hint = (gsa.twoFactorPhoneHint ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if hint.allSatisfy(\.isNumber), hint.count <= 3 {
            twoFactorPhoneHint = nil
        } else {
            twoFactorPhoneHint = hint.isEmpty ? nil : hint
        }
    }

    private func twoFactorPromptMessage() -> String {
        if twoFactorUsesSMS {
            if let hint = twoFactorPhoneHint, !hint.isEmpty {
                return "Enter the 6-digit code texted to \(hint)."
            }
            return "Enter the 6-digit code texted to your phone."
        }
        // System sheets overlay THIS app when AuthKit claims a MacBook (not iPhone).
        let device = AuthClientSpoof.current.displayName
        if storeNeedsVerification, isSignedIn {
            return "Watch for Apple’s Allow sheet (map · \(device)) on this iPhone and enter the 6-digit code below to unlock Store downloads. Turn Focus off (moon) if it doesn’t appear."
        }
        return "Watch for Apple’s Allow sheet (map · \(device)) on this iPhone, then enter the verification code below — turn Focus off (moon) if they don’t appear."
    }

    /// Trusted-device Allow push (“Send again to devices”).
    /// - Parameter forStoreUnlock: Second-step Store unlock after Apple ID is already signed in.
    /// - Parameter force: When false, keep an Allow that was already sent (a second push burns the first code).
    func requestTrustedDevicePush(forStoreUnlock: Bool = false, force: Bool = false) async {
        lastError = nil
        // Always MacBook for map Allow on this iPhone (Store unlock + Apple ID Step 1).
        let resetFromiPhone = AuthClientSpoof.ensureMacBookForAllowOverlay()
        let forcePush = force || resetFromiPhone
        let keepStoreSheet = forStoreUnlock || (isSignedIn && storeNeedsVerification)
        authPhase = .verifying
        statusMessage = forcePush
            ? "Sending a fresh Allow request (MacBook · map on this iPhone)…"
            : "Sending Allow request (MacBook · map on this iPhone)…"
        let gsa = GSAAuthClient.shared

        func finishWaitingForCode() {
            refreshTwoFactorChannelFromGSA()
            // Never demote a green Store session just because Apple ID is signed in —
            // that forced Unlock Store / re-login between Gets of different apps.
            if storefrontSession()?.isUsable == true {
                clearStoreVerificationIfSessionUsable()
            } else if forStoreUnlock || storeNeedsVerification {
                storeNeedsVerification = true
            }
            authPhase = keepStoreSheet ? .idle : .awaitingTwoFactor
            statusMessage = twoFactorPromptMessage()
        }

        do {
            if !gsa.hasPendingTwoFactor {
                // After Apple ID sign-in, GSA pending is cleared — open a new challenge and
                // fire the trusted-device push so Store can get a fresh Allow code.
                do {
                    try await openGSATwoFactorChallenge(forStoreSMS: false)
                    storefrontNeedsRefresh = true
                    if let session = try? await ensureStorefrontSession(forceRefresh: true), session.isUsable {
                        storeNeedsVerification = false
                        authPhase = .idle
                        statusMessage = "Store access ready — free & purchased downloads unlocked"
                        return
                    }
                    if storefrontSession()?.isUsable == true {
                        clearStoreVerificationIfSessionUsable()
                        authPhase = .idle
                        statusMessage = "Store access ready — free & purchased downloads unlocked"
                    } else if keepStoreSheet {
                        storeNeedsVerification = true
                        authPhase = .idle
                        statusMessage = "Couldn't mint Store from trust alone — tap Send again, then enter the Allow code."
                    } else {
                        authPhase = .idle
                    }
                    return
                } catch AppleAuthError.needsTwoFactor {
                    // authenticateOnce already sent the Allow push — do not send another.
                    finishWaitingForCode()
                    return
                }
            }

            // Challenge already live: only re-push when the user explicitly asks (force),
            // or we just flipped AuthKit back to MacBook (prior iPhone push won't overlay here).
            if gsa.twoFactorCodeAlreadySent, !forcePush {
                finishWaitingForCode()
                return
            }
            _ = try await gsa.requestTrustedDevicePush()
            finishWaitingForCode()
        } catch {
            refreshTwoFactorChannelFromGSA()
            if storefrontSession()?.isUsable == true {
                clearStoreVerificationIfSessionUsable()
                authPhase = .idle
            } else if keepStoreSheet {
                storeNeedsVerification = true
                authPhase = .idle
            } else {
                authPhase = gsa.hasPendingTwoFactor ? .awaitingTwoFactor : .idle
            }
            lastError = error.localizedDescription
            statusMessage = "Couldn't send the MacBook Allow sheet. Turn Focus off, then tap Resend Code."
        }
    }

    func submitVerificationCode() {
        Task { await submitTwoFactor(code: verificationCode) }
    }

    func cancelTwoFactor() {
        GSAAuthClient.shared.cancel()
        Keychain.deleteSessionSecret(Self.passwordPrefix + "pending")
        pendingStoreAuthCode = nil
        pendingStoreSession = nil
        authPhase = .idle
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

    /// Distinct ISO country codes for every linked account that has a storefront session.
    func linkedStorefrontCountryCodes() -> [String] {
        var codes: [String] = []
        var seen = Set<String>()
        for account in accounts {
            guard let data = account.storeSessionJSON,
                  let session = try? JSONDecoder().decode(StorefrontSession.self, from: data),
                  let code = StorefrontCountry.code(fromStoreFront: session.storeFront) else {
                continue
            }
            if seen.insert(code).inserted {
                codes.append(code)
            }
        }
        return codes
    }

    /// Activate the linked Apple ID whose storefront matches `countryCode` (e.g. `jp`).
    @discardableResult
    func selectAccountMatching(countryCode: String) -> Bool {
        let want = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !want.isEmpty else { return false }
        for account in accounts {
            guard let data = account.storeSessionJSON,
                  let session = try? JSONDecoder().decode(StorefrontSession.self, from: data),
                  let code = StorefrontCountry.code(fromStoreFront: session.storeFront),
                  code == want else {
                continue
            }
            if account.id != activeAccountID {
                selectAccount(id: account.id)
            }
            return true
        }
        return false
    }

    func removeAccount(id: String) {
        Keychain.deleteSessionSecret(Self.passwordPrefix + id)
        Keychain.deleteSessionSecret(Self.petPrefix + id)
        Keychain.deleteSessionSecret(Self.petMintedAtPrefix + id)
        _ = Keychain.setSessionData(Self.storeSessionPrefix + id, Data())
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
        for a in accounts {
            Keychain.deleteSessionSecret(Self.passwordPrefix + a.id)
            Keychain.deleteSessionSecret(Self.petPrefix + a.id)
            Keychain.deleteSessionSecret(Self.petMintedAtPrefix + a.id)
            _ = Keychain.setSessionData(Self.storeSessionPrefix + a.id, Data())
        }
        Keychain.deleteSessionSecret(Self.accountsBackupKey)
        Keychain.deleteSessionSecret(Self.activeBackupKey)
        accounts = []
        activeAccountID = nil
        draftEmail = ""
        draftPassword = ""
        verificationCode = ""
        storeReady = false
        storeConnecting = false
        storefrontNeedsRefresh = false
        statusMessage = nil
        lastError = nil
        presentedDisplayCode = nil
        twoFactorUsesSMS = false
        twoFactorPhoneHint = nil
        pendingStoreSession = nil
        authPhase = .idle
        UserDefaults.standard.set(false, forKey: Self.storeReadyKey)
        save()
        _ = Keychain.set(Self.legacyEmailKey, "")
        Keychain.deleteSessionSecret(Self.legacyPasswordKey)
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
        // Renew replaces: drop expired/stale linked IDs so preference never sticks on the old cert.
        let store = CertificateStore.shared
        accounts[idx].linkedCertificateIDs.removeAll { id in
            guard let c = store.certificates.first(where: { $0.id == id }) else { return true }
            return store.cachedProfileInfo(for: c).isExpired
        }
        if !accounts[idx].linkedCertificateIDs.contains(certID) {
            accounts[idx].linkedCertificateIDs.insert(certID, at: 0)
        } else if let at = accounts[idx].linkedCertificateIDs.firstIndex(of: certID), at != 0 {
            accounts[idx].linkedCertificateIDs.remove(at: at)
            accounts[idx].linkedCertificateIDs.insert(certID, at: 0)
        }
        accounts[idx].revokedCertificateIDs.removeAll { $0 == certID }
        if let cert = store.certificates.first(where: { $0.id == certID }) {
            let info = store.cachedProfileInfo(for: cert)
            mergeProfileInfo(info, into: idx)
        }
        store.activeID = certID
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

    /// Prefer a non-expired certificate linked to the active Store account.
    /// Does not fall back to arbitrary custom/enterprise certs (those use their own signing method).
    func preferredSigningCertificateID() -> String? {
        let store = CertificateStore.shared
        let linked = activeAccount?.linkedCertificateIDs ?? []
        // Newest-first: linkCertificate inserts at 0; skip expired / deleted.
        for id in linked {
            guard let cert = store.certificates.first(where: { $0.id == id }) else { continue }
            if store.cachedProfileInfo(for: cert).isExpired { continue }
            return cert.id
        }
        return nil
    }

    /// True when `cert` is linked to the active Apple ID (free 7-day path).
    func isLinkedAppleIDCertificate(_ cert: Certificate) -> Bool {
        activeAccount?.linkedCertificateIDs.contains(cert.id) == true
    }

    func portalSession() -> AppleAuthSession? {
        guard let data = activeAccount?.portalSessionJSON else { return nil }
        return try? JSONDecoder().decode(AppleAuthSession.self, from: data)
    }

    /// Re-run GrandSlam with the saved password so Developer Portal tokens work again after error 1100.
    @discardableResult
    func refreshPortalSession() async throws -> AppleAuthSession {
        guard let account = activeAccount else {
            throw AppleAuthError.message("Sign in under Account first.")
        }
        guard let password = passwordForAccount(id: account.id), !password.isEmpty else {
            throw AppleAuthError.message("Missing Apple ID password — sign out and sign in again under Account.")
        }
        authPhase = .authenticating
        lastError = nil
        statusMessage = "Refreshing Developer Portal session…"
        do {
            let session = try await GSAAuthClient.shared.authenticate(email: account.email, password: password)
            await finishRealSignIn(session: session, password: password)
            return session
        } catch AppleAuthError.needsTwoFactor {
            withAnimation(.snappy) { authPhase = .awaitingTwoFactor }
            refreshTwoFactorChannelFromGSA()
            statusMessage = twoFactorPromptMessage()
            throw AppleAuthError.needsTwoFactor
        } catch {
            authPhase = .idle
            lastError = error.localizedDescription
            throw error
        }
    }

    /// True when a portal API failure means the GrandSlam cookie/session must be renewed.
    static func isPortalSessionExpired(_ error: Error) -> Bool {
        if let e = error as? AppleAuthError, case .portal(let code, let msg) = e {
            return code == 1100 || msg.localizedCaseInsensitiveContains("session has expired")
        }
        let text = error.localizedDescription
        return text.contains("1100") || text.localizedCaseInsensitiveContains("session has expired")
    }

    /// iTunes Store session for silent purchase/download.
    func storefrontSession() -> StorefrontSession? {
        guard let data = activeAccount?.storeSessionJSON else { return nil }
        return try? JSONDecoder().decode(StorefrontSession.self, from: data)
    }

    /// Mark store token stale for the next ensure — does **not** wipe the persisted session
    /// (or the Apple ID). Re-auth replaces the token; sign-out is the only wipe path.
    func invalidateStorefrontSession() {
        storefrontNeedsRefresh = true
    }

    func noteStoreNeedsVerification() {
        // Owned/DAAP / soft errors must not demote a still-usable passwordToken —
        // that made the next Get look like a full Sign Out → Sign In.
        if storefrontSession()?.isUsable == true {
            storeNeedsVerification = false
            return
        }
        storeNeedsVerification = true
    }

    /// After a successful Get / unlock — keep Apple ID + Store green for the next app.
    func clearStoreVerificationIfSessionUsable() {
        guard storefrontSession()?.isUsable == true else { return }
        storeNeedsVerification = false
        storefrontNeedsRefresh = false
        if lastError.map(Self.isSoftStoreNoise) == true {
            lastError = nil
        }
    }

    /// Ensure a usable storefront session for silent buy/download.
    /// Remints with the same PET → password+code cascade as sign-in (password-only fails for 2FA).
    /// Never wipes a still-usable prior token when remint soft-fails.
    func ensureStorefrontSession(forceRefresh: Bool = false) async throws -> StorefrontSession {
        let refresh = forceRefresh || storefrontNeedsRefresh
        let prior = storefrontSession()
        if !refresh, let existing = prior, existing.isUsable {
            storeNeedsVerification = false
            return existing
        }
        guard let email = activeAccount?.email, !email.isEmpty else {
            throw AppStoreClientError.message("Sign in under Account first.")
        }
        guard let aid = activeAccountID,
              let password = passwordForAccount(id: aid), !password.isEmpty else {
            throw AppStoreClientError.message("Missing Apple ID password — sign in again under Account.")
        }

        let code = (pendingStoreAuthCode ?? "").filter(\.isNumber)
        // Skip dead PETs — they expire in minutes and make remint look like a logout.
        let pet = freshStoredPET()?.trimmingCharacters(in: .whitespacesAndNewlines)
        var lastError: Error?

        func accept(_ session: StorefrontSession) -> StorefrontSession {
            pendingStoreAuthCode = nil
            storefrontNeedsRefresh = false
            storeNeedsVerification = false
            persistStoreSession(session)
            // Keep PET for later remints during Decrypt — only sign-out clears it.
            return session
        }

        // Prefer password (+ code) when PET is stale/absent so we don't burn the UX on a dead PET.
        // 1) Password + digits.
        if code.count == 6 {
            do {
                let session = try await authenticateStoreWithRetries(
                    email: email, password: password, authCode: code
                )
                if session.isUsable { return accept(session) }
            } catch {
                lastError = error
            }
        }

        // 2) Fresh PET + digits (same Allow window).
        if let pet, !pet.isEmpty, code.count == 6 {
            do {
                let session = try await authenticateStoreWithRetries(
                    email: email, password: pet, authCode: code
                )
                if session.isUsable { return accept(session) }
            } catch {
                lastError = error
            }
        }

        // 3) Fresh PET alone.
        if let pet, !pet.isEmpty {
            do {
                let session = try await authenticateStoreWithRetries(
                    email: email, password: pet, authCode: ""
                )
                if session.isUsable { return accept(session) }
            } catch {
                lastError = error
                // Dead PET — drop it so the next remint goes straight to password.
                clearStoredPET()
            }
        }

        // 4) Password-only (non-2FA / warm edge).
        do {
            let session = try await AppStoreClient.shared.authenticate(
                email: email,
                password: password,
                authCode: nil
            )
            if session.isUsable { return accept(session) }
        } catch {
            lastError = error
        }

        // Prefer a still-usable prior token over bouncing to Unlock Store / Sign In.
        // needsTwoFactor on background remint is not proof the existing passwordToken is dead.
        if let existing = prior, existing.isUsable {
            if let ase = lastError as? AppStoreClientError, case .needsTwoFactor = ase {
                storefrontNeedsRefresh = false
                storeNeedsVerification = false
                return existing
            }
            if !forceRefresh {
                storefrontNeedsRefresh = false
                storeNeedsVerification = false
                return existing
            }
        }

        if let lastError {
            if let ase = lastError as? AppStoreClientError, case .needsTwoFactor = ase {
                storeNeedsVerification = true
            }
            throw lastError
        }
        throw AppStoreClientError.message("App Store sign-in failed after retries.")
    }

    /// Complete App Store (MZFinance) 2FA without signing out — then silent download works.
    /// GSA is only used to *deliver* the SMS; the digits must hit MZFinance first so the
    /// store passwordToken is minted before GrandSlam consumes the one-time code.
    func submitStoreVerificationCode(_ code: String) async throws -> StorefrontSession {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else {
            throw AppStoreClientError.message("Enter the 6-digit verification code.")
        }
        guard let email = activeAccount?.email, !email.isEmpty else {
            throw AppStoreClientError.message("Sign in under Account first.")
        }
        guard let aid = activeAccountID,
              let password = passwordForAccount(id: aid), !password.isEmpty else {
            throw AppStoreClientError.message(
                "Missing saved Apple ID password. Sign Out, then Sign In once — the same 2FA unlocks Store automatically."
            )
        }

        pendingStoreAuthCode = digits
        storefrontNeedsRefresh = true
        lastError = nil
        authPhase = .verifying
        statusMessage = "Unlocking Store downloads…"

        // Prefer PET + digits when we already have a GrandSlam trust token from Allow.
        let pet = storedPET()?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            var session: StorefrontSession?
            var petError: Error?
            if let pet, !pet.isEmpty {
                do {
                    session = try await authenticateStoreWithRetries(
                        email: email,
                        password: pet,
                        authCode: digits
                    )
                } catch {
                    petError = error
                    session = nil
                }
            }
            if session?.isUsable != true {
                // Hit MZFinance with password+code (not ensure→reuse stale flags).
                do {
                    session = try await authenticateStoreWithRetries(
                        email: email,
                        password: password,
                        authCode: digits
                    )
                } catch {
                    // Prefer password-path error; keep PET failure as context if both fail.
                    if let petError {
                        throw AppStoreClientError.message(
                            "Store unlock failed (\(error.localizedDescription)). PET path also failed: \(petError.localizedDescription)."
                        )
                    }
                    throw error
                }
            }
            guard let session, session.isUsable else {
                throw AppStoreClientError.message("App Store sign-in failed after retries.")
            }
            persistStoreSession(session)
            pendingStoreAuthCode = nil
            storefrontNeedsRefresh = false
            storeNeedsVerification = false
            authPhase = .idle
            statusMessage = "Store access ready — free & purchased downloads unlocked"
            // Best-effort: finish / clear the GSA challenge that sent the SMS (code may already be spent).
            await finishOrClearPendingGSA(code: digits)
            return session
        } catch AppStoreClientError.needsTwoFactor {
            // Store rejected the code — drop GSA pending so the next Resend starts clean.
            pendingStoreAuthCode = nil
            storeNeedsVerification = true
            authPhase = .awaitingTwoFactor
            GSAAuthClient.shared.cancel()
            twoFactorUsesSMS = false
            twoFactorPhoneHint = nil
            lastError = "That code didn’t unlock Store downloads (often burned by a second Apple prompt). Tap Send again for a fresh Allow sheet, then Submit — stay signed in."
            // Stay idle so Account shows Unlock Store (not the full Sign In sheet).
            authPhase = .idle
            throw AppStoreClientError.message(lastError ?? "Store needs a fresh code.")
        } catch {
            storeNeedsVerification = true
            authPhase = .idle
            lastError = error.localizedDescription
            throw error
        }
    }

    /// MZFinance authenticate — prefer iPadn bag.xml + redirect login, then AppStoreClient.
    private func authenticateStoreWithRetries(
        email: String,
        password: String,
        authCode: String
    ) async throws -> StorefrontSession {
        // iPadn MZFinance only — no AppStoreClient authenticate fallback / remint stack.
        let session = try await IPadnStoreLogin.authenticate(
            email: email,
            password: password,
            authCode: authCode
        )
        guard session.isUsable else {
            throw AppStoreClientError.message("Apple returned an incomplete Store session. Try again.")
        }
        statusMessage = "Store unlocked…"
        return session
    }

    /// After store verify, close out a pending GSA SMS challenge without blocking Store Access.
    private func finishOrClearPendingGSA(code: String) async {
        guard GSAAuthClient.shared.hasPendingTwoFactor else {
            withAnimation(.snappy) { authPhase = .idle }
            return
        }
        do {
            let portal = try await GSAAuthClient.shared.submitTwoFactor(code: code)
            if let idx = accounts.firstIndex(where: { $0.id == activeAccountID }) {
                accounts[idx].portalSessionJSON = try? JSONEncoder().encode(portal)
                accounts[idx].teamID = portal.teamID
                accounts[idx].teamName = portal.teamName
                save()
            }
        } catch {
            // Code was for the store session — drop the GSA pending state so Settings isn't stuck.
            GSAAuthClient.shared.cancel()
        }
        withAnimation(.snappy) { authPhase = .idle }
    }

    /// Recovery when Store never piggybacked the first trust / Owned HTTP 204:
    /// re-mint with PET (+ Allow digits if still held). Keeps the prior session if remint fails.
    func requestStoreVerificationPrompt() async {
        storefrontNeedsRefresh = true
        lastError = nil
        statusMessage = storedPET() == nil
            ? "No Store trust token yet — Sign Out, then Sign In once so Apple’s Allow code can mint Store…"
            : (pendingStoreAuthCode?.count == 6
                ? "Retrying Store with trust token + the same verification code…"
                : "Retrying Store with your Apple ID trust token…")
        // Drop stray GSA SMS challenges — Store must not ask for its own code.
        if GSAAuthClient.shared.hasPendingTwoFactor {
            GSAAuthClient.shared.cancel()
        }

        // Snapshot so a failed remint (HTTP 404 edge) cannot leave Store Access empty
        // when we already had a usable passwordToken.
        let previous = storefrontSession()
        // 302-without-Location / HTTP 204 Retry loops often follow exotic spoof + stale SAP.
        StoreDeviceSpoof.applyThisiPhone()
        await AnisetteClient.shared.invalidate(resetProvisioning: false)
        SAPSigner.invalidateCache()
        await AnisetteClient.shared.prefetchIfNeeded()
        await SAPSigner.warm()
        await reconnectStoreSessionIfNeeded(force: true)

        if let session = storefrontSession(), session.isUsable {
            storeNeedsVerification = false
            lastError = nil
            // Owned list is best-effort — never demote green Store Access if it soft-fails.
            _ = try? await AppStoreClient.shared.purchaseHistory(account: session)
            let keptPrior = previous.map { $0.passwordToken == session.passwordToken } ?? false
            statusMessage = keptPrior && previous != nil
                ? "Store access ready — kept previous session (remint soft-failed). Try Decrypt search/download."
                : "Store access ready — free & purchased downloads unlocked"
            withAnimation(.snappy) { authPhase = .idle }
            return
        }

        if let previous, previous.isUsable {
            persistStoreSession(previous)
            storeNeedsVerification = false
            lastError = nil
            statusMessage = "Store access ready — kept previous session (remint soft-failed). Try Decrypt search/download."
            withAnimation(.snappy) { authPhase = .idle }
            return
        }

        storeNeedsVerification = true
        statusMessage = "Store still needs an Allow push — open Unlock Store, tap Send again, then enter the 6-digit code."
        withAnimation(.snappy) { authPhase = .idle }
    }

    private func persistStoreSession(_ store: StorefrontSession) {
        guard let idx = accounts.firstIndex(where: { $0.email.caseInsensitiveCompare(store.email) == .orderedSame })
                ?? accounts.firstIndex(where: { $0.id == activeAccountID }) else { return }
        accounts[idx].storeSessionJSON = try? JSONEncoder().encode(store)
        // Mirror into Keychain so a prefs wipe doesn't drop the passwordToken mid-session.
        if let data = accounts[idx].storeSessionJSON {
            _ = Keychain.setSessionData(Self.storeSessionPrefix + accounts[idx].id, data)
        }
        storefrontNeedsRefresh = false
        save()
    }

    /// Fold live commerce Set-Cookie values into the persisted Store session jar.
    func mergeLiveStoreCookies(_ header: String?) {
        guard let header, !header.isEmpty else { return }
        guard let existing = storefrontSession(), existing.isUsable else { return }
        persistStoreSession(existing.mergingCookies(header))
    }

    /// After a successful Get — keep the in-flight Store session (and cookie jar) for the next app.
    func mergeStoreCookies(from account: StorefrontSession) {
        guard account.isUsable else { return }
        if let existing = storefrontSession(), existing.isUsable,
           existing.passwordToken == account.passwordToken {
            let merged = account.cookieHeader.map { existing.mergingCookies($0) } ?? existing
            persistStoreSession(merged)
        } else {
            persistStoreSession(account)
        }
        storeNeedsVerification = false
        storefrontNeedsRefresh = false
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
        // Keep PET in memory for Store mint; don't write the short-lived token into portal JSON.
        let petForStore = session.pet
        session.pet = nil
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
            _ = Keychain.setSessionSecret(Self.passwordPrefix + accounts[idx].id, password)
        } else {
            let id = UUID().uuidString
            var account = AppleIDAccount(id: id, email: email, addedAt: Date())
            account.portalSessionJSON = sessionJSON
            account.teamID = session.teamID
            account.teamName = session.teamName
            accounts.append(account)
            activeAccountID = id
            _ = Keychain.setSessionSecret(Self.passwordPrefix + id, password)
        }

        Keychain.deleteSessionSecret(Self.passwordPrefix + "pending")
        draftEmail = email
        draftPassword = ""
        verificationCode = ""
        twoFactorUsesSMS = false
        twoFactorPhoneHint = nil
        lastError = nil
        // Apple ID row can show Signed in immediately; Store Access keeps its own spinner
        // until the same-session passwordToken is persisted (green check target).
        storeReady = true
        UserDefaults.standard.set(true, forKey: Self.storeReadyKey)
        save()

        if let petForStore, !petForStore.isEmpty, let aid = activeAccountID {
            persistPET(petForStore, forAccountID: aid)
        }

        await connectStoreSession(
            email: email,
            password: password,
            authCode: pendingStoreAuthCode,
            prefetched: pendingStoreSession,
            pet: petForStore,
            teamName: session.teamName
        )
        pendingStoreSession = nil

        activatePreferredSigningCertificate()
        await finishPreparing()
    }

    /// Mint / persist iTunes Store session.
    /// Prefer GrandSlam PET as MZFinance `password` after HSA2 — raw Apple ID password
    /// alone does not unlock Store for 2FA accounts (Allow-sheet digits ≠ store OTPs).
    private func connectStoreSession(
        email: String,
        password: String,
        authCode: String?,
        prefetched: StorefrontSession?,
        pet: String?,
        teamName: String?
    ) async {
        storeConnecting = true
        statusMessage = "Connecting App Store download session…"
        defer { storeConnecting = false }
        sanitizeStoreIdentityForAccountAPIs()

        if let prefetched, prefetched.isUsable {
            persistStoreSession(prefetched)
            storeNeedsVerification = false
            pendingStoreAuthCode = nil
            // Keep PET so Decrypt remints / Retry Store unlock work without a second OTP.
            lastError = nil
            statusMessage = teamName.map { "Signed in · \($0) · free & purchased downloads ready" }
                ?? "Signed in · free & purchased downloads ready"
            return
        }

        let code = (authCode ?? "").filter(\.isNumber)
        // Prefer an explicitly passed PET from this sign-in; otherwise only a fresh PET.
        let resolvedPET = (pet ?? freshStoredPET())?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var lastStoreError: String?

        func succeed(_ store: StorefrontSession) {
            persistStoreSession(store)
            storeNeedsVerification = false
            pendingStoreAuthCode = nil
            // Keep PET for silent remint during purchase/download (cleared on Sign Out only).
            lastError = nil
            statusMessage = teamName.map { "Signed in · \($0) · free & purchased downloads ready" }
                ?? "Signed in · free & purchased downloads ready"
        }

        // 1) PET + same Allow/SMS digits — PET alone often still reports needsTwoFactor.
        if let resolvedPET, !resolvedPET.isEmpty, code.count == 6 {
            statusMessage = "Unlocking Store with trust token + code…"
            do {
                let store = try await authenticateStoreWithRetries(
                    email: email, password: resolvedPET, authCode: code
                )
                if store.isUsable { succeed(store); return }
            } catch {
                lastStoreError = "PET+code: \(error.localizedDescription)"
            }
        }

        // 2) PET alone.
        if let resolvedPET, !resolvedPET.isEmpty {
            statusMessage = "Unlocking Store with Apple ID trust token…"
            do {
                let store = try await authenticateStoreWithRetries(
                    email: email, password: resolvedPET, authCode: ""
                )
                if store.isUsable { succeed(store); return }
            } catch {
                lastStoreError = "Store PET unlock: \(error.localizedDescription)"
            }
        }

        // 3) Password + same digits (SMS-style store OTPs).
        if code.count == 6 {
            statusMessage = "Unlocking Store with the same verification code…"
            do {
                let store = try await authenticateStoreWithRetries(
                    email: email, password: password, authCode: code
                )
                if store.isUsable { succeed(store); return }
            } catch {
                lastStoreError = "password+code: \(error.localizedDescription)"
            }
        }

        // 4) Legacy password-only (non-2FA / rare warm sessions).
        for attempt in 1...2 {
            statusMessage = attempt == 1
                ? "Unlocking Store from the same Apple ID trust…"
                : "Retrying Store unlock…"
            if attempt > 1 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await AnisetteClient.shared.invalidate(resetProvisioning: false)
            }
            do {
                let store = try await AppStoreClient.shared.authenticate(
                    email: email, password: password, authCode: nil
                )
                if store.isUsable { succeed(store); return }
            } catch {
                lastStoreError = error.localizedDescription
            }
        }

        if storefrontSession()?.isUsable == true {
            storeNeedsVerification = false
            pendingStoreAuthCode = nil
            lastError = nil
            statusMessage = teamName.map { "Signed in · \($0)" } ?? "Signed in"
        } else {
            storeNeedsVerification = true
            if let lastStoreError, !lastStoreError.isEmpty {
                lastError = lastStoreError
            }
            statusMessage = "Signed in — Store needs a second Allow push. Open Unlock Store, allow the sign-in, then enter the code."
        }
    }

    /// Drop red Store-edge noise once a usable passwordToken session exists.
    func clearStaleStoreErrorIfSessionUsable() {
        guard storefrontSession()?.isUsable == true else { return }
        guard let err = lastError, Self.isSoftStoreNoise(err) || err.localizedCaseInsensitiveContains("store") else { return }
        lastError = nil
    }

    private static func isSoftStoreNoise(_ message: String) -> Bool {
        let m = message.lowercased()
        return m.contains("http 204")
            || m.contains("http 404")
            || m.contains("http 403")
            || m.contains("non-plist")
            || m.contains("without location")
            || m.contains("sap setup")
            || m.contains("network connection was lost")
            || m.contains("resend text")
            || m.contains("owned")
            || m.contains("token expired")
            || m.contains("session expired")
            || m.contains("daap")
    }

    private func storedPET() -> String? {
        guard let aid = activeAccountID else { return nil }
        return Keychain.getSessionSecret(Self.petPrefix + aid)
    }

    /// PET only if minted recently — Apple PETs die in minutes and fake a “logged out” remint.
    private func freshStoredPET() -> String? {
        guard let aid = activeAccountID,
              let pet = Keychain.getSessionSecret(Self.petPrefix + aid),
              !pet.isEmpty else { return nil }
        guard let raw = Keychain.getSessionSecret(Self.petMintedAtPrefix + aid),
              let minted = Double(raw) else {
            // Legacy PET without mint time — treat as stale so password remint wins.
            return nil
        }
        let age = Date().timeIntervalSince1970 - minted
        guard age >= 0, age <= Self.petUsefulLifetime else { return nil }
        return pet
    }

    private func persistPET(_ pet: String, forAccountID aid: String) {
        _ = Keychain.setSessionSecret(Self.petPrefix + aid, pet)
        _ = Keychain.setSessionSecret(
            Self.petMintedAtPrefix + aid,
            String(Date().timeIntervalSince1970)
        )
    }

    private func clearStoredPET() {
        guard let aid = activeAccountID else { return }
        Keychain.deleteSessionSecret(Self.petPrefix + aid)
        Keychain.deleteSessionSecret(Self.petMintedAtPrefix + aid)
    }

    private func finishPreparing() async {
        storeConnecting = false
        storeReady = true
        UserDefaults.standard.set(true, forKey: Self.storeReadyKey)
        clearStaleStoreErrorIfSessionUsable()
        withAnimation(.snappy) { authPhase = .idle }
    }
}
