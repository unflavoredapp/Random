//
// Brand: Tetherless · https://tetherless.dev
//  FailurePlaybook.swift
//  Map store/portal/FairPlay failures to one-tap fixes.
//

import Foundation
import SwiftUI

struct FailurePlay: Identifiable, Equatable {
    let id: String
    let title: String
    let summary: String
    let matches: [String]
    let actionTitle: String
    let action: PlayAction

    enum PlayAction: Equatable {
        case openAppStoreSignIn
        case reauthStore
        case refreshPortal
        case turnOffClientInfoRewrite
        case openPair
        case openLibrary
        case openStoreAccess
        case acknowledgeFairPlay
        case refreshAll
    }
}

@MainActor
enum FailurePlaybook {
    static let plays: [FailurePlay] = [
        FailurePlay(
            id: "204",
            title: "Empty store response (HTTP 204)",
            summary: "Apple returned no package. Sign in again under Account, then retry Get / Download.",
            matches: ["http 204", "204", "empty response"],
            actionTitle: "Open Account",
            action: .openStoreAccess
        ),
        FailurePlay(
            id: "403",
            title: "Store rejected the download (HTTP 403)",
            summary: "Apple blocked the download request. Sign in again under Account. If the app is already on this iPhone, Decrypt from Library / Installed.",
            matches: ["http 403", "403", "client identity"],
            actionTitle: "Open Account",
            action: .openStoreAccess
        ),
        FailurePlay(
            id: "404",
            title: "Package not found (HTTP 404)",
            summary: "CDN or version pin missed. Sign in under Account and retry the download, or pick another build.",
            matches: ["http 404", "404", "not found"],
            actionTitle: "Open Account",
            action: .openStoreAccess
        ),
        FailurePlay(
            id: "1100",
            title: "Developer Portal session expired (1100)",
            summary: "GrandSlam cookie went stale. Refresh the Apple ID signing session so Create cert / Refresh Portal works again.",
            matches: ["1100", "session expired", "grandslam", "portal session"],
            actionTitle: "Refresh portal session",
            action: .refreshPortal
        ),
        FailurePlay(
            id: "9610",
            title: "Store auth rejected (9610)",
            summary: "passwordToken went stale. Tap to silently remint the Store session from your saved Apple ID — you stay signed in.",
            matches: ["9610", "passwordtoken", "storefront"],
            actionTitle: "Refresh Store session",
            action: .reauthStore
        ),
        FailurePlay(
            id: "fairplay-eperm",
            title: "FairPlay needs live install or stamped IPA",
            summary: "Companion hit EPERM on EmbeddedPayload. Install this app from the App Store (same Apple ID), re-run Get so the encrypted IPA is stamped/bundled, then open Tetherless Decrypt again.",
            matches: [
                "eperm",
                "embeddedpayload",
                "no live install",
                "stamped ipa",
                "live path is stamped",
                "operation not permitted",
            ],
            actionTitle: "Capture FairPlay keys",
            action: .openAppStoreSignIn
        ),
        FailurePlay(
            id: "fairplay-macho",
            title: "No Mach-O binaries found",
            summary: "Couldn’t see executables in the live install (common for Flutter apps like Cake Wallet). Sign in under Account, tap Get so the Store IPA embeds EncryptedSource.ipa into Tetherless Decrypt, delete any old companion, then retry.",
            matches: ["no mach-o binaries found", "no mach-o", "no mach-os"],
            actionTitle: "Open Account",
            action: .openAppStoreSignIn
        ),
        FailurePlay(
            id: "fairplay-gate",
            title: "App Store Media & Purchases sign-in needed",
            summary: "Capture FairPlay keys once: open App Store / Media & Purchases with the same Apple ID, return here, confirm, then retry the download.",
            matches: [
                "before silent download",
                "before companion decrypt",
                "capture fairplay keys",
                "get fairplay keys",
                "i’ve signed in on this iphone",
                "i've signed in on this iphone",
                "media & purchases",
                "confirming fairplay keys",
                "fairplay keys ready",
                "never stored media",
            ],
            actionTitle: "Capture FairPlay keys",
            action: .openAppStoreSignIn
        ),
        FailurePlay(
            id: "cryptid",
            title: "FairPlay still encrypted (cryptid)",
            summary: "Required Mach-Os still report cryptid ≠ 0 after decrypt. Confirm FairPlay keys for this Apple ID, install the app from the App Store if needed, then retry Get.",
            matches: ["cryptid", "still encrypted", "decryption keys", "full ipa decrypt left"],
            actionTitle: "Capture FairPlay keys",
            action: .openAppStoreSignIn
        ),
        FailurePlay(
            id: "pair",
            title: "Native install / pairing dropped",
            summary: "VPN or pairing died (common after re-signing TetherLess). Re-pair or let Install Autopilot fall back to OTA.",
            matches: ["pair", "lockdownd", "vpn", "tunnel", "idevice"],
            actionTitle: "Open Pair",
            action: .openPair
        ),
    ]

    static func match(errorText: String?) -> FailurePlay? {
        guard let raw = errorText?.lowercased(), !raw.isEmpty else { return nil }
        return plays.first { play in
            play.matches.contains { raw.contains($0) }
        }
    }

    static func run(_ play: FailurePlay) async {
        switch play.action {
        case .openAppStoreSignIn:
            // Clear stale ack and open the capture sheet → App Store / Media & Purchases.
            AppStoreDecryptGuide.setAcknowledged(false, email: AppleIDStore.shared.email)
            FairPlayKeysFetcher.shared.presentCaptureSheet()
            FairPlayKeysFetcher.shared.startFetchFromSession()
        case .acknowledgeFairPlay:
            let email = AppleIDStore.shared.email
            if email.isEmpty {
                // Can't key the FairPlay ack without an Apple ID — send them to Account first.
                AppNav.shared.goAccount()
                return
            }
            FairPlayKeysFetcher.shared.presentCaptureSheet()
            FairPlayKeysFetcher.shared.markGrabbedManually()
        case .reauthStore:
            // Silent remint — do not wipe the account or force a full login.
            // Dead passwordTokens are reminted from the saved Keychain password.
            do {
                AppleIDStore.shared.invalidateStorefrontSession()
                _ = try await AppleIDStore.shared.ensureStorefrontSession(forceRefresh: true)
            } catch {
                // Only escalate to Account if remint itself failed (missing password / 2FA).
                AppNav.shared.goAccount()
            }
        case .refreshPortal:
            do {
                _ = try await AppleIDStore.shared.refreshPortalSession()
            } catch {
                AppNav.shared.goSettings()
            }
        case .turnOffClientInfoRewrite:
            AppNav.shared.goAccount()
        case .openPair:
            AppNav.shared.goPair()
        case .openLibrary:
            AppNav.shared.goLibrary()
        case .openStoreAccess:
            AppNav.shared.goAccount()
        case .refreshAll:
            SideloadSurvival.refreshAllWithKeepAlive()
        }
    }
}

struct FailurePlaybookCard: View {
    let errorText: String?
    @State private var status: String?

    var body: some View {
        if let play = FailurePlaybook.match(errorText: errorText) {
            GlassCard(corner: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(play.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(play.summary)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task {
                            await FailurePlaybook.run(play)
                            status = "Applied: \(play.actionTitle)"
                        }
                    } label: {
                        Text(play.actionTitle)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(TetherlessPalette.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    if let status {
                        Text(status).font(.caption2).foregroundStyle(TetherlessPalette.accent)
                    }
                }
            }
        }
    }
}
