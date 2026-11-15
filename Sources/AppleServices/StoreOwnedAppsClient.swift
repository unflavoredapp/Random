//
//  StoreOwnedAppsClient.swift
//  Purchase DAAP owned-apps list (ipatool list-purchases), SAP-signed.
//

import Foundation

/// Lists apps owned by the signed-in Apple ID via `pd.itunes.apple.com` Purchase DAAP.
@MainActor
enum StoreOwnedAppsClient {
    private static let base = "https://pd.itunes.apple.com/WebObjects/MZPurchaseDaap.woa/purchase"
    private static let mediaKindApps: UInt32 = 131_072
    private static let mediaKindArcade: UInt32 = 262_144
    private static let mediaKindMac: UInt32 = 67_108_864
    private static let configuratorUA =
        "Configurator/2.15 (Macintosh; OS X 11.0.0; 16A5288f) AppleWebKit/0605.2.7.5"

    static func fetch(account: StorefrontSession) async throws -> [OwnedStoreApp] {
        let guid = account.guid.isEmpty ? UUID().uuidString.replacingOccurrences(of: "-", with: "") : account.guid
        let signer = try await SAPSigner.connect()
        let now = Date()

        // 1) Login — opens a DAAP purchase session (unsigned login is OK).
        let loginData = try await postRaw(
            url: "\(base)/login",
            body: Data(),
            headers: daapHeaders(account: account, guid: guid, now: now),
            contentType: nil,
            signature: nil
        )
        try throwIfHTTPOrDAAPFailed(loginData.status, body: loginData.body, label: "Owned login")
        guard let sessionID = firstDMAPUint(loginData.body, tag: "mlid"), sessionID <= UInt64(UInt32.max) else {
            throw AppStoreClientError.message("Owned list login missing session id.")
        }

        let query =
            "('com.apple.itunes.extended\\-media\\-kind:\(mediaKindApps)'," +
            "'com.apple.itunes.extended\\-media\\-kind:\(mediaKindArcade)'," +
            "'com.apple.itunes.extended\\-media\\-kind:\(mediaKindMac)')"

        // 2) Update — SAP-signed form body.
        let updateBody = Data(
            "session-id=\(sessionID)&revision-number=(null)&query=\(query)".utf8
        )
        let updateSig = try await signer.sign(updateBody)
        var updateHeaders = daapHeaders(account: account, guid: guid, now: Date())
        updateHeaders["Content-Type"] = "application/x-www-form-urlencoded"
        updateHeaders["X-Apple-ActionSignature"] = updateSig.base64EncodedString()
        let updateData = try await postRaw(
            url: "\(base)/update",
            body: updateBody,
            headers: updateHeaders,
            contentType: "application/x-www-form-urlencoded",
            signature: nil // already in headers
        )
        try throwIfHTTPOrDAAPFailed(updateData.status, body: updateData.body, label: "Owned update")
        guard let revision = firstDMAPUint(updateData.body, tag: "musr"), revision <= UInt64(UInt32.max) else {
            throw AppStoreClientError.message("Owned list update missing revision.")
        }

        // 3) Items — SAP-signed DMAP body.
        let itemsBody = ownedAppsItemsBody(
            sessionID: UInt32(sessionID),
            latestVersion: UInt32(revision),
            query: query,
            now: Date()
        )
        let itemsSig = try await signer.sign(itemsBody)
        var itemsHeaders = daapHeaders(account: account, guid: guid, now: Date())
        itemsHeaders["Content-Type"] = "application/x-dmap-tagged"
        itemsHeaders["X-Apple-ActionSignature"] = itemsSig.base64EncodedString()
        let itemsData = try await postRaw(
            url: "\(base)/databases/\(revision)/items",
            body: itemsBody,
            headers: itemsHeaders,
            contentType: "application/x-dmap-tagged",
            signature: nil
        )
        try throwIfHTTPOrDAAPFailed(itemsData.status, body: itemsData.body, label: "Owned items")
        return parseOwnedApps(itemsData.body)
    }

    // MARK: - HTTP

