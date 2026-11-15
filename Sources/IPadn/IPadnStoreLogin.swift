//
//  IPadnStoreLogin.swift
//  Derived from mengangs/ipadn AppleService.performLogin + AppleLoginResponse (GPL-2.0).
//  ActionSignature via TetherLess StoreSAP; AMD via Anisette (not WASM ADI).
//  Bridges into StorefrontSession for Settings › Store Access.
//

import Foundation

enum IPadnAppleLoginError: LocalizedError {
    case verificationRequired
    case verificationRejected

    var errorDescription: String? {
        switch self {
        case .verificationRequired:
            return "Allow this sign-in on a trusted device, then enter the 6-digit code."
        case .verificationRejected:
            return "Apple rejected that verification. Check password and the latest 6-digit code."
        }
    }
}

enum IPadnAppleLoginResponse {
    static func body(email: String, password: String, code: String, guid: String) throws -> Data {
        try IPadnHTTPClient.encodePlist([
            "appleId": email,
            "attempt": code.isEmpty ? "1" : "2",
            "guid": guid,
            "password": password + code,
            "rmp": "0",
            "why": "signIn"
        ])
    }

    /// Phone-number Apple Accounts in CN / IN need an explicit storefront header (ipatool / iPadn).
    static func phoneNumberStorefront(_ appleID: String) -> String? {
        var number = appleID.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        var international = false
        if number.hasPrefix("+") {
            international = true
            number.removeFirst()
        } else if number.hasPrefix("00") {
            international = true
            number.removeFirst(2)
        }
        guard !number.isEmpty, number.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let china = "143465", india = "143467"
        if number.count == 13 && number.hasPrefix("861") { return china }
        if number.count == 12 && number.hasPrefix("91") {
            number.removeFirst(2)
        } else if international {
            return nil
        }
        if number.count == 11 && number.hasPrefix("1") { return china }
        if !international && number.count == 11 && number.hasPrefix("0") {
            number.removeFirst()
        }
        if number.count == 10, let first = number.first, ("6"..."9").contains(first) {
            return india
        }
        return nil
    }

    static func failure(_ response: [String: Any], submittedCode: Bool) -> Error? {
        if let failure = IPadnHTTPClient.appleFailure(response) { return failure }
        let message = ipadnPlistString(response["customerMessage"])
        if message == "MZFinance.BadLogin.Configurator_message" {
            return submittedCode
                ? IPadnAppleLoginError.verificationRejected
                : IPadnAppleLoginError.verificationRequired
        }
        if message.hasPrefix("AMD-Action") {
            return IPadnToolError.message("Device verification incomplete — retry Store unlock.")
        }
        if let info = response["accountInfo"] as? [String: Any],
           !ipadnPlistString(info["appleId"]).isEmpty {
            return nil
        }
        if message.isEmpty, !ipadnPlistString(response["passwordToken"]).isEmpty {
            return nil
        }
        if message.hasPrefix("MZ") {
            return IPadnToolError.message("Apple couldn’t complete login. Try again.")
        }
        return IPadnToolError.message(
            message.isEmpty
                ? "Apple returned incomplete login info. Check the account and retry."
                : message
        )
    }

