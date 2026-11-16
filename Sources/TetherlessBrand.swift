//
//  TetherlessBrand.swift
//  Brand: Tetherless · https://tetherless.dev
//

import Foundation

/// Canonical product brand for Tetherless (site, ASCII mark, user-agent helpers).
nonisolated enum TetherlessBrand {
    static let name = "Tetherless"
    static let siteHost = "tetherless.dev"
    static let siteURL = URL(string: "https://tetherless.dev")!
    static let siteDisplay = "https://tetherless.dev"
    static let bundleID = "dev.tetherless.app"
    static let userAgent = "tetherless-ios"

    /// Figlet-style mark — keep this pure ASCII for logs, README, and About.
    static let ascii: String = #"""
 _____     _   _           _
|_   _|__ | |_| |__   ___ | | ___  ___ ___
  | |/ _ \| __| '_ \ / _ \| |/ _ \/ __/ __|
  | |  __/| |_| | | |  __/| |  __/\__ \__ \
  |_|\___| \__|_| |_|\___||_|\___||___/___/
"""#

    static var asciiBanner: String {
        "\(ascii)\n\(siteDisplay)\n"
    }

    /// One-line stamp for file headers / logs.
    static let stamp = "Brand: Tetherless · https://tetherless.dev"

    static func printBanner() {
        print(asciiBanner)
    }
}
