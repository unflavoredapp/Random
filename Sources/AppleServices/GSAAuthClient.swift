//
//  GSAAuthClient.swift
//  Real Apple GrandSlam SRP authentication + trusted-device / SMS 2FA.
//  Pattern from SideSign Authentication.swift — no simulated delays or fake codes.
//

import Foundation
import Combine

@MainActor
final class GSAAuthClient: ObservableObject {
    static let shared = GSAAuthClient()

    private let gsURL = URL(string: "https://gsa.apple.com/grandslam/GsService2")!
    private let validateURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/validate")!
    private let trustedDeviceURL = URL(string: "https://gsa.apple.com/auth/verify/trusteddevice")!
    private let trustedDeviceSecurityCodeURL = URL(string: "https://gsa.apple.com/auth/verify/trusteddevice/securitycode")!
    private let phonePutURL = URL(string: "https://gsa.apple.com/auth/verify/phone/put?mode=sms")!
    private let phoneSecurityCodeURL = URL(string: "https://gsa.apple.com/auth/verify/phone/securitycode?referrer=/auth/verify/phone/put")!
    private let authApp = "com.apple.gs.xcode.auth"
    /// Personally Entitled Token — MZFinance authenticate accepts this as `password` after HSA2.
    private let petApp = "com.apple.gs.idms.pet"
    /// SideInstaller / SideStore working Xcode version string for GSA + 2FA.
    private let xcodeVersion = "15.3 (15E204a)"
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // GrandSlam sometimes redirects to HTML error pages; never follow those.
        config.httpShouldSetCookies = false
        // Avoid connection reuse — GSA/auth often returns 5xx on pooled sockets (SideStore).
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config, delegate: GSRedirectBlocker.shared, delegateQueue: nil)
    }()

    private var pendingEmail = ""
    private var pendingPassword = ""
    private var pendingAnisette: AnisetteHeaders?
    private var pendingDSID: String?
    private var pendingIDMS: String?
    private var pending2FA: TwoFactorPending?
    /// Captured from validate `X-Apple-PE-Token` or apptokens `com.apple.gs.idms.pet`.
    private var pendingPET: String?
    /// Apple already pushed a code (hsc 409 / pushedCode) — do not hit /trusteddevice again.
    private(set) var twoFactorCodeAlreadySent = false
    /// Obfuscated phone shown after SMS request (e.g. ••••42).
    private(set) var twoFactorPhoneHint: String?
    /// Active 2FA channel for UI copy / resend.
    private(set) var twoFactorChannel: TwoFactorPending = .trustedDevice

    /// True after password SRP hit 2FA and before `submitTwoFactor` / `cancel` — required to text an SMS.
    var hasPendingTwoFactor: Bool {
        pendingAnisette != nil
            && pendingDSID != nil
            && pendingIDMS != nil
            && !pendingEmail.isEmpty
            && !pendingPassword.isEmpty
    }

    private init() {}

    /// Completes password SRP. Throws `.needsTwoFactor` after Apple has been asked to push a code.
    /// - Parameter requestTrustedDevicePush: When `true` (default), fire Mac `/auth/verify/trusteddevice`
    ///   so Allow + code sheets overlay this iPhone. Pass `false` when opening a challenge only to
    ///   text an SMS for Store Access — a push here races MZFinance and burns usable OTPs.
    func authenticate(
        email: String,
        password: String,
        requestTrustedDevicePush: Bool = true
    ) async throws -> AppleAuthSession {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard e.contains("@"), !password.isEmpty else {
            throw AppleAuthError.message("Enter Apple ID and password.")
        }

        pendingEmail = e
        pendingPassword = password
        pendingPET = nil
        twoFactorCodeAlreadySent = false
        twoFactorPhoneHint = nil
        twoFactorChannel = .trustedDevice

        do {
            return try await authenticateOnce(
                email: e,
                password: password,
                skipTwoFactorGate: false,
                requestTrustedDevicePush: requestTrustedDevicePush
            )
        } catch let AppleAuthError.portal(code, _) where Self.isTransientAnisetteRejection(code) {
            // Apple rejected the machine identity — wipe adi.pb and provision a fresh one once.
            await AnisetteClient.shared.invalidate(resetProvisioning: true)
            return try await authenticateOnce(
                email: e,
                password: password,
                skipTwoFactorGate: false,
                requestTrustedDevicePush: requestTrustedDevicePush
            )
        }
    }

    private func authenticateOnce(
        email: String,
        password: String,
        skipTwoFactorGate: Bool,
        requestTrustedDevicePush: Bool = true
    ) async throws -> AppleAuthSession {
        let anisette = try await AnisetteClient.shared.fetch()
        pendingAnisette = anisette
        do {
            return try await runSRP(email: email, password: password, anisette: anisette, skipTwoFactorGate: skipTwoFactorGate)
        } catch AppleAuthError.needsTwoFactor {
            pending2FA = .trustedDevice
            twoFactorChannel = .trustedDevice
            // Store SMS delivery must skip this GET — a Mac push + SMS on the same challenge
            // leaves MZFinance rejecting the texted digits (“That code didn’t unlock Store”).
            if requestTrustedDevicePush, hasPendingTwoFactor {
                _ = await requestTrustedDeviceCodeBestEffort()
            }
            throw AppleAuthError.needsTwoFactor
        }
    }

    /// UI “Send again to devices” — force a fresh trusted-device push (may invalidate a prior code).
    @discardableResult
    func requestTrustedDevicePush() async throws -> Bool {
        guard pendingAnisette != nil, pendingDSID != nil, pendingIDMS != nil else {
            throw AppleAuthError.missingPendingAuth
        }
        pending2FA = .trustedDevice
        twoFactorChannel = .trustedDevice
        twoFactorPhoneHint = nil
        try await requestTrustedDeviceCode(preferMacClient: true)
        twoFactorCodeAlreadySent = true
        return true
    }

    /// Explicitly text a code to the Apple ID’s trusted phone (UI “Text me a code”).
    /// Returns a human-readable phone hint when Apple provides one (never the numeric phone id).
    @discardableResult
    func requestSMSCode(phoneID: String = "1") async throws -> String {
        guard pendingAnisette != nil, pendingDSID != nil, pendingIDMS != nil else {
            throw AppleAuthError.missingPendingAuth
        }
        let hint = try await sendSMSCodeRequest(phoneID: phoneID)
        pending2FA = .sms(phoneID: hint.phoneID)
        twoFactorChannel = .sms(phoneID: hint.phoneID)
        twoFactorPhoneHint = Self.displayablePhoneHint(hint.obfuscated)
        twoFactorCodeAlreadySent = true
        return twoFactorPhoneHint ?? ""
    }

    /// Reject bare phone-number ids (`"1"`) so the UI never says “sent to 1”.
    private static func displayablePhoneHint(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.allSatisfy(\.isNumber), trimmed.count <= 3 { return nil }
        return trimmed
    }

    private static func isTransientAnisetteRejection(_ code: Int) -> Bool {
        // -80043 / -80045: "This action cannot be completed at this time" — anisette / client-identity reject.
        code == -80043 || code == -80045 || code == 80043 || code == 80045
    }

    /// Continues after `authenticate` threw `.needsTwoFactor`.
    func submitTwoFactor(code: String) async throws -> AppleAuthSession {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else {
            throw AppleAuthError.message("Enter the 6-digit verification code.")
        }
        guard pendingAnisette != nil, !pendingEmail.isEmpty, !pendingPassword.isEmpty else {
            throw AppleAuthError.missingPendingAuth
        }
        switch pending2FA ?? twoFactorChannel {
        case .sms(let phoneID):
            try await submitPhoneCode(digits, phoneID: phoneID, mode: "sms")
        case .trustedDevice:
            try await submitTrustedDeviceCode(digits)
        }
        do {
            let session = try await completeAfterTwoFactor()
            clearPending()
            return session
        } catch let AppleAuthError.portal(code, _) where Self.isTransientAnisetteRejection(code) {
            await AnisetteClient.shared.invalidate(resetProvisioning: true)
            let session = try await completeAfterTwoFactor()
            clearPending()
            return session
        }
    }

    private func completeAfterTwoFactor() async throws -> AppleAuthSession {
        // Fresh anisette OTP after 2FA, then full SRP again (SideSign pattern).
        let fresh = try await AnisetteClient.shared.fetch()
        pendingAnisette = fresh
        return try await runSRP(
            email: pendingEmail,
            password: pendingPassword,
            anisette: fresh,
            skipTwoFactorGate: true
        )
    }

    func cancel() { clearPending() }

    private func clearPending() {
        pendingEmail = ""
        pendingPassword = ""
        pendingAnisette = nil
        pendingDSID = nil
        pendingIDMS = nil
        pending2FA = nil
        pendingPET = nil
        twoFactorCodeAlreadySent = false
        twoFactorPhoneHint = nil
        twoFactorChannel = .trustedDevice
    }

    private func capturePEToken(from response: URLResponse?) {
        guard let http = response as? HTTPURLResponse else { return }
        // Apple Wiki: validate returns X-Apple-PE-Token after a successful security code.
        let keys = ["X-Apple-PE-Token", "x-apple-pe-token", "X-Apple-Pe-Token"]
        for key in keys {
            if let raw = http.value(forHTTPHeaderField: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                pendingPET = raw
                return
            }
        }
        // Some pods emit PE among multi-value GS tokens — keep first non-empty PE-looking header.
        for (key, value) in http.allHeaderFields {
            let k = String(describing: key).lowercased()
            guard k.contains("pe-token") || k.contains("petoken") else { continue }
            let v = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty {
                pendingPET = v
                return
            }
        }
    }

    private struct SMSRequestResult {
        var phoneID: String
        var obfuscated: String
    }

    private func requestSMSCodeBestEffort(phoneID: String) async -> Bool {
        do {
            _ = try await requestSMSCode(phoneID: phoneID)
            return true
        } catch {
            return false
        }
    }

    /// SideSign `sendPhone2FACodeRequest` — POST `/auth/verify/phone/put?mode=sms`.
    private func sendSMSCodeRequest(phoneID: String) async throws -> SMSRequestResult {
        guard let anisette = pendingAnisette, let dsid = pendingDSID, let idms = pendingIDMS else {
            throw AppleAuthError.missingPendingAuth
        }
        let sanitized = phoneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "1"
            : phoneID.trimmingCharacters(in: .whitespacesAndNewlines)

        var lastError: Error = AppleAuthError.network("SMS request failed.")
        for spoofClient in [true, false] {
            do {
                var req = makeTwoFactorRequest(
                    url: phonePutURL,
                    dsid: dsid,
                    idms: idms,
                    anisette: anisette,
                    preferSpoofClient: spoofClient
                )
                req.httpMethod = "POST"
                req.httpShouldHandleCookies = false
                req.httpBody = try PropertyListSerialization.data(fromPropertyList: [
                    "serverInfo": [
                        "mode": "sms",
                        "phoneNumber.id": sanitized
                    ]
                ], format: .xml, options: 0)

                let (data, resp) = try await session.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0

                if let alert = parseXMLUIAlert(from: data), status >= 400 {
                    if status == 429 || alert.localizedCaseInsensitiveContains("too many") {
                        throw AppleAuthError.tooManyAttempts(alert)
                    }
                    lastError = AppleAuthError.network(alert)
                    if [403, 433, 500, 503].contains(status) { continue }
                    throw lastError
                }

                let dict = parsePlist(data)
                let ec = dict?["ec"] as? Int
                    ?? ((dict?["Status"] as? [String: Any])?["ec"] as? Int)
                    ?? 0
                let em = (dict?["em"] as? String)
                    ?? ((dict?["Status"] as? [String: Any])?["em"] as? String)
                if ec == -21668 || ec == -20102 || ec == -22411 || status == 429 {
                    throw AppleAuthError.tooManyAttempts(em ?? "Too many verification attempts.")
                }
                if ec != 0 {
                    lastError = AppleAuthError.portal(ec, em ?? "Failed to text a verification code.")
                    if [403, 433, 500, 503].contains(status) { continue }
                    throw lastError
                }
                guard status == 200 || status == 201 || status == 204 else {
                    lastError = AppleAuthError.network(
                        em ?? "SMS request failed (HTTP \(status))."
                    )
                    if [403, 433, 500, 503].contains(status) { continue }
                    throw lastError
                }

                let phoneDict = (dict?["phoneNumber"] as? [String: Any])
                    ?? (dict?["phoneNumbers"] as? [[String: Any]])?.first
                    ?? (dict?["trustedPhoneNumbers"] as? [[String: Any]])?.first
                let xmlInfo = parseXMLUIServerInfo(from: data)
                let resolvedID = {
                    if let raw = phoneDict?["id"] {
                        let s = "\(raw)".trimmingCharacters(in: .whitespacesAndNewlines)
                        if !s.isEmpty { return s }
                    }
                    if let xml = xmlInfo.phoneID, !xml.isEmpty { return xml }
                    return sanitized
                }()
                let obfuscated = (phoneDict?["numberWithDialCode"] as? String)
                    ?? (phoneDict?["obfuscatedNumber"] as? String)
                    ?? (phoneDict?["lastTwoDigits"] as? String).map { "••\($0)" }
                    ?? parseXMLUIObfuscatedNumber(from: data)
                    ?? ""
                return SMSRequestResult(phoneID: resolvedID, obfuscated: obfuscated)
            } catch let e as AppleAuthError {
                switch e {
                case .tooManyAttempts(_), .missingPendingAuth:
                    throw e
                default:
                    lastError = e
                    continue
                }
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    /// SideSign `validatePhone2FACode` — POST phone securitycode + PE token expected.
    private func submitPhoneCode(_ code: String, phoneID: String, mode: String) async throws {
        guard let anisette = pendingAnisette, let dsid = pendingDSID, let idms = pendingIDMS else {
            throw AppleAuthError.missingPendingAuth
        }

        var lastError: Error = AppleAuthError.incorrectCode
        for spoofClient in [true, false] {
            var req = makeTwoFactorRequest(
                url: phoneSecurityCodeURL,
                dsid: dsid,
                idms: idms,
                anisette: anisette,
                preferSpoofClient: spoofClient
            )
            req.httpMethod = "POST"
            req.httpShouldHandleCookies = false
            // SideSign uses dotted keys + nested serverInfo for phone verify.
            req.httpBody = try PropertyListSerialization.data(fromPropertyList: [
                "securityCode.code": code,
                "serverInfo": [
                    "mode": mode,
                    "phoneNumber.id": phoneID
                ]
            ], format: .xml, options: 0)

            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0

            do {
                try throwIfBad2FA(data: data, status: status)
            } catch AppleAuthError.incorrectCode {
                throw AppleAuthError.incorrectCode
            } catch let AppleAuthError.tooManyAttempts(msg) {
                throw AppleAuthError.tooManyAttempts(msg)
            } catch {
                lastError = error
                if [403, 433, 500, 503].contains(status) { continue }
                throw error
            }

            if status == 200 || status == 204 {
                // Phone verify should return X-Apple-PE-Token (SideSign); capture for Store mint.
                capturePEToken(from: resp)
                return
            }
            if status == 401 || status == 403 {
                throw AppleAuthError.incorrectCode
            }
            lastError = AppleAuthError.incorrectCode
            if [500, 503].contains(status) { continue }
        }
        throw lastError
    }

    private func parseXMLUIServerInfo(from data: Data) -> (phoneID: String?, mode: String?) {
        guard let str = String(data: data, encoding: .utf8),
              let range = str.range(of: #"<serverInfo[^>]*>"#, options: .regularExpression) else {
            return (nil, nil)
        }
        let tag = String(str[range])
        var phoneID: String?
        var mode: String?
        if let r = tag.range(of: #"(?<=phoneNumber\.id=")[^"]+"#, options: .regularExpression) {
            phoneID = String(tag[r])
        }
        if let r = tag.range(of: #"(?<=mode=")[^"]+"#, options: .regularExpression) {
            mode = String(tag[r])
        }
        return (phoneID, mode)
    }

    private func parseXMLUIObfuscatedNumber(from data: Data) -> String? {
        guard let str = String(data: data, encoding: .utf8) else { return nil }
        for pattern in [
            #"(?<=numberWithDialCode=")[^"]+"#,
            #"(?<=obfuscatedNumber=")[^"]+"#,
            #"(?<=lastTwoDigits=")[^"]+"#
        ] {
            if let r = str.range(of: pattern, options: .regularExpression) {
                let v = String(str[r])
                if pattern.contains("lastTwoDigits") { return "••\(v)" }
                return v
            }
        }
        return nil
    }

    // MARK: - SRP (init → complete → decrypt spd → apptokens)

    private func runSRP(
        email: String,
        password: String,
        anisette: AnisetteHeaders,
        skipTwoFactorGate: Bool
    ) async throws -> AppleAuthSession {
        let cpd = clientDictionary(anisette)
        guard let srp = SRPClient(), let publicKey = srp.startAuthentication() else {
            throw AppleAuthError.message("Couldn't start SRP handshake.")
        }

        let initResp = try await sendGS([
            "A2k": publicKey,
            "cpd": cpd,
            "ps": ["s2k", "s2k_fo"],
            "o": "init",
            "u": email
        ], anisette: anisette)

        guard let c = initResp["c"] as? String,
              let salt = initResp["s"] as? Data,
              let iterations = initResp["i"] as? Int,
              let serverPublicKey = initResp["B"] as? Data else {
            throw AppleAuthError.message("Auth init response incomplete.")
        }

        let sp = initResp["sp"] as? String
        let isHex = (sp == "s2k_fo")
        guard let passwordData = password.data(using: .utf8),
              let digest = CryptoUtilities.sha256(passwordData) else {
            throw AppleAuthError.message("Password digest failed.")
        }
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let inputDigest: Data = isHex ? Data(hex.utf8) : digest
        guard let derived = CryptoUtilities.pbkdf2SHA256(
            password: inputDigest, salt: salt, rounds: iterations, outputLength: digest.count
        ) else {
            throw AppleAuthError.message("PBKDF2 failed.")
        }
        guard let m1 = srp.processChallenge(
            username: email, password: derived, salt: salt, serverPublicKey: serverPublicKey
        ) else {
            throw AppleAuthError.message("SRP challenge failed.")
        }

        let completeResp = try await sendGS([
            "c": c,
            "cpd": cpd,
            "M1": m1,
            "o": "complete",
            "u": email
        ], anisette: anisette)

        let statusEarly = completeResp["Status"] as? [String: Any]
        let auEarly = (statusEarly?["au"] as? String) ?? (completeResp["au"] as? String)
        let hscEarly = statusEarly?["hsc"] as? Int
        let flagged2FA = {
            if let auEarly, ["trustedDeviceSecondaryAuth", "trustedDevice", "secondaryAuth", "sms", "voice", "phone", "pushedCode"].contains(auEarly) {
                return true
            }
            return hscEarly == 409
        }()

        guard let encryptedSPD = completeResp["spd"] as? Data,
              let m2 = completeResp["M2"] as? Data else {
            if flagged2FA {
                // 2FA required but SPD missing — still try to salvage identity tokens so we
                // can fire the Mac trusteddevice GET that shows Allow + code on this iPhone.
                if let dsid = (completeResp["adsid"] as? String)
                    ?? (statusEarly?["adsid"] as? String)
                    ?? (completeResp["dsid"] as? CustomStringConvertible)?.description {
                    pendingDSID = dsid
                }
                if let idms = (completeResp["GsIdmsToken"] as? String)
                    ?? (completeResp["idmsToken"] as? String)
                    ?? (statusEarly?["GsIdmsToken"] as? String) {
                    pendingIDMS = idms
                }
                twoFactorCodeAlreadySent = (auEarly == "pushedCode")
                throw AppleAuthError.needsTwoFactor
            }
            throw AppleAuthError.message("Auth complete missing SPD/M2.")
        }
        guard srp.verifyServerProof(m2), let shared = srp.sessionKey() else {
            throw AppleAuthError.message("SRP server proof failed.")
        }
        guard let spdKey = CryptoUtilities.hmacSHA256(key: shared, strings: ["extra data key:"]),
              let spdIV = CryptoUtilities.hmacSHA256(key: shared, strings: ["extra data iv:"]),
              let decrypted = CryptoUtilities.aesCBCDecrypt(key: spdKey, iv: spdIV, ciphertext: encryptedSPD),
              let dict = parsePlist(decrypted) else {
            throw AppleAuthError.message("Couldn't decrypt SPD.")
        }

        let dsid = (dict["adsid"] as? String)
            ?? (dict["dsid"] as? CustomStringConvertible)?.description
        let idms = (dict["GsIdmsToken"] as? String) ?? (dict["idmsToken"] as? String)
        guard let dsid, let idms else {
            throw AppleAuthError.message("Missing dsid / idms token.")
        }
        pendingDSID = dsid
        pendingIDMS = idms

        let status = completeResp["Status"] as? [String: Any]
        let au = (status?["au"] as? String) ?? (completeResp["au"] as? String)
        let hsc = status?["hsc"] as? Int
        let needs2FA: Bool = {
            if let au, ["trustedDeviceSecondaryAuth", "trustedDevice", "secondaryAuth", "sms", "voice", "phone", "pushedCode"].contains(au) {
                return true
            }
            return hsc == 409
        }()
        if needs2FA, !skipTwoFactorGate {
            // Never assume the Allow sheet already appeared — authenticateOnce always GETs.
            twoFactorCodeAlreadySent = (au == "pushedCode")
            throw AppleAuthError.needsTwoFactor
        }

        if let statusAU = status?["au"] as? String, statusAU == "repair" {
            let msg = (status?["em"] as? String) ?? "Apple ID requires account verification on developer.apple.com."
            throw AppleAuthError.accountRepairRequired(msg)
        }

        guard let sk = dict["sk"] as? Data, let cookie = dict["c"] as? Data else {
            throw AppleAuthError.message("Missing session key for apptokens.")
        }

        // Prefer PET already in SPD `t`, else from validate PE-Token, else apptokens fetch.
        if pendingPET == nil {
            if let tokens = dict["t"] as? [String: Any],
               let petEntry = tokens[petApp] as? [String: Any],
               let pet = petEntry["token"] as? String, !pet.isEmpty {
                pendingPET = pet
            }
        }

        let authToken = try await fetchAppToken(
            app: authApp, sk: sk, cookie: cookie, dsid: dsid, idms: idms, cpd: cpd, anisette: anisette
        )
        if pendingPET == nil {
            if let pet = try? await fetchAppToken(
                app: petApp, sk: sk, cookie: cookie, dsid: dsid, idms: idms, cpd: cpd, anisette: anisette
            ), !pet.isEmpty {
                pendingPET = pet
            }
        }

        let now = Date()
        let pet = pendingPET
        return AppleAuthSession(
            dsid: dsid,
            authToken: authToken,
            email: email,
            anisette: anisette,
            createdAt: now,
            expiresAt: nil,
            timeToLive: nil,
            xcodeVersion: xcodeVersion,
            pet: pet
        )
    }

    /// Decrypt one GrandSlam app token (`com.apple.gs.xcode.auth` / `com.apple.gs.idms.pet`).
    private func fetchAppToken(
        app: String,
        sk: Data,
        cookie: Data,
        dsid: String,
        idms: String,
        cpd: [String: Any],
        anisette: AnisetteHeaders
    ) async throws -> String {
        guard let checksum = CryptoUtilities.hmacSHA256(key: sk, strings: ["apptokens", dsid, app]) else {
            throw AppleAuthError.message("apptokens checksum failed.")
        }
        let tokenResp = try await sendGS([
            "app": [app],
            "c": cookie,
            "checksum": checksum,
            "cpd": cpd,
            "o": "apptokens",
            "t": idms,
            "u": dsid
        ], anisette: anisette)

        guard let et = tokenResp["et"] as? Data, et.count > 35 else {
            throw AppleAuthError.message("Missing encrypted auth token (\(app)).")
        }
        let aad = Data(et[..<3])
        let nonce = Data(et[3..<19])
        let ciphertext = Data(et[19..<(et.count - 16)])
        let tag = Data(et[(et.count - 16)...])
        guard let tokenBytes = CryptoUtilities.aesGCMDecrypt(
            key: sk, nonce: nonce, aad: aad, ciphertext: ciphertext, tag: tag
        ), let tokens = parsePlist(tokenBytes),
           let appTokens = tokens["t"] as? [String: Any],
           let entry = appTokens[app] as? [String: Any],
           let token = entry["token"] as? String, !token.isEmpty else {
            throw AppleAuthError.message("Couldn't parse auth token (\(app)).")
        }
        return token
    }

    // MARK: - Trusted-device 2FA

    /// Best-effort trusted-device push. Returns `true` when Apple accepted the challenge
    /// (or already had one live). `false` means nothing was delivered — caller may SMS-fallback.
    @discardableResult
    private func requestTrustedDeviceCodeBestEffort() async -> Bool {
        do {
            try await requestTrustedDeviceCode(preferMacClient: true)
            twoFactorCodeAlreadySent = true
            return true
        } catch {
            return false
        }
    }

    private func requestTrustedDeviceCode(preferMacClient: Bool) async throws {
        guard let anisette = pendingAnisette else {
            throw AppleAuthError.missingPendingAuth
        }
        guard pendingDSID != nil, pendingIDMS != nil else {
            // Without identity token the GET cannot authorize a push — don't pretend it worked.
            throw AppleAuthError.missingPendingAuth
        }

        // SideSign uses GET (Apple Wiki / AltSign). POST produced HTTP 500 xmlui.
        func attempt(spoofClient: Bool, override: (clientInfo: String, userAgent: String)? = nil) async throws -> (Data, Int) {
            var req = makeTwoFactorRequest(
                url: trustedDeviceURL,
                dsid: pendingDSID!,
                idms: pendingIDMS!,
                anisette: anisette,
                preferSpoofClient: spoofClient,
                spoofOverride: override
            )
            req.httpMethod = "GET"
            req.httpShouldHandleCookies = false
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (data, code)
        }

        var lastData = Data()
        var lastCode = 0
        // Selected MacBook/iPhone AuthKit identity first (Settings › Sign-in device),
        // then alternate Mac profiles, then raw anisette/Windows — SideSign parity.
        if preferMacClient {
            for identity in AuthClientSpoof.current.fallbackClientInfos {
                let (data, code) = try await attempt(spoofClient: true, override: identity)
                lastData = data
                lastCode = code
                if code == 200 || code == 201 || code == 204 || code == 409 {
                    return
                }
                if ![403, 433, 500, 503].contains(code) { break }
            }
            let (data, code) = try await attempt(spoofClient: false)
            lastData = data
            lastCode = code
            if code == 200 || code == 201 || code == 204 || code == 409 {
                return
            }
        } else {
            for spoofClient in [false, true] {
                let (data, code) = try await attempt(spoofClient: spoofClient)
                lastData = data
                lastCode = code
                if code == 200 || code == 201 || code == 204 || code == 409 {
                    return
                }
                if ![403, 433, 500, 503].contains(code) { break }
            }
        }

        if let alert = parseXMLUIAlert(from: lastData) {
            throw AppleAuthError.network(alert)
        }
        let raw = String(data: lastData, encoding: .utf8) ?? ""
        throw AppleAuthError.network(
            "Trusted-device challenge failed (HTTP \(lastCode)): \(raw.prefix(120))"
        )
    }

    private func submitTrustedDeviceCode(_ code: String) async throws {
        guard let anisette = pendingAnisette else { throw AppleAuthError.missingPendingAuth }

        // Prefer identity-token validate (SideSign / Apple Wiki), then securitycode endpoint.
        if let dsid = pendingDSID, let idms = pendingIDMS {
            for spoofClient in [true, false] {
                var validate = makeTwoFactorRequest(
                    url: validateURL,
                    dsid: dsid,
                    idms: idms,
                    anisette: anisette,
                    preferSpoofClient: spoofClient
                )
                validate.httpMethod = "GET"
                validate.setValue(code, forHTTPHeaderField: "security-code")
                validate.httpShouldHandleCookies = false
                let (data, resp) = try await session.data(for: validate)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 {
                    try throwIfBad2FA(data: data, status: status)
                    capturePEToken(from: resp)
                    return
                }
                // Wrong code — don't thrash client identities.
                if status == 401 || status == 403 {
                    try throwIfBad2FA(data: data, status: status)
                }
                if spoofClient { continue }

                var sec = makeTwoFactorRequest(
                    url: trustedDeviceSecurityCodeURL,
                    dsid: dsid,
                    idms: idms,
                    anisette: anisette,
                    preferSpoofClient: true
                )
                sec.httpMethod = "POST"
                sec.httpBody = try PropertyListSerialization.data(fromPropertyList: [
                    "securityCode": ["code": code]
                ], format: .xml, options: 0)
                let (data2, resp2) = try await session.data(for: sec)
                let status2 = (resp2 as? HTTPURLResponse)?.statusCode ?? 0
                try throwIfBad2FA(data: data2, status: status2)
                guard status2 == 200 || status2 == 204 else {
                    throw AppleAuthError.incorrectCode
                }
                capturePEToken(from: resp2)
                return
            }
            throw AppleAuthError.incorrectCode
        }

        // Fallback without identity (should be rare)
        var req = URLRequest(url: trustedDeviceSecurityCodeURL)
        req.httpMethod = "POST"
        applyAnisette(&req, anisette)
        applyAuthClientSpoofIdentity(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "securityCode": ["code": code]
        ])
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        try throwIfBad2FA(data: data, status: status)
        guard (200..<300).contains(status) || status == 204 else {
            throw AppleAuthError.incorrectCode
        }
        capturePEToken(from: resp)
    }

    private func throwIfBad2FA(data: Data, status: Int) throws {
        if let alert = parseXMLUIAlert(from: data), status >= 400 {
            if alert.localizedCaseInsensitiveContains("incorrect") || status == 401 || status == 403 {
                throw AppleAuthError.incorrectCode
            }
            throw AppleAuthError.network(alert)
        }
        let dict = parsePlist(data)
        let ec = dict?["ec"] as? Int
            ?? ((dict?["Status"] as? [String: Any])?["ec"] as? Int)
            ?? 0
        let em = (dict?["em"] as? String)
            ?? ((dict?["Status"] as? [String: Any])?["em"] as? String)
        if ec == -21669 || status == 401 || status == 403 {
            throw AppleAuthError.incorrectCode
        }
        if ec == -21668 || ec == -20102 || ec == -22411 || status == 429 {
            throw AppleAuthError.tooManyAttempts(em ?? "Too many verification attempts.")
        }
        if ec != 0 {
            throw AppleAuthError.portal(ec, em ?? "2FA verification failed")
        }
    }

    private func makeTwoFactorRequest(
        url: URL,
        dsid: String,
        idms: String,
        anisette: AnisetteHeaders,
        preferSpoofClient: Bool,
        spoofOverride: (clientInfo: String, userAgent: String)? = nil
    ) -> URLRequest {
        let identity = Data("\(dsid):\(idms)".utf8).base64EncodedString()
        var req = URLRequest(url: url)
        applyAnisette(&req, anisette)
        if preferSpoofClient {
            applyAuthClientSpoofIdentity(&req, override: spoofOverride)
        }
        req.setValue("application/x-buddyml", forHTTPHeaderField: "Accept")
        req.setValue("en-us", forHTTPHeaderField: "Accept-Language")
        req.setValue("application/x-plist", forHTTPHeaderField: "Content-Type")
        req.setValue(authApp, forHTTPHeaderField: "X-Apple-App-Info")
        req.setValue(xcodeVersion, forHTTPHeaderField: "X-Xcode-Version")
        req.setValue(identity, forHTTPHeaderField: "X-Apple-Identity-Token")
        return req
    }

    /// Apply Settings › Sign-in device spoof (MacBook / iPhone + OS) over anisette headers.
    private func applyAuthClientSpoofIdentity(
        _ req: inout URLRequest,
        override: (clientInfo: String, userAgent: String)? = nil
    ) {
        let spoof = AuthClientSpoof.current
        req.setValue(override?.clientInfo ?? spoof.clientInfo, forHTTPHeaderField: "X-MMe-Client-Info")
        req.setValue(override?.userAgent ?? spoof.userAgent, forHTTPHeaderField: "User-Agent")
    }

    private func parseXMLUIAlert(from data: Data) -> String? {
        guard let str = String(data: data, encoding: .utf8),
              str.localizedCaseInsensitiveContains("xmlui") || str.localizedCaseInsensitiveContains("<alert") else {
            return nil
        }
        var title: String?
        var message: String?
        if let r = str.range(of: #"(?<=title=")[^"]+"#, options: .regularExpression) {
            title = String(str[r])
        }
        if let r = str.range(of: #"(?<=message=")[^"]+"#, options: .regularExpression) {
            message = String(str[r])
        }
        let parts = [title, message]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ": ")
    }

    // MARK: - Wire

    /// Minimal CPD matching clients that currently clear GrandSlam (AltSign / iloader Windows shape).
    private func clientDictionary(_ a: AnisetteHeaders) -> [String: Any] {
        [
            "bootstrap": true,
            "icscrec": true,
            "pbe": false,
            "prkgen": true,
            "svct": "iCloud",
            "loc": a.locale,
            "X-Apple-I-MD": a.oneTimePassword,
            "X-Apple-I-MD-M": a.machineID,
            "X-Mme-Device-Id": a.deviceID
        ]
    }

    private func applyAnisette(_ req: inout URLRequest, _ a: AnisetteHeaders) {
        // User-Agent + Client-Info MUST match the anisette provider that minted MID/OTP.
        req.setValue(a.clientInfo, forHTTPHeaderField: "X-MMe-Client-Info")
        req.setValue(a.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(a.machineID, forHTTPHeaderField: "X-Apple-I-MD-M")
        req.setValue(a.oneTimePassword, forHTTPHeaderField: "X-Apple-I-MD")
        req.setValue(a.localUserID, forHTTPHeaderField: "X-Apple-I-MD-LU")
        req.setValue(a.routingInfo, forHTTPHeaderField: "X-Apple-I-MD-RINFO")
        req.setValue(a.deviceID, forHTTPHeaderField: "X-Mme-Device-Id")
        req.setValue(a.serialNumber, forHTTPHeaderField: "X-Apple-I-SRL-NO")
        req.setValue(a.clientTime, forHTTPHeaderField: "X-Apple-I-Client-Time")
        req.setValue(a.locale, forHTTPHeaderField: "X-Apple-Locale")
        req.setValue(a.timeZone, forHTTPHeaderField: "X-Apple-I-TimeZone")
        req.setValue(authApp, forHTTPHeaderField: "X-Apple-App-Info")
        req.setValue(xcodeVersion, forHTTPHeaderField: "X-Xcode-Version")
        req.setValue("close", forHTTPHeaderField: "Connection")
    }

    private func sendGS(_ requestParams: [String: Any], anisette: AnisetteHeaders) async throws -> [String: Any] {
        let parameters: [String: Any] = [
            "Header": ["Version": "1.0.1"],
            "Request": requestParams
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: parameters, format: .xml, options: 0)
        var req = URLRequest(url: gsURL)
        req.httpMethod = "POST"
        req.httpBody = plist
        req.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        req.setValue("text/x-xml-plist", forHTTPHeaderField: "Accept")
        req.httpShouldHandleCookies = false
        applyAnisette(&req, anisette)
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(code) {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw AppleAuthError.network("Apple's authentication servers returned an error (HTTP \(code)). \(raw.prefix(120))")
        }
        guard !data.isEmpty else {
            throw AppleAuthError.network("Empty GrandSlam response (HTTP \(code)).")
        }
        guard let root = parsePlist(data) else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw AppleAuthError.network("GrandSlam non-plist response (HTTP \(code)): \(raw.prefix(200))")
        }
        let dictionary = (root["Response"] as? [String: Any]) ?? root
        guard let status = dictionary["Status"] as? [String: Any] else {
            return dictionary
        }
        let ec = status["ec"] as? Int ?? 0
        if ec != 0 {
            let em = status["em"] as? String
            switch ec {
            case -22406: throw AppleAuthError.incorrectCredentials
            case -20101, -20209: throw AppleAuthError.appSpecificPasswordRequired
            case -21669: throw AppleAuthError.incorrectCode
            case -21668, -20102, -22411: throw AppleAuthError.tooManyAttempts(em ?? "Too many attempts.")
            case -80043, -80045, 80043, 80045:
                throw AppleAuthError.portal(
                    ec,
                    em ?? "Apple rejected this device identity. Try Sign In again in a moment."
                )
            default: throw AppleAuthError.portal(ec, em ?? "Authentication failed")
            }
        }
        return dictionary
    }

    private func parsePlist(_ data: Data) -> [String: Any]? {
        if let o = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            return o
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Blocks HTTP redirects on GrandSlam so HTML 503 pages aren't parsed as plists.
private final class GSRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = GSRedirectBlocker()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
