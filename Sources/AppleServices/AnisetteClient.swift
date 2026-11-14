//
//  AnisetteClient.swift
//  Remote anisette (Windows/iTunes client identity) for GrandSlam — no mock.
//  Default server: https://ani.jkcoxson.com (v3).
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

    var errorDescription: String? {
        switch self {
        case .badURL: return "Bad anisette server URL."
        case .badResponse(let c, let b): return "Anisette server error (\(c)): \(b)"
        case .missingFields: return "Anisette response missing required headers."
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

    func fetch() async throws -> AnisetteHeaders {
        if let c = cached, Date().timeIntervalSince(c.1) < cacheTTL { return c.0 }

        let base = serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // Prefer v3 client_info + headers so GrandSlam gets matching Windows/iTunes identity.
        if let infoURL = URL(string: "\(base)/v3/client_info"),
           let headers = try? await fetchV3(clientInfoURL: infoURL, base: base) {
            cached = (headers, Date())
            return headers
        }
        // Legacy root GET
        var req = URLRequest(url: serverURL)
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnisetteError.badResponse(code, String(data: data, encoding: .utf8) ?? "")
        }
        let headers = try parse(json)
        cached = (headers, Date())
        return headers
    }

    private func fetchV3(clientInfoURL: URL, base: String) async throws -> AnisetteHeaders {
        var infoReq = URLRequest(url: clientInfoURL)
        infoReq.timeoutInterval = 15
        let (infoData, infoResp) = try await URLSession.shared.data(for: infoReq)
        let infoCode = (infoResp as? HTTPURLResponse)?.statusCode ?? 0
        guard infoCode == 200,
              let info = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any] else {
            throw AnisetteError.badResponse(infoCode, String(data: infoData, encoding: .utf8) ?? "")
        }
        let clientInfo = (info["client_info"] as? String)
            ?? "<PC> <Windows;6.2(0,0);9200> <com.apple.AuthKit/1 (com.apple.iTunes/12.12.4.1)>"
        let userAgent = (info["user_agent"] as? String) ?? "akd/1.0 CFNetwork/808.1.4"

        // Identifier + empty adi_pb → server provisions and returns headers
        guard let headersURL = URL(string: "\(base)/v3/get_headers") else { throw AnisetteError.badURL }
        var post = URLRequest(url: headersURL)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.timeoutInterval = 20
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // Persist identifier so MID stays stable across fetches in-session
        let stored = UserDefaults.standard.string(forKey: "tetherless.anisette.identifier") ?? identifier
        if UserDefaults.standard.string(forKey: "tetherless.anisette.identifier") == nil {
            UserDefaults.standard.set(stored, forKey: "tetherless.anisette.identifier")
        }
        let adiB64 = UserDefaults.standard.string(forKey: "tetherless.anisette.adi_pb") ?? ""
        post.httpBody = try JSONSerialization.data(withJSONObject: [
            "identifier": stored,
            "adi_pb": adiB64
        ])
        let (data, resp) = try await URLSession.shared.data(for: post)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AnisetteError.badResponse(code, String(data: data, encoding: .utf8) ?? "")
        }
        if let result = json["result"] as? String, result == "GetHeadersError" {
            // Clear stale adi and retry once with empty
            UserDefaults.standard.removeObject(forKey: "tetherless.anisette.adi_pb")
            throw AnisetteError.badResponse(code, (json["message"] as? String) ?? result)
        }
        if let adi = json["adi_pb"] as? String, !adi.isEmpty {
            UserDefaults.standard.set(adi, forKey: "tetherless.anisette.adi_pb")
        }
        var headers = try parse(json)
        headers.clientInfo = clientInfo
        headers.userAgent = userAgent
        return headers
    }

    private func parse(_ json: [String: Any]) throws -> AnisetteHeaders {
        func s(_ keys: String...) -> String? {
            for k in keys {
                if let v = json[k] as? String, !v.isEmpty { return v }
                if let v = json[k] as? NSNumber { return v.stringValue }
            }
            return nil
        }
        // Servers use mixed key styles
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
