//
// Brand: Tetherless · https://tetherless.dev
//  IPadnStoreProofStore.swift
//  Derived from mengangs/ipadn KeychainStore StoreProofRecord / StoreProofStore (GPL-2.0).
//  Persists WASM ADI store-proof state per device GUID.
//

import Foundation
import Security

struct IPadnStoreProofRecord: Codable, Equatable, Sendable {
    var identifier: String
    var files: [String: String]
    var updatedAt: Date = Date()
}

enum IPadnStoreProofStore {
    private static let maxEntries = 8
    private static var service: String {
        (Bundle.main.bundleIdentifier ?? "tetherless") + ".storeproof"
    }

    private static func query() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "store-proof-v1"
        ]
    }

    static func load() -> [String: IPadnStoreProofRecord] {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let decoded = try? JSONDecoder().decode([String: IPadnStoreProofRecord].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func save(_ records: [String: IPadnStoreProofRecord]) {
        let trimmed: [String: IPadnStoreProofRecord]
        if records.count > maxEntries {
            let kept = records.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(maxEntries)
            trimmed = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        } else {
            trimmed = records
        }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query()
            attributes.forEach { item[$0.key] = $0.value }
            _ = SecItemAdd(item as CFDictionary, nil)
        }
    }
}
