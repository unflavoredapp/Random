//
// Brand: Tetherless · https://tetherless.dev
//  TetherlessChrome.swift
//  Visual shell matching the TetherLess glassmorphism UI (purple→teal gradient,
//  glass cards, floating capsule tab bar). Tab information architecture follows
//  mengangs/ipadn: Search · Downloads · Purchased · Account (English labels).
//

import SwiftUI

// MARK: - Palette (matches reference screenshots)

enum TetherlessPalette {
    static let top = Color(red: 0.16, green: 0.12, blue: 0.40)
    static let mid = Color(red: 0.25, green: 0.38, blue: 0.62)
    static let bottom = Color(red: 0.33, green: 0.75, blue: 0.85)
    static let accent = Color(red: 0.27, green: 0.56, blue: 0.97)
    static let success = Color(red: 0.30, green: 0.80, blue: 0.40)
    static let accentHex = "458FF7"
}

struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [TetherlessPalette.top, TetherlessPalette.mid, TetherlessPalette.bottom],
            startPoint: .top, endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

struct GlassCard<Content: View>: View {
    var corner: CGFloat = 28
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            )
    }
}


extension View {
    /// Glass panel for Settings / Manage cards that already apply their own padding.
    func tetherlessGlassCard(cornerRadius: CGFloat = 22) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            )
    }
}

struct GlassPillRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(TetherlessPalette.accent.opacity(configuration.isPressed ? 0.7 : 1), in: Capsule())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(.white.opacity(configuration.isPressed ? 0.18 : 0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
    }
}

struct ScreenTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 40, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ScreenScroll<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                HStack(alignment: .center) {
                    ScreenTitle(text: title)
                    if let trailing { trailing }
                }
                .padding(.top, 12)
                .padding(.bottom, 4)
                content
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
    }
}

struct StatusRow: View {
    enum Kind { case ok, info, warning, busy }
    let kind: Kind
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                switch kind {
                case .ok: Image(systemName: "checkmark.seal.fill").foregroundStyle(TetherlessPalette.success)
                case .info: Image(systemName: "info.circle").foregroundStyle(.white.opacity(0.85))
                case .warning: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                case .busy: ProgressView().tint(TetherlessPalette.accent)
                }
            }
            .font(.title2)
            .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold)).foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
    }
}

// MARK: - Tabs (iPadn: Search · Downloads · Purchased · Account)

enum AppTab: Int, CaseIterable, Identifiable {
    case search, downloads, purchased, account
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .search: return "Search"
        case .downloads: return "Downloads"
        case .purchased: return "Purchased"
        case .account: return "Account"
        }
    }

    var symbol: String {
        switch self {
        case .search: return "magnifyingglass"
        case .downloads: return "arrow.down.circle.fill"
        case .purchased: return "bag.fill"
        case .account: return "person.crop.circle.fill"
        }
    }

    // Compatibility aliases for older call sites / deep links.
    static var decrypt: AppTab { .search }
    static var settings: AppTab { .account }
    static var pair: AppTab { .account }
    static var files: AppTab { .account }
    static var library: AppTab { .account }
}

/// Nested destinations under Account (TetherLess Pair / Files / Library / Settings).
enum AppAccountPush: String, Identifiable, Hashable {
    case pair, files, library, settings, installation
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pair: return "Pair"
        case .files: return "Files"
        case .library: return "Library"
        case .settings: return "Settings"
        case .installation: return "Installation settings"
        }
    }

    var symbol: String {
        switch self {
        case .pair: return "iphone.radiowaves.left.and.right"
        case .files: return "folder.fill"
        case .library: return "square.stack.3d.up.fill"
        case .settings: return "gearshape.fill"
        case .installation: return "wrench.and.screwdriver"
        }
    }
}

struct FloatingTabBar: View {
    @Binding var selection: AppTab
    var downloadBadge: Int = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = tab }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    VStack(spacing: 3) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: tab.symbol)
                                .font(.system(size: 18, weight: selection == tab ? .semibold : .regular))
                            if tab == .downloads, downloadBadge > 0 {
                                Text(downloadBadge > 9 ? "9+" : "\(downloadBadge)")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(TetherlessPalette.accent, in: Capsule())
                                    .offset(x: 10, y: -6)
                            }
                        }
                        Text(tab.label).font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(selection == tab ? TetherlessPalette.accent : .white.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}
