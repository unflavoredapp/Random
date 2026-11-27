//
//  TetherlessBrand.swift
//  Brand: AppAssassin · https://fastdecrypt.ai
//  (Type name kept for call-site stability; product brand is AppAssassin.)
//

import Foundation
import UIKit
#if !DECRYPT_HELPER
import SwiftUI
#endif

/// Canonical product brand for AppAssassin (site, ASCII mark, user-agent helpers).
nonisolated enum TetherlessBrand {
    static let name = "AppAssassin"
    /// Marketing / XPC product home (hand-rolled service: software.decrypt.xpc).
    static let decryptSoftwareHost = "decrypt.software"
    static let decryptSoftwareURL = URL(string: "https://decrypt.software")!
    static let decryptSoftwareXPCService = "software.decrypt.xpc"
    static let siteHost = "decrypt.software"
    static let siteURL = URL(string: "https://decrypt.software")!
    static let siteDisplay = "https://decrypt.software"
    /// Home-screen / signing bundle id (lowercase reverse-DNS).
    static let bundleID = "bot.fastdecrypt.ai"
    static let appGroup = "group.bot.fastdecrypt.ai"
    static let userAgent = "appassassin-ios"
    /// Asset catalog name for the home-screen App Icon (also shipped as an imageset for in-app use).
    static let appIconAsset = "AppAssassinAppIcon"

    /// Figlet-style mark — pure ASCII for logs, README, and About.
    static let ascii: String = #"""
    _                  _                _
   / \   _ __  _ __   / \   ___ ___  ___| |__   ___
  / _ \ | '_ \| '_ \ / _ \ / __/ __|/ _ \ '_ \ / _ \
 / ___ \| |_) | |_) / ___ \\__ \__ \  __/ |_) | (_) |
/_/   \_\ .__/| .__/_/   \_\___/___/\___|_.__/ \___/
        |_|   |_|
"""#

    static var asciiBanner: String {
        "\(ascii)\n\(siteDisplay)\n"
    }

    /// One-line stamp for file headers / logs.
    static let stamp = "Brand: AppAssassin · https://decrypt.software"
    static let xpcStamp = "Brand: decrypt.software · XPC \(decryptSoftwareXPCService)"

    static func printBanner() {
        print(asciiBanner)
    }

    /// Marketing / About icon — same artwork as the App Store / home-screen icon.
    static func appIconImage() -> UIImage? {
        if let named = UIImage(named: appIconAsset) { return named }
        if let named = UIImage(named: "TetherlessAppIcon") { return named }
        if let url = Bundle.main.url(forResource: "AppAssassinAppIcon", withExtension: "png"),
           let data = try? Data(contentsOf: url),
           let img = UIImage(data: data) {
            return img
        }
        return UIImage(named: "fastdecrypt_logo") ?? UIImage(named: "airshare_mark")
    }
}

#if !DECRYPT_HELPER
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
                            colors: [
                                Color(red: 1.0, green: 0.45, blue: 0.1),
                                Color(red: 0.85, green: 0.25, blue: 0.05),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        Text("A")
                            .font(.system(size: size * 0.48, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityLabel(TetherlessBrand.name)
    }
}
#endif
