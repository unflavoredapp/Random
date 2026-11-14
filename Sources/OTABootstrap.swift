import Foundation
import UIKit

/// Keeps the tetherless.dev public SSL pack installed so OTA works without a
/// Settings visit. Runs on launch and whenever the app becomes active.
enum OTABootstrap {
    private static var lastAttempt: Date?
    private static let minInterval: TimeInterval = 60
    private static let trustPromptKey = "uzd_ota_pack_ca_prompted"

    /// Force public mode and pull pack.json into the cache.
    @MainActor
    @discardableResult
    static func ensurePublicPack(force: Bool = false) async -> ZefvCert.Meta? {
        if !force, let last = lastAttempt, Date().timeIntervalSince(last) < minInterval {
            return ZefvCert.meta
        }
        lastAttempt = Date()
        ServerConfig.setCertMode("public")
        let meta = await ZefvCert.installPublicPack()
        if meta != nil {
            offerPackCATrustIfNeeded()
        }
        return meta
    }

    /// Share sheet for the pack CA trust profile when it isn't trusted yet.
    @MainActor
    static func offerPackCATrustIfNeeded(force: Bool = false) {
        guard !ZefvCert.isPackCATrusted() else { return }
        // Re-prompt at most once per install until the user trusts it (or clears defaults).
        if !force, UserDefaults.standard.bool(forKey: trustPromptKey) { return }
        guard let url = ZefvCert.writePackCATrustProfile() else { return }
        UserDefaults.standard.set(true, forKey: trustPromptKey)
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController?
            .present(av, animated: true)
    }

    /// Allow Settings to re-show the trust profile.
    @MainActor
    static func resetTrustPrompt() {
        UserDefaults.standard.set(false, forKey: trustPromptKey)
    }
}
