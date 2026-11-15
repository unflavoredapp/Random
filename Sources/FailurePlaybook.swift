//
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
            summary: "Apple returned no package. Remint Store Access with a fresh anisette session — stay on real-device identity (no Store spoof).",
            matches: ["http 204", "204", "empty response"],
            actionTitle: "Remint Store Access",
            action: .turnOffClientInfoRewrite
        ),
        FailurePlay(
            id: "403",
            title: "Store rejected client identity (HTTP 403)",
            summary: "Apple blocked the silent store request. Store spoof is disabled — we remint + rotate anisette, then fall back to backend encrypted-IPA fetch. Or enable optional iPadn (Settings) to download owned/history IPAs and Decrypt from Installed.",
            matches: ["http 403", "403", "client identity"],
            actionTitle: "Remint Store Access",
            action: .turnOffClientInfoRewrite
        ),
        FailurePlay(
            id: "404",
            title: "Package not found (HTTP 404)",
            summary: "CDN or version pin missed. Remint Store Access and retry the download.",
            matches: ["http 404", "404", "not found"],
            actionTitle: "Remint Store Access",
            action: .turnOffClientInfoRewrite
        ),
        FailurePlay(
            id: "1100",
            title: "Developer Portal session expired (1100)",
            summary: "GrandSlam cookie went stale. Re-auth Store Access so Create cert / Refresh Portal works again.",
            matches: ["1100", "session expired", "grandslam", "portal session"],
            actionTitle: "Refresh portal session",
            action: .refreshPortal
        ),
        FailurePlay(
            id: "9610",
            title: "Store auth rejected (9610)",
            summary: "passwordToken / storefront session invalid. Sign in again under Store Access.",
            matches: ["9610", "passwordtoken", "storefront"],
            actionTitle: "Re-auth Store Access",
            action: .reauthStore
        ),
        FailurePlay(
            id: "cryptid",
            title: "FairPlay still encrypted (cryptid)",
            summary: "iOS never stored Media & Purchases keys for this Apple ID. Sign in once in the App Store (Media & Purchases), then tap I’ve signed in on this iPhone.",
            matches: ["cryptid", "fairplay", "still encrypted", "decryption keys", "media & purchases"],
            actionTitle: "Open App Store sign-in",
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
            // Force the Decrypt ack sheet again after a real Media & Purchases sign-in.
            AppStoreDecryptGuide.setAcknowledged(false, email: AppleIDStore.shared.email)
            AppStoreDecryptGuide.openAppStore()
        case .acknowledgeFairPlay:
            AppStoreDecryptGuide.setAcknowledged(true, email: AppleIDStore.shared.email)
        case .reauthStore:
            AppNav.shared.go(AppTab.settings.rawValue)
            do {
                _ = try await AppleIDStore.shared.ensureStorefrontSession()
            } catch {
                // User may need to re-enter password / 2FA in Store Access UI.
            }
        case .refreshPortal:
            do {
                _ = try await AppleIDStore.shared.refreshPortalSession()
            } catch {
                AppNav.shared.go(AppTab.settings.rawValue)
            }
        case .turnOffClientInfoRewrite:
            StoreDeviceSpoof.clearPersistedSpoof()
            await AppleIDStore.shared.requestStoreVerificationPrompt()
        case .openPair:
            AppNav.shared.go(AppTab.pair.rawValue)
        case .openStoreAccess:
            AppNav.shared.go(AppTab.settings.rawValue)
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
