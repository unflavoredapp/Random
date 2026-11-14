//
//  DeveloperPortalClient.swift
//  Real developerservices2.apple.com QH65B2 plist + v1 certificates API.
//

import Foundation
import Combine

@MainActor
final class DeveloperPortalClient: ObservableObject {
    static let shared = DeveloperPortalClient()

    private let clientID = "XABBG36SBA"
    private let protocolVersion = "QH65B2"
    private let authApp = "com.apple.gs.xcode.auth"
    private let servicesBase = "https://developerservices2.apple.com/services/QH65B2"
    private let servicesV1Base = "https://developerservices2.apple.com/services/v1"
    private let session = URLSession(configuration: .ephemeral)

    private init() {}

    // MARK: - Teams

    func listTeams(session auth: AppleAuthSession) async throws -> [Team] {
        try await listTeams(auth: auth)
    }

    func listTeams(auth: AppleAuthSession) async throws -> [Team] {
        let dict = try await sendPlist(
            path: "/listTeams.action",
            parameters: [:],
            session: auth,
            teamId: nil
        )
        let rawTeams = dict["teams"] as? [[String: Any]] ?? []
        let teams: [Team] = rawTeams.compactMap { t in
            let id: String
            if let s = t["teamId"] as? String { id = s }
            else if let n = t["teamId"] as? NSNumber { id = n.stringValue }
            else { return nil }
            guard !id.isEmpty else { return nil }
            let name = (t["name"] as? String) ?? (t["teamName"] as? String) ?? id
            let type = (t["type"] as? String) ?? ""
            let memberships = t["memberships"] as? [[String: Any]] ?? []
            let membershipName = (memberships.first?["name"] as? String) ?? ""
            let isFree: Bool = {
                let m = membershipName.lowercased()
                if m.contains("free") { return true }
                // Personal / unpaid Apple IDs are Individual with no paid Program membership.
                if type == "Individual" {
                    if memberships.isEmpty { return true }
                    if memberships.count == 1 && !m.contains("organization") && !m.contains("company") {
                        // "Apple Developer Program" paid individuals still contain "program"; free often says "Free".
                        return m.contains("free") || m.isEmpty
                    }
                }
                return false
            }()
            return Team(id: id, name: name, isFree: isFree)
        }
        if teams.isEmpty {
            throw AppleAuthError.message("No development teams for this Apple ID.")
        }
        return teams
    }

    // MARK: - Certificates

    func listCertificates(session auth: AppleAuthSession, team: Team) async throws -> [DevCertificate] {
        try await listCertificates(auth: auth, team: team)
    }

    func listCertificates(auth: AppleAuthSession, team: Team) async throws -> [DevCertificate] {
        if team.isFree {
            do { return try await listCertificatesV1(session: auth, team: team) } catch { /* fall through */ }
        }
        do {
            return try await listCertificatesV1(session: auth, team: team)
        } catch {
            return try await listCertificatesPlist(session: auth, team: team)
        }
    }

    func revokeCertificate(_ certificate: DevCertificate, session auth: AppleAuthSession, team: Team) async throws {
        try await revokeCertificate(certificate, auth: auth, team: team)
    }

    func revokeCertificate(_ cert: DevCertificate, auth: AppleAuthSession, team: Team) async throws {
        let url = URL(string: "\(servicesV1Base)/certificates/\(cert.id)")!
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        try await sendServicesJSON(req, session: auth, team: team, allowEmpty: true)
    }

    func createDevelopmentCertificate(
        machineName: String,
        session auth: AppleAuthSession,
        team: Team
    ) async throws -> (certificate: DevCertificate, privateKeyPEM: String) {
        let created = try await createDevelopmentCertificate(machineName: machineName, auth: auth, team: team)
        return (created.certificate, String(data: created.privateKeyPEM, encoding: .utf8) ?? created.csr.privateKeyPEM)
    }

