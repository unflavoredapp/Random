//
//  IPadnStoreDownload.swift
//  Derived from mengangs/ipadn AppleService.fetchAsset + acquireFreeApp + ownedApps (GPL-2.0).
//  DownloadDispatch ent/download + WASM kbsync — not our volumeStore / remint / backend stack.
//

import Foundation

struct IPadnDownloadAsset: @unchecked Sendable {
    var adamId: String
    var name: String
    var bundleID: String
    var version: String
    var externalVersionId: String
    var externalVersionIDs: [String]
    var url: URL
    var sinfs: [Data]
    var metadata: [String: Any]
    var fileSize: Int64
    var minimumOS: String?
}

struct IPadnVersionTicket: Sendable {
    var displayVersion: String
    var rawShortVersion: String
    var buildVersion: String
    var fileSize: Int64?
    var minimumOS: String?
    var externalVersionId: String
}

@MainActor
enum IPadnStoreDownload {
    private static let noOfferMessage = "Apple did not return a download for this version."

    /// In-memory cookie jar (dsid → Cookie header). Persist at most once a minute.
    private static var liveCookies: [String: String] = [:]
    private static var cookiesSavedAt = Date.distantPast

    /// iPadn Get/Download: fetchAsset → CDN IPA → metadata + sinfs. Then FairPlay stays ours.
    static func purchaseAndDownload(
        adamId: Int,
        account: StorefrontSession,
        destination: URL,
        externalVersionId: String? = nil,
        onProgress: ((String) -> Void)? = nil
    ) async throws -> (url: URL, item: StoreDownloadItem) {
        guard adamId > 0 else {
            throw IPadnToolError.message("Missing App Store id.")
        }
        var session = account.normalizedForCommerce()
        guard session.isUsable else {
            throw IPadnToolError.message("Sign in under Account with the Apple ID that owns this app.")
        }
        onProgress?("Requesting App Store package…")
        let pin = (externalVersionId ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let asset = try await fetchAsset(
            appID: String(adamId),
            versionID: pin.isEmpty ? nil : pin,
            account: &session,
            useCache: true,
            fallback: false,
            refreshed: false,
            purchased: false,
            allowLicenseAcquisition: true
        )
        onProgress?("Downloading encrypted IPA\(asset.version.isEmpty ? "" : " v\(asset.version)")…")
        try await downloadFile(from: asset.url, to: destination, onProgress: onProgress)
        onProgress?("Writing iTunesMetadata + FairPlay licenses…")
        do {
            try IPadnIPAPackager.writeMetadata(asset.metadata, email: session.email, intoIPA: destination)
        } catch {
            onProgress?("iTunesMetadata write failed (\(error.localizedDescription)) — continuing.")
        }
        if !asset.sinfs.isEmpty {
            try IPadnIPAPackager.injectSinfs(asset.sinfs, intoIPA: destination)
            onProgress?("Embedded \(asset.sinfs.count) FairPlay license(s)…")
        }
        // Persist any cookies absorbed during fetch/buy so the next cold start stays warm.
        if let cookie = liveCookies[session.dsid] ?? session.cookieHeader {
            cookiesSavedAt = Date()
            AppleIDStore.shared.mergeLiveStoreCookies(cookie)
        }
        let item = StoreDownloadItem(
            url: destination,
            md5: nil,
            artworkURL: nil,
            sinfs: asset.sinfs.enumerated().map { StoreSinf(id: Int64($0.offset), data: $0.element) },
            metadata: asset.metadata
        )
        return (destination, item)
    }

    /// Official version IDs from DownloadDispatch (not volumeStore), with ticket labels.
    static func resolveVersionHistory(
        adamId: Int,
        account: StorefrontSession,
        limit: Int = 40
    ) async throws -> [DecryptVersion] {
        var session = account.normalizedForCommerce()
        guard session.isUsable else {
            throw IPadnToolError.message("Sign in under Account first.")
        }
        let offer = try await fetchAsset(
            appID: String(adamId),
            versionID: nil,
            account: &session,
            useCache: true,
            fallback: false,
            refreshed: false,
            purchased: false,
            allowLicenseAcquisition: false
        )
        var ids = offer.externalVersionIDs
        if ids.isEmpty, !offer.externalVersionId.isEmpty {
            ids = [offer.externalVersionId]
        }
        let newestFirst = Array(ids.reversed())
        let slice = Array(newestFirst.prefix(max(1, limit)))
        let latest = offer.externalVersionId.isEmpty ? slice.first : offer.externalVersionId

        var resolved: [DecryptVersion] = []
        resolved.reserveCapacity(slice.count)
        // Serial tickets — each call may refresh cookies on the shared session.
        for ext in slice {
            if ext == offer.externalVersionId, !offer.version.isEmpty {
                resolved.append(DecryptVersion(
                    v: offer.version,
                    current: true,
                    minOS: offer.minimumOS,
                    externalId: ext
                ))
                continue
            }
            do {
                let ticket = try await versionTicketDetails(
                    appID: String(adamId),
                    versionID: ext,
                    account: &session,
                    useCache: true
                )
                let label = ticket.displayVersion.isEmpty ? ext : ticket.displayVersion
                resolved.append(DecryptVersion(
                    v: label,
                    current: ext == latest,
                    minOS: ticket.minimumOS,
                    externalId: ext
                ))
            } catch {
                resolved.append(DecryptVersion(v: ext, current: ext == latest, minOS: nil, externalId: ext))
            }
        }

        if resolved.isEmpty, !offer.version.isEmpty {
            return [
                DecryptVersion(
                    v: offer.version,
                    current: true,
                    minOS: offer.minimumOS,
                    externalId: latest
                )
            ]
        }
        return resolved
    }

    // MARK: - DownloadDispatch

    private static func fetchAsset(
        appID: String,
        versionID: String?,
        account: inout StorefrontSession,
        useCache: Bool,
        fallback: Bool,
        refreshed: Bool,
        purchased: Bool,
        allowLicenseAcquisition: Bool
    ) async throws -> IPadnDownloadAsset {
        let guid = resolvedGUID(account)
        let root = fallback
            ? "https://downloaddispatch.itunes.apple.com/up/backgroundUpdateProduct"
            : "https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download"
        var payload: [String: Any] = [
            "guid": guid,
            "salableAdamId": NSNumber(value: UInt64(appID) ?? 0),
            "serialNumber": "0"
        ]
        if let versionID {
            payload[fallback ? "appExtVrsId" : "externalVersionId"] = versionID
        }
        if !fallback {
            guard !account.dsid.isEmpty else {
                throw IPadnToolError.message("Apple login expired — sign in again under Account.")
            }
            let kbsync = try await IPadnWASMSPSigner.shared.kbsync(
                guid: guid,
                dsid: account.dsid,
                useCache: useCache
            )
            payload["kbsync"] = kbsync
        }
        let url = URL(string: root + "?guid=" + guid)!
        let (raw, _) = try await storePlist(
            url,
            body: try IPadnHTTPClient.encodePlist(payload),
            headers: authHeaders(account),
            guid: guid,
            useCache: useCache,
            account: &account
        )
        let failure = ipadnPlistString(raw["failureType"])
        if requiresReauthentication(raw) || ["2034", "2042"].contains(failure) {
            if refreshed {
                throw IPadnToolError.message("Apple login expired — sign in again under Account.")
            }
            account = try await silentRefresh(account)
            return try await fetchAsset(
                appID: appID,
                versionID: versionID,
                account: &account,
                useCache: useCache,
                fallback: fallback,
                refreshed: true,
                purchased: purchased,
                allowLicenseAcquisition: allowLicenseAcquisition
            )
        }
        if shouldAcquireLicense(failure: failure, purchased: purchased, allowLicenseAcquisition: allowLicenseAcquisition) {
            try await acquireFreeApp(appID, account: &account, useCache: useCache)
            return try await fetchAsset(
                appID: appID,
                versionID: versionID,
                account: &account,
                useCache: useCache,
                fallback: fallback,
                refreshed: refreshed,
                purchased: true,
                allowLicenseAcquisition: allowLicenseAcquisition
            )
        }
        if failure == "9610" && !allowLicenseAcquisition {
            throw IPadnToolError.message("This account doesn’t have a license for this app.")
        }
        if let error = IPadnHTTPClient.appleFailure(raw) { throw error }
        guard let song = (raw["songList"] as? [[String: Any]])?.first else {
            if !fallback {
                return try await fetchAsset(
                    appID: appID,
                    versionID: versionID,
                    account: &account,
                    useCache: useCache,
                    fallback: true,
                    refreshed: refreshed,
                    purchased: purchased,
                    allowLicenseAcquisition: allowLicenseAcquisition
                )
            }
            throw IPadnToolError.message(noOfferMessage)
        }
        guard let cdn = URL(string: ipadnPlistString(song["URL"])), cdn.scheme == "https",
              var metadata = song["metadata"] as? [String: Any] else {
            throw IPadnToolError.message("Couldn’t download right now — try again.")
        }
        metadata = purchaseMetadata(metadata, account: account, appID: appID, purchaseDate: song["purchaseDate"] as? Date ?? Date())
        let externalID = ipadnPlistString(metadata["softwareVersionExternalIdentifier"])
        if let requested = versionID, !externalID.isEmpty, externalID != requested {
            throw IPadnToolError.message("That version isn’t available to download — pick another build.")
        }
        let assetInfo = song["asset-info"] as? [String: Any]
        let rawShort = ipadnPlistString(metadata["bundleShortVersionString"])
        let rawBuild = ipadnPlistString(metadata["bundleVersion"])
        let version = reconcileTicketVersion(shortVersion: rawShort, buildVersion: rawBuild)
        let sinfs = try mobileSinfs(song["sinfs"] as? [[String: Any]] ?? [])
        let externalIDs = (metadata["softwareVersionExternalIdentifiers"] as? [Any] ?? [])
            .map { ipadnPlistString($0) }
            .filter { !$0.isEmpty }
        return IPadnDownloadAsset(
            adamId: ipadnPlistString(song["songId"]).isEmpty ? appID : ipadnPlistString(song["songId"]),
            name: ipadnPlistString(metadata["bundleDisplayName"]),
            bundleID: ipadnPlistString(metadata["softwareVersionBundleId"]),
            version: version.isEmpty ? rawShort : version,
            externalVersionId: externalID,
            externalVersionIDs: externalIDs,
            url: cdn,
            sinfs: sinfs,
            metadata: metadata,
            fileSize: (assetInfo?["file-size"] as? NSNumber)?.int64Value ?? 0,
            minimumOS: {
                let v = ipadnPlistString(metadata["minimumOSVersion"]).isEmpty
                    ? ipadnPlistString(metadata["minimumOsVersion"])
                    : ipadnPlistString(metadata["minimumOSVersion"])
                return v.isEmpty ? nil : v
            }()
        )
    }

    /// Ticket metadata for one version — never acquires a license.
    private static func versionTicketDetails(
        appID: String,
        versionID: String,
        account: inout StorefrontSession,
        useCache: Bool
    ) async throws -> IPadnVersionTicket {
        guard !account.dsid.isEmpty else {
            throw IPadnToolError.message("Apple login expired — sign in again under Account.")
        }
        guard UInt64(appID).map({ $0 > 0 }) == true,
              UInt64(versionID).map({ $0 > 0 }) == true else {
            throw IPadnToolError.message("Version ID must be numeric.")
        }
        let guid = resolvedGUID(account)
        let kbsync = try await IPadnWASMSPSigner.shared.kbsync(
            guid: guid,
            dsid: account.dsid,
            useCache: useCache
        )
        let payload: [String: Any] = [
            "guid": guid,
            "salableAdamId": NSNumber(value: UInt64(appID) ?? 0),
            "serialNumber": "0",
            "externalVersionId": versionID,
            "kbsync": kbsync
        ]
        let url = URL(string: "https://downloaddispatch.itunes.apple.com/WebObjects/DownloadDispatch.woa/wa/ent/download?guid=" + guid)!
        let (raw, _) = try await storePlist(
            url,
            body: try IPadnHTTPClient.encodePlist(payload),
            headers: authHeaders(account),
            guid: guid,
            useCache: useCache,
            account: &account
        )
        let failure = ipadnPlistString(raw["failureType"])
        if requiresReauthentication(raw) || ["2034", "2042"].contains(failure) {
            throw IPadnToolError.message("Apple login expired — sign in again under Account.")
        }
        if failure == "9610" {
            throw IPadnToolError.message("This account doesn’t have a license for this app.")
        }
        if let error = IPadnHTTPClient.appleFailure(raw) { throw error }
        guard let song = (raw["songList"] as? [[String: Any]])?.first,
              let metadata = song["metadata"] as? [String: Any],
              [versionID, ""].contains(ipadnPlistString(metadata["softwareVersionExternalIdentifier"])) else {
            throw IPadnToolError.message("Apple did not return that version’s info.")
        }
        let rawShort = ipadnPlistString(metadata["bundleShortVersionString"])
        let rawBuild = ipadnPlistString(metadata["bundleVersion"])
        let display = reconcileTicketVersion(shortVersion: rawShort, buildVersion: rawBuild)
        let assetInfo = song["asset-info"] as? [String: Any]
        let minOS = {
            let v = ipadnPlistString(metadata["minimumOSVersion"]).isEmpty
                ? ipadnPlistString(metadata["minimumOsVersion"])
                : ipadnPlistString(metadata["minimumOSVersion"])
            return v.isEmpty ? nil : v
        }()
        return IPadnVersionTicket(
            displayVersion: display,
            rawShortVersion: rawShort,
            buildVersion: rawBuild,
            fileSize: (assetInfo?["file-size"] as? NSNumber)?.int64Value.flatMap { $0 > 0 ? $0 : nil },
            minimumOS: minOS,
            externalVersionId: versionID
        )
    }

    private static func acquireFreeApp(
        _ id: String,
        account: inout StorefrontSession,
        arcade: Bool = false,
        useCache: Bool,
        refreshed: Bool = false
    ) async throws {
        let guid = resolvedGUID(account)
        let payload: [String: Any] = [
            "appExtVrsId": "0",
            "buyWithoutAuthorization": "true",
            "guid": guid,
            "hasAskedToFulfillPreorder": "true",
            "hasDoneAgeCheck": "true",
            "price": "0",
            "pricingParameters": arcade ? "GAME" : "STDQ",
            "productType": "C",
            "salableAdamId": id
        ]
        var headers = authHeaders(account)
        headers["Content-Type"] = "application/x-apple-plist"
        let (raw, _) = try await storePlist(
            URL(string: "https://buy.itunes.apple.com/WebObjects/MZFinance.woa/wa/buyProduct")!,
            body: try IPadnHTTPClient.encodePlist(payload),
            headers: headers,
            guid: guid,
            useCache: useCache,
            account: &account
        )
        let failure = ipadnPlistString(raw["failureType"])
        if requiresReauthentication(raw) || ["2034", "2042"].contains(failure)
            || ipadnPlistString(raw["customerMessage"]) == "MZFinance.BadLogin.Configurator_message" {
            if refreshed {
                throw IPadnToolError.message("Allow this sign-in on a trusted device, then enter the 6-digit code under Account.")
            }
            account = try await silentRefresh(account)
            return try await acquireFreeApp(id, account: &account, arcade: arcade, useCache: useCache, refreshed: true)
        }
        if failure == "5002" { return }
        if ipadnPlistString(raw["customerMessage"]) == "Subscription Required" {
            throw IPadnToolError.message("This app needs an Apple Arcade subscription on this Apple ID.")
        }
        if failure == "2059" && !arcade {
            return try await acquireFreeApp(id, account: &account, arcade: true, useCache: useCache, refreshed: refreshed)
        }
        if let error = IPadnHTTPClient.appleFailure(raw) { throw error }
        guard raw["jingleDocType"] != nil else {
            throw IPadnToolError.message("Couldn’t get a free license — get the app once in the App Store, then retry.")
        }
    }

    /// Quiet remint via saved password / PET (iPadn login only).
    private static func silentRefresh(_ account: StorefrontSession) async throws -> StorefrontSession {
        let refreshed = try await AppleIDStore.shared.ensureStorefrontSession(forceRefresh: true)
        guard refreshed.isUsable else {
            throw IPadnToolError.message("Apple login expired — sign in again under Account.")
        }
        liveCookies[account.dsid] = nil
        if let cookie = refreshed.cookieHeader, !cookie.isEmpty {
            liveCookies[refreshed.dsid] = cookie
        }
        return refreshed.normalizedForCommerce()
    }

    // MARK: - Transport + cookies

    private static func storePlist(
        _ url: URL,
        body: Data,
        headers: [String: String],
        guid: String,
        useCache: Bool,
        account: inout StorefrontSession
    ) async throws -> ([String: Any], HTTPURLResponse) {
        let signer = IPadnWASMSPSigner.shared
        let result = try await IPadnAppleAuthentication.withStoreProof(
            endpoint: url,
            baseHeaders: headers,
            loadProof: {
                try await signer.storeProofHeaders(guid: guid, useCache: useCache)
            },
            provisionProof: { challenge in
                try await signer.provisionStoreProof(challenge: challenge, guid: guid, useCache: useCache)
            },
            resetProof: {
                signer.resetStoreProof(guid: guid)
            },
            execute: { headerProvider in
                let initial = try await headerProvider(url)
                return try await IPadnHTTPClient.shared.plist(
                    url,
                    body: body,
                    headers: initial,
                    refreshHeaders: headerProvider
                )
            }
        )
        absorbCookies(from: result.1, account: &account)
        return result
    }

    private static func authHeaders(_ account: StorefrontSession) -> [String: String] {
        var headers: [String: String] = [
            "Content-Type": "application/x-www-form-urlencoded",
            "X-Dsid": account.dsid,
            "iCloud-DSID": account.dsid
        ]
        let cookie = liveCookies[account.dsid] ?? account.cookieHeader
        if let cookie, !cookie.isEmpty {
            headers["Cookie"] = cookie
        }
        if !account.storeFront.isEmpty {
            headers["X-Apple-Store-Front"] = account.storeFront
        }
        if !account.passwordToken.isEmpty {
            headers["X-Token"] = account.passwordToken
        }
        return headers
    }

    /// Purchase DAAP headers — same Cookie / GUID / token as download.
    static func purchaseHeaders(_ account: StorefrontSession) -> [String: String] {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let iso = ISO8601DateFormatter()
        var headers = authHeaders(account)
        headers["Accept"] = "*/*"
        headers["Accept-Language"] = "en-us"
        headers["Client-Cloud-DAAP-Request-Reason"] = "5"
        headers["Client-Cloud-Purchase-Daap-Version"] = "1.1/Configurator-2.0"
        headers["Client-DAAP-Version"] = "3.12"
        headers["Date"] = date.string(from: now)
        headers["X-Apple-I-Client-Time"] = iso.string(from: now)
        headers["X-Apple-I-Locale"] = "en_US"
        headers["X-Apple-I-TimeZone"] = "Local"
        headers["X-Apple-TZ"] = String(TimeZone.current.secondsFromGMT(for: now) / 60)
        headers["X-Guid"] = resolvedGUID(account)
        return headers
    }

    static func resolvedGUID(_ account: StorefrontSession) -> String {
        let fromAccount = account.normalizedForCommerce().guid
        if fromAccount.count == 12, fromAccount.allSatisfy({ $0.isASCII && $0.isHexDigit }) {
            return fromAccount.uppercased()
        }
        return IPadnStoreLogin.storeGUID()
    }

    static func absorbCookies(from response: HTTPURLResponse, account: inout StorefrontSession) {
        guard let url = response.url else { return }
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            fields[String(describing: key)] = String(describing: value)
        }
        let received = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        guard !received.isEmpty else { return }
        let current = liveCookies[account.dsid] ?? account.cookieHeader ?? ""
        let merged = mergedCookie(current, with: received)
        guard merged != current else { return }
        liveCookies[account.dsid] = merged
        account.cookieHeader = merged
        if Date().timeIntervalSince(cookiesSavedAt) > 60 {
            cookiesSavedAt = Date()
            AppleIDStore.shared.mergeLiveStoreCookies(merged)
        }
    }

