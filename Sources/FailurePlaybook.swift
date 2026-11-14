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
            summary: "Apple returned no package. Usually Client-Info rewrite fighting anisette — turn rewrite off and retry.",
            matches: ["http 204", "204", "empty response"],
            actionTitle: "Turn off Client-Info rewrite",
            action: .turnOffClientInfoRewrite
        ),
        FailurePlay(
            id: "403",
            title: "Store rejected client identity (HTTP 403)",
            summary: "Apple blocked the silent store request. Usually spoof advertising iOS 99 / exotic headers — switch to This iPhone or Newest IPA, then re-auth Store Access.",
            matches: ["http 403", "403", "client identity"],
            actionTitle: "Use This iPhone spoof",
            action: .turnOffClientInfoRewrite
        ),
        FailurePlay(
            id: "404",
            title: "Package not found (HTTP 404)",
            summary: "CDN or version pin missed. Match this iPhone’s spoof, clear a bad externalVersionId, and retry.",
            matches: ["http 404", "404", "not found"],
            actionTitle: "Match this iPhone spoof",
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
            summary: "iOS never stored Media & Purchases keys for this Apple ID. Sign in once in the App Store, then acknowledge.",
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
            var spoof = StoreDeviceSpoof.current
            spoof.rewriteClientInfo = false
            spoof.sanitizeAbsurdIOSClaim()
            let profiles = StoreSpoofProfile.builtIn(realModel: StoreDeviceSpoof.realModelIdentifier())
            // Prefer a safe preset when recovering from 403/404.
            if let match = profiles.first(where: { $0.id == "device" }) {
                spoof.apply(match)
            }
            StoreDeviceSpoof.current = spoof
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
