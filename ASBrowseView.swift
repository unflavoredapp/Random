import SwiftUI

// MARK: - Backdrop (black, faint star dots, thin red side rails like airshare.lol)

nonisolated struct ASDot: Sendable {
    var x: Double
    var y: Double
    var r: Double
    var a: Double
}

nonisolated enum ASDots {
    static let all: [ASDot] = {
        var seed: UInt64 = 7
        var out: [ASDot] = []
        for _ in 0..<80 {
            var vals: [Double] = []
            for _ in 0..<4 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                vals.append(Double((seed >> 33) & 0xFFFFFF) / Double(0xFFFFFF))
            }
            out.append(ASDot(x: vals[0], y: vals[1], r: 0.7 + vals[2] * 1.1, a: 0.07 + vals[3] * 0.2))
        }
        return out
    }()
}

struct ASBackdrop: View {
    var body: some View {
        ZStack {
            Color.black
            Canvas { ctx, size in
                for d in ASDots.all {
                    let rect = CGRect(x: d.x * size.width, y: d.y * size.height, width: d.r * 2, height: d.r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(Color.white.opacity(d.a)))
                }
            }
            HStack {
                Rectangle().fill(ASTheme.red.opacity(0.9)).frame(width: 1.5)
                Spacer()
                Rectangle().fill(ASTheme.red.opacity(0.9)).frame(width: 1.5)
            }
            .padding(.horizontal, 5)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Shared icon view

struct ASIcon: View {
    let url: URL?
    let size: CGFloat
    var tint: ASRGB? = nil
    var border: Bool = false

    var body: some View {
        let radius = size * 0.23
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Color(white: 0.14)
                    Image(systemName: "app.dashed")
                        .font(.system(size: size * 0.4))
                        .foregroundColor(.white.opacity(0.35))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(border ? tintColor.opacity(0.85) : Color.white.opacity(0.1), lineWidth: border ? 1.2 : 1)
        )
    }

    private var tintColor: Color {
        guard let t = tint else { return ASTheme.brand }
        return Color(red: t.r, green: t.g, blue: t.b)
    }
}

// MARK: - Browse

struct ASBrowseView: View {
    /// Hook these to your own download / sign pipeline. When nil, the download URL is opened.
    var onDownload: ((ASApp, ASVersion?) -> Void)? = nil
    var onSign: ((ASApp, ASVersion?) -> Void)? = nil

    @StateObject private var store = ASFeedStore()
    @State private var category: ASCategory = .all
    @State private var selected: ASApp?
    @Environment(\.openURL) private var openURL

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    private var visibleApps: [ASApp] {
        category == .all ? store.apps : store.apps.filter { $0.categories.contains(category) }
    }

    var body: some View {
        ZStack {
            ASBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !store.news.isEmpty {
                        sectionTitle("NEWS")
                        newsRail
                    }
                    chips
                    if category == .all && !store.picks.isEmpty {
                        staffHeader
                        picksRail
                    }
                    gridSection
                    Color.clear.frame(height: 120)
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
            }
            .scrollIndicators(.hidden)
            .refreshable { await store.refresh() }
        }
        .sheet(item: $selected) { app in
            ASAppDetailSheet(
                app: app,
                onDownload: { a, v in handleDownload(a, v) },
                onSign: { a, v in handleSign(a, v) })
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
        }
    }

    // MARK: actions

    private func handleDownload(_ app: ASApp, _ v: ASVersion?) {
        if let cb = onDownload { cb(app, v); return }
        if let u = v?.downloadURL ?? app.downloadURL { openURL(u) }
    }

    private func handleSign(_ app: ASApp, _ v: ASVersion?) {
        if let cb = onSign { cb(app, v); return }
        if let u = v?.downloadURL ?? app.downloadURL { openURL(u) }
    }

    private func openNews(_ n: ASNews) {
        if let id = n.appID, let a = store.app(forBundle: id) {
            selected = a
        } else if let u = n.url {
            openURL(u)
        }
    }

    // MARK: headings

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 18, weight: .heavy))
            .tracking(4)
            .foregroundColor(ASTheme.grey)
            .padding(.leading, 2)
    }

    private var staffHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "star.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(ASTheme.red)
            Text("STAFF PICKS")
                .font(.system(size: 20, weight: .heavy))
                .tracking(5)
                .foregroundColor(ASTheme.grey)
        }
        .padding(.top, 8)
        .padding(.leading, 2)
    }

    // MARK: news

    private var newsRail: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(store.news) { n in newsCard(n) }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func newsCard(_ n: ASNews) -> some View {
        Button { openNews(n) } label: {
            ZStack(alignment: .bottomLeading) {
                newsBackground(n)
                LinearGradient(colors: [Color.black.opacity(0.0), Color.black.opacity(0.8)],
                               startPoint: .top, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 3) {
                    Text(n.title)
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if !n.caption.isEmpty {
                        Text(n.caption)
                            .font(.system(size: 11.5))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(12)
                .frame(width: 262, alignment: .leading)
            }
            .frame(width: 262, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(ASTheme.red.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func newsBackground(_ n: ASNews) -> some View {
        let t = n.tint.map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? ASTheme.red
        AsyncImage(url: n.imageURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                LinearGradient(colors: [t.opacity(0.7), Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .frame(width: 262, height: 104)
        .clipped()
    }

    // MARK: chips

    private var chips: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(ASCategory.allCases) { c in chip(c) }
        }
    }

    @ViewBuilder
    private func chipIcon(_ c: ASCategory) -> some View {
        if c == .paid {
            Text("$").font(.system(size: 14, weight: .heavy)).foregroundColor(.white)
        } else {
            Image(systemName: c.icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(c == .all ? ASTheme.red : .white)
        }
    }

    private func chip(_ c: ASCategory) -> some View {
        let on = category == c
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { category = c }
        } label: {
            HStack(spacing: 7) {
                chipIcon(c)
                Text(c.title)
                    .font(.system(size: 12.5, weight: .heavy))
                    .tracking(1.6)
                    .foregroundColor(.white)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(on ? ASTheme.red.opacity(0.16) : Color(white: 0.07)))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(on ? ASTheme.red : Color.white.opacity(0.13), lineWidth: on ? 1.4 : 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: staff picks

    private var picksRail: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(store.picks) { a in pickCard(a) }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func pickCard(_ a: ASApp) -> some View {
        Button { selected = a } label: {
            HStack(spacing: 12) {
                ASIcon(url: a.iconURL, size: 52, tint: a.tint, border: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.name)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(a.desc)
                        .font(.system(size: 11.5))
                        .foregroundColor(ASTheme.grey)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 262, height: 88)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.19, green: 0.05, blue: 0.09),
                                                  Color(red: 0.10, green: 0.03, blue: 0.06)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(alignment: .topTrailing) {
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(ASTheme.red)
                    .padding(11)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(ASTheme.red.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: grid (two apps per row, no screenshots)

    @ViewBuilder
    private var gridSection: some View {
        if store.apps.isEmpty && store.loading {
            ProgressView()
                .tint(ASTheme.red)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else if store.apps.isEmpty && store.failed {
            VStack(spacing: 10) {
                Text("Couldn't load apps")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Button("Retry") { Task { await store.refresh() } }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(ASTheme.red)
                    .frame(minHeight: 44)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 30)
        } else {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(visibleApps) { a in appCard(a) }
            }
            .padding(.top, 4)
        }
    }

    private func appCard(_ a: ASApp) -> some View {
        Button { selected = a } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 9) {
                    ASIcon(url: a.iconURL, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.name)
                            .font(.system(size: 14.5, weight: .heavy))
                            .foregroundColor(ASTheme.red)
                            .lineLimit(1)
                        Text(a.bundleID)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(ASTheme.grey)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(ASTheme.red)
                }
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .stroke(ASTheme.red, lineWidth: 2)
                        .frame(width: 7, height: 7)
                        .padding(.top, 4)
                    Text(a.desc)
                        .font(.system(size: 11.5))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                HStack {
                    Spacer()
                    Text(a.version)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(ASTheme.red)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(ASTheme.red.opacity(0.12)))
                        .overlay(Capsule().stroke(ASTheme.red.opacity(0.5), lineWidth: 1))
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.black))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
