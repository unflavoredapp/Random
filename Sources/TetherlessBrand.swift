//
//  TetherlessBrand.swift
//  Brand: Tetherless · https://tetherless.dev
//

import Foundation
import SwiftUI
import UIKit

/// Canonical product brand for Tetherless (site, ASCII mark, user-agent helpers).
nonisolated enum TetherlessBrand {
    static let name = "Tetherless"
    static let siteHost = "tetherless.dev"
    static let siteURL = URL(string: "https://tetherless.dev")!
    static let siteDisplay = "https://tetherless.dev"
    static let bundleID = "dev.tetherless.app"
    static let userAgent = "tetherless-ios"
    /// Asset catalog name for the home-screen App Icon (also shipped as an imageset for in-app use).
    static let appIconAsset = "TetherlessAppIcon"

    /// Figlet-style mark — keep this pure ASCII for logs, README, and About.
    /// Spells T-e-t-h-e-r-l-e-s-s; tight letter spacing (~65 cols).
    static let ascii: String = #"""
_____           _     _                     _
|_   _|  ___   | |_  | |__    ___    _ __  | |  ___    ___   ___
  | |   / _ \  | __| | '_ \  / _ \  | '__| | | / _ \  / __| / __|
  | |   |  __/ | |_  | | | | |  __/ | |    | | |  __/ \__ \ \__ \
  |_|   \___|   \__| |_| |_| \___|  |_|    |_| \___|  |___/ |___/
"""#

    static var asciiBanner: String {
        "\(ascii)\n\(siteDisplay)\n"
    }

    /// One-line stamp for file headers / logs.
    static let stamp = "Brand: Tetherless · https://tetherless.dev"

    static func printBanner() {
        print(asciiBanner)
    }

    /// Marketing / About icon — same artwork as the App Store / home-screen icon.
    static func appIconImage() -> UIImage? {
        if let named = UIImage(named: appIconAsset) { return named }
        // Fallback when the imageset is missing from a thin build.
        if let url = Bundle.main.url(forResource: "TetherlessAppIcon", withExtension: "png"),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            return img
        }
        return UIImage(named: "airshare_mark") ?? UIImage(named: "aircore_logo")
    }
}

/// Squircle App Icon used in Settings About and branded chrome.
struct TetherlessAppIconView: View {
    var size: CGFloat = 52
    var cornerRadius: CGFloat? = nil

    private var radius: CGFloat { cornerRadius ?? size * 0.2237 }

    var body: some View {
        Group {
            if let image = TetherlessBrand.appIconImage() {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.45, green: 0.2, blue: 0.85), Color(red: 0.15, green: 0.75, blue: 0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        Image(systemName: "cable.connector")
                            .font(.system(size: size * 0.42, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityLabel(TetherlessBrand.name)
    }
}
