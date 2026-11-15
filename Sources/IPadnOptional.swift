//
//  IPadnOptional.swift
//  Optional companion: mengangs/ipadn downloads owned / history / delisted
//  encrypted IPAs; TetherLess FairPlay-decrypts them (or Installed apps).
//  We do not vendor iPadn — link only (GPL-2.0).
//

import SwiftUI
import UIKit

enum IPadnOptional {
    static let defaultsKey = "tetherless.optional.ipadn.enabled"
    static let repoURL = URL(string: "https://github.com/mengangs/ipadn")!
    static let releasesURL = URL(string: "https://github.com/mengangs/ipadn/releases/latest")!
    static let altStoreSourceURL = URL(
        string: "https://raw.githubusercontent.com/mengangs/ipadn/main/altstore-source.json"
    )!

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static func openRepo() {
        UIApplication.shared.open(repoURL)
    }

    static func openReleases() {
        UIApplication.shared.open(releasesURL)
    }
}

/// Settings toggle — opt into iPadn as an encrypted-IPA downloader beside TetherLess.
struct IPadnOptionalCard: View {
    @AppStorage(IPadnOptional.defaultsKey) private var enabled = false

    var body: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iPadn (optional)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Open-source owned-app downloader (history versions, delisted, regional). Sign their unsigned IPA, download encrypted packages there, then FairPlay-decrypt here — or Decrypt from Library › Installed.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(TetherlessPalette.accent)

                if enabled {
                    HStack(spacing: 10) {
                        Button {
                            IPadnOptional.openReleases()
                        } label: {
                            Text("Get iPadn IPA")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(TetherlessPalette.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            IPadnOptional.openRepo()
                        } label: {
                            Text("GitHub")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.10), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    Text("SideStore / AltStore source: raw.githubusercontent.com/mengangs/ipadn/main/altstore-source.json — or Library › + after you share an encrypted IPA from iPadn into TetherLess.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Decrypt-tab tip when the optional iPadn path is enabled.
struct IPadnDecryptTipCard: View {
    @AppStorage(IPadnOptional.defaultsKey) private var enabled = false

    var body: some View {
        if enabled {
            GlassCard(corner: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.app.fill")
                            .foregroundStyle(TetherlessPalette.accent)
                        Text("iPadn → TetherLess")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                    Text("Use iPadn to pull owned / older / delisted encrypted IPAs when Store Access is stuck. Share the IPA into Library › Unsigned, install it, then Decrypt from Installed — FairPlay stays on this iPhone.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        IPadnOptional.openReleases()
                    } label: {
                        Text("Open iPadn releases")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(TetherlessPalette.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
