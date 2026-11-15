//
//  IPadnOptional.swift
//  In-app iPadn search + version history (vendored under Sources/IPadn, GPL-2.0).
//  Upstream: https://github.com/mengangs/ipadn
//

import SwiftUI
import UIKit

enum IPadnOptional {
    static let defaultsKey = "tetherless.optional.ipadn.enabled"
    static let countryKey = "tetherless.ipadn.searchCountry"
    static let platformKey = "tetherless.ipadn.searchPlatform"
    static let repoURL = URL(string: "https://github.com/mengangs/ipadn")!
    static let releasesURL = URL(string: "https://github.com/mengangs/ipadn/releases/latest")!

    /// Register once so first launch gets iPadn search on (seamless Decrypt).
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            defaultsKey: true,
            countryKey: "US",
            platformKey: IPadnPlatform.iOS.rawValue,
        ])
    }

    static var isEnabled: Bool {
        get {
            registerDefaults()
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    static func openRepo() {
        UIApplication.shared.open(repoURL)
    }

    static func openReleases() {
        UIApplication.shared.open(releasesURL)
    }
}

/// Settings card — iPadn powers Decrypt search / App ID / delisted stubs + version feeds.
struct IPadnOptionalCard: View {
    @AppStorage(IPadnOptional.defaultsKey) private var enabled = true
    @AppStorage(IPadnOptional.countryKey) private var country = "US"
    @AppStorage(IPadnOptional.platformKey) private var platform = IPadnPlatform.iOS.rawValue

    var body: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("iPadn Store search")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Decrypt search uses iPadn’s store lookup (name, App ID, store link, multi-region, delisted stubs) plus Timbrd/Bilin/iosdump version history. FairPlay still runs in TetherLess. Source: mengangs/ipadn (GPL-2.0).")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(TetherlessPalette.accent)

                if enabled {
                    HStack(spacing: 8) {
                        Picker("Region", selection: $country) {
                            ForEach(IPadnBrowserModel.countries, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(TetherlessPalette.accent)

                        Picker("Platform", selection: $platform) {
                            ForEach(IPadnPlatform.allCases.filter { $0 == .iOS || $0 == .iPadOS }) { p in
                                Text(p.title).tag(p.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(TetherlessPalette.accent)
                    }

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
        .onAppear { IPadnOptional.registerDefaults() }
    }
}