    /// Create a new iOS Development certificate via CSR.
    func createDevelopmentCertificate(
        machineName: String,
        auth: AppleAuthSession,
        team: Team
    ) async throws -> (certPEM: Data, privateKeyPEM: Data, certificate: DevCertificate, csr: CSRBuilder.Result) {
        let csr = try CSRBuilder.generate(commonName: machineName)
        let dict = try await sendPlist(
            path: "/ios/submitDevelopmentCSR.action",
            parameters: [
                "csrContent": csr.csrPEM,
                "machineName": machineName,
                "machineId": UUID().uuidString.uppercased()
            ],
            session: auth,
            teamId: team.id,
            resultCodeHandler: { code, message in
                if code == 3250 { return AppleAuthError.csrFailed(message) }
                if code == 35 || code == 7460 { return AppleAuthError.portal(code, message) }
                return nil
            }
        )

        var certData: Data?
        var serial = ""
        var certId = ""
        var name = machineName

        if let certReq = dict["certRequest"] as? [String: Any] {
            certData = certReq["certContent"] as? Data
            if certData == nil, let s = certReq["certContent"] as? String {
                certData = Data(base64Encoded: s, options: .ignoreUnknownCharacters)
            }
            if certData == nil, let d = certReq["certificate"] as? Data { certData = d }
            if certData == nil, let s = certReq["certificate"] as? String {
                certData = Data(base64Encoded: s, options: .ignoreUnknownCharacters)
            }
            serial = (certReq["serialNumber"] as? String) ?? (certReq["serialNum"] as? String) ?? ""
            certId = (certReq["certificateId"] as? String) ?? (certReq["certRequestId"] as? String) ?? ""
            name = (certReq["name"] as? String) ?? machineName
        }
        if certData == nil, let s = dict["certificateContent"] as? String {
            certData = Data(base64Encoded: s, options: .ignoreUnknownCharacters)
        }

        if certData == nil {
            let all = try await listCertificates(auth: auth, team: team)
            if let matched = all.first(where: {
                ($0.machineName ?? "").caseInsensitiveCompare(machineName) == .orderedSame
            }) ?? all.first {
                let pem: Data
                if let raw = matched.certificateData {
                    pem = Self.certificatePEM(from: raw)
                } else {
                    throw AppleAuthError.message("Certificate created but content missing from portal listing.")
                }
                return (pem, Data(csr.privateKeyPEM.utf8), matched, csr)
            }
            throw AppleAuthError.message("Portal didn't return a certificate for the CSR.")
        }

        let pem = Self.certificatePEM(from: certData!)
        if certId.isEmpty { certId = serial.isEmpty ? UUID().uuidString : serial }
        let cert = DevCertificate(
            id: certId,
            name: name,
            serialNumber: serial,
            expires: nil,
            machineName: machineName,
            certificateData: certData
        )
        return (pem, Data(csr.privateKeyPEM.utf8), cert, csr)
    }

    // MARK: - Devices

    func listDevices(session auth: AppleAuthSession, team: Team) async throws -> [DevDevice] {
        try await listDevices(auth: auth, team: team)
    }

    func listDevices(auth: AppleAuthSession, team: Team) async throws -> [DevDevice] {
        let dict = try await sendPlist(
            path: "/ios/listDevices.action",
            parameters: [:],
            session: auth,
            teamId: team.id
        )
        let raw = dict["devices"] as? [[String: Any]] ?? []
        return raw.compactMap { d in
            let udid = (d["deviceNumber"] as? String) ?? (d["udid"] as? String) ?? ""
            guard !udid.isEmpty else { return nil }
            let deviceId = (d["deviceId"] as? String) ?? udid
            let name = (d["name"] as? String) ?? udid
            return DevDevice(
                id: deviceId,
                name: name,
                udid: udid,
                model: d["deviceClass"] as? String ?? d["model"] as? String,
                status: d["status"] as? String
            )
        }
    }

    func addDevice(udid: String, name: String, session auth: AppleAuthSession, team: Team) async throws -> DevDevice {
        try await addDevice(udid: udid, name: name, auth: auth, team: team)
    }

