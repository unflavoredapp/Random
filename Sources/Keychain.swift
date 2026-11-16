//
//  Keychain.swift
//

import Foundation
import Security

nonisolated enum Keychain {
    private static let service = "Tetherless"
    /// Pre-rename service — still readable so upgrades keep sessions / certs.
    private static let legacyService = "unzip-drop"

    private static func deleteAccount(_ key: String, service: String, synchronizable: Bool = false) {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if synchronizable { q[kSecAttrSynchronizable as String] = kCFBooleanTrue as Any }
        SecItemDelete(q as CFDictionary)
    }

    @discardableResult
    static func set(_ key: String, _ value: String) -> Bool {
        deleteAccount(key, service: service)
        deleteAccount(key, service: legacyService)
        if value.isEmpty { return true }
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            // Readable after the first unlock, so a launch while the phone is locked (background refresh,
            // VPN) can still see the saved session instead of treating the user as signed out.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        for svc in [service, legacyService] {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
               let d = out as? Data,
               let s = String(data: d, encoding: .utf8) {
                return s
            }
        }
        return nil
    }

    // MARK: - Non-exportable secrets (private keys)
    //
    // Used for the local CA's root/leaf private keys: ThisDeviceOnly means the
    // item is excluded from iTunes/Finder and iCloud backups and can never
    // migrate to another device — if the CA key ever leaves this Keychain, it's
    // because the device itself was restored, not because a backup carried it.

    @discardableResult
    static func setSecret(_ key: String, _ value: String) -> Bool {
        deleteAccount(key, service: service)
        deleteAccount(key, service: legacyService)
        if value.isEmpty { return true }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            // CA private keys stay device-local and unlock-gated.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func getSecret(_ key: String) -> String? { get(key) }   // read path is accessibility-agnostic

    static func deleteSecret(_ key: String) { _ = set(key, "") }

    /// Apple ID password / store session blobs — survive lock + reboot (after first unlock),
    /// stay off iCloud backups (`ThisDeviceOnly`). Prefer this over `setSecret` for auth sessions
    /// so background refresh / cold launch don't treat the user as signed out.
    @discardableResult
    static func setSessionSecret(_ key: String, _ value: String) -> Bool {
        deleteAccount(key, service: service)
        deleteAccount(key, service: legacyService)
        if value.isEmpty { return true }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func getSessionSecret(_ key: String) -> String? { get(key) }

    @discardableResult
    static func setSessionData(_ key: String, _ data: Data) -> Bool {
        deleteAccount(key, service: service)
        deleteAccount(key, service: legacyService)
        if data.isEmpty { return true }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func getSessionData(_ key: String) -> Data? {
        for svc in [service, legacyService] {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecAttrAccount as String: key,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess {
                return out as? Data
            }
        }
        return nil
    }

    static func deleteSessionSecret(_ key: String) { _ = setSessionSecret(key, "") }

    // MARK: - Persistent binary storage (survives app deletion)
    //
    // Items written with these methods have kSecAttrSynchronizable = true so
    // they sync into the user's iCloud Keychain. This is the only way a
    // Keychain item can outlive app deletion on iOS 10.3+ without an app
    // group entitlement — Apple wipes local-only Keychain items when an
    // app is uninstalled.
    //
    // Used for the leaf/root CA + user-imported .p12 / .mobileprovision so
    // deleting TetherLess doesn't force the user to re-import certs when
    // they reinstall.

    @discardableResult
    static func setPersistent(_ key: String, _ data: Data) -> Bool {
        deleteAccount(key, service: service, synchronizable: true)
        deleteAccount(key, service: legacyService, synchronizable: true)
        if data.isEmpty { return true }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func getPersistent(_ key: String) -> Data? {
        for svc in [service, legacyService] {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecAttrAccount as String: key,
                kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
               let d = out as? Data {
                return d
            }
        }
        return nil
    }

    /// String convenience over the persistent (iCloud-synced) storage.
    @discardableResult
    static func setPersistentString(_ key: String, _ value: String) -> Bool {
        setPersistent(key, Data(value.utf8))
    }
    static func getPersistentString(_ key: String) -> String? {
        guard let d = getPersistent(key) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Enumerate all persistent keys under our service — used at startup so
    /// CertificateStore can rehydrate the on-disk .p12 / .mobileprovision
    /// files after a fresh reinstall.
    static func allPersistentKeys() -> [String] {
        var keys = Set<String>()
        for svc in [service, legacyService] {
            let q: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: svc,
                kSecAttrSynchronizable as String: kCFBooleanTrue as Any,
                kSecReturnAttributes as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll,
            ]
            var out: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { continue }
            if let arr = out as? [[String: Any]] {
                for item in arr {
                    if let account = item[kSecAttrAccount as String] as? String {
                        keys.insert(account)
                    }
                }
            }
        }
        return Array(keys)
    }
}