    private static func daapHeaders(account: StorefrontSession, guid: String, now: Date) -> [String: String] {
        let utc = ISO8601DateFormatter()
        utc.formatOptions = [.withInternetDateTime]
        let tzSeconds = TimeZone.current.secondsFromGMT()
        return [
            "Accept": "*/*",
            "Accept-Language": "en-us",
            "Client-Cloud-DAAP-Request-Reason": "5",
            "Client-Cloud-Purchase-Daap-Version": "1.1/Configurator-2.0",
            "Client-DAAP-Version": "3.12",
            "User-Agent": configuratorUA,
            "iCloud-DSID": account.dsid,
            "X-Apple-I-Client-Time": utc.string(from: now),
            "X-Apple-I-Locale": "en_US",
            "X-Apple-I-TimeZone": TimeZone.current.identifier,
            "X-Apple-Store-Front": account.storeFront,
            "X-Apple-TZ": "\(tzSeconds / 60)",
            "X-Dsid": account.dsid,
            "X-Guid": guid,
            "X-Token": account.passwordToken
        ]
    }

    private static func postRaw(
        url: String,
        body: Data,
        headers: [String: String],
        contentType: String?,
        signature: Data?
    ) async throws -> (status: Int, body: Data) {
        guard let endpoint = URL(string: url) else {
            throw AppStoreClientError.message("Bad Owned list URL.")
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 45
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let signature {
            req.setValue(signature.base64EncodedString(), forHTTPHeaderField: "X-Apple-ActionSignature")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }

    private static func throwIfHTTPOrDAAPFailed(_ status: Int, body: Data, label: String) throws {
        // DAAP 401/403 often means this Purchase-DAAP path rejected the token — not that
        // MZFinance passwordToken is dead for downloads. Soft-fail Owned; keep Store Access.
        if status == 401 || status == 403 {
            throw AppStoreClientError.message(
                "Owned list unavailable (HTTP \(status)). Search still works — Store Access can stay signed in."
            )
        }
        if status != 200 {
            throw AppStoreClientError.network("\(label) returned HTTP \(status).")
        }
        if let daap = firstDMAPUint(body, tag: "mstt") {
            if daap == 401 || daap == 403 {
                throw AppStoreClientError.message(
                    "Owned list unavailable (DAAP \(daap)). Search still works — Store Access can stay signed in."
                )
            }
            if daap != 200 {
                throw AppStoreClientError.network("\(label) returned DAAP status \(daap).")
            }
        }
    }

    // MARK: - DMAP

    private static func ownedAppsItemsBody(
        sessionID: UInt32,
        latestVersion: UInt32,
        query: String,
        now: Date
    ) -> Data {
        var payload = Data()
        payload.append(dmapUint32("mstc", UInt32(now.timeIntervalSince1970)))
        payload.append(dmapUint32("mlid", sessionID))
        payload.append(dmapUint8("mikd", 2))
        payload.append(dmapUint32("musr", latestVersion))
        payload.append(dmapUint32("mder", 0))
        payload.append(dmapString("mque", query))
        payload.append(dmapTag("aetl", Data()))
        return dmapTag("adsr", payload)
    }

    private static func dmapTag(_ name: String, _ payload: Data) -> Data {
        var out = Data(name.utf8)
        while out.count < 4 { out.append(0) }
        out = Data(out.prefix(4))
        var len = UInt32(payload.count).bigEndian
        out.append(Data(bytes: &len, count: 4))
        out.append(payload)
        return out
    }

    private static func dmapUint8(_ name: String, _ value: UInt8) -> Data {
        dmapTag(name, Data([value]))
    }

    private static func dmapUint32(_ name: String, _ value: UInt32) -> Data {
        var be = value.bigEndian
        return dmapTag(name, Data(bytes: &be, count: 4))
    }

    private static func dmapString(_ name: String, _ value: String) -> Data {
        dmapTag(name, Data(value.utf8))
    }

    private static func firstDMAPUint(_ data: Data, tag: String) -> UInt64? {
        var found: UInt64?
        _ = walkDMAP(data, depth: 0) { name, payload in
            guard found == nil, name == tag else { return }
            switch payload.count {
            case 4:
                found = UInt64(readUInt32BE(payload))
            case 8:
                found = readUInt64BE(payload)
            default:
                break
            }
        }
        return found
    }

    private static func parseOwnedApps(_ data: Data) -> [OwnedStoreApp] {
        var apps: [OwnedStoreApp] = []
        var seen = Set<Int>()
        _ = walkDMAP(data, depth: 0) { tag, payload in
            guard tag == "mlit" else { return }
            guard let app = parseOwnedApp(payload), app.adamId != 0, seen.insert(app.adamId).inserted else { return }
            // Prefer iOS / iPadOS-ish entries; skip pure Mac-only later if needed.
            apps.append(app)
        }
        return apps
    }

    private static func parseOwnedApp(_ data: Data) -> OwnedStoreApp? {
        var adamId: Int = 0
        var bundleId = ""
        var name = ""
        var version = ""
        var mediaKind: UInt64 = 0
        _ = walkDMAP(data, depth: 0) { tag, payload in
            switch tag {
            case "aeSI":
                if let v = dmapInt64(payload) { adamId = Int(v) }
            case "aeBI":
                bundleId = String(data: payload, encoding: .utf8) ?? ""
            case "aeLN":
                name = String(data: payload, encoding: .utf8) ?? ""
            case "minm":
                if name.isEmpty { name = String(data: payload, encoding: .utf8) ?? "" }
            case "aePd":
                version = String(data: payload, encoding: .utf8) ?? ""
            case "aeMk":
                mediaKind = dmapUInt(payload)
            default:
                break
            }
        }
        guard adamId != 0 else { return nil }
        // Skip Mac-only catalog rows when we can detect them.
        if mediaKind == UInt64(mediaKindMac), bundleId.isEmpty { return nil }
        return OwnedStoreApp(
            adamId: adamId,
            name: name.isEmpty ? "App \(adamId)" : name,
            bundleId: bundleId,
            version: version,
            artistName: "",
            iconURL: nil
        )
    }

    private static func dmapInt64(_ payload: Data) -> Int64? {
        switch payload.count {
        case 4: return Int64(readUInt32BE(payload))
        case 8:
            let v = readUInt64BE(payload)
            guard v <= UInt64(Int64.max) else { return nil }
            return Int64(v)
        default: return nil
        }
    }

    private static func dmapUInt(_ payload: Data) -> UInt64 {
        switch payload.count {
        case 1: return UInt64(payload[0])
        case 2: return UInt64(readUInt16BE(payload))
        case 4: return UInt64(readUInt32BE(payload))
        case 8: return readUInt64BE(payload)
        default: return 0
        }
    }

    private static func readUInt16BE(_ data: Data) -> UInt16 {
        guard data.count >= 2 else { return 0 }
        return (UInt16(data[data.startIndex]) << 8) | UInt16(data[data.startIndex + 1])
    }

    private static func readUInt32BE(_ data: Data) -> UInt32 {
        guard data.count >= 4 else { return 0 }
        let b = data
        let i = b.startIndex
        return (UInt32(b[i]) << 24) | (UInt32(b[i + 1]) << 16) | (UInt32(b[i + 2]) << 8) | UInt32(b[i + 3])
    }

    private static func readUInt64BE(_ data: Data) -> UInt64 {
        guard data.count >= 8 else { return 0 }
        let hi = UInt64(readUInt32BE(data))
        let lo = UInt64(readUInt32BE(data.subdata(in: data.startIndex + 4 ..< data.startIndex + 8)))
        return (hi << 32) | lo
    }

    private static func walkDMAP(_ data: Data, depth: Int, visit: (String, Data) -> Void) -> Bool {
        if depth > 16 { return false }
        var offset = 0
        while offset + 8 <= data.count {
            let tagData = data.subdata(in: offset ..< offset + 4)
            guard let tag = String(data: tagData, encoding: .ascii), tag.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 0x20 }) else {
                return false
            }
            let length = Int(readUInt32BE(data.subdata(in: offset + 4 ..< offset + 8)))
            guard length >= 0, offset + 8 + length <= data.count else { return false }
            let payload = data.subdata(in: offset + 8 ..< offset + 8 + length)
            visit(tag, payload)
            if isContainer(tag) {
                _ = walkDMAP(payload, depth: depth + 1, visit: visit)
            }
            offset += 8 + length
        }
        return true
    }

    private static func isContainer(_ tag: String) -> Bool {
        ["adbs", "adsr", "aply", "avdb", "mbcl", "mccr", "mcty", "mdcl", "mlcl", "mlit", "mlog", "msrv", "mupd"].contains(tag)
    }
}
