//
//  MDID.swift
//  AirShare
//
//  A per-install MDID. New installs mint a cryptographically-random ID on the
//  first request instead of deriving the ID from device hardware/display data.
//  The value is persisted in Keychain. Server-side account/role authorization
//  remains authoritative.
//

import Foundation
import Security

nonisolated final class MDIDManager {
    static let shared = MDIDManager()
    private let acct = "party.msign.mdid"
    private let charset = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private init() {}

    /// Returns the persisted per-install ADID, minting a new random one on the
    /// first request. Existing valid IDs are preserved for backwards compatibility.
    func mdid() -> String {
        if let current = read(acct), isValid(current) {
            // Migrate legacy MS- identities to the AS- prefix, keeping the suffix.
            if current.hasPrefix("MS-") {
                let migrated = "AS-" + current.dropFirst(3)
                save(migrated, acct)
                return migrated
            }
            return current
        }
        let generated = generateRandom()
        save(generated, acct)
        return generated
    }

    /// Replace the locally stored ADID after the server has accepted an
    /// administrator-authorized change.
    @discardableResult
    func setMDID(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard isValid(normalized) else { return false }
        save(normalized, acct)
        return true
    }

    func isValid(_ s: String) -> Bool {
        s.range(of: #"^(AS|MS)-[A-Z0-9]{6}-[A-Z0-9]{2}$"#, options: [.regularExpression]) != nil
    }

    /// Generate AS-XXXXXX-XX using SecRandomCopyBytes. This is intentionally
    /// independent of hardware identifiers so a first-time install gets a new
    /// random identity.
    private func generateRandom() -> String {
        func block(_ count: Int) -> String {
            var bytes = [UInt8](repeating: 0, count: count)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            if status == errSecSuccess {
                return String(bytes.map { charset[Int($0) % charset.count] })
            }
            // Extremely unlikely fallback: still non-device-derived.
            return String((0..<count).map { _ in charset.randomElement()! })
        }
        return "AS-\(block(6))-\(block(2))"
    }

    private func save(_ value: String, _ account: String) {
        guard let data = value.data(using: .utf8) else { return }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemDelete(q as CFDictionary)
        SecItemAdd(q as CFDictionary, nil)
    }

    private func read(_ account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

nonisolated enum MDID {
    static var current: String { MDIDManager.shared.mdid() }

    @discardableResult
    static func replace(_ value: String) -> Bool {
        MDIDManager.shared.setMDID(value)
    }

    /// Preview a fresh random ADID without changing the stored identity.
    static func randomPreview() -> String {
        let charset = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        func block(_ count: Int) -> String {
            var bytes = [UInt8](repeating: 0, count: count)
            if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
                return String(bytes.map { charset[Int($0) % charset.count] })
            }
            return String((0..<count).map { _ in charset.randomElement()! })
        }
        return "AS-\(block(6))-\(block(2))"
    }
}
