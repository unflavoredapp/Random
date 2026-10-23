//
//  Components.swift
//

import SwiftUI
import UniformTypeIdentifiers

/// UIActivityViewController bridge (share a single file).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Export a folder (as a copy) into a user-chosen location in Files.
struct DirExporter: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
}

/// Floating glass title bar for app sections. Put it in `.safeAreaInset(edge: .top)`.
/// The theme controls live in Settings › Appearance; the title bar intentionally has no palette button.
/// `center` renders a centered subtitle (AirShare-style "57 Apps") behind the leading title.
struct TabTitleBar<Trailing: View>: View {
    let title: String
    var center: String? = nil            // second-row caption, e.g. "3 Apps"
    var custom: AnyView? = nil           // replaces the title text (e.g. Decrypt's bot picker)
    @ViewBuilder var trailing: Trailing
    var body: some View {
        VStack(spacing: 0) {
            // Row 1: palette · title (centered) · tab actions
            ZStack {
                if let custom {
                    custom.frame(maxWidth: .infinity).padding(.horizontal, 90)
                } else {
                    Text(title).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                        .frame(maxWidth: .infinity).padding(.horizontal, 90)
                }
                HStack(spacing: 10) {
                    ThemePaletteButton()
                    Spacer()
                    trailing
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            // Row 2: caption · account chip (ADID as guest, avatar + name when signed in)
            HStack(spacing: 8) {
                Text(center ?? "").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 6)
                AccountChip()
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(Color.white.opacity(0.04))
        }
        .floatingGlassBar(edge: .top, cornerRadius: 28)
    }
}

// MARK: - AirShare-style app row (shared by Library & Signed)

/// Tall row: 60pt icon · bold title · monospace version·bundle · status pill · ↗ action.
/// Edge-to-edge with a hairline divider — no bordered card.
struct AirShareRow: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    let icon: Data?
    let title: String
    let subtitle: String        // "1.0 • com.mrzefv.unzipdrop"
    let badge: String           // "Signed 2h ago" / "Downloaded"
    var badgeAccented: Bool = false      // tinted pill (AirShare uses it for TrollStore)
    var badgeSymbol: String? = nil       // SF Symbol shown before the badge text (e.g. lock.fill)
    var locked: Bool = false             // DRM: lock badge on the icon
    var updatePill: String? = nil        // "1.0 → 1.2": shown next to the badge when a newer version exists
    var busy: Bool = false
    var accent: Color = Color(red: 0.25, green: 0.55, blue: 1.0)
    let onAction: () -> Void
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            AirShareIcon(data: icon)
                .overlay(alignment: .bottomTrailing) {
                    if locked {
                        Image(systemName: "lock.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20).background(Circle().fill(Color.red))
                            .overlay(Circle().stroke(Color.black, lineWidth: 2)).offset(x: 5, y: 5)
                    }
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(subtitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.subtle).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        if let badgeSymbol { Image(systemName: badgeSymbol).font(.system(size: 10, weight: .bold)) }
                        Text(badge)
                    }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(badgeAccented ? accent : Theme.subtle)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(badgeAccented ? accent.opacity(0.14) : Color.white.opacity(0.06))
                        .overlay(Capsule().stroke(badgeAccented ? accent.opacity(0.32) : .clear, lineWidth: 1))
                        .clipShape(Capsule())
                    if let updatePill {
                        Text(updatePill).font(.system(size: 11, weight: .bold)).lineLimit(1)
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Color.orange.opacity(0.16))
                            .overlay(Capsule().stroke(Color.orange.opacity(0.5), lineWidth: 1))
                            .clipShape(Capsule())
                    }
                }
            }
            Spacer(minLength: 8)
            if busy { ProgressView().tint(accent) }
            else {
                Button(action: onAction) {
                    Image(systemName: "arrow.up.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(accent.opacity(0.95))
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// AirShare's relative wording: "Just now" · "5m ago" · "2h ago" · "3d ago" · short date.
func airshareRelative(_ date: Date) -> String {
    let diff = Int(Date().timeIntervalSince(date))
    if diff < 60 { return "Just now" }
    if diff < 3600 { return "\(diff / 60)m ago" }
    if diff < 86400 { return "\(diff / 3600)h ago" }
    if diff < 604800 { return "\(diff / 86400)d ago" }
    let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none
    return f.string(from: date)
}

struct AirShareIcon: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    let data: Data?
    var body: some View {
        Group {
            if let data, let img = UIImage(data: data) { Image(uiImage: img).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent.opacity(0.15)).overlay(Image(systemName: "app.fill").foregroundStyle(Theme.accent)) }
        }
        .frame(width: 60, height: 60).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// AirShare's exact Library/Signed row: 60pt SSMediaIconView · 18pt title ·
/// 13pt "version • bundle" · capsule origin/status pill · arrow.up.right.
/// Renders on the app's black background with a hairline divider between rows.
struct AirShareAppRow: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    let iconURL: URL?
    let title: String
    let subtitle: String        // "1.0 • com.mrzefv.unzipdrop"
    let pill: String            // "Downloaded" / "Signed 2h ago"
    var pillAccented: Bool = false
    var busy: Bool = false
    var accent: Color = SSTheme.tintColor
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            SSMediaIconView(url: iconURL, size: 60, cornerRadius: 14)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(subtitle).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.subtle).lineLimit(1).truncationMode(.middle)
                Text(pill).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(pillAccented ? accent : Theme.subtle)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(pillAccented ? accent.opacity(0.14) : Color.white.opacity(0.06))
                    .overlay(Capsule().stroke(pillAccented ? accent.opacity(0.32) : .clear, lineWidth: 1))
                    .clipShape(Capsule())
            }
            Spacer(minLength: 8)
            if busy { ProgressView().tint(accent) }
            else { Image(systemName: "arrow.up.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(accent.opacity(0.95)) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// AirShare search field — pill, no visible border.
struct AirShareSearchField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.subtle)
            TextField(placeholder, text: $text)
                .autocorrectionDisabled().textInputAutocapitalization(.never).foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Color.white.opacity(0.06)).clipShape(Capsule())
    }
}

struct TopBar: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox.fill").foregroundStyle(Theme.accent)
            Text("UNZIP DROP")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .kerning(1).foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .floatingGlassBar(edge: .top)
    }
}

/// Identifiable URL wrapper for .sheet(item:).
struct URLItem: Identifiable { let url: URL; var id: String { url.path } }
