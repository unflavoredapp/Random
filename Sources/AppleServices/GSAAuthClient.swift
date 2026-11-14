//
//  GSAAuthClient.swift
//  Real Apple GrandSlam SRP authentication + trusted-device 2FA.
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
    private let authApp = "com.apple.gs.xcode.auth"
    private let xcodeVersion = "14.0"
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // GrandSlam sometimes redirects to HTML error pages; never follow those.
        config.httpShouldSetCookies = false
        return URLSession(configuration: config, delegate: GSRedirectBlocker.shared, delegateQueue: nil)
    }()

    private var pendingEmail = ""
    private var pendingPassword = ""
    private var pendingAnisette: AnisetteHeaders?
    private var pendingDSID: String?
    private var pendingIDMS: String?
    private var pending2FA: TwoFactorPending?

    private init() {}

    /// Completes password SRP. Throws `.needsTwoFactor` after Apple has been asked to push a code.
    func authenticate(email: String, password: String) async throws -> AppleAuthSession {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard e.contains("@"), !password.isEmpty else {
            throw AppleAuthError.message("Enter Apple ID and password.")
        }

        pendingEmail = e
        pendingPassword = password

        do {
            return try await authenticateOnce(email: e, password: password, skipTwoFactorGate: false)
        } catch let AppleAuthError.portal(code, _) where Self.isTransientAnisetteRejection(code) {
            // Apple rejected the machine identity — wipe adi.pb and provision a fresh one once.
            await AnisetteClient.shared.invalidate(resetProvisioning: true)
            return try await authenticateOnce(email: e, password: password, skipTwoFactorGate: false)
        }
    }

    private func authenticateOnce(
        email: String,
        password: String,
        skipTwoFactorGate: Bool
    ) async throws -> AppleAuthSession {
        let anisette = try await AnisetteClient.shared.fetch()
        pendingAnisette = anisette
        do {
            return try await runSRP(email: email, password: password, anisette: anisette, skipTwoFactorGate: skipTwoFactorGate)
        } catch AppleAuthError.needsTwoFactor {
            pending2FA = .trustedDevice
            try await requestTrustedDeviceCode()
            throw AppleAuthError.needsTwoFactor
        }
    }

    private static func isTransientAnisetteRejection(_ code: Int) -> Bool {
        // -80043 / -80045: "This action cannot be completed at this time" — anisette / client-identity reject.
        code == -80043 || code == -80045 || code == 80043 || code == 80045
    }

    /// Continues after `authenticate` threw `.needsTwoFactor`.
    func submitTwoFactor(code: String) async throws -> AppleAuthSession {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else {
            throw AppleAuthError.message("Enter the 6-digit code from a trusted device.")
        }
        guard let anisette = pendingAnisette, !pendingEmail.isEmpty, !pendingPassword.isEmpty else {
            throw AppleAuthError.missingPendingAuth
        }
        try await submitTrustedDeviceCode(digits)
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

        guard let encryptedSPD = completeResp["spd"] as? Data,
              let m2 = completeResp["M2"] as? Data else {
            let status = completeResp["Status"] as? [String: Any]
            let au = status?["au"] as? String
            let hsc = status?["hsc"] as? Int
            if au != nil || hsc == 409 {
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
        let needs2FA: Bool = {
            if let au, ["trustedDeviceSecondaryAuth", "trustedDevice", "secondaryAuth", "sms", "voice", "phone", "pushedCode"].contains(au) {
                return true
            }
            return (status?["hsc"] as? Int) == 409
        }()
        if needs2FA, !skipTwoFactorGate {
            throw AppleAuthError.needsTwoFactor
        }

        if let statusAU = status?["au"] as? String, statusAU == "repair" {
            let msg = (status?["em"] as? String) ?? "Apple ID requires account verification on developer.apple.com."
            throw AppleAuthError.accountRepairRequired(msg)
        }

        guard let sk = dict["sk"] as? Data, let cookie = dict["c"] as? Data else {
            throw AppleAuthError.message("Missing session key for apptokens.")
        }
        guard let checksum = CryptoUtilities.hmacSHA256(key: sk, strings: ["apptokens", dsid, authApp]) else {
            throw AppleAuthError.message("apptokens checksum failed.")
        }

        let tokenResp = try await sendGS([
            "app": [authApp],
            "c": cookie,
            "checksum": checksum,
            "cpd": cpd,
            "o": "apptokens",
            "t": idms,
            "u": dsid
        ], anisette: anisette)

        guard let et = tokenResp["et"] as? Data, et.count > 35 else {
            throw AppleAuthError.message("Missing encrypted auth token.")
        }
        let aad = Data(et[..<3])
        let nonce = Data(et[3..<19])
        let ciphertext = Data(et[19..<(et.count - 16)])
        let tag = Data(et[(et.count - 16)...])
        guard let tokenBytes = CryptoUtilities.aesGCMDecrypt(
            key: sk, nonce: nonce, aad: aad, ciphertext: ciphertext, tag: tag
        ), let tokens = parsePlist(tokenBytes),
           let appTokens = tokens["t"] as? [String: Any],
           let entry = appTokens[authApp] as? [String: Any],
           let authToken = entry["token"] as? String else {
            throw AppleAuthError.message("Couldn't parse Xcode auth token.")
        }

        let now = Date()
        var expires: Date?
        var ttl: TimeInterval?
        if let expiry = entry["expiry"] as? Date {
            expires = expiry
            ttl = expiry.timeIntervalSince(now)
        } else if let expiryStr = entry["expiry"] as? String,
                  let parsed = ISO8601DateFormatter().date(from: expiryStr) {
            expires = parsed
            ttl = parsed.timeIntervalSince(now)
        } else if let t = entry["ttl"] as? Double ?? (entry["ttl"] as? Int).map(Double.init) {
            ttl = t
            expires = now.addingTimeInterval(t)
        }

        return AppleAuthSession(
            dsid: dsid,
            authToken: authToken,
            email: email,
            anisette: anisette,
            createdAt: now,
            expiresAt: expires,
            timeToLive: ttl,
            xcodeVersion: xcodeVersion
        )
    }

    // MARK: - Trusted-device 2FA

    private func requestTrustedDeviceCode() async throws {
        guard let anisette = pendingAnisette, let dsid = pendingDSID, let idms = pendingIDMS else {
            // No identity yet (spd missing) — still ping endpoint so Apple may push; caller retries auth after code.
            var req = URLRequest(url: trustedDeviceURL)
            req.httpMethod = "POST"
            if let a = pendingAnisette { applyAnisette(&req, a) }
            req.setValue("application/x-plist", forHTTPHeaderField: "Content-Type")
            req.setValue("application/x-buddyml", forHTTPHeaderField: "Accept")
            let (_, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<500).contains(code) else {
                throw AppleAuthError.network("Trusted-device challenge failed (HTTP \(code)).")
            }
            return
        }
        var req = makeTwoFactorRequest(url: trustedDeviceURL, dsid: dsid, idms: idms, anisette: anisette)
        req.httpMethod = "POST"
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 || code == 201 || code == 204 || code == 409 else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw AppleAuthError.network("Trusted-device challenge failed (HTTP \(code)): \(raw.prefix(240))")
        }
    }

    private func submitTrustedDeviceCode(_ code: String) async throws {
        guard let anisette = pendingAnisette else { throw AppleAuthError.missingPendingAuth }

        // Prefer identity-token validate (SideSign), then securitycode endpoint.
        if let dsid = pendingDSID, let idms = pendingIDMS {
            var validate = makeTwoFactorRequest(url: validateURL, dsid: dsid, idms: idms, anisette: anisette)
            validate.httpMethod = "GET"
            validate.setValue(code, forHTTPHeaderField: "security-code")
            let (data, resp) = try await session.data(for: validate)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            try throwIfBad2FA(data: data, status: status)

            if status == 200 { return }

            var sec = makeTwoFactorRequest(url: trustedDeviceSecurityCodeURL, dsid: dsid, idms: idms, anisette: anisette)
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
            return
        }

        // Fallback without identity (should be rare)
        var req = URLRequest(url: trustedDeviceSecurityCodeURL)
        req.httpMethod = "POST"
        applyAnisette(&req, anisette)
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
    }

    private func throwIfBad2FA(data: Data, status: Int) throws {
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
        anisette: AnisetteHeaders
    ) -> URLRequest {
        let identity = Data("\(dsid):\(idms)".utf8).base64EncodedString()
        var req = URLRequest(url: url)
        applyAnisette(&req, anisette)
        req.setValue("application/x-buddyml", forHTTPHeaderField: "Accept")
        req.setValue("en-us", forHTTPHeaderField: "Accept-Language")
        req.setValue("application/x-plist", forHTTPHeaderField: "Content-Type")
        req.setValue(authApp, forHTTPHeaderField: "X-Apple-App-Info")
        req.setValue(xcodeVersion, forHTTPHeaderField: "X-Xcode-Version")
        req.setValue(identity, forHTTPHeaderField: "X-Apple-Identity-Token")
        return req
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
