//
//  AnisetteClient.swift
//  Remote anisette (v3) for GrandSlam — provision via WebSocket when adi_pb is missing.
//  Default server: https://ani.jkcoxson.com
//

import Foundation

struct AnisetteHeaders: Sendable, Codable, Equatable {
    var machineID: String
    var oneTimePassword: String
    var localUserID: String
    var routingInfo: String
    var deviceID: String
    var serialNumber: String
    var clientInfo: String
    var userAgent: String
    var clientTime: String
    var locale: String
    var timeZone: String
}

enum AnisetteError: LocalizedError {
    case badURL
    case badResponse(Int, String)
    case missingFields
    case provisioning(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Bad anisette server URL."
        case .badResponse(let c, let b): return "Anisette server error (\(c)): \(b)"
        case .missingFields: return "Anisette response missing required headers."
        case .provisioning(let m): return "Anisette provisioning failed: \(m)"
        }
    }
}

actor AnisetteClient {
    static let shared = AnisetteClient()

    /// Override with UserDefaults "tetherless.anisette.server" if needed.
    var serverURL: URL {
        let raw = UserDefaults.standard.string(forKey: "tetherless.anisette.server")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let u = URL(string: raw), !raw.isEmpty { return u }
        return URL(string: "https://ani.jkcoxson.com")!
    }

    private var cached: (AnisetteHeaders, Date)?
    private let cacheTTL: TimeInterval = 25
    private let lookupURL = URL(string: "https://gsa.apple.com/grandslam/GsService2/lookup")!

    private enum Keys {
        static let identifier = "tetherless.anisette.identifier"
        static let adiPb = "tetherless.anisette.adi_pb"
        static let routing = "tetherless.anisette.routing"
        static let server = "tetherless.anisette.server"
    }

    func fetch() async throws -> AnisetteHeaders {
        if let c = cached, Date().timeIntervalSince(c.1) < cacheTTL { return c.0 }

        let base = serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let clientMeta = try await fetchClientInfo(base: base)

        // Prefer provisioned v3 headers so MID/OTP match the server's ADI identity.
        do {
            let headers = try await fetchV3Provisioned(base: base, clientMeta: clientMeta)
            cached = (headers, Date())
            return headers
        } catch {
            // One reset + retry covers stale adi_pb / identifier pairs Apple rejects.
            resetProvisioningState()
            let headers = try await fetchV3Provisioned(base: base, clientMeta: clientMeta)
            cached = (headers, Date())
            return headers
        }
    }

    /// Drop cached OTP + provisioning blob so the next fetch re-provisions.
    func invalidate(resetProvisioning: Bool = false) {
        cached = nil
        if resetProvisioning {
            resetProvisioningState()
        }
    }

    private func resetProvisioningState() {
        UserDefaults.standard.removeObject(forKey: Keys.adiPb)
        UserDefaults.standard.removeObject(forKey: Keys.routing)
        UserDefaults.standard.removeObject(forKey: Keys.identifier)
        cached = nil
    }

    private struct ClientMeta {
        var clientInfo: String
        var userAgent: String
    }

    private func fetchClientInfo(base: String) async throws -> ClientMeta {
        guard let infoURL = URL(string: "\(base)/v3/client_info") else { throw AnisetteError.badURL }
        var infoReq = URLRequest(url: infoURL)
        infoReq.timeoutInterval = 15
        infoReq.cachePolicy = .reloadIgnoringLocalCacheData
        let (infoData, infoResp) = try await URLSession.shared.data(for: infoReq)
        let infoCode = (infoResp as? HTTPURLResponse)?.statusCode ?? 0
        if infoCode == 200,
           let info = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any] {
            let clientInfo = (info["client_info"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let userAgent = (info["user_agent"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let clientInfo, !clientInfo.isEmpty, let userAgent, !userAgent.isEmpty {
                return ClientMeta(clientInfo: clientInfo, userAgent: userAgent)
            }
        }
        // Windows iTunes identity — what Apple currently accepts for remote anisette.
        return ClientMeta(
            clientInfo: "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>",
            userAgent: "akd/1.0 CFNetwork/808.1.4"
        )
    }

    private func stableIdentifier() -> String {
        if let existing = UserDefaults.standard.string(forKey: Keys.identifier), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(fresh, forKey: Keys.identifier)
        return fresh
    }

    private func fetchV3Provisioned(base: String, clientMeta: ClientMeta) async throws -> AnisetteHeaders {
        let identifier = stableIdentifier()
        var adiB64 = UserDefaults.standard.string(forKey: Keys.adiPb) ?? ""

        if adiB64.isEmpty {
            let blob = try await provisionRemote(base: base, identifier: identifier, clientMeta: clientMeta)
            adiB64 = blob.base64EncodedString()
            UserDefaults.standard.set(adiB64, forKey: Keys.adiPb)
        }

        guard let headersURL = URL(string: "\(base)/v3/get_headers") else { throw AnisetteError.badURL }
        var post = URLRequest(url: headersURL)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.timeoutInterval = 20
        post.cachePolicy = .reloadIgnoringLocalCacheData
        post.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": identifier,
            "adi_pb": adiB64
        ])
        let (data, resp) = try await URLSession.shared.data(for: post)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnisetteError.badResponse(code, String(data: data, encoding: .utf8) ?? "")
        }
        if let result = json["result"] as? String, result == "GetHeadersError" {
            UserDefaults.standard.removeObject(forKey: Keys.adiPb)
            throw AnisetteError.badResponse(code, (json["message"] as? String) ?? result)
        }
        if let adi = json["adi_pb"] as? String, !adi.isEmpty {
            UserDefaults.standard.set(adi, forKey: Keys.adiPb)
        }
        var headers = try parse(json)
        // Always overlay the server's client identity — Apple rejects MID/OTP + Client-Info mismatches.
        headers.clientInfo = clientMeta.clientInfo
        headers.userAgent = clientMeta.userAgent
        if let routing = UserDefaults.standard.string(forKey: Keys.routing), !routing.isEmpty {
            headers.routingInfo = routing
        }
        return headers
    }

    // MARK: - Remote v3 provisioning (Apple lookup ↔ anisette WebSocket)

    private func provisionRemote(base: String, identifier: String, clientMeta: ClientMeta) async throws -> Data {
        let (startURL, endURL) = try await fetchProvisioningURLs(clientMeta: clientMeta, identifier: identifier)
        var routing = UserDefaults.standard.string(forKey: Keys.routing)

        let (spim, startRouting) = try await fetchSPIM(
            startURL: startURL,
            clientMeta: clientMeta,
            identifier: identifier,
            routingInfo: routing
        )
        if let startRouting { routing = startRouting }

        let session = try await openProvisioningSession(base: base)
        defer { session.cancel(with: .normalClosure, reason: nil) }

        let cpim = try await startProvision(
            session: session,
            identifier: identifier,
            spim: spim
        )

        let (ptm, tk, endRouting) = try await fetchPTM(
            endURL: endURL,
            cpim: cpim,
            clientMeta: clientMeta,
            identifier: identifier,
            routingInfo: routing
        )
        if let endRouting {
            routing = endRouting
            UserDefaults.standard.set(endRouting, forKey: Keys.routing)
        }

        return try await endProvision(session: session, ptm: ptm, tk: tk)
    }

    private func fetchProvisioningURLs(clientMeta: ClientMeta, identifier: String) async throws -> (URL, URL) {
        var req = URLRequest(url: lookupURL)
        req.httpMethod = "GET"
        applyProvisionHeaders(&req, clientMeta: clientMeta, identifier: identifier, routingInfo: nil)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let urls = plist["urls"] as? [String: String],
              let start = urls["midStartProvisioning"].flatMap(URL.init(string:)),
              let end = urls["midFinishProvisioning"].flatMap(URL.init(string:)) else {
            throw AnisetteError.provisioning("Apple lookup missing midStart/midFinish URLs (HTTP \(code)).")
        }
        return (start, end)
    }

    private func fetchSPIM(
        startURL: URL,
        clientMeta: ClientMeta,
        identifier: String,
        routingInfo: String?
    ) async throws -> (Data, String?) {
        var req = URLRequest(url: startURL)
        req.httpMethod = "POST"
        applyProvisionHeaders(&req, clientMeta: clientMeta, identifier: identifier, routingInfo: routingInfo)
        req.httpBody = try PropertyListSerialization.data(
            fromPropertyList: ["Header": ["Version": "1.0.1"], "Request": ["Type": "StartProvisioning"] as [String: Any]],
            format: .xml,
            options: 0
        )
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AnisetteError.provisioning("Start provisioning failed (HTTP \(code)).")
        }
        let response = (root["Response"] as? [String: Any]) ?? root
        guard let spimB64 = response["spim"] as? String, let spim = Data(base64Encoded: spimB64), !spim.isEmpty else {
            throw AnisetteError.provisioning("Start provisioning missing spim.")
        }
        let routing = response["routing-info"] as? String
            ?? (response["routing-info"] as? NSNumber)?.stringValue
            ?? httpRouting(resp)
        return (spim, routing)
    }

    private func fetchPTM(
        endURL: URL,
        cpim: Data,
        clientMeta: ClientMeta,
        identifier: String,
        routingInfo: String?
    ) async throws -> (Data, Data, String?) {
        var req = URLRequest(url: endURL)
        req.httpMethod = "POST"
        applyProvisionHeaders(&req, clientMeta: clientMeta, identifier: identifier, routingInfo: routingInfo)
        req.httpBody = try PropertyListSerialization.data(
            fromPropertyList: [
                "Header": ["Version": "1.0.1"],
                "Request": [
                    "Type": "FinishProvisioning",
                    "cpim": cpim.base64EncodedString()
                ] as [String: Any]
            ],
            format: .xml,
            options: 0
        )
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AnisetteError.provisioning("Finish provisioning failed (HTTP \(code)).")
        }
        let response = (root["Response"] as? [String: Any]) ?? root
        guard let ptmB64 = response["ptm"] as? String, let ptm = Data(base64Encoded: ptmB64),
              let tkB64 = response["tk"] as? String, let tk = Data(base64Encoded: tkB64) else {
            throw AnisetteError.provisioning("Finish provisioning missing ptm/tk.")
        }
        let routing = response["routing-info"] as? String
            ?? (response["routing-info"] as? NSNumber)?.stringValue
            ?? httpRouting(resp)
        return (ptm, tk, routing)
    }

    private func openProvisioningSession(base: String) async throws -> URLSessionWebSocketTask {
        guard let httpURL = URL(string: "\(base)/v3/provisioning_session"),
              var comps = URLComponents(url: httpURL, resolvingAgainstBaseURL: true) else {
            throw AnisetteError.badURL
        }
        comps.scheme = (comps.scheme == "http") ? "ws" : "wss"
        guard let wsURL = comps.url else { throw AnisetteError.badURL }
        let task = URLSession.shared.webSocketTask(with: wsURL)
        task.resume()
        return task
    }

    private func startProvision(
        session: URLSessionWebSocketTask,
        identifier: String,
        spim: Data
    ) async throws -> Data {
        while true {
            let json = try await receiveJSON(from: session)
            guard let result = json["result"] as? String else {
                throw AnisetteError.provisioning("Missing result in provisioning WebSocket.")
            }
            switch result {
            case "GiveIdentifier":
                try await sendJSON(["identifier": identifier], to: session)
            case "GiveStartProvisioningData":
                try await sendJSON(["spim": spim.base64EncodedString()], to: session)
            case "GiveEndProvisioningData":
                guard let cpimB64 = json["cpim"] as? String, let cpim = Data(base64Encoded: cpimB64) else {
                    throw AnisetteError.provisioning("Missing cpim from anisette server.")
                }
                return cpim
            default:
                let msg = (json["message"] as? String) ?? result
                throw AnisetteError.provisioning(msg)
            }
        }
    }

    private func endProvision(
        session: URLSessionWebSocketTask,
        ptm: Data,
        tk: Data
    ) async throws -> Data {
        try await sendJSON([
            "ptm": ptm.base64EncodedString(),
            "tk": tk.base64EncodedString()
        ], to: session)
        while true {
            let json = try await receiveJSON(from: session)
            guard let result = json["result"] as? String else {
                throw AnisetteError.provisioning("Missing result at end of provisioning.")
            }
            switch result {
            case "ProvisioningSuccess":
                guard let adi = json["adi_pb"] as? String, let data = Data(base64Encoded: adi), !data.isEmpty else {
                    throw AnisetteError.provisioning("Missing adi_pb after ProvisioningSuccess.")
                }
                return data
            default:
                let msg = (json["message"] as? String) ?? result
                throw AnisetteError.provisioning(msg)
            }
        }
    }

    private func sendJSON(_ dict: [String: String], to task: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        guard let str = String(data: data, encoding: .utf8) else {
            throw AnisetteError.provisioning("Couldn't encode WebSocket JSON.")
        }
        try await task.send(.string(str))
    }

    private func receiveJSON(from task: URLSessionWebSocketTask) async throws -> [String: Any] {
        let msg = try await task.receive()
        let str: String
        switch msg {
        case .string(let s): str = s
        case .data(let d): str = String(data: d, encoding: .utf8) ?? ""
        @unknown default: str = ""
        }
        guard let data = str.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnisetteError.provisioning("Invalid WebSocket JSON.")
        }
        return json
    }

    private func applyProvisionHeaders(
        _ req: inout URLRequest,
        clientMeta: ClientMeta,
        identifier: String,
        routingInfo: String?
    ) {
        req.setValue("text/x-xml-plist", forHTTPHeaderField: "Content-Type")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue(clientMeta.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(clientMeta.clientInfo, forHTTPHeaderField: "X-MMe-Client-Info")
        req.setValue(identifier.uppercased(), forHTTPHeaderField: "X-Mme-Device-Id")
        req.setValue("0000000000000000000000000000000000000000000000000000000000000001", forHTTPHeaderField: "X-Apple-I-MD-LU")
        req.setValue(routingInfo ?? "17106176", forHTTPHeaderField: "X-Apple-I-MD-RINFO")
        req.setValue("0", forHTTPHeaderField: "X-Apple-I-SRL-NO")
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        req.setValue(df.string(from: Date()), forHTTPHeaderField: "X-Apple-I-Client-Time")
        req.setValue("en_US", forHTTPHeaderField: "X-Apple-Locale")
        req.setValue("UTC", forHTTPHeaderField: "X-Apple-I-TimeZone")
    }

    private func httpRouting(_ resp: URLResponse) -> String? {
        guard let http = resp as? HTTPURLResponse else { return nil }
        for (k, v) in http.allHeaderFields {
            if String(describing: k).caseInsensitiveCompare("X-Apple-I-MD-RINFO") == .orderedSame,
               let s = v as? String, !s.isEmpty {
                return s
            }
        }
        return nil
    }

    private func parse(_ json: [String: Any]) throws -> AnisetteHeaders {
        func s(_ keys: String...) -> String? {
            for k in keys {
                if let v = json[k] as? String, !v.isEmpty { return v }
                if let v = json[k] as? NSNumber { return v.stringValue }
            }
            return nil
        }
        guard let mid = s("X-Apple-I-MD-M", "machineID", "mid"),
              let otp = s("X-Apple-I-MD", "oneTimePassword", "otp"),
              let lu = s("X-Apple-I-MD-LU", "localUserID", "lu") else {
            throw AnisetteError.missingFields
        }
        let routing = s("X-Apple-I-MD-RINFO", "routingInfo", "rinfo") ?? "17106176"
        let deviceID = s("X-Mme-Device-Id", "deviceID", "device_id") ?? UUID().uuidString.uppercased()
        let serial = s("X-Apple-I-SRL-NO", "serialNumber", "serial") ?? "0"
        let clientInfo = s("X-MMe-Client-Info", "client_info", "clientInfo")
            ?? "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>"
        let ua = s("User-Agent", "user_agent", "userAgent") ?? "akd/1.0 CFNetwork/808.1.4"
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime]
        let clientTime = s("X-Apple-I-Client-Time", "clientTime") ?? df.string(from: Date())
        let locale = s("X-Apple-Locale", "X-Apple-I-Locale", "locale") ?? "en_US"
        let tz = s("X-Apple-I-TimeZone", "timeZone") ?? (TimeZone.current.abbreviation() ?? "UTC")
        return AnisetteHeaders(
            machineID: mid, oneTimePassword: otp, localUserID: lu, routingInfo: routing,
            deviceID: deviceID, serialNumber: serial, clientInfo: clientInfo, userAgent: ua,
            clientTime: clientTime, locale: locale, timeZone: tz
        )
    }
}
