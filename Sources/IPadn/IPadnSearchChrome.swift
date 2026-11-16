//
// Brand: Tetherless · https://tetherless.dev
//  IPadnSearchChrome.swift
//  App Store–style search chrome derived from mengangs/ipadn SearchView /
//  DesignSystem / SharedViews (GPL-2.0). Used by TetherLess Decrypt.
//

import SwiftUI

// MARK: - Search history

enum DecryptSearchHistory {
    private static let key = "tetherless.decrypt.searchHistory"

    static func load() -> [String] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).filter { !$0.isEmpty }
    }

    static func remember(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 1 else { return }
        var list = load().filter { $0.caseInsensitiveCompare(t) != .orderedSame }
        list.insert(t, at: 0)
        UserDefaults.standard.set(Array(list.prefix(16)), forKey: key)
    }

    static func remove(_ term: String) {
        UserDefaults.standard.set(load().filter { $0 != term }, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Page header (iPadn PageHeader)

struct IPadnPageHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
    }
}

// MARK: - Collapsing blur nav (large title → centered material overlay)

private struct IPadnScrollMinYKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Scroll chrome shared by Search / Downloads / Purchased / Account.
/// Large title rides in the scroll; after a short drag a centered title sits on
/// an `ultraThinMaterial` overlay (reference: compact Decrypt top bar).
struct IPadnBlurNavScroll<Trailing: View, Content: View>: View {
    let title: String
    var collapseDistance: CGFloat = 56
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    @State private var minY: CGFloat = 0

    private var progress: CGFloat {
        min(1, max(0, -minY) / collapseDistance)
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    IPadnPageHeader(title: title) {
                        trailing()
                            .opacity(1 - progress)
                            .allowsHitTesting(progress < 0.55)
                    }
                    .opacity(1 - min(1, progress * 1.25))
                    .accessibilityHidden(progress > 0.85)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: IPadnScrollMinYKey.self,
                                value: geo.frame(in: .named("ipadnBlurScroll")).minY
                            )
                        }
                    )

                    content()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 120)
            }
            .coordinateSpace(name: "ipadnBlurScroll")
            .onPreferenceChange(IPadnScrollMinYKey.self) { minY = $0 }

            VStack(spacing: 0) {
                ZStack {
                    Text(title)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 72)

                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        trailing()
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 44)

                Rectangle()
                    .fill(Color.white.opacity(0.14 * progress))
                    .frame(height: 0.5)
            }
            .background {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .opacity(progress)
                    .ignoresSafeArea(edges: .top)
            }
            .opacity(progress > 0.02 ? 1 : 0)
            .allowsHitTesting(progress > 0.45)
            .accessibilityHidden(progress < 0.45)
            .animation(.easeOut(duration: 0.16), value: progress > 0.45)
        }
    }
}

extension IPadnBlurNavScroll where Trailing == EmptyView {
    init(title: String, collapseDistance: CGFloat = 56, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.collapseDistance = collapseDistance
        self.trailing = { EmptyView() }
        self.content = content
    }
}

// MARK: - Capsule search (iPadn SearchInput)

struct IPadnCapsuleSearch: View {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onClear: (() -> Void)? = nil
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.45))
            TextField(placeholder, text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($focused)
                .foregroundStyle(.white)
                .onSubmit {
                    focused = false
                    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { onSubmit() }
                }
            if !text.isEmpty {
                Button {
                    text = ""
                    onClear?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(minHeight: 44)
        .background(Color.white.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture { focused = true }
    }
}

// MARK: - Filter chips (region / platform)

struct IPadnFilterChip: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption.weight(.semibold))
            Text(title).font(.subheadline.weight(.medium))
            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(Color.white.opacity(0.10), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
    }
}

// MARK: - Get capsule (iPadn StoreDownloadActionButton idle look)