    func addDevice(udid: String, name: String, auth: AppleAuthSession, team: Team) async throws -> DevDevice {
        let dict = try await sendPlist(
            path: "/ios/addDevice.action",
            parameters: [
                "deviceNumber": udid,
                "name": name,
                "DTDK_Platform": "ios"
            ],
            session: auth,
            teamId: team.id,
            resultCodeHandler: { code, message in
                if code == 35 { return AppleAuthError.portal(code, message) }
                return nil
            }
        )
        if let d = dict["device"] as? [String: Any] {
            let u = (d["deviceNumber"] as? String) ?? udid
            let id = (d["deviceId"] as? String) ?? u
            let n = (d["name"] as? String) ?? name
            return DevDevice(id: id, name: n, udid: u, model: d["deviceClass"] as? String, status: d["status"] as? String)
        }
        return DevDevice(id: udid, name: name, udid: udid, model: nil, status: "c")
    }

    // MARK: - App IDs

    func listAppIDs(session auth: AppleAuthSession, team: Team) async throws -> [DevAppID] {
        try await listAppIDs(auth: auth, team: team)
    }

    func listAppIDs(auth: AppleAuthSession, team: Team) async throws -> [DevAppID] {
        let dict = try await sendPlist(
            path: "/ios/listAppIds.action",
            parameters: [:],
            session: auth,
            teamId: team.id
        )
        let raw = dict["appIds"] as? [[String: Any]] ?? []
        return raw.compactMap { a in
            let id = (a["appIdId"] as? String) ?? ""
            let bundle = (a["identifier"] as? String) ?? ""
            guard !id.isEmpty || !bundle.isEmpty else { return nil }
            let name = (a["name"] as? String) ?? bundle
            return DevAppID(id: id.isEmpty ? bundle : id, name: name, bundleID: bundle)
        }
    }

    func addAppID(bundleId: String, name: String, session auth: AppleAuthSession, team: Team) async throws -> DevAppID {
        try await addAppID(bundleID: bundleId, name: name, auth: auth, team: team)
    }

    func addAppID(bundleID: String, name: String, auth: AppleAuthSession, team: Team) async throws -> DevAppID {
        let dict = try await sendPlist(
            path: "/ios/addAppId.action",
            parameters: [
                "name": name,
                "identifier": bundleID
            ],
            session: auth,
            teamId: team.id,
            resultCodeHandler: { code, message in
                if code == 35 || code == 37 { return AppleAuthError.portal(code, message) }
                return nil
            }
        )
        if let a = dict["appId"] as? [String: Any] {
            let id = (a["appIdId"] as? String) ?? bundleID
            let bundle = (a["identifier"] as? String) ?? bundleID
            let n = (a["name"] as? String) ?? name
            return DevAppID(id: id, name: n, bundleID: bundle)
        }
        throw AppleAuthError.message("App ID create response missing appId.")
    }

    // MARK: - Profiles

    func downloadDevelopmentProfile(
        for appID: DevAppID,
        session auth: AppleAuthSession,
        team: Team
    ) async throws -> DevProvisioningProfile {
        let data = try await downloadDevelopmentProfile(appID: appID, auth: auth, team: team)
        return DevProvisioningProfile(id: nil, name: appID.name, data: data)
    }

    func downloadDevelopmentProfile(
        appID: DevAppID,
        auth: AppleAuthSession,
        team: Team
    ) async throws -> Data {
        let dict = try await sendPlist(
            path: "/ios/downloadTeamProvisioningProfile.action",
            parameters: ["appIdId": appID.id],
            session: auth,
            teamId: team.id,
            resultCodeHandler: { code, message in
                if code == 9115 || code == 8201 {
                    return AppleAuthError.portal(code, "App ID not found: \(message)")
                }
                return nil
            }
        )
        if let d = dict["provisioningProfile"] as? Data { return d }
        if let s = dict["provisioningProfile"] as? String, let d = Data(base64Encoded: s) { return d }
        if let nested = dict["provisioningProfile"] as? [String: Any] {
            if let d = nested["encodedProfile"] as? Data { return d }
            if let s = nested["encodedProfile"] as? String, let d = Data(base64Encoded: s) { return d }
        }
        throw AppleAuthError.message("Portal didn't return a provisioning profile.")
    }

