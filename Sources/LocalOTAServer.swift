//
//  LocalOTAServer.swift
//  On-device AirShare install the way full AirShare does it: a Vapor HTTPS server on
//  the device (NIOSSL) serving an itms-services manifest + the signed IPA.
//
//  Any domain works: point `*.<domain>` at 127.0.0.1 and let certs.yml issue
//  a Let's Encrypt wildcard for it. airshare.lol is just the default whose cert
//  ships in the bundle. The cert is one WE issue: .github/workflows/certs.yml runs certbot (DNS-01) and
//  publishes server.crt / server.pem / pack.json on the `certs` branch. A copy
//  ships in the bundle (Build.yml bakes the latest one in) and the app refreshes
//  from the branch before expiry. iOS trusts the chain, connects to
//  loopback as ota.airshare.lol, installs — no network needed for the install itself.
//

import Foundation
import Vapor
import NIOSSL

// MARK: - Config

nonisolated enum ServerConfig {
    /// Bring-your-own domain. Requirements: `*.<domain>` (and ideally `<domain>`) have an
    /// A record → 127.0.0.1, and certs.yml has issued a wildcard cert for it.
    /// Default is airshare.lol, whose cert ships in the bundle.
    static let defaultDomain = "airshare.lol"
    static var certDomain: String {
        let v = UserDefaults.standard.string(forKey: "uzd_cert_domain") ?? ""
        return (v.isEmpty || v.contains("zefv.dev")) ? defaultDomain : v   // legacy zefv.dev → airshare.lol
    }
    static func setCertDomain(_ d: String) { UserDefaults.standard.set(d, forKey: "uzd_cert_domain") }

    /// SNI + manifest host. Must be under `certDomain` and covered by the cert's SANs.
    /// Default `ota.airshare.lol`: on Cloudflare, `*.airshare.lol` points at the VPS (user
    /// subdomains), so the AirShare host is a dedicated label with its own A record → 127.0.0.1.
    /// `ota.airshare.lol` is one label under the wildcard, so the *.airshare.lol cert covers it.
    static let defaultInstallHost = "ota.airshare.lol"
    static var installHost: String {
        let v = UserDefaults.standard.string(forKey: "uzd_install_host") ?? ""
        if !v.isEmpty && !v.contains("zefv.dev") { return v }
        return certDomain == defaultDomain ? defaultInstallHost : "ota.\(certDomain)"
    }
    static func setInstallHost(_ h: String) { UserDefaults.standard.set(h, forKey: "uzd_install_host") }

    /// Bundled Let's Encrypt pair from AirShare (Sources/Resources):
    ///   server.crt ← fullchain.pem   server.pem ← privkey.pem
    static let certResource = "server"

    /// AirShare TLS source:
    ///   "public" — the airshare.lol wildcard cert, issued and auto-renewed on the VPS
    ///              (certbot + Cloudflare DNS-01) and pulled from airshare.lol.
    ///   "custom" — the user's own cert + key for their own domain (imported PEM).
    ///   "local"  — our own root CA (no DNS, needs the root profile installed).
    static var certMode: String { UserDefaults.standard.string(forKey: "uzd_cert_mode") ?? "public" }
    static func setCertMode(_ m: String) { UserDefaults.standard.set(m, forKey: "uzd_cert_mode") }
    static let certModes = ["public", "custom", "local"]

    /// Where the "public" cert comes from. The VPS serves the live wildcard pair
    /// (fullchain + key, JSON) behind a shared token; certbot renews it there.
    static let defaultCertSourceURL = "https://airshare.lol/ota/cert.php"
    static var certSourceURL: String {
        let v = UserDefaults.standard.string(forKey: "uzd_cert_source_url") ?? ""
        return (v.isEmpty || v.contains("zefv.dev")) ? defaultCertSourceURL : v
    }
    static func setCertSourceURL(_ u: String) { UserDefaults.standard.set(u, forKey: "uzd_cert_source_url") }
    static let defaultCertSourceToken = "airshare-ota-2026"
    static var certSourceToken: String {
        let v = UserDefaults.standard.string(forKey: "uzd_cert_source_token") ?? ""
        return (v.isEmpty || v == "zefv-ota-2026") ? defaultCertSourceToken : v
    }
    static func setCertSourceToken(_ t: String) { UserDefaults.standard.set(t, forKey: "uzd_cert_source_token") }

    /// Hand-rolled cert pipeline: .github/workflows/certs.yml runs certbot
    /// (DNS-01) for *.airshare.lol and commits server.crt / server.pem / pack.json
    /// to the `certs` branch. The app reads them through the GitHub Contents
    /// API with its own token, so private repos work too.
    static var certRepoOwner: String { UserDefaults.standard.string(forKey: "uzd_cert_owner") ?? "mrzefv" }
    static var certRepoName:  String { UserDefaults.standard.string(forKey: "uzd_cert_repo")  ?? "unzip-drop" }
    static var certBranch:    String { UserDefaults.standard.string(forKey: "uzd_cert_branch") ?? "certs" }
    static func setCertSource(owner: String, repo: String, branch: String) {
        UserDefaults.standard.set(owner, forKey: "uzd_cert_owner")
        UserDefaults.standard.set(repo,  forKey: "uzd_cert_repo")
        UserDefaults.standard.set(branch, forKey: "uzd_cert_branch")
    }
    static let certWorkflowPath = ".github/workflows/certs.yml"

    // ACME certificate authority + optional ZeroSSL EAB credentials.
    static var certCA: String { UserDefaults.standard.string(forKey: "uzd_cert_ca") ?? "letsencrypt" }
    static func setCertCA(_ v: String) { UserDefaults.standard.set(v, forKey: "uzd_cert_ca") }
    static var eabKID: String { UserDefaults.standard.string(forKey: "uzd_eab_kid") ?? "" }
    static var eabHMAC: String { UserDefaults.standard.string(forKey: "uzd_eab_hmac") ?? "" }
    static func setEAB(kid: String, hmac: String) {
        UserDefaults.standard.set(kid, forKey: "uzd_eab_kid")
        UserDefaults.standard.set(hmac, forKey: "uzd_eab_hmac")
    }

    /// Legacy fallback (AirShare's endpoint), tried only if the GitHub source fails.
    static let refreshURL = URL(string: "https://mrzefv.com/certs/pack.json")!
    static let refreshBufferDays = 21
}

