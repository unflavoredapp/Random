//
// Brand: Tetherless · https://tetherless.dev
//  DecryptMacRouting.swift
//  Optional server fallback: Companion / This Device → Decrypt site URL
//  (Linux VPS Phone Worker queue or legacy Mac unfairplay) instead of
//  on-device companion FairPlay.
//

import Foundation

/// When enabled, routes Get / companion / “This Device” decrypt through the
/// Decrypt site URL (`as_site_base` → Linux/Mac HTTPS API) instead of the
/// development-cert companion on this iPhone.
enum DecryptMacRouting {
    static let macOnlyKey = "tetherless.decrypt.macOnly"

    /// Default OFF — stock iPhone uses development-cert companion FairPlay.
    /// Opt in only to force every job onto Decrypt site URL (Linux VPS / Mac).
    static var macOnly: Bool {
        get {
            if UserDefaults.standard.object(forKey: macOnlyKey) == nil { return false }
            return UserDefaults.standard.bool(forKey: macOnlyKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: macOnlyKey) }
    }

    /// Site root used for server decrypt (same as `DecryptClient.siteBase`).
    static var macSiteConfigured: Bool {
        let raw = (UserDefaults.standard.string(forKey: "as_site_base") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !raw.isEmpty
    }

    @MainActor
    static func startMacDecrypt(storeURL: String, version: String?, displayName: String) {
        let url = storeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error =
                "Server decrypt needs an App Store link. Set Decrypt site URL under FairPlay Decrypt."
            DecryptClient.shared.message = DecryptClient.shared.error ?? ""
            return
        }
        if AppleSystemAppGate.isBlocked(bundleID: nil, storeURL: url) {
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = AppleSystemAppGate.userMessage
            DecryptClient.shared.message = AppleSystemAppGate.userMessage
            DecryptClient.shared.finishedName = name.isEmpty ? "App" : name
            return
        }
        if !macSiteConfigured {
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error =
                "Set Decrypt site URL under Account › FairPlay Decrypt (Linux VPS API or Mac host)."
            DecryptClient.shared.message = DecryptClient.shared.error ?? ""
            return
        }
        // Do NOT set .queued before start() — DecryptClient.start guards on busy
        // (queued/running/downloading) and would no-op, leaving the UI stuck forever.
        if DecryptClient.shared.busy {
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = "Already decrypting — wait for the current server job to finish."
            DecryptClient.shared.message = DecryptClient.shared.error ?? ""
            return
        }
        DecryptClient.shared.error = nil
        DecryptClient.shared.finishedName = name.isEmpty ? "App" : name
        DecryptClient.shared.start(
            url: url,
            version: version?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            display: name.isEmpty ? "App" : name
        )
        if DecryptClient.shared.busy {
            DecryptClient.shared.message = "Decrypting on server…"
        }
    }

    /// Same as `startMacDecrypt`, then wait until DecryptClient reaches a terminal phase.
    @MainActor
    static func startMacDecryptAndWait(storeURL: String, version: String?, displayName: String) async {
        startMacDecrypt(storeURL: storeURL, version: version, displayName: displayName)
        while true {
            switch DecryptClient.shared.phase {
            case .done, .failed, .handedOff, .idle:
                return
            case .queued, .running, .downloading:
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
