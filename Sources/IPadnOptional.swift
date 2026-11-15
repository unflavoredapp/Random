//
//  IPadnOptional.swift
//  Optional in-app iPadn search (vendored logic under Sources/IPadn, GPL-2.0).
//  Upstream: https://github.com/mengangs/ipadn
//

import SwiftUI
import UIKit

enum IPadnOptional {
    static let defaultsKey = "tetherless.optional.ipadn.enabled"
    static let repoURL = URL(string: "https://github.com/mengangs/ipadn")!
    static let releasesURL = URL(string: "https://github.com/mengangs/ipadn/releases/latest")!

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

/// Settings toggle — enables in-app iPadn search on the Decrypt tab.
struct IPadnOptionalCard: View {
    @AppStorage(IPadnOptional.defaultsKey) private var enabled = false

    var body: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iPadn search (optional)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Uses iPadn’s store search in TetherLess (multi-region, App ID, delisted stubs). Decrypt still runs FairPlay here. Source: mengangs/ipadn (GPL-2.0).")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(TetherlessPalette.accent)

                if enabled {
                    Text("Open Decrypt — the iPadn Search card appears under This Device. You can still install the standalone iPadn IPA for history downloads.")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button {
                            AppNav.shared.go(AppTab.decrypt.rawValue)
                        } label: {
                            Text("Open Decrypt")
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
                            Text("Source")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.10), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

