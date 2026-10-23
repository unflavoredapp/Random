//
//  ZefvClient.swift
//  Account client for the AirShare backend (airshare.lol/app/v1). Registration/login are
//  OPTIONAL — the app works fully as a guest keyed on the device MDID. An
//  account links this ADID to a username + role so staff tools follow you
//  across reinstalls and devices.
//
//  All requests carry the shared X-OTA-Token (ServerConfig.certSourceToken).
//  The per-user session token is stored in the Keychain.
//

import Foundation

@MainActor
final class ZefvAccount: ObservableObject {
    static let shared = ZefvAccount()

    @Published private(set) var username: String?
    @Published private(set) var email: String?
    @Published private(set) var style: UserStyle = UserStyle.load()
    @Published private(set) var signsToday: Int = UserDefaults.standard.integer(forKey: "zefv_signs_today")
    @Published private(set) var signsTotal: Int = UserDefaults.standard.integer(forKey: "zefv_signs_total")
    @Published private(set) var role: UserRole = .member
    @Published private(set) var sponsor: String = ""
    @Published private(set) var busy = false
    @Published var lastError: String?
    /// Set whenever a login/register/autologin attempt reports the account is banned; nil the rest of the time.
    @Published var banInfo: BanInfo?
    @Published var appealError: String?
    @Published var panelShown = false

    private static let kSession  = "zefv_session_token"
    private static let kUsername = "zefv_username"
    private static let kDeviceKey = "zefv_device_key"      // issued at sign-in; with the ADID it signs this device in automatically
    private static let kLastAuthenticatedAt = "zefv_last_authenticated_at"

    var lastAuthenticatedAt: Date? {
        let value = UserDefaults.standard.double(forKey: Self.kLastAuthenticatedAt)
        return value > 0 ? Date(timeIntervalSince1970: value) : nil
    }

    var isLoggedIn: Bool { username != nil }
    var sessionToken: String? { Keychain.get(Self.kSession) }

    private init() {
        username = Keychain.get(Self.kUsername)
        if let raw = Keychain.get("zefv_role"), let r = UserRole(rawValue: raw) { role = r }
        migrateKeychainAccessibility()
    }

    /// Re-read the saved sign-in. If the app was launched while the phone was locked the Keychain was unreadable
    /// and the account stayed "signed out" for the whole run; this puts it back as soon as the Keychain opens.
    func restoreFromKeychainIfNeeded() {
        guard username == nil, let name = Keychain.get(Self.kUsername), !name.isEmpty else { return }
        username = name
        if let raw = Keychain.get("zefv_role"), let r = UserRole(rawValue: raw) { role = r }
        migrateKeychainAccessibility()
    }

    /// One-time: rewrite existing sign-in items so they stay readable while the phone is locked.
    private func migrateKeychainAccessibility() {
        let flag = "zefv_keychain_after_first_unlock_v1"
        guard !UserDefaults.standard.bool(forKey: flag), Keychain.get(Self.kUsername) != nil else { return }
        for key in [Self.kSession, Self.kUsername, "zefv_role", Self.kDeviceKey] {
            if let v = Keychain.get(key), !v.isEmpty { _ = Keychain.set(key, v) }
        }
        UserDefaults.standard.set(true, forKey: flag)
    }

    // MARK: - Endpoint base — the PHP account API lives on apii (api.zefv.dev is a router)

    /// AirShare backend (Node). Override with UserDefaults "as_api_base" if it ever moves.
    nonisolated static let defaultBase = "https://airshare.lol/app/v1/"
    nonisolated static var apiBase: String {
        let v = UserDefaults.standard.string(forKey: "as_api_base") ?? ""
        return v.isEmpty ? defaultBase : (v.hasSuffix("/") ? v : v + "/")
    }
    private func base() -> URL? {
        URL(string: Self.apiBase)
    }
    private func endpoint(_ path: String) -> URL? { base()?.appendingPathComponent(path) }

