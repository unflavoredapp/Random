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
    /// SideInstaller / SideStore working Xcode version string for GSA + 2FA.
    private let xcodeVersion = "14.2 (14C18)"
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // GrandSlam sometimes redirects to HTML error pages; never follow those.
        config.httpShouldSetCookies = false
        // Avoid connection reuse — GSA/auth often returns 5xx on pooled sockets (SideStore).
        config.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: config, delegate: GSRedirectBlocker.shared, delegateQueue: nil)
    }()

    /// Mac AuthKit identity for `gsa.apple.com/auth/*` — Windows/akd clears SRP but auth pages often 500/403 it.
    private let twoFactorMacClientInfo =
        "<MacBookPro18,3> <macOS;13.1;22C65> <com.apple.AuthKit/1 (com.apple.dt.Xcode/14.3.0)>"
    private let twoFactorMacUserAgent = "Xcode"

    private var pendingEmail = ""
    private var pendingPassword = ""
    private var pendingAnisette: AnisetteHeaders?
    private var pendingDSID: String?
    private var pendingIDMS: String?
    private var pending2FA: TwoFactorPending?
    /// Apple already pushed a code (hsc 409 / pushedCode) — do not hit /trusteddevice again.
    private(set) var twoFactorCodeAlreadySent = false

    private init() {}

    /// Completes password SRP. Throws `.needsTwoFactor` after Apple has been asked to push a code.
    func authenticate(email: String, password: String) async throws -> AppleAuthSession {
        let e = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard e.contains("@"), !password.isEmpty else {
            throw AppleAuthError.message("Enter Apple ID and password.")
        }

        pendingEmail = e
        pendingPassword = password
        twoFactorCodeAlreadySent = false

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
            // AltSign #59: when Apple already pushed the code, requesting another kills it
            // and /auth/verify/trusteddevice often returns HTTP 500 "Could not connect to iCloud".
            if !twoFactorCodeAlreadySent {
                await requestTrustedDeviceCodeBestEffort()
            }
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
        twoFactorCodeAlreadySent = false
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
                // hsc 409 with empty au = Apple already pushed a code (AltSign #59 / isideload).
                twoFactorCodeAlreadySent = (hsc == 409) || (au == "pushedCode")
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
            twoFactorCodeAlreadySent = (hsc == 409) || (au == "pushedCode")
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

    /// Best-effort code request. Never blocks the 2FA UI — Apple often already pushed a code,
    /// and `/auth/verify/trusteddevice` frequently returns HTTP 500 xmlui "Could not connect to iCloud"
    /// when hit with the Windows anisette identity used for GrandSlam SRP (SideStore/SideSign).
    private func requestTrustedDeviceCodeBestEffort() async {
        do {
            try await requestTrustedDeviceCode(preferMacClient: true)
        } catch {
            // Soft-fail: still show the code field. A code may already be on trusted devices.
            twoFactorCodeAlreadySent = true
        }
    }

    private func requestTrustedDeviceCode(preferMacClient: Bool) async throws {
        guard let anisette = pendingAnisette else {
            throw AppleAuthError.missingPendingAuth
        }

        // SideSign uses GET (Apple Wiki / AltSign). POST is what produced the user's HTTP 500 xmlui.
        func attempt(macClient: Bool) async throws -> (Data, Int) {
            var req: URLRequest
            if let dsid = pendingDSID, let idms = pendingIDMS {
                req = makeTwoFactorRequest(
                    url: trustedDeviceURL,
                    dsid: dsid,
                    idms: idms,
                    anisette: anisette,
                    preferMacClient: macClient
                )
            } else {
                req = URLRequest(url: trustedDeviceURL)
                applyAnisette(&req, anisette)
                if macClient { applyTwoFactorMacIdentity(&req) }
                req.setValue("application/x-plist", forHTTPHeaderField: "Content-Type")
                req.setValue("application/x-buddyml", forHTTPHeaderField: "Accept")
            }
            req.httpMethod = "GET"
            req.httpShouldHandleCookies = false
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (data, code)
        }

        var (data, code) = try await attempt(macClient: preferMacClient)
        // Retry once with the opposite client identity on auth-page 403/500/503.
        if [403, 433, 500, 503].contains(code) {
            (data, code) = try await attempt(macClient: !preferMacClient)
        }

        if code == 200 || code == 201 || code == 204 || code == 409 {
            return
        }

        if let alert = parseXMLUIAlert(from: data) {
            // "Could not connect to iCloud" after Apple already pushed → continue to code entry.
            if alert.localizedCaseInsensitiveContains("icloud") || code == 500 {
                twoFactorCodeAlreadySent = true
                return
            }
            throw AppleAuthError.network(alert)
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        if code >= 500 {
            twoFactorCodeAlreadySent = true
            return
        }
        throw AppleAuthError.network("Trusted-device challenge failed (HTTP \(code)): \(raw.prefix(160))")
    }

    private func submitTrustedDeviceCode(_ code: String) async throws {
        guard let anisette = pendingAnisette else { throw AppleAuthError.missingPendingAuth }

        // Prefer identity-token validate (SideSign / Apple Wiki), then securitycode endpoint.
        if let dsid = pendingDSID, let idms = pendingIDMS {
            for macClient in [true, false] {
                var validate = makeTwoFactorRequest(
                    url: validateURL,
                    dsid: dsid,
                    idms: idms,
                    anisette: anisette,
                    preferMacClient: macClient
                )
                validate.httpMethod = "GET"
                validate.setValue(code, forHTTPHeaderField: "security-code")
                validate.httpShouldHandleCookies = false
                let (data, resp) = try await session.data(for: validate)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 {
                    try throwIfBad2FA(data: data, status: status)
                    return
                }
                // Wrong code — don't thrash client identities.
                if status == 401 || status == 403 {
                    try throwIfBad2FA(data: data, status: status)
                }
                if macClient { continue }

                var sec = makeTwoFactorRequest(
                    url: trustedDeviceSecurityCodeURL,
                    dsid: dsid,
                    idms: idms,
                    anisette: anisette,
                    preferMacClient: true
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
                return
            }
            throw AppleAuthError.incorrectCode
        }

        // Fallback without identity (should be rare)
        var req = URLRequest(url: trustedDeviceSecurityCodeURL)
        req.httpMethod = "POST"
        applyAnisette(&req, anisette)
        applyTwoFactorMacIdentity(&req)
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
        preferMacClient: Bool
    ) -> URLRequest {
        let identity = Data("\(dsid):\(idms)".utf8).base64EncodedString()
        var req = URLRequest(url: url)
        applyAnisette(&req, anisette)
        if preferMacClient {
            applyTwoFactorMacIdentity(&req)
        }
        req.setValue("application/x-buddyml", forHTTPHeaderField: "Accept")
        req.setValue("en-us", forHTTPHeaderField: "Accept-Language")
        req.setValue("application/x-plist", forHTTPHeaderField: "Content-Type")
        req.setValue(authApp, forHTTPHeaderField: "X-Apple-App-Info")
        req.setValue(xcodeVersion, forHTTPHeaderField: "X-Xcode-Version")
        req.setValue(identity, forHTTPHeaderField: "X-Apple-Identity-Token")
        return req
    }

    private func applyTwoFactorMacIdentity(_ req: inout URLRequest) {
        req.setValue(twoFactorMacClientInfo, forHTTPHeaderField: "X-MMe-Client-Info")
        req.setValue(twoFactorMacUserAgent, forHTTPHeaderField: "User-Agent")
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