struct IPadnGetCapsule: View {
    var title: String = "Get"
    var filled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .foregroundStyle(filled ? .white : TetherlessPalette.accent)
                .padding(.horizontal, 16)
                .frame(minWidth: 74, minHeight: 30)
                .background(
                    filled ? AnyShapeStyle(TetherlessPalette.accent) : AnyShapeStyle(Color.white.opacity(0.14)),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - App row (iPadn AppRow)

struct IPadnDecryptAppRow: View {
    let app: DecryptApp
    var onGet: () -> Void
    var onVersions: (() -> Void)? = nil
    /// Show disclosure chevron (iPadn Search → App Detail).
    var showsChevron: Bool = true

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: app.icon) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .overlay {
                            Image(systemName: "app.fill").foregroundStyle(.white.opacity(0.35))
                        }
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    if !app.countryLabel.isEmpty {
                        Text(app.countryLabel)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                }
                // iPadn Search rows: category, then vX · size.
                let subtitle = app.category.isEmpty ? app.dev : app.category
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                let facts = [
                    app.version.isEmpty ? nil : "v\(app.version)",
                    app.sizeLabel.isEmpty ? nil : app.sizeLabel
                ].compactMap { $0 }.joined(separator: " · ")
                if !facts.isEmpty {
                    Text(facts)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            IPadnGetCapsule(title: "Get", filled: false, action: onGet)
            if showsChevron {
                Button {
                    onVersions?()
                } label: {
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(minWidth: 28, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Details")
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Account avatar menu (iPadn AccountMenuButton)

struct IPadnAccountMenuButton: View {
    @ObservedObject private var store = AppleIDStore.shared

    var body: some View {
        Menu {
            if store.isSignedIn {
                Section("Apple Account") {
                    ForEach(store.accounts) { account in
                        Button {
                            store.selectAccount(id: account.id)
                        } label: {
                            if store.activeAccountID == account.id {
                                Label(account.email, systemImage: "checkmark.circle.fill")
                            } else {
                                Label(account.email, systemImage: "person.crop.circle")
                            }
                        }
                    }
                }
                Button("Account", systemImage: "person.crop.circle") {
                    AppNav.shared.goAccount()
                }
                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    store.signOut()
                }
            } else {
                Button("Account", systemImage: "person.crop.circle") {
                    AppNav.shared.goAccount()
                }
                Button("Sign in — Apple Account", systemImage: "person.crop.circle.badge.plus") {
                    AppNav.shared.goStoreLogin()
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        store.isSignedIn
                            ? AnyShapeStyle(LinearGradient(
                                colors: [Color.white.opacity(0.35), Color.white.opacity(0.15)],
                                startPoint: .top, endPoint: .bottom))
                            : AnyShapeStyle(Color.white.opacity(0.12))
                    )
                if store.isSignedIn {
                    Text(String(store.email.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            .frame(width: 32, height: 32)
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Switch or manage Apple ID")
    }
}

// MARK: - Recent search chips

struct IPadnRecentSearchChips: View {
    let terms: [String]
    var onSelect: (String) -> Void
    var onDelete: (String) -> Void
    var onClearAll: () -> Void
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Clear") { confirmClear = true }
                    .font(.body)
                    .foregroundStyle(TetherlessPalette.accent)
                    .confirmationDialog("Clear recent searches?", isPresented: $confirmClear, titleVisibility: .visible) {
                        Button("Clear", role: .destructive, action: onClearAll)
                        Button("Cancel", role: .cancel) {}
                    }
            }
            FlowWrap(spacing: 8) {
                ForEach(terms, id: \.self) { term in
                    Button {
                        onSelect(term)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "magnifyingglass").font(.caption.weight(.semibold))
                            Text(term).font(.subheadline.weight(.medium)).lineLimit(1)
                        }
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 34)
                        .background(Color.white.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete", role: .destructive) { onDelete(term) }
                    }
                }
            }
            Text("Long-press a chip to delete it.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.35))
        }
    }
}

/// Simple wrapping HStack (iPadn ChipFlow stand-in).
struct FlowWrap<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        // Prefer LazyVGrid-style wrap via ViewThatFits isn't ideal; use flexible layout.
        _FlowWrapLayout(spacing: spacing) { content }
    }
}

private struct _FlowWrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, totalH: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxW, x > 0 {
                y += rowH + spacing
                totalH = y
                x = 0
                rowH = 0
            }
            x += size.width + spacing
            rowH = max(rowH, size.height)
            totalH = y + rowH
        }
        return CGSize(width: maxW.isFinite ? maxW : x, height: totalH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowH + spacing
                x = bounds.minX
                rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}