    private func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        guard let url = endpoint(path), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw Err.badURL }
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let u = c.url else { throw Err.badURL }
        var req = URLRequest(url: u)
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue(ServerConfig.certSourceToken, forHTTPHeaderField: "X-OTA-Token")
        let (d, r) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 { throw Err.server((obj["error"] as? String) ?? "Server error (\(code))") }
        return obj
    }

    private func post(_ path: String, _ payload: [String: Any]) async throws -> [String: Any] {
        guard let url = endpoint(path) else { throw Err.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ServerConfig.certSourceToken, forHTTPHeaderField: "X-OTA-Token")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (d, r) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 {
            let msg = (obj["error"] as? String) ?? "Server error (\(code))"
            if obj["banned"] as? Bool == true, let ban = obj["ban"] as? [String: Any] {
                throw Err.banned(BanInfo(json: ban, fallbackMessage: msg))
            }
            throw Err.server(msg)
        }
        return obj
    }

    private func accountAPIGet(_ query: [String: String]) async throws -> [String: Any] {
        guard let base = endpoint("account"), var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw Err.badURL }
        c.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = c.url else { throw Err.badURL }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let t = query["token"] { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        let (d, r) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 { throw Err.server((obj["error"] as? String) ?? "Server error (\(code))") }
        return obj
    }

    private func accountAPIPost(_ payload: [String: Any]) async throws -> [String: Any] {
        guard let url = endpoint("account") else { throw Err.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(ServerConfig.certSourceToken, forHTTPHeaderField: "X-OTA-Token")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (d, r) = try await URLSession.shared.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 { throw Err.server((obj["error"] as? String) ?? "Server error (\(code))") }
        return obj
    }

    // MARK: - Actions

    func register(username u: String, password p: String) async -> Bool {
        await run { try await self.post("register", ["username": u, "password": p, "adid": MDID.current]) }
    }
    func login(username u: String, password p: String) async -> Bool {
        await run { try await self.post("login", ["username": u, "password": p, "adid": MDID.current]) }
    }

    private func run(_ call: @escaping () async throws -> [String: Any]) async -> Bool {
        busy = true; lastError = nil; banInfo = nil; defer { busy = false }
        do {
            let o = try await call()
            guard let tok = o["token"] as? String, let name = o["username"] as? String else {
                lastError = "Malformed response"; return false
            }
            let r = UserRole(rawValue: (o["role"] as? String) ?? "member") ?? .member
            _ = Keychain.set(Self.kSession, tok)
            _ = Keychain.set(Self.kUsername, name)
            _ = Keychain.set("zefv_role", r.rawValue)
            if let dk = o["device_key"] as? String, !dk.isEmpty { _ = Keychain.set(Self.kDeviceKey, dk) }
            username = name; role = r
            // The account owns an ADID: adopt it so staff roles follow you to a new device / reinstall.
            if let a = (o["adid"] as? String)?.uppercased(), MDIDManager.shared.isValid(a), a != MDID.current { _ = MDID.replace(a) }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.kLastAuthenticatedAt)
            await StaffGate.shared.refresh()
            WidgetDataManager.shared.refresh()
            await syncCertificates()
            return true
        } catch {
            if let e = error as? Err, case .banned(let b) = e { banInfo = b }
            lastError = (error as? Err)?.message ?? error.localizedDescription
            return false
        }
    }

    /// Pull username/role/email for the stored session; clears the session if the server rejects it.
    func refreshProfile() async {
        guard let tok = sessionToken, !tok.isEmpty else { return }
        do {
            let o = try await accountAPIGet(["token": tok])
            if let name = o["username"] as? String { username = name; _ = Keychain.set(Self.kUsername, name) }
            email = (o["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            var st = UserStyle(json: o["style"] as? [String: Any])
            st.badges = (o["badges"] as? [String]) ?? []
            style = st; st.save()
            let r = UserRole(rawValue: (o["role"] as? String) ?? "member") ?? .member
            role = r; _ = Keychain.set("zefv_role", r.rawValue)
            sponsor = (o["sponsor"] as? String) ?? ""
            if (Keychain.get(Self.kDeviceKey) ?? "").isEmpty, MDIDManager.shared.isValid(MDID.current),
               let d = try? await post("account", ["action": "device_key", "token": tok, "adid": MDID.current]),
               let dk = d["device_key"] as? String, !dk.isEmpty {
                _ = Keychain.set(Self.kDeviceKey, dk)       // existing sessions pair themselves once
            }
            await StaffGate.shared.refresh()
            await syncCertificates()
        } catch let e as Err {
            if case .server(let m) = e, m.lowercased().contains("session") {
                await clearLocal()
                _ = await autoLoginIfNeeded()          // expired session → recognized device signs straight back in
            }
            lastError = e.message
        } catch { lastError = error.localizedDescription }
    }

    /// Automatic sign-in: once this device has signed in, its ADID + hidden device key (Keychain) get a fresh session
    /// with no password. Does nothing when already signed in or when the device was never paired.
    @discardableResult
    func autoLoginIfNeeded() async -> Bool {
        if let t = sessionToken, !t.isEmpty, username != nil { return true }
        guard let key = Keychain.get(Self.kDeviceKey), !key.isEmpty, MDIDManager.shared.isValid(MDID.current) else { return false }
        let ok = await run { try await self.post("autologin", ["adid": MDID.current, "device_key": key]) }
        if !ok && banInfo == nil {
            if (lastError ?? "").lowercased().contains("recognized") { _ = Keychain.set(Self.kDeviceKey, "") }   // revoked on the server
            lastError = nil                // quiet: the normal sign-in screen simply shows
        }
        // A ban is the one autologin failure that should NOT stay quiet — it's shown app-wide (see AccountBannedOverlay)
        // rather than only on the sign-in sheet, since autologin can fire before the person opens Settings at all.
        return ok
    }

    /// One appeal message per ban. Re-sends the credentials that would normally sign in — a banned account has
    /// no working session/token — so submits only from the sign-in form (or wherever the password is in hand).
    func submitAppeal(username u: String, password p: String, message: String) async -> Bool {
        busy = true; appealError = nil; defer { busy = false }
        do {
            let o = try await post("appeal", ["username": u, "password": p, "message": message])
            if let ap = o["appeal"] as? [String: Any] {
                banInfo = banInfo.map { BanInfo(banned: $0.banned, reason: $0.reason, until: $0.until, appeal: BanAppeal(json: ap)) }
            }
            return true
        } catch { appealError = (error as? Err)?.message ?? error.localizedDescription; return false }
    }

    /// Registered-only cosmetics: username color / rainbow / animated background.
    func setStyle(_ st: UserStyle) async -> Bool {
        guard let tok = sessionToken else { return false }
        busy = true; lastError = nil; defer { busy = false }
        do {
            _ = try await post("account", ["action": "set_style", "token": tok,
                                               "color": st.colorHex, "rainbow": st.rainbow ? 1 : 0, "gif": st.gifURL,
                                               "font": st.fontName, "size": st.sizeStep])
            var saved = st; saved.badges = style.badges
            style = saved; saved.save(); return true
        } catch { lastError = (error as? Err)?.message ?? error.localizedDescription; return false }
    }

    // MARK: - Sign counter (aesthetic only — no limits)

    private func applyCounts(_ o: [String: Any]) {
        if let t = o["today"] as? Int { signsToday = t; UserDefaults.standard.set(t, forKey: "zefv_signs_today") }
        if let t = o["total"] as? Int { signsTotal = t; UserDefaults.standard.set(t, forKey: "zefv_signs_total") }
        WidgetDataManager.shared.refresh()
    }
    func refreshSignCounts() async {
        do {
            let o = try await get("quota", ["adid": StaffGate.shared.mdid])
            applyCounts(o)
        } catch {
            lastError = (error as? Err)?.message ?? error.localizedDescription
        }
    }
    /// Fire-and-forget after a successful sign.
    func recordSign() {
        signsToday += 1; signsTotal += 1
        Task { if let o = try? await post("quota", ["adid": StaffGate.shared.mdid, "action": "consume"]) { applyCounts(o) } }
    }

    /// Admin-only ADID reassignment for the currently authenticated account.
    /// The server must atomically update the account ADID and any role/allowlist
    /// mapping before returning the canonical value. Only then do we update the
    /// local Keychain value and re-check the role against the new MDID.
    func adminChangeOwnMDID(_ requested: String) async -> Bool {
        guard role == .admin || StaffGate.shared.role == .admin, let tok = sessionToken else { return false }
        let value = requested.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard MDIDManager.shared.isValid(value) else {
            lastError = "ADID must look like AS-XXXXXX-XX"
            return false
        }
        busy = true; lastError = nil; defer { busy = false }
        do {
            let o = try await accountAPIPost([
                "action": "admin_set_mdid",
                "token": tok,
                "mdid": value
            ])
            guard let canonical = (o["mdid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                  MDIDManager.shared.isValid(canonical),
                  MDID.replace(canonical) else {
                lastError = "Server returned an invalid ADID"
                return false
            }
            await refreshProfile()
            await StaffGate.shared.refresh()
            return true
        } catch {
            lastError = (error as? Err)?.message ?? error.localizedDescription
            return false
        }
    }

    // MARK: - Admin: groups & sponsors (server enforces admin-only)

    struct AdminMember: Identifiable, Equatable, Sendable {
        let username: String
        let adid: String
        let role: String
        var groups: [String]
        var sponsor: String
        var id: String { username }
    }

    private var isAdminNow: Bool { role == .admin || StaffGate.shared.role == .admin }

    func adminListUsers(_ q: String) async -> (groups: [String], users: [AdminMember])? {
        guard isAdminNow, let tok = sessionToken else { return nil }
        do {
            let o = try await accountAPIPost(["action": "admin_list_users", "token": tok, "q": q])
            let cat = (o["groups"] as? [String]) ?? []
            let list = (o["users"] as? [[String: Any]]) ?? []
            let users = list.map { u in
                AdminMember(username: (u["username"] as? String) ?? "", adid: (u["adid"] as? String) ?? "",
                            role: (u["role"] as? String) ?? "member", groups: (u["groups"] as? [String]) ?? [],
                            sponsor: (u["sponsor"] as? String) ?? "")
            }
            return (cat, users)
        } catch { lastError = (error as? Err)?.message ?? error.localizedDescription; return nil }
    }

    func adminSetGroups(_ username: String, _ groups: [String]) async -> [String]? {
        guard isAdminNow, let tok = sessionToken else { return nil }
        do {
            let o = try await accountAPIPost(["action": "admin_set_groups", "token": tok, "username": username, "groups": groups])
            if username.lowercased() == (self.username ?? "").lowercased() { await refreshProfile() }
            return (o["groups"] as? [String]) ?? groups
        } catch { lastError = (error as? Err)?.message ?? error.localizedDescription; return nil }
    }

    func adminSetSponsor(_ username: String, _ value: String) async -> String? {
        guard isAdminNow, let tok = sessionToken else { return nil }
        do {
            let o = try await accountAPIPost(["action": "admin_set_sponsor", "token": tok, "username": username, "sponsor": value])
            if username.lowercased() == (self.username ?? "").lowercased() { await refreshProfile() }
            return (o["sponsor"] as? String) ?? value
        } catch { lastError = (error as? Err)?.message ?? error.localizedDescription; return nil }
    }

    func setUsername(_ n: String) async -> Bool {
        guard let tok = sessionToken else { return false }
        busy = true; lastError = nil; defer { busy = false }
        do {
            let o = try await post("account", ["action": "set_username", "token": tok, "username": n])
            let name = (o["username"] as? String) ?? n
            username = name; _ = Keychain.set(Self.kUsername, name)
            return true
        } catch { lastError = (error as? Err)?.message ?? error.localizedDescription; return false }
    }

    func setEmail(_ e: String) async -> Bool {
        guard let tok = sessionToken else { return false }
        busy = true; lastError = nil; defer { busy = false }
        do { _ = try await post("account", ["action": "set_email", "token": tok, "email": e]); email = e.isEmpty ? nil : e; return true }
        catch { lastError = (error as? Err)?.message ?? error.localizedDescription; return false }
    }

    func changePassword(current: String, new n: String) async -> Bool {
        guard let tok = sessionToken else { return false }
        busy = true; lastError = nil; defer { busy = false }
        do {
            let o = try await post("account", ["action": "change_password", "token": tok, "current_password": current, "new_password": n])
            if let t = o["token"] as? String, !t.isEmpty { _ = Keychain.set(Self.kSession, t) }
            return true
        }
        catch { lastError = (error as? Err)?.message ?? error.localizedDescription; return false }
    }

    private func clearLocal() async {
        _ = Keychain.set(Self.kSession, "")
        _ = Keychain.set(Self.kUsername, "")
        _ = Keychain.set("zefv_role", "")
        username = nil; email = nil; role = .member; sponsor = ""; style = .none; UserStyle.none.save()
    }

    func logout() async {
        if let tok = sessionToken { _ = try? await post("account", ["action": "logout", "token": tok, "adid": MDID.current]) }
        _ = Keychain.set(Self.kDeviceKey, "")
        removeSyncedCertificates()
        await clearLocal()
    }

    // MARK: - Certificate sync (account → on-device signer)

    private static let kSyncedCerts = "as_synced_certs"   // [serverCertId: localCertId]

    private var syncedMap: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: Self.kSyncedCerts) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.kSyncedCerts) }
    }

    /// Pulls the account's certificates (.p12 + profile + password) into the local store.
    /// Admin-provided (locked) certs sync too, but are stored privately and can't be exported or deleted in the app.
    /// New ones are imported, ones removed from the account are dropped, existing ones are left alone.
    @discardableResult
    func syncCertificates() async -> Int {
        guard let tok = sessionToken, !tok.isEmpty, let url = endpoint("certificates") else { return 0 }
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
        guard let (d, r) = try? await URLSession.shared.data(for: req),
              (r as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let list = obj["certificates"] as? [[String: Any]] else { return 0 }

        let store = CertificateStore.shared
        var map = syncedMap
        var seen = Set<String>()
        var added = 0
        for c in list {
            guard let sid = c["id"] as? String else { continue }
            seen.insert(sid)
            if let lid = map[sid], store.certificates.contains(where: { $0.id == lid }) { continue }
            guard let p12 = (c["p12"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let prov = (c["prov"] as? String).flatMap({ Data(base64Encoded: $0) }),
                  let pw = c["password"] as? String else { continue }
            let name = (c["name"] as? String) ?? "Certificate"
            if let cert = try? store.importPair(name: name, p12: p12, password: pw, provision: prov, makeActive: store.active == nil, locked: (c["locked"] as? Bool) ?? false) {
                map[sid] = cert.id
                added += 1
            }
        }
        for (sid, lid) in Array(map) where !seen.contains(sid) {
            if let local = store.certificates.first(where: { $0.id == lid }) { store.delete(local) }
            map[sid] = nil
        }
        syncedMap = map
        return added
    }

    /// Certificates that came from the account leave the device with the session.
    private func removeSyncedCertificates() {
        let store = CertificateStore.shared
        for lid in syncedMap.values {
            if let local = store.certificates.first(where: { $0.id == lid }) { store.delete(local) }
        }
        syncedMap = [:]
    }

    enum Err: Error { case badURL, server(String), banned(BanInfo)
        var message: String {
            switch self {
            case .badURL: return "Bad URL"
            case .server(let m): return m
            case .banned(let b): return b.message
            }
        }
    }
}
