//
// Brand: Tetherless · https://tetherless.dev
//  DecryptMacRouting.swift
//  Companion / This Device → Mac Decrypt site URL only (unfairplay on MacDuty).
//

import Foundation

/// Routes Get / companion / “This Device” decrypt through the Mac host API
/// (`as_site_base` → Mac HTTPS / Cloudflare) instead of on-device FairPlay.
enum DecryptMacRouting {
    static let macOnlyKey = "tetherless.decrypt.macOnly"

    /// Default ON — no on-device companion FairPlay; jobs hit Decrypt site URL (your Mac).
    static var macOnly: Bool {
        get {
            if UserDefaults.standard.object(forKey: macOnlyKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: macOnlyKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: macOnlyKey) }
    }

    /// Site root used for Mac decrypt (same as `DecryptClient.siteBase`).
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
            DecryptClient.shared.error = "Mac decrypt needs an App Store link. Set Decrypt site URL to your Mac."
            DecryptClient.shared.message = DecryptClient.shared.error ?? ""
            return
        }
        if !macSiteConfigured {
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error =
                "Set Mac API URL under Account › FairPlay Decrypt (run: zsh ~/tetherless/server/mac-ssh.sh api)."
            DecryptClient.shared.message = DecryptClient.shared.error ?? ""
            return
        }
        // Do NOT set .queued before start() — DecryptClient.start guards on busy
        // (queued/running/downloading) and would no-op, leaving the UI stuck forever.
        if DecryptClient.shared.busy {
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = "Already decrypting — wait for the current Mac job to finish."
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
            DecryptClient.shared.message = "Decrypting on Mac…"
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