    // MARK: - Plist dispatcher

    @discardableResult
    private func sendPlist(
        path: String,
        parameters: [String: Any],
        session auth: AppleAuthSession,
        teamId: String?,
        resultCodeHandler: ((Int, String) -> Error?)? = nil
    ) async throws -> [String: Any] {
        var params: [String: Any] = [
            "clientId": clientID,
            "protocolVersion": protocolVersion,
            "requestId": UUID().uuidString.uppercased()
        ]
        if let teamId { params["teamId"] = teamId }
        parameters.forEach { params[$0.key] = $0.value }

        let body = try PropertyListSerialization.data(fromPropertyList: params, format: .xml, options: 0)
        let url = URL(string: "\(servicesBase)\(path)?clientId=\(clientID)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        applySessionHeaders(&req, auth: auth, contentType: "text/x-xml-plist", accept: "text/x-xml-plist")

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard !data.isEmpty else {
            throw AppleAuthError.network("Empty portal response (HTTP \(code)) for \(path)")
        }
        guard let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            throw AppleAuthError.network("Non-plist portal response for \(path): \(raw.prefix(240))")
        }

        if let resultCode = dict["resultCode"] as? Int, resultCode != 0 {
            let message = (dict["userString"] as? String)
                ?? (dict["resultString"] as? String)
                ?? (dict["errorString"] as? String)
                ?? "Apple Developer Portal error"
            if let custom = resultCodeHandler?(resultCode, message) {
                throw custom
            }
            throw AppleAuthError.portal(resultCode, message)
        }
        return dict
    }

    // MARK: - v1 certificates JSON

    private func listCertificatesV1(session auth: AppleAuthSession, team: Team) async throws -> [DevCertificate] {
        let url = URL(string: "\(servicesV1Base)/certificates")!
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        let dict = try await sendServicesJSON(req, session: auth, team: team)
        let items = dict["data"] as? [[String: Any]] ?? []
        return items.compactMap { item in
            let id = (item["id"] as? String) ?? ""
            guard !id.isEmpty else { return nil }
            let attrs = item["attributes"] as? [String: Any] ?? [:]
            let name = (attrs["displayName"] as? String)
                ?? (attrs["name"] as? String)
                ?? id
            let serial = (attrs["serialNumber"] as? String) ?? ""
            let machine = attrs["machineName"] as? String
            var expires: Date?
            if let s = attrs["expirationDate"] as? String {
                expires = ISO8601DateFormatter().date(from: s)
            }
            var certData: Data?
            if let b64 = attrs["certificateContent"] as? String {
                certData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
            }
            return DevCertificate(
                id: id,
                name: name,
                serialNumber: serial,
                expires: expires,
                machineName: machine,
                certificateData: certData
            )
        }
    }

    private func listCertificatesPlist(session auth: AppleAuthSession, team: Team) async throws -> [DevCertificate] {
        let dict = try await sendPlist(
            path: "/ios/listAllDevelopmentCerts.action",
            parameters: [:],
            session: auth,
            teamId: team.id
        )
        let raw = (dict["certificates"] as? [[String: Any]])
            ?? (dict["certRequests"] as? [[String: Any]])
            ?? []
        return raw.compactMap { c in
            let id = (c["certificateId"] as? String) ?? (c["certRequestId"] as? String) ?? (c["serialNumber"] as? String) ?? ""
            let serial = (c["serialNumber"] as? String) ?? (c["serialNum"] as? String) ?? ""
            guard !id.isEmpty || !serial.isEmpty else { return nil }
            let name = (c["name"] as? String) ?? (c["machineName"] as? String) ?? serial
            var certData = c["certContent"] as? Data
            if certData == nil, let s = c["certContent"] as? String {
                certData = Data(base64Encoded: s, options: .ignoreUnknownCharacters)
            }
            return DevCertificate(
                id: id.isEmpty ? serial : id,
                name: name,
                serialNumber: serial,
                expires: c["expirationDate"] as? Date,
                machineName: c["machineName"] as? String,
                certificateData: certData
            )
        }
    }

