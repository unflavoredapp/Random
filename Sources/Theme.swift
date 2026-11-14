//
//  Theme.swift
//  Adaptive palette. Every color is computed from AppTheme's persisted state
//  (accent hex + dark/light) so a theme change re-skins the whole app.
//

import SwiftUI

nonisolated enum Theme {
    static let keyAccent     = "theme_accent_hex"
    static let keyDark       = "theme_dark"
    static let keyBackground = "theme_background"
    /// Tetherless blue — matches the purple→teal glass UI.
    static let defaultAccent = "458FF7"

    static var isDark: Bool {
        UserDefaults.standard.object(forKey: keyDark) == nil ? true : UserDefaults.standard.bool(forKey: keyDark)
    }
    static var accentHex: String {
        let h = UserDefaults.standard.string(forKey: keyAccent) ?? ""
        return h.isEmpty ? defaultAccent : h
    }

    /// Clear so the root AppBackground gradient shows through every tab.
    static var bg: Color     { .clear }
    static var card: Color   { Color.white.opacity(isDark ? 0.10 : 0.92) }
    static var stroke: Color { Color.white.opacity(isDark ? 0.15 : 0.12) }
    static var text: Color   { isDark ? Color.white : Color(red: 0.08, green: 0.09, blue: 0.10) }
    static var subtle: Color { isDark ? Color.white.opacity(0.55) : Color(red: 0.42, green: 0.46, blue: 0.49) }
    static var accent: Color { Color(hex: accentHex) }

    static let appName    = "Tetherless"
    static let appVersion = "3.7"
    /// Version of the local signing engine, shown under the ADID in Settings.
    static let trustCoreVersion = "1.6"
    static let owner      = "ᴍƦᴢᴇꜰΛ · mrzefv.com"
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }
}