    static func storefrontIdentifier(_ storefront: String) -> String {
        String(storefront.split(whereSeparator: { $0 == "-" || $0 == "," }).first ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// iPadn-style MZFinance mint → `StorefrontSession`.
@MainActor
enum IPadnStoreLogin {
    private(set) static var lastDiagnostic = "No iPadn login attempted."

    /// Authenticate like iPadn: bag.xml → SAP ActionSignature → AMD proof loop → passwordToken.
    static func authenticate(
        email: String,
        password: String,
        authCode: String = ""
    ) async throws -> StorefrontSession {
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let code = authCode.trimmingCharacters(in: .whitespacesAndNewlines).filter(\.isNumber)
        guard !email.isEmpty, !password.isEmpty else {
            throw IPadnToolError.message("Enter Apple ID and password for Store downloads.")
        }
        guard code.isEmpty || (code.count == 6 && code.allSatisfy(\.isNumber)) else {
            throw IPadnToolError.message("Enter a 6-digit verification code.")
        }

        StoreDeviceSpoof.clearPersistedSpoof()

        var stage = "configuration"
        lastDiagnostic = "stage=configuration"

        let anisette = try await AnisetteClient.shared.fetch()
        let guid = AppStoreClient.deviceGUID(from: anisette)

        let sapSigner: SAPSigner
        do {
            sapSigner = try await SAPSigner.connect()
        } catch {
            lastDiagnostic = "stage=signing; sap-connect-failed"
            throw AppStoreClientError.message(
                "Store SAP setup failed (\(error.localizedDescription)). Tap Retry Store unlock."
            )
        }

        let raw: [String: Any]
        let response: HTTPURLResponse
        do {
            let endpoint = try await IPadnAppleAuthentication.configuration(
                guid: guid,
                send: { try await IPadnHTTPClient.shared.request($0, headers: ["Accept": "application/xml"]) },
                report: { lastDiagnostic = $0 }
            )
            stage = "signing"
            lastDiagnostic = "stage=signing"
            let body = try IPadnAppleLoginResponse.body(
                email: email, password: password, code: code, guid: guid
            )
            let signature = try await sapSigner.sign(body)
            var headers: [String: String] = [
                "Content-Type": "application/x-apple-plist",
                "X-Apple-ActionSignature": signature.base64EncodedString()
            ]
            if let storefront = IPadnAppleLoginResponse.phoneNumberStorefront(email) {
                headers["X-Apple-Store-Front"] = storefront
            }

            stage = "authentication"
            let result = try await IPadnAppleAuthentication.withStoreProof(
                endpoint: endpoint,
                baseHeaders: headers,
                loadProof: {
                    let a = try await AnisetteClient.shared.fetch()
                    return [
                        "X-Apple-AMD": a.oneTimePassword,
                        "X-Apple-AMD-M": a.machineID
                    ]
                },
                provisionProof: { _ in
                    stage = "store-provisioning"
                    lastDiagnostic = "stage=store-provisioning"
                    await AnisetteClient.shared.invalidate(resetProvisioning: false)
                    let a = try await AnisetteClient.shared.fetch()
                    stage = "authentication"
                    return [
                        "X-Apple-AMD": a.oneTimePassword,
                        "X-Apple-AMD-M": a.machineID
                    ]
                },
                resetProof: {
                    Task { await AnisetteClient.shared.invalidate(resetProvisioning: false) }
                },
                execute: { headerProvider in
                    try await IPadnAppleAuthentication.authenticate(
                        endpoint: endpoint,
                        body: body,
                        makeHeaders: { try await headerProvider(endpoint) },
                        send: { url, body, headers in
                            try await IPadnHTTPClient.shared.request(
                                url,
                                method: "POST",
                                body: body,
                                headers: headers,
                                appleRedirects: true,
                                authentication: true,
                                refreshHeaders: headerProvider
                            )
                        },
                        report: { lastDiagnostic = $0 }
                    )
                }
            )
            raw = result.0
            response = result.1
        } catch is CancellationError {
            lastDiagnostic = "stage=\(stage); cancelled"
            throw CancellationError()
        } catch let error as IPadnAppleLoginError {
            lastDiagnostic += "; result=\(error)"
            throw mapLoginError(error)
        } catch {
            if stage == "signing" || stage == "store-provisioning" {
                lastDiagnostic = "stage=\(stage); " + IPadnAppleAuthentication.errorCode(error)
            }
            if stage == "configuration" {
                throw AppStoreClientError.message(
                    "Couldn’t fetch Apple login configuration. Check the network and retry."
                )
            }
            throw mapGeneric(error)
        }

        if let failure = IPadnAppleLoginResponse.failure(raw, submittedCode: !code.isEmpty) {
            lastDiagnostic += "; result=apple-rejected-or-verification-required"
            throw mapGeneric(failure)
        }

        var cookieHeaders: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            cookieHeaders[String(describing: key)] = String(describing: value)
        }
        let cookies = response.url.map {
            HTTPCookie.cookies(withResponseHeaderFields: cookieHeaders, for: $0)
        } ?? []
        let cookie = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

        var resolvedDSID = ipadnPlistString(raw["dsPersonId"])
        if resolvedDSID.isEmpty,
           let headerDSID = response.value(forHTTPHeaderField: "X-Dsid")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !headerDSID.isEmpty,
           headerDSID.allSatisfy({ $0.isASCII && $0.isNumber }) {
            resolvedDSID = headerDSID
        }
        if resolvedDSID.isEmpty {
            for item in cookies {
                for prefix in ["mz_at0-", "mz_at_ssl-"] where item.name.hasPrefix(prefix) {
                    let candidate = String(item.name.dropFirst(prefix.count))
                    if !candidate.isEmpty, candidate.allSatisfy({ $0.isASCII && $0.isNumber }) {
                        resolvedDSID = candidate
                        break
                    }
                }
                if !resolvedDSID.isEmpty { break }
            }
        }

        let passwordToken = ipadnPlistString(raw["passwordToken"])
        guard !resolvedDSID.isEmpty, !passwordToken.isEmpty else {
            lastDiagnostic += "; result=incomplete-credentials"
            throw AppStoreClientError.needsTwoFactor
        }

        let fullStore = response.value(forHTTPHeaderField: "X-Set-Apple-Store-Front")
            ?? response.value(forHTTPHeaderField: "X-Apple-Request-Store-Front")
            ?? ""
        let resolvedFront = fullStore.isEmpty ? "143441-1,29" : fullStore
        let pod = response.value(forHTTPHeaderField: "pod")
            ?? response.value(forHTTPHeaderField: "Pod")

        lastDiagnostic += "; result=signed-in"
        return StorefrontSession(
            email: email,
            passwordToken: passwordToken,
            dsid: resolvedDSID,
            storeFront: resolvedFront,
            pod: pod,
            guid: guid,
            createdAt: Date(),
            cookieHeader: cookie.isEmpty ? nil : cookie
        )
    }

    private static func mapGeneric(_ error: Error) -> Error {
        if error is IPadnAppleLoginError {
            return AppStoreClientError.needsTwoFactor
        }
        let desc = error.localizedDescription
        if desc.localizedCaseInsensitiveContains("verification")
            || desc.localizedCaseInsensitiveContains("trusted device")
            || desc.localizedCaseInsensitiveContains("验证") {
            return AppStoreClientError.needsTwoFactor
        }
        if let tool = error as? IPadnToolError, case .message(let m) = tool {
            return AppStoreClientError.message(m)
        }
        if let http = error as? IPadnHTTPStatusError {
            return AppStoreClientError.network("Store authenticate HTTP \(http.code).")
        }
        return error
    }
}