    @discardableResult
    private func sendServicesJSON(
        _ original: URLRequest,
        session auth: AppleAuthSession,
        team: Team,
        allowEmpty: Bool = false
    ) async throws -> [String: Any] {
        var req = original
        var comps = URLComponents()
        comps.queryItems = [URLQueryItem(name: "teamId", value: team.id)]
        let query = comps.query ?? "teamId=\(team.id)"
        let body = try JSONSerialization.data(withJSONObject: ["urlEncodedQueryParams": query])
        let methodOverride = req.httpMethod ?? "GET"
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue(methodOverride, forHTTPHeaderField: "X-HTTP-Method-Override")
        applySessionHeaders(&req, auth: auth, contentType: "application/vnd.api+json", accept: "application/vnd.api+json")

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if data.isEmpty {
            if allowEmpty || code == 204 || methodOverride == "DELETE" {
                return [:]
            }
            throw AppleAuthError.network("Empty v1 services response (HTTP \(code))")
        }
        if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errors = dict["errors"] as? [[String: Any]],
               let detail = errors.first?["detail"] as? String {
                throw AppleAuthError.portal(-1, detail)
            }
            if let resultCode = dict["resultCode"] as? Int, resultCode != 0 {
                let message = (dict["userString"] as? String) ?? (dict["resultString"] as? String) ?? "Portal error"
                throw AppleAuthError.portal(resultCode, message)
            }
            return dict
        }
        if allowEmpty || methodOverride == "DELETE" { return [:] }
        let raw = String(data: data, encoding: .utf8) ?? ""
        throw AppleAuthError.network("Non-JSON v1 response (HTTP \(code)): \(raw.prefix(240))")
    }

    private func applySessionHeaders(
        _ req: inout URLRequest,
        auth: AppleAuthSession,
        contentType: String,
        accept: String
    ) {
        let a = auth.anisette
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("en-us", forHTTPHeaderField: "Accept-Language")
        req.setValue("Xcode", forHTTPHeaderField: "User-Agent")
        req.setValue(authApp, forHTTPHeaderField: "X-Apple-App-Info")
        req.setValue(auth.xcodeVersion, forHTTPHeaderField: "X-Xcode-Version")
        req.setValue(auth.dsid, forHTTPHeaderField: "X-Apple-I-Identity-Id")
        req.setValue(auth.authToken, forHTTPHeaderField: "X-Apple-GS-Token")
        req.setValue(a.machineID, forHTTPHeaderField: "X-Apple-I-MD-M")
        req.setValue(a.oneTimePassword, forHTTPHeaderField: "X-Apple-I-MD")
        req.setValue(a.localUserID, forHTTPHeaderField: "X-Apple-I-MD-LU")
        req.setValue(a.routingInfo, forHTTPHeaderField: "X-Apple-I-MD-RINFO")
        req.setValue(a.deviceID, forHTTPHeaderField: "X-Mme-Device-Id")
        req.setValue(a.clientInfo, forHTTPHeaderField: "X-MMe-Client-Info")
        req.setValue(a.clientTime, forHTTPHeaderField: "X-Apple-I-Client-Time")
        req.setValue(a.locale, forHTTPHeaderField: "X-Apple-Locale")
        req.setValue(a.locale, forHTTPHeaderField: "X-Apple-I-Locale")
        req.setValue(a.timeZone, forHTTPHeaderField: "X-Apple-I-TimeZone")
    }

    private static func certificatePEM(from data: Data) -> Data {
        if String(data: data, encoding: .utf8)?.contains("BEGIN CERTIFICATE") == true {
            return data
        }
        let b64 = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN CERTIFICATE-----\n\(b64)\n-----END CERTIFICATE-----\n".utf8)
    }
}
