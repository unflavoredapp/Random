import SwiftUI
import UIKit

struct ASAppDetailSheet: View {
    let app: ASApp
    var onDownload: (ASApp, ASVersion?) -> Void
    var onSign: (ASApp, ASVersion?) -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("as.favorites") private var favoritesRaw: String = ""
    @State private var copied = false

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    // MARK: derived

    private var siteURL: URL? {
        let enc = app.bundleID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? app.bundleID
        return URL(string: "\(ASConfig.siteBase)/app/\(enc)")
    }

    private var hue: Double {
        guard let t = app.tint else { return 0.97 }
        let ui = UIColor(red: t.r, green: t.g, blue: t.b, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.2 || b < 0.15 { return 0.97 }
        return Double(h)
    }

    private var accent: Color { Color(hue: hue, saturation: 0.62, brightness: 1.0) }
    private var accentSoft: Color { Color(hue: hue, saturation: 0.36, brightness: 1.0) }

    private var isFavorite: Bool {
        favoritesRaw.split(separator: "\n").contains { String($0) == app.bundleID }
    }

    private func toggleFavorite() {
        var list = favoritesRaw.split(separator: "\n").map { String($0) }
        if let i = list.firstIndex(of: app.bundleID) { list.remove(at: i) } else { list.append(app.bundleID) }
        favoritesRaw = list.joined(separator: "\n")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func copyLink() {
        guard let u = siteURL else { return }
        UIPasteboard.general.string = u.absoluteString
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            copied = false
        }
    }

    private var updatedText: String {
        guard let d = app.versionDate else { return "-" }
        return Self.relative.localizedString(for: min(d, Date()), relativeTo: Date())
    }

    private var sizeText: String {
        app.size > 0 ? ByteCountFormatter.string(fromByteCount: app.size, countStyle: .file) : "-"
    }

    private var stats: [(String, String)] {
        [("Version", app.version.isEmpty ? "-" : "v\(app.version)"),
         ("Size", sizeText),
         ("Updated", updatedText),
         ("Downloads", app.downloads.map { String($0) } ?? "-"),
         ("Views", app.views.map { String($0) } ?? "-")]
    }

    // MARK: body

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        actionsRow
                        statsRow
                        screenshotsSection
                        descriptionSection
                        Color.clear.frame(height: 100)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                }
                .scrollIndicators(.hidden)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    }

    // MARK: pieces

    private var background: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.24, green: 0.18, blue: 0.66), location: 0.0),
                    .init(color: Color(red: 0.42, green: 0.17, blue: 0.71), location: 0.18),
                    .init(color: Color(hue: hue, saturation: 0.70, brightness: 0.48), location: 0.34),
                    .init(color: Color(hue: hue, saturation: 0.75, brightness: 0.28), location: 0.50),
                    .init(color: Color(hue: hue, saturation: 0.65, brightness: 0.14), location: 0.66),
                    .init(color: Color(red: 0.07, green: 0.045, blue: 0.06), location: 0.85),
                    .init(color: Color(red: 0.04, green: 0.03, blue: 0.045), location: 1.0)
                ],
                startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [Color(red: 0.12, green: 0.59, blue: 0.67).opacity(0.32), Color.clear],
                center: UnitPoint(x: 0.9, y: 0.52), startRadius: 0, endRadius: 260)
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        ZStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            HStack {
                Spacer()
                if let u = URL(string: ASConfig.siteBase) {
                    Link(destination: u) {
                        Text("airshare.lol")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 38)
                            .background(Capsule().fill(Color.black.opacity(0.45)))
                    }
                }
            }
            .padding(.trailing, 24)
        }
        .frame(height: 52)
        .padding(.top, 8)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ASIcon(url: app.iconURL, size: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundColor(accent)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                if !app.developer.isEmpty {
                    Text(app.developer)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white.opacity(0.82))
                        .lineLimit(1)
                }
                Text(app.bundleID)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(accentSoft)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
    }

    private func actionIcon(_ name: String, tint: Color = Color.white.opacity(0.92)) -> some View {
        Image(systemName: name)
            .font(.system(size: 22))
            .foregroundColor(tint)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private var actionsRow: some View {
        HStack(spacing: 6) {
            Spacer()
            Button { toggleFavorite() } label: {
                actionIcon(isFavorite ? "heart.fill" : "heart", tint: isFavorite ? accent : Color.white.opacity(0.92))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Favorite")

            if let u = siteURL {
                ShareLink(item: u) { actionIcon("square.and.arrow.up") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Share")
            }

            Button { copyLink() } label: {
                actionIcon(copied ? "checkmark" : "doc.on.doc", tint: copied ? accent : Color.white.opacity(0.92))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy link")

            Menu {
                if app.versions.count > 1 {
                    Section("Download version") {
                        ForEach(app.versions, id: \.self) { v in
                            Button("v\(v.version)") { onDownload(app, v) }
                        }
                    }
                }
                Button { onSign(app, nil) } label: {
                    Label("Sign latest", systemImage: "signature")
                }
                if let u = siteURL {
                    Link(destination: u) { Label("Open on airshare.lol", systemImage: "safari") }
                }
            } label: {
                actionIcon("gearshape.fill")
            }
            .accessibilityLabel("Options")
        }
    }

    private var statsRow: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, s in
                VStack(spacing: 4) {
                    Text(s.0)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.78))
                    Text(s.1)
                        .font(.system(size: 14.5, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var screenshotsSection: some View {
        if !app.screenshots.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Screenshots")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(accent)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(Array(app.screenshots.enumerated()), id: \.offset) { _, u in
                            AsyncImage(url: u) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else {
                                    Color.white.opacity(0.08)
                                }
                            }
                            .frame(width: 82, height: 176)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 1))
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(.top, 6)
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !app.desc.isEmpty {
                Text("Description")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(accent)
                Text(app.desc)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundColor(.white.opacity(0.92))
            }
            if !app.versionNotes.isEmpty && app.versionNotes != app.desc {
                Text("What's New")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(accent)
                    .padding(.top, 6)
                Text(app.versionNotes)
                    .font(.system(size: 15))
                    .lineSpacing(4)
                    .foregroundColor(.white.opacity(0.92))
            }
        }
        .padding(.top, 6)
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onDownload(app, nil)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 26, weight: .medium))
                    Text("Download")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(minWidth: 92, minHeight: 60)
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 1) {
                if ASConfig.showsBrandLine {
                    Text("MRZefv")
                        .font(.system(size: 13, weight: .heavy))
                        .tracking(0.6)
                        .foregroundColor(ASTheme.brand)
                }
                Text("Powered by")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.88))
                Text("airshare.lol")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(accent)
            }

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onSign(app, nil)
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "signature")
                        .font(.system(size: 26, weight: .medium))
                    Text("Sign")
                        .font(.system(size: 16, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(minWidth: 92, minHeight: 60)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(
            LinearGradient(colors: [Color.black.opacity(0.0), Color.black.opacity(0.88)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom))
    }
}