    /// Upstream AppleService.mergedCookie — new values replace by name; expired/empty drop.
    nonisolated static func mergedCookie(_ existing: String, with received: [HTTPCookie], now: Date = Date()) -> String {
        var names: [String] = []
        var values: [String: String] = [:]
        for part in existing.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else { continue }
            let name = String(pair[..<equals])
            if values[name] == nil { names.append(name) }
            values[name] = String(pair[pair.index(after: equals)...])
        }
        for cookie in received {
            if cookie.value.isEmpty || (cookie.expiresDate.map { $0 <= now } ?? false) {
                values[cookie.name] = nil
                names.removeAll { $0 == cookie.name }
            } else {
                if values[cookie.name] == nil { names.append(cookie.name) }
                values[cookie.name] = cookie.value
            }
        }
        return names.compactMap { name in values[name].map { "\(name)=\($0)" } }.joined(separator: "; ")
    }

    private static func downloadFile(
        from url: URL,
        to destination: URL,
        onProgress: ((String) -> Void)?
    ) async throws {
        var req = URLRequest(url: url)
        req.setValue(IPadnHTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw IPadnToolError.message("IPA download failed (HTTP \(status)).")
        }
        let expected = (response as? HTTPURLResponse)
            .flatMap { $0.value(forHTTPHeaderField: "Content-Length") }
            .flatMap(Int64.init) ?? 0
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 {
                    let pct = Int((Double(written) / Double(expected)) * 100)
                    onProgress?("Downloading… \(pct)% (\(Self.formatBytes(written)) / \(Self.formatBytes(expected)))")
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
        }
        guard written > 0 else {
            throw IPadnToolError.message("IPA download produced an empty file.")
        }
    }

    // MARK: - Helpers

    private static func requiresReauthentication(_ raw: [String: Any]) -> Bool {
        let message = ipadnPlistString(raw["customerMessage"])
        if message == "MZFinance.BadLogin.Configurator_message" { return true }
        if message.localizedCaseInsensitiveContains("sign in") { return true }
        return false
    }

    private static func shouldAcquireLicense(
        failure: String,
        purchased: Bool,
        allowLicenseAcquisition: Bool
    ) -> Bool {
        failure == "9610" && !purchased && allowLicenseAcquisition
    }

    private static func mobileSinfs(_ records: [[String: Any]]) throws -> [Data] {
        func bytes(_ value: Any?) -> Data? {
            if let value = value as? Data { return value.isEmpty ? nil : value }
            if let encoded = value as? String,
               let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
               !data.isEmpty {
                return data
            }
            return nil
        }
        guard !records.isEmpty else {
            throw IPadnToolError.message("This account has no download license for that app.")
        }
        var result: [Data] = []
        result.reserveCapacity(records.count)
        for record in records {
            guard let data = bytes(record["sinf"]) else {
                throw IPadnToolError.message("Incomplete FairPlay license set — retry the download.")
            }
            result.append(data)
        }
        return result
    }

    private static func purchaseMetadata(
        _ source: [String: Any],
        account: StorefrontSession,
        appID: String,
        purchaseDate: Date
    ) -> [String: Any] {
        var metadata = source
        let dsidNum = UInt64(account.dsid).map(NSNumber.init(value:)) ?? NSNumber(value: 0)
        var info: [String: Any] = [
            "AppleID": account.email,
            "UserName": account.email,
            "DSPersonID": dsidNum,
            "DownloaderID": dsidNum,
            "PurchaserID": dsidNum,
            "FamilyID": NSNumber(value: 0)
        ]
        if !account.storeFront.isEmpty {
            info["AccountStoreFront"] = account.storeFront
        }
        let formatter = ISO8601DateFormatter()
        metadata["com.apple.iTunesStore.downloadInfo"] = [
            "accountInfo": info,
            "purchaseDate": formatter.string(from: purchaseDate)
        ]
        metadata["appleId"] = account.email
        metadata["apple-id"] = account.email
        metadata["userName"] = account.email
        if dsidNum.uint64Value > 0 {
            metadata["DSPersonID"] = dsidNum
            metadata["downloader-id"] = dsidNum
            metadata["purchaser-id"] = dsidNum
        }
        if metadata["itemId"] == nil, let idNum = UInt64(appID) {
            metadata["itemId"] = NSNumber(value: idNum)
        }
        if metadata["purchaseDate"] == nil {
            metadata["purchaseDate"] = purchaseDate
        }
        return metadata
    }

    private static func reconcileTicketVersion(shortVersion: String, buildVersion: String) -> String {
        let short = shortVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let build = buildVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        if !short.isEmpty { return short }
        return build
    }

    private static func formatBytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: n)
    }
}
