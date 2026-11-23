//
// Brand: Tetherless · https://tetherless.dev
//  AppleSystemAppGate.swift
//  Refuse Apple first-party / system App Store titles (TestFlight, App Store, …)
//  before Store SAP / Mac unfairplay — they are not decryptable third-party apps.
//

import Foundation

enum AppleSystemAppGate {
    /// Known adam IDs that match the Telegram bot refusal list.
    private static let blockedAdams: Set<String> = [
        "899247664", // TestFlight
        "1231336508", // Apple Store
        "1146562112", // Apple TV
    ]

    static func adamId(fromStoreURL url: String) -> String? {
        guard let r = url.range(of: #"/id(\d+)"#, options: .regularExpression) else { return nil }
        let digits = String(url[r]).filter(\.isNumber)
        return digits.isEmpty ? nil : digits
    }

    static func isBlocked(bundleID: String?, storeURL: String?, adamId: String? = nil) -> Bool {
        let bid = (bundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if bid.hasPrefix("com.apple.") { return true }
        if let adam = (adamId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
           blockedAdams.contains(adam) {
            return true
        }
        if let fromURL = Self.adamId(fromStoreURL: storeURL ?? ""), blockedAdams.contains(fromURL) {
            return true
        }
        return false
    }

#if !DECRYPT_HELPER
    static func isBlocked(_ app: DecryptApp) -> Bool {
        let adamFromId: String? = {
            // ids look like "itunes-899247664-us" or "owned-899247664"
            let parts = app.id.split(separator: "-").map(String.init)
            if let hit = parts.first(where: { $0.count >= 8 && $0.allSatisfy(\.isNumber) }) {
                return hit
            }
            return nil
        }()
        return isBlocked(bundleID: app.bundle, storeURL: app.url, adamId: adamFromId)
    }
#endif

    static var userMessage: String {
        "Apple system apps (TestFlight, App Store, …) can’t be decrypted. Pick a third-party App Store title."
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