// MARK: - Cert (bundled + refreshed)

nonisolated enum ZefvCert {
    static var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var cachedCrt: URL { docs.appendingPathComponent("refreshed-server.crt") }
    static var cachedKey: URL { docs.appendingPathComponent("refreshed-server.pem") }
    static var metaURL: URL { docs.appendingPathComponent("refreshed-cert.json") }

    static var bundledCrt: URL? { Bundle.main.url(forResource: ServerConfig.certResource, withExtension: "crt") }
    static var bundledKey: URL? { Bundle.main.url(forResource: ServerConfig.certResource, withExtension: "pem") }

    static var hasCached: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: cachedCrt.path) && fm.fileExists(atPath: cachedKey.path)
    }

    // Bring-your-own cert (mode "custom"): the user's fullchain + private key.
    static var customCrt: URL { docs.appendingPathComponent("custom-server.crt") }
    static var customKey: URL { docs.appendingPathComponent("custom-server.pem") }
    static var customMetaURL: URL { docs.appendingPathComponent("custom-cert.json") }
    static var hasCustom: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: customCrt.path) && fm.fileExists(atPath: customKey.path)
    }
    static var customSANs: [String] {
        guard let d = try? Data(contentsOf: customCrt) else { return [] }
        return sans(fromPEM: d)
    }
    static var customNotAfter: Date? {
        guard let d = try? Data(contentsOf: customCrt) else { return nil }
        return notAfter(fromPEM: d)
    }

    /// Pair in effect: custom mode → imported pair; otherwise refreshed copy wins over the bundle.
    static var crtURL: URL? {
        if ServerConfig.certMode == "custom" { return hasCustom ? customCrt : nil }
        return hasCached ? cachedCrt : bundledCrt
    }
    static var keyURL: URL? {
        if ServerConfig.certMode == "custom" { return hasCustom ? customKey : nil }
        return hasCached ? cachedKey : bundledKey
    }
    static var isAvailable: Bool { crtURL != nil && keyURL != nil }

    /// SANs of the cert in effect (bundled or refreshed).
    static var effectiveSANs: [String] {
        guard let u = crtURL, let d = try? Data(contentsOf: u) else { return [] }
        return sans(fromPEM: d)
    }

    /// Does the current cert cover `host`? Exact match or one-label wildcard.
    static func covers(_ host: String, sans: [String]? = nil) -> Bool {
        let h = host.lowercased()
        for san in (sans ?? effectiveSANs).map({ $0.lowercased() }) {
            if san == h { return true }
            if san.hasPrefix("*."), h.hasSuffix(String(san.dropFirst(1))),
               !h.dropLast(san.count - 1).contains(".") { return true }
        }
        return false
    }

    /// Does `host` resolve to loopback? (A record via DNS-over-HTTPS.)
    static func resolvesToLoopback(_ host: String) async -> Bool? {
        for q in ["https://cloudflare-dns.com/dns-query?name=\(host)&type=A",
                  "https://dns.google/resolve?name=\(host)&type=A"] {
            guard let u = URL(string: q) else { continue }
            var req = URLRequest(url: u); req.setValue("application/dns-json", forHTTPHeaderField: "accept")
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (d, _) = try? await URLSession.shared.data(for: req),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let ips = ((j["Answer"] as? [[String: Any]]) ?? []).compactMap { $0["data"] as? String }
            if ips.isEmpty { continue }
            return ips.contains { $0.hasPrefix("127.") }
        }
        return nil
    }

    struct Meta: Codable, Sendable { var notAfter: Date?; var fetchedAt: Date }

    static var meta: Meta? {
        guard let d = try? Data(contentsOf: metaURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Meta.self, from: d)
    }

    /// Expiry of whichever cert is in effect (bundled or refreshed).
    static var effectiveNotAfter: Date? {
        if ServerConfig.certMode == "custom" { return customNotAfter }
        if hasCached, let m = meta?.notAfter { return m }
        if let u = crtURL, let d = try? Data(contentsOf: u) { return notAfter(fromPEM: d) }
        return nil
    }

    static var needsRefresh: Bool {
        guard ServerConfig.certMode == "public" else { return false }
        guard let exp = effectiveNotAfter else { return true }
        return exp.timeIntervalSinceNow < TimeInterval(ServerConfig.refreshBufferDays * 86400)
    }

    enum CertError: LocalizedError {
        case unavailable, badPack(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: return "server.crt / server.pem aren't in the bundle and no refreshed copy exists."
            case .badPack(let m): return "Cert refresh (mrzefv.com/certs/pack.json): \(m)"
            }
        }
    }

    private struct Manifest: Decodable {
        let bundle: String
        let key: String?
        let expires: String?
    }

    /// Pull a fresh chain + key. Primary: the VPS endpoint (certbot + Cloudflare
    /// auto-renews there, so this is always the live wildcard pair).
    /// Fallback: AirShare's pack.json. The `token` argument is kept for call-site
    /// compatibility; the VPS uses its own shared token (ServerConfig.certSourceToken).
    static func fetch(token: String? = nil) async throws -> Meta {
        try await fetchFromVPS()
    }

    /// VPS JSON: { "cert": "<fullchain PEM>", "key": "<privkey PEM>", "not_after": "ISO8601", "sans": [...] }
    private struct VPSPack: Decodable {
        let cert: String
        let key: String
        let not_after: String?
        let sans: [String]?
    }

    static func fetchFromVPS() async throws -> Meta {
        guard let url = URL(string: ServerConfig.certSourceURL) else { throw CertError.badPack("bad cert source URL") }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 20
        req.setValue(ServerConfig.certSourceToken, forHTTPHeaderField: "X-OTA-Token")
        req.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code < 400, !data.isEmpty else {
            throw CertError.badPack("\(url.host ?? "VPS") → HTTP \(code). Try again in a moment.")
        }
        let pack: VPSPack
        do { pack = try JSONDecoder().decode(VPSPack.self, from: data) } catch { throw CertError.badPack("VPS returned an unreadable cert pack") }
        guard pack.cert.contains("BEGIN CERTIFICATE"), pack.key.contains("PRIVATE KEY") else {
            throw CertError.badPack("VPS pack is missing the cert or key")
        }
        return try store(chain: Data(pack.cert.utf8), key: Data(pack.key.utf8), expires: pack.not_after)
    }

    // MARK: Bring-your-own cert (mode "custom")

    /// Import the user's own TLS pair from any mix of files: a fullchain/cert PEM,
    /// a key PEM, or one combined PEM. Validates with NIOSSL before saving.
    static func importCustom(files: [URL]) throws {
        var certPEM = "", keyPEM = ""
        for f in files {
            let scoped = f.startAccessingSecurityScopedResource()
            defer { if scoped { f.stopAccessingSecurityScopedResource() } }
            guard let text = try? String(contentsOf: f) else { continue }
            certPEM += pemBlocks(in: text, containing: "CERTIFICATE").joined(separator: "\n")
            if !certPEM.isEmpty { certPEM += "\n" }
            let keys = pemBlocks(in: text, containing: "PRIVATE KEY")
            if let k = keys.first { keyPEM = k + "\n" }
        }
        guard !certPEM.isEmpty else { throw CertError.badPack("No certificate found — pick your fullchain.pem / .crt (PEM).") }
        guard !keyPEM.isEmpty  else { throw CertError.badPack("No private key found — pick your privkey.pem / .key (PEM, unencrypted).") }
        _ = try NIOSSLCertificate.fromPEMBytes(Array(certPEM.utf8))
        _ = try NIOSSLPrivateKey(bytes: Array(keyPEM.utf8), format: .pem)
        try Data(certPEM.utf8).write(to: customCrt, options: .atomic)
        try Data(keyPEM.utf8).write(to: customKey, options: .atomic)
        let meta = Meta(notAfter: notAfter(fromPEM: Data(certPEM.utf8)), fetchedAt: Date())
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(meta).write(to: customMetaURL)
    }

    static func clearCustom() {
        for u in [customCrt, customKey, customMetaURL] { try? FileManager.default.removeItem(at: u) }
    }

    /// All `-----BEGIN <X>-----` … `-----END <X>-----` blocks whose label contains `label`.
    private static func pemBlocks(in text: String, containing label: String) -> [String] {
        var out: [String] = []
        var search = text.startIndex
        while let b = text.range(of: "-----BEGIN ", range: search..<text.endIndex) {
            guard let hdrEnd = text.range(of: "-----", range: b.upperBound..<text.endIndex) else { break }
            let kind = String(text[b.upperBound..<hdrEnd.lowerBound])
            let endMarker = "-----END \(kind)-----"
            guard let e = text.range(of: endMarker, range: hdrEnd.upperBound..<text.endIndex) else { break }
            if kind.contains(label) { out.append(String(text[b.lowerBound..<e.upperBound])) }
            search = e.upperBound
        }
        return out
    }

    static func fetchFromGitHub(token: String?) async throws -> Meta {
        let o = ServerConfig.certRepoOwner, r = ServerConfig.certRepoName, b = ServerConfig.certBranch
        func raw(_ path: String) async throws -> Data {
            var c = URLComponents(string: "https://api.github.com/repos/\(o)/\(r)/contents/\(path)")!
            c.queryItems = [URLQueryItem(name: "ref", value: b)]
            var req = URLRequest(url: c.url!)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
            req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            req.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
            if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            let (d, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 400, !d.isEmpty else {
                throw CertError.badPack("\(o)/\(r)@\(b)/\(path) → HTTP \(code). The cert files aren't on the certs branch yet. If the last run showed VALIDATED, its publish step failed — open the run's 'Write pack.json & publish' step, or tap Renew now to re-issue. Also confirm the token can read this repo.")
            }
            return d
        }
        let packData = try await raw("pack.json")
        let m: Manifest
        do { m = try JSONDecoder().decode(Manifest.self, from: packData) } catch { throw CertError.badPack("unreadable pack.json") }
        guard let keyFile = m.key, !keyFile.isEmpty else { throw CertError.badPack("pack.json has no key entry") }
        let chain = try await raw(m.bundle)
        let key   = try await raw(keyFile)
        return try store(chain: chain, key: key, expires: m.expires)
    }

    static func fetchFromURL(_ url: URL) async throws -> Meta {
        var req = URLRequest(url: url); req.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { throw CertError.badPack("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)") }
        let m: Manifest
        do { m = try JSONDecoder().decode(Manifest.self, from: data) } catch { throw CertError.badPack("unreadable pack.json") }
        guard let keyFile = m.key, !keyFile.isEmpty else { throw CertError.badPack("pack.json has no key entry") }
        let base = url.deletingLastPathComponent()
        func get(_ name: String) async throws -> Data {
            let u = name.hasPrefix("http") ? URL(string: name)! : base.appendingPathComponent(name)
            let (d, r) = try await URLSession.shared.data(from: u)
            guard (r as? HTTPURLResponse)?.statusCode ?? 0 < 400, !d.isEmpty else { throw CertError.badPack("couldn't download \(name)") }
            return d
        }
        return try store(chain: try await get(m.bundle), key: try await get(keyFile), expires: m.expires)
    }

    /// Validate (NIOSSL must parse both, key must match the leaf's SAN set) then cache.
    private static func store(chain: Data, key: Data, expires: String?) throws -> Meta {
        _ = try NIOSSLCertificate.fromPEMBytes(Array(chain))
        _ = try NIOSSLPrivateKey(bytes: Array(key), format: .pem)
        try chain.write(to: cachedCrt, options: .atomic)
        try key.write(to: cachedKey, options: .atomic)
        let exp = expires.flatMap { ISO8601DateFormatter().date(from: $0) } ?? notAfter(fromPEM: chain)
        let meta = Meta(notAfter: exp, fetchedAt: Date())
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(meta).write(to: metaURL)
        return meta
    }

    @discardableResult
    static func refreshIfNeeded(token: String? = nil) async -> Meta? {
        guard needsRefresh else { return meta }
        return try? await fetch(token: token)
    }

    static func clearCache() {
        for u in [cachedCrt, cachedKey, metaURL] { try? FileManager.default.removeItem(at: u) }
    }

    // MARK: notAfter from the leaf cert (minimal DER walk)

    static func notAfter(fromPEM pem: Data) -> Date? {
        guard let s = String(data: pem, encoding: .utf8),
              let a = s.range(of: "-----BEGIN CERTIFICATE-----"),
              let b = s.range(of: "-----END CERTIFICATE-----") else { return nil }
        let b64 = s[a.upperBound..<b.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
        guard let der = Data(base64Encoded: b64) else { return nil }
        return parseNotAfter([UInt8](der))
    }
    private static func parseNotAfter(_ b: [UInt8]) -> Date? {
        var i = 0
        func readTL() -> (tag: UInt8, len: Int, hdr: Int)? {
            guard i + 1 < b.count else { return nil }
            let tag = b[i]; var p = i + 1
            var len = Int(b[p]); p += 1
            if len & 0x80 != 0 {
                let n = len & 0x7F; len = 0
                guard p + n <= b.count else { return nil }
                for _ in 0..<n { len = (len << 8) | Int(b[p]); p += 1 }
            }
            return (tag, len, p - i)
        }
        guard let outer = readTL(), outer.tag == 0x30 else { return nil }; i += outer.hdr
        guard let tbs = readTL(), tbs.tag == 0x30 else { return nil }; i += tbs.hdr
        if let v = readTL(), v.tag == 0xA0 { i += v.hdr + v.len }             // version
        guard let serial = readTL() else { return nil }; i += serial.hdr + serial.len
        guard let sigAlg = readTL() else { return nil }; i += sigAlg.hdr + sigAlg.len
        guard let issuer = readTL() else { return nil }; i += issuer.hdr + issuer.len
        guard let validity = readTL(), validity.tag == 0x30 else { return nil }; i += validity.hdr
        guard let nb = readTL() else { return nil }; i += nb.hdr + nb.len          // notBefore
        guard let na = readTL(), i + na.hdr + na.len <= b.count else { return nil }
        let s = String(decoding: b[(i + na.hdr)..<(i + na.hdr + na.len)], as: UTF8.self)
        let f = DateFormatter(); f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = na.tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return f.date(from: s)
    }
}

extension ZefvCert {
    /// dNSName SANs from the leaf cert: find the SAN extension OID (2.5.29.17) in DER,
    /// then read the [2] IA5String entries of the inner SEQUENCE.
    static func sans(fromPEM pem: Data) -> [String] {
        guard let s = String(data: pem, encoding: .utf8),
              let a = s.range(of: "-----BEGIN CERTIFICATE-----"),
              let b = s.range(of: "-----END CERTIFICATE-----") else { return [] }
        let b64 = s[a.upperBound..<b.lowerBound].components(separatedBy: .whitespacesAndNewlines).joined()
        guard let der = Data(base64Encoded: b64) else { return [] }
        let x = [UInt8](der)
        let oid: [UInt8] = [0x06, 0x03, 0x55, 0x1D, 0x11]
        guard x.count > oid.count + 4 else { return [] }
        var i = 0
        while i + oid.count < x.count {
            if Array(x[i..<i+oid.count]) == oid { break }
            i += 1
        }
        guard i + oid.count < x.count else { return [] }
        var p = i + oid.count
        func len(_ at: inout Int) -> Int? {
            guard at < x.count else { return nil }
            var l = Int(x[at]); at += 1
            if l & 0x80 != 0 { let n = l & 0x7F; l = 0; guard at + n <= x.count else { return nil }; for _ in 0..<n { l = (l << 8) | Int(x[at]); at += 1 } }
            return l
        }
        if p < x.count, x[p] == 0x01 { p += 3 }                  // optional critical BOOLEAN
        guard p < x.count, x[p] == 0x04 else { return [] }        // OCTET STRING
        p += 1; guard let _ = len(&p) else { return [] }
        guard p < x.count, x[p] == 0x30 else { return [] }        // SEQUENCE
        p += 1; guard let seqLen = len(&p) else { return [] }
        let end = min(x.count, p + seqLen)
        var out: [String] = []
        while p < end {
            let tag = x[p]; p += 1
            guard let l = len(&p), p + l <= end else { break }
            if tag == 0x82, let str = String(bytes: x[p..<p+l], encoding: .ascii) { out.append(str) }
            p += l
        }
        return out
    }
}

// MARK: - One-tap link-up (phone only: sign in to GitHub, link a repo, done)

nonisolated enum CertSourceLinker {
    struct Report: Sendable {
        var repoOK = false
        var installedFiles: [String] = []
        var branchCreated = false
        var notes: [String] = []
    }

    private static func gh(_ path: String, token: String, method: String = "GET", body: [String: Any]? = nil,
                           accept: String = "application/vnd.github+json") async throws -> (Int, [String: Any]) {
        var req = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let body { req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (d, r) = try await URLSession.shared.data(for: req)
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        return (code, obj)
    }

    /// 1) verify the token sees the repo, 2) install certs.yml + hooks on the default branch
    ///    if they're missing, 3) create the orphan `certs` branch (README + empty challenge board).
    static func link(owner: String, repo: String, token: String, forceUpdate: Bool = false) async throws -> Report {
        guard !token.isEmpty else { throw GitHubError.badConfig("Add a GitHub token in Settings › Access token first.") }
        var rep = Report()
        let base = "/repos/\(owner)/\(repo)"

        let (rc, rj) = try await gh(base, token: token)
        guard rc == 200 else { throw GitHubError.badConfig("Can't see \(owner)/\(repo) (HTTP \(rc)). Check the repo name and that the token has Contents + Actions + Workflows: Read and write on it.") }
        rep.repoOK = true
        let defaultBranch = rj["default_branch"] as? String ?? "main"

        // 2) pipeline files — push only what's missing (the app's own push engine).
        // forceUpdate: push every pipeline file regardless — replaces a stale
        // certs.yml/hook on main with the app's embedded copy.
        var missing: [(path: String, data: Data)] = []
        for f in CertPipeline.files {
            if forceUpdate { missing.append(f); continue }
            let (c, _) = try await gh("\(base)/contents/\(f.path)?ref=\(defaultBranch)", token: token)
            if c == 404 { missing.append(f) }
        }
        if !missing.isEmpty {
            let client = GitHubClient(owner: owner, repo: repo, branch: defaultBranch, token: token)
            do {
                _ = try await client.push(files: missing, subpath: "", message: forceUpdate ? "Update AirShare cert pipeline (certbot via Actions)" : "Add AirShare cert pipeline (certbot via Actions)", progress: { _, _ in })
                rep.installedFiles = missing.map(\.path)
            } catch {
                throw GitHubError.badConfig("Installing the workflow failed: \(error.localizedDescription) — the token needs Workflows: Read and write to add .github/workflows files.")
            }
        } else {
            rep.notes.append("Pipeline already installed on \(defaultBranch).")
        }

        // 3) certs branch (orphan commit via the Git Data API).
        let (bc, _) = try await gh("\(base)/branches/\(CertPipeline.branch)", token: token)
        if bc == 404 {
            func blob(_ text: String) async throws -> String {
                let (c, j) = try await gh("\(base)/git/blobs", token: token, method: "POST", body: ["content": text, "encoding": "utf-8"])
                guard c == 201, let sha = j["sha"] as? String else { throw GitHubError.badConfig("blob failed (\(c))") }
                return sha
            }
            let readme = try await blob("# AirShare certs\n\nPublished by `.github/workflows/certs.yml`: server.crt (fullchain), server.pem (key), pack.json, challenge.json.\n")
            let board  = try await blob("{\"records\":[],\"updatedAt\":\"\",\"instructions\":\"Linked. Tap Renew now in the app to issue your first cert.\"}\n")
            let (tc, tj) = try await gh("\(base)/git/trees", token: token, method: "POST", body: ["tree": [
                ["path": "README.md",      "mode": "100644", "type": "blob", "sha": readme],
                ["path": "challenge.json", "mode": "100644", "type": "blob", "sha": board],
            ]])
            guard tc == 201, let tree = tj["sha"] as? String else { throw GitHubError.badConfig("tree failed (\(tc))") }
            let (cc, cj) = try await gh("\(base)/git/commits", token: token, method: "POST", body: ["message": "init certs branch", "tree": tree, "parents": []])
            guard cc == 201, let commit = cj["sha"] as? String else { throw GitHubError.badConfig("commit failed (\(cc))") }
            let (refc, _) = try await gh("\(base)/git/refs", token: token, method: "POST", body: ["ref": "refs/heads/\(CertPipeline.branch)", "sha": commit])
            guard refc == 201 else { throw GitHubError.badConfig("creating branch failed (\(refc))") }
            rep.branchCreated = true
        } else {
            rep.notes.append("certs branch already exists.")
        }
        return rep
    }
}

// MARK: - ACME challenge board (manual DNS-01 progress from certs.yml)

nonisolated struct AcmeCheck: Decodable, Sendable {
    struct NS: Decodable, Sendable { let seen: Bool; let txt: String? }
    let at: String?
    let authoritative: [String: NS]?
    let authoritativeSeen: Bool?
    let resolvers: [String: Bool]?
}

nonisolated struct AcmeChallenge: Decodable, Identifiable, Sendable {
    let domain: String
    let name: String
    let value: String
    let step: Int
    let of: Int
    let status: String          // pending | seen | forced | validated | timeout
    let force: Bool?
    let lastCheck: AcmeCheck?
    var id: String { value }
}

nonisolated struct AcmeBoard: Decodable, Sendable {
    let records: [AcmeChallenge]
    let updatedAt: String?
    let instructions: String?
    var pending: [AcmeChallenge] { records.filter { $0.status == "pending" } }
}

extension ZefvCert {
    /// challenge.json from the certs branch (nil if the branch/file doesn't exist yet).
    static func challengeBoard(token: String?) async -> AcmeBoard? {
        let o = ServerConfig.certRepoOwner, r = ServerConfig.certRepoName, b = ServerConfig.certBranch
        var c = URLComponents(string: "https://api.github.com/repos/\(o)/\(r)/contents/challenge.json")!
        c.queryItems = [URLQueryItem(name: "ref", value: b)]
        var req = URLRequest(url: c.url!)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (d, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { return nil }
        return try? JSONDecoder().decode(AcmeBoard.self, from: d)
    }

    /// Flip "force": true on a pending record in challenge.json (certs branch). The hook
    /// pulls the file every poll and proceeds to validation as soon as it sees it.
    static func forceChallenge(value: String, token: String) async throws {
        guard !token.isEmpty else { throw GitHubError.badConfig("GitHub token required.") }
        let o = ServerConfig.certRepoOwner, r = ServerConfig.certRepoName, b = ServerConfig.certBranch
        let url = URL(string: "https://api.github.com/repos/\(o)/\(r)/contents/challenge.json?ref=\(b)")!
        var req = URLRequest(url: url); req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
        let (d, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let meta = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let sha = meta["sha"] as? String,
              let b64 = (meta["content"] as? String)?.replacingOccurrences(of: "\n", with: ""),
              let raw = Data(base64Encoded: b64),
              var doc = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw GitHubError.badConfig("Couldn't read challenge.json on \(b).")
        }
        var recs = doc["records"] as? [[String: Any]] ?? []
        var hit = false
        for i in recs.indices where (recs[i]["value"] as? String) == value { recs[i]["force"] = true; hit = true }
        guard hit else { throw GitHubError.badConfig("That challenge is no longer on the board.") }
        doc["records"] = recs
        doc["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        let newData = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
        var put = URLRequest(url: URL(string: "https://api.github.com/repos/\(o)/\(r)/contents/challenge.json")!)
        put.httpMethod = "PUT"
        put.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        put.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        put.httpBody = try JSONSerialization.data(withJSONObject: [
            "message": "acme: force continue (from app)",
            "content": newData.base64EncodedString(),
            "sha": sha, "branch": b,
        ])
        let (_, pr) = try await URLSession.shared.data(for: put)
        guard (200...299).contains((pr as? HTTPURLResponse)?.statusCode ?? 0) else {
            throw GitHubError.badConfig("Couldn't update challenge.json (HTTP \((pr as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
    }

    /// What's actually on the certs branch — reports per-file presence so the
    /// UI can distinguish "publish step failed" from "wrong repo/branch/token".
    struct BranchProbe: Sendable {
        var reachable = false
        var httpCode = 0
        var hasPackJson = false, hasServerCrt = false, hasServerPem = false
        var files: [String] = []
        var summary: String {
            if httpCode == 404 && files.isEmpty { return "Branch/repo not found, or token can't read it (HTTP 404)." }
            if !reachable { return "Couldn't reach the branch (HTTP \(httpCode))." }
            if hasPackJson && hasServerCrt && hasServerPem { return "All cert files present — tap Pull latest." }
            var missing: [String] = []
            if !hasPackJson { missing.append("pack.json") }
            if !hasServerCrt { missing.append("server.crt") }
            if !hasServerPem { missing.append("server.pem") }
            return "Branch exists but missing: \(missing.joined(separator: ", ")). The workflow's publish step didn't finish — re-run it (Renew now)."
        }
    }

    static func probeCertBranch(token: String?) async -> BranchProbe {
        var p = BranchProbe()
        let o = ServerConfig.certRepoOwner, r = ServerConfig.certRepoName, b = ServerConfig.certBranch
        var c = URLComponents(string: "https://api.github.com/repos/\(o)/\(r)/git/trees/\(b)")!
        c.queryItems = [URLQueryItem(name: "recursive", value: "0")]
        var req = URLRequest(url: c.url!)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        guard let (d, resp) = try? await URLSession.shared.data(for: req) else { return p }
        p.httpCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard p.httpCode < 400, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let tree = j["tree"] as? [[String: Any]] else { return p }
        p.reachable = true
        p.files = tree.compactMap { $0["path"] as? String }
        p.hasPackJson = p.files.contains("pack.json")
        p.hasServerCrt = p.files.contains("server.crt")
        p.hasServerPem = p.files.contains("server.pem")
        return p
    }

    /// Authoritative nameservers for a zone (walks up to the registrable domain).
    static func nameservers(for domain: String) async -> [String] {
        var zone = domain
        while zone.contains(".") {
            if let ns = await dohNS(zone), !ns.isEmpty { return ns }
            let parts = zone.split(separator: ".")
            if parts.count <= 2 { break }
            zone = parts.dropFirst().joined(separator: ".")
        }
        return await dohNS(zone) ?? []
    }
    private static func dohNS(_ name: String) async -> [String]? {
        guard let u = URL(string: "https://dns.google/resolve?name=\(name)&type=NS") else { return nil }
        var req = URLRequest(url: u); req.setValue("application/dns-json", forHTTPHeaderField: "accept"); req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (d, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let ans = j["Answer"] as? [[String: Any]] else { return nil }
        let ns = ans.compactMap { ($0["data"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
        return ns.isEmpty ? nil : ns
    }

    /// Pre-issuance readiness for Public/ACME. Verifies the two DNS facts that
    /// make or break a certbot run before we dispatch one.
    struct DNSReadiness: Sendable {
        var wildcardLoopback: Bool?     // *.domain (via ota-probe) → 127.0.0.1
        var nameservers: [String]       // zone is delegated & reachable
        var challengeResolvable: Bool?  // _acme-challenge.domain answers at all (no NXDOMAIN on the name)
        var ready: Bool { wildcardLoopback == true && !nameservers.isEmpty }
    }
    static func dnsReadiness(domain: String) async -> DNSReadiness {
        async let loop = resolvesToLoopback("ota-probe.\(domain)")
        async let ns = nameservers(for: domain)
        // _acme-challenge may legitimately be empty (no TXT yet) but the NAME's zone
        // must be resolvable; reuse the NS presence as the signal.
        let r = DNSReadiness(wildcardLoopback: await loop, nameservers: await ns, challengeResolvable: nil)
        return r
    }

    /// Live TXT lookup over DNS-over-HTTPS (same resolvers the hook polls).
    static func txtRecords(_ name: String) async -> [String] {
        var out = Set<String>()
        for q in ["https://cloudflare-dns.com/dns-query?name=\(name)&type=TXT",
                  "https://dns.google/resolve?name=\(name)&type=TXT"] {
            guard let u = URL(string: q) else { continue }
            var req = URLRequest(url: u); req.setValue("application/dns-json", forHTTPHeaderField: "accept")
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (d, _) = try? await URLSession.shared.data(for: req),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let ans = j["Answer"] as? [[String: Any]] else { continue }
            for a in ans {
                if let s = a["data"] as? String { out.insert(s.replacingOccurrences(of: "\"", with: "")) }
            }
        }
        return Array(out)
    }
}

// MARK: - Install trace (what installd actually fetched)

/// Every request the AirShare server answered during an install, so a failure can be
/// diagnosed: no requests = TLS/DNS; manifest only = IPA fetch failed; both =
/// installd rejected the package (signing/provisioning/bundle-id).
nonisolated final class OTATrace: @unchecked Sendable {
    static let shared = OTATrace()
    struct Entry: Sendable, Identifiable { let id = UUID(); let at: Date; let path: String; let status: Int; let bytes: Int64 }
    private var entries: [Entry] = []
    private let lock = NSLock()

    func reset() { lock.lock(); entries.removeAll(); lock.unlock() }
    func add(_ path: String, status: Int, bytes: Int64) {
        lock.lock(); entries.append(Entry(at: Date(), path: path, status: status, bytes: bytes)); lock.unlock()
    }
    var all: [Entry] { lock.lock(); defer { lock.unlock() }; return entries }

    var manifestFetched: Bool { all.contains { $0.path.hasSuffix(".plist") && $0.status == 200 } }
    var ipaFetched: Bool { all.contains { $0.path.hasSuffix(".ipa") && $0.status == 200 } }
    var ipaBytes: Int64 { all.filter { $0.path.hasSuffix(".ipa") }.map(\.bytes).max() ?? 0 }

    /// Plain-English diagnosis of the last install attempt.
    func diagnosis(ipaSize: Int64) -> String {
        if all.isEmpty {
            return "installd never connected. iOS showed the sheet but couldn't reach https://\(ServerConfig.installHost) — usually TLS: the cert isn't trusted by installd (Certificate Trust Settings toggle off), or the host isn't resolving to 127.0.0.1 from installd's resolver."
        }
        if !manifestFetched {
            return "installd connected but never got the manifest. Check the AirShare host matches the cert SANs exactly (see Certificate inspector)."
        }
        if !ipaFetched {
            return "Manifest delivered but the IPA was never downloaded. installd rejected the manifest — bundle-identifier / bundle-version mismatch with the IPA, or the display-image PNG failed."
        }
        if ipaBytes < ipaSize {
            return "IPA download was cut short (\(ByteCountFormatter.string(fromByteCount: ipaBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: ipaSize, countStyle: .file))). The server was torn down too early or the app was backgrounded mid-download."
        }
        return "installd downloaded the full IPA and then refused to install it. That is a signing/provisioning problem, not a delivery problem: (1) this device's UDID isn't in the .mobileprovision, (2) the profile or cert is expired/revoked, (3) an app with the same bundle ID is already installed from a different team — delete it first, or change the bundle ID in the sign sheet, or (4) the entitlements don't match the profile (try Strip content › remove extensions, or disable App Groups/iCloud in the profile)."
    }
}

// MARK: - Vapor HTTPS server

nonisolated struct InstallAppData: Sendable {
    var id: String
    var version: String
    var name: String
}

nonisolated final class LocalOTAServer: Identifiable, @unchecked Sendable {
    let id = UUID()
    let package: URL
    let metadata: InstallAppData
    private let imageSmall: Data
    private let imageLarge: Data
    private var registered = false

    static func host() -> String { LocalZSignAPI.host() }

    /// Registers this AirShare package with AirShare's single shared HTTPS service.
    /// There is deliberately no second Vapor `Application` or listening socket.
    init(package: URL, metadata: InstallAppData, imageSmall: Data, imageLarge: Data) throws {
        self.package = package
        self.metadata = metadata
        self.imageSmall = imageSmall
        self.imageLarge = imageLarge
        LocalZSignAPI.shared.startIfNeeded()
        try LocalZSignAPI.shared.registerOTAServer(self)
        registered = true
    }

    var itmsServicesURL: URL {
        var c = URLComponents()
        c.scheme = "itms-services"
        c.path = "/"
        c.queryItems = [
            .init(name: "action", value: "download-manifest"),
            .init(name: "url", value: "https://\(Self.host()):\(LocalZSignAPI.shared.port)/ota/\(id.uuidString)/manifest.plist"),
        ]
        return c.url!
    }

    func response(for resource: String, request: Request) throws -> Response {
        let manifest: [String: Any] = [
            "items": [[
                "assets": [
                    ["kind": "software-package", "url": "https://\(Self.host()):\(LocalZSignAPI.shared.port)/ota/\(id.uuidString)/app.ipa"],
                    ["kind": "display-image",    "url": "https://\(Self.host()):\(LocalZSignAPI.shared.port)/ota/\(id.uuidString)/app57x57.png"],
                    ["kind": "full-size-image",  "url": "https://\(Self.host()):\(LocalZSignAPI.shared.port)/ota/\(id.uuidString)/app512x512.png"],
                ],
                "metadata": [
                    "bundle-identifier": metadata.id,
                    "bundle-version": metadata.version,
                    "kind": "software",
                    "title": metadata.name,
                ],
            ]],
        ]
        let manifestData = (try? PropertyListSerialization.data(fromPropertyList: manifest, format: .xml, options: .zero)) ?? Data()
        let ipaSize = (try? FileManager.default.attributesOfItem(atPath: package.path)[.size] as? Int64) ?? 0

        switch resource {
        case "ping":
            OTATrace.shared.add("/ota/\(id.uuidString)/ping", status: 200, bytes: 4)
            return Response(status: .ok, version: request.version, headers: ["Content-Type": "text/plain"], body: .init(string: "pong"))
        case "manifest.plist":
            OTATrace.shared.add("/ota/\(id.uuidString)/manifest.plist", status: 200, bytes: Int64(manifestData.count))
            return Response(status: .ok, version: request.version, headers: ["Content-Type": "text/xml"], body: .init(data: manifestData))
        case "app57x57.png":
            OTATrace.shared.add("/ota/\(id.uuidString)/app57x57.png", status: 200, bytes: Int64(imageSmall.count))
            return Response(status: .ok, version: request.version, headers: ["Content-Type": "image/png"], body: .init(data: imageSmall))
        case "app512x512.png":
            OTATrace.shared.add("/ota/\(id.uuidString)/app512x512.png", status: 200, bytes: Int64(imageLarge.count))
            return Response(status: .ok, version: request.version, headers: ["Content-Type": "image/png"], body: .init(data: imageLarge))
        case "app.ipa":
            OTATrace.shared.add("/ota/\(id.uuidString)/app.ipa", status: 200, bytes: ipaSize)
            return request.fileio.streamFile(at: package.path)
        default:
            OTATrace.shared.add("/ota/\(id.uuidString)/\(resource)", status: 404, bytes: 0)
            throw Abort(.notFound)
        }
    }

    func shutdown() {
        guard registered else { return }
        registered = false
        LocalZSignAPI.shared.removeOTAServer(id)
    }
}


// MARK: - VPS status + install analytics (airshare.lol/ota/status.php · event.php)

nonisolated enum ZefvVPS {
    /// Derived from the cert source URL so a custom source moves everything together.
    private static func endpoint(_ file: String) -> URL? {
        guard let base = URL(string: ServerConfig.certSourceURL) else { return nil }
        return base.deletingLastPathComponent().appendingPathComponent(file)
    }
    private static func request(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url); r.httpMethod = method; r.timeoutInterval = 15
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.setValue(ServerConfig.certSourceToken, forHTTPHeaderField: "X-OTA-Token")
        r.setValue("unzip-drop-ios", forHTTPHeaderField: "User-Agent")
        if let body { r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    // Status ----------------------------------------------------------------

    struct LastRenew: Decodable, Sendable { let ok: Bool?; let at: String?; let source: String? }
    struct Status: Decodable, Sendable {
        let server_time: String?
        let not_after: String?
        let days_left: Int?
        let issuer: String?
        let sans: [String]?
        let cert_mtime: String?
        let last_renew: LastRenew?
        let error: String?

        var notAfter: Date? { not_after.flatMap { ISO8601DateFormatter().date(from: $0) } }
        var renewedAt: Date? {
            guard let a = last_renew?.at else { return nil }
            if let d = ISO8601DateFormatter().date(from: a) { return d }
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.timeZone = TimeZone(identifier: "UTC")
            return f.date(from: a)
        }
    }

    static func status() async throws -> Status {
        guard let u = endpoint("status.php") else { throw ZefvCert.CertError.badPack("bad cert source URL") }
        let (d, r) = try await URLSession.shared.data(for: request(u))
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        guard code < 400 else { throw ZefvCert.CertError.badPack("\(u.host ?? "VPS") status → HTTP \(code)") }
        return try JSONDecoder().decode(Status.self, from: d)
    }

    // Analytics ---------------------------------------------------------------

    static var analyticsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "uzd_analytics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "uzd_analytics") }
    }
    /// Anonymous per-install id — not tied to the device or any account.
    static var deviceToken: String {
        if let t = UserDefaults.standard.string(forKey: "uzd_analytics_id") { return t }
        let t = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16).description
        UserDefaults.standard.set(t, forKey: "uzd_analytics_id"); return t
    }

    /// Fire-and-forget. `stage`: "prompted" (itms-services handed to iOS) or "installed" (installd fetched the IPA).
    static func report(bundle: String, version: String, name: String, stage: String) {
        guard analyticsEnabled, let u = endpoint("event.php") else { return }
        let body: [String: String] = ["bundle": bundle, "version": version, "name": name,
                                      "mode": ServerConfig.certMode, "stage": stage, "device": deviceToken]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        Task.detached { _ = try? await URLSession.shared.data(for: request(u, method: "POST", body: data)) }
    }

    /// Install counts for every bundle the VPS has seen.
    static func installCounts() async -> [String: Int] {
        guard let u = endpoint("event.php") else { return [:] }
        guard let (d, r) = try? await URLSession.shared.data(for: request(u)),
              ((r as? HTTPURLResponse)?.statusCode ?? 0) < 400,
              let dict = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return dict.compactMapValues { $0 as? Int }
    }
}
