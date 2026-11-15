//
//  IPadnAppDetailView.swift
//  English App Detail + Version History — mengangs/ipadn AppDetailView structure (GPL-2.0).
//

import SwiftUI

struct IPadnAppDetailView: View {
    @State var app: IPadnStoreApp
    @ObservedObject private var manager = IPadnDownloadManager.shared
    @ObservedObject private var store = AppleIDStore.shared
    @State private var versions: [DecryptVersion] = []
    @State private var versionsLoading = false
    @State private var versionError: String?
    @State private var versionNote: String?
    @State private var versionSearch = ""
    @AppStorage("tetherless.officialVersions") private var official = true
    @State private var showAllVersions = false
    @State private var expandedNotes = Set<String>()
    @State private var showDescription = false
    @State private var enqueueError: String?

    private var filteredVersions: [DecryptVersion] {
        let q = versionSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = versions
        if q.isEmpty { return base }
        return base.filter {
            $0.v.localizedCaseInsensitiveContains(q)
                || ($0.externalId?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    private var visibleVersions: [DecryptVersion] {
        let list = filteredVersions
        if showAllVersions || list.count <= 5 { return list }
        return Array(list.prefix(5))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                header
                infoStrip
                if !app.screenshotURLs.isEmpty {
                    previewSection
                }
                versionSection
                if !app.description.isEmpty {
                    descriptionSection
                }
                infoSection
                NavigationLink {
                    IPadnRegionPriceView(app: app)
                } label: {
                    Label("Compare prices by region", systemImage: "globe")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(TetherlessPalette.accent)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 120)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadListing() }
        .task(id: "\(official)-\(app.id)") { await loadVersions() }
        .alert("Download", isPresented: Binding(
            get: { enqueueError != nil },
            set: { if !$0 { enqueueError = nil } }
        )) {
            Button("OK", role: .cancel) { enqueueError = nil }
        } message: {
            Text(enqueueError ?? "")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: app.iconURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white.opacity(0.1))
                }
            }
            .frame(width: 112, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text(app.name)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                if !app.category.isEmpty {
                    Text(app.category)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))
                }
                if !app.version.isEmpty {
                    Text("v\(app.version)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
                HStack(spacing: 4) {
                    Text("ID \(app.id)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.4))
                    Button {
                        UIPasteboard.general.string = app.id
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    enqueueDownload(versionID: app.externalVersionID)
                } label: {
                    Text(app.isFree ? "Get" : "Download")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)

                if store.isSignedIn {
                    Text("Using \(store.email)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .padding(.top, 8)
    }

    private var infoStrip: some View {
        HStack(spacing: 0) {
            stripItem(title: "Rating", value: app.rating > 0 ? String(format: "%.1f" , app.rating) : "—")
            divider
            stripItem(title: "Size", value: app.sizeLabel.isEmpty ? "—" : app.sizeLabel)
            divider
            stripItem(title: "Compatibility", value: app.minimumOS.isEmpty ? "—" : "\(app.minimumOS)+ iOS")
            divider
            stripItem(title: "Category", value: app.category.isEmpty ? "—" : app.category)
        }
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 36)
    }

    private func stripItem(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Preview")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(app.screenshotURLs.enumerated()), id: \.offset) { _, url in
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            default:
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            }
                        }
                        .frame(width: 160, height: 286)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        }
    }

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Version History")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Button("Refresh") { Task { await loadVersions() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
            }

            Toggle(isOn: $official) {
                Text("Fetch full version list from Apple")
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
            .tint(TetherlessPalette.accent)

            if let versionNote {
                Label(versionNote, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
            }

            if versions.count > 6 {
                IPadnCapsuleSearch(
                    text: $versionSearch,
                    placeholder: "Filter by version or version ID",
                    onSubmit: {}
                )
            }

            if versionsLoading && versions.isEmpty {
                HStack {
                    ProgressView().tint(TetherlessPalette.accent)
                    Text("Loading versions…")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.5))
                }
            } else if let versionError {
                Text(versionError).font(.footnote).foregroundStyle(.orange)
            } else {
                ForEach(visibleVersions) { ver in
                    versionRow(ver)
                    Divider().overlay(.white.opacity(0.08))
                }
                if !showAllVersions && filteredVersions.count > 5 {
                    Button("Show all versions (\(filteredVersions.count))") {
                        showAllVersions = true
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
                }
            }
        }
    }

    private func versionRow(_ ver: DecryptVersion) -> some View {
        let versionID = ver.externalId ?? ""
        let title = ver.v.isEmpty ? versionID : ver.v
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(title)")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                    if !versionID.isEmpty {
                        Text("Version ID \(versionID)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    if let minOS = ver.minOS, !minOS.isEmpty {
                        Text("Requires iOS \(minOS)+")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                Spacer()
                Button("Download") {
                    enqueueDownload(versionID: versionID.isEmpty ? nil : versionID)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.14), in: Capsule())
                .buttonStyle(.plain)
            }
            if ver.current {
                Text("Current store version")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.success)
            }
        }
        .padding(.vertical, 4)
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            Text(app.description)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(showDescription ? nil : 4)
            Button(showDescription ? "Less" : "More") {
                showDescription.toggle()
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(TetherlessPalette.accent)
        }
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Information")
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            infoRow("Provider", app.developer.isEmpty ? "—" : app.developer)
            infoRow("Size", app.sizeLabel.isEmpty ? "—" : app.sizeLabel)
            infoRow("Category", app.category.isEmpty ? "—" : app.category)
            infoRow("Compatibility", app.minimumOS.isEmpty ? "—" : "iOS \(app.minimumOS)+")
            infoRow("Language", "English")
            infoRow("Price", app.isFree ? "Free" : (app.price.isEmpty ? "—" : app.price))
            infoRow("Region", app.country)
            infoRow("Bundle ID", app.bundleID.isEmpty ? "—" : app.bundleID)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.white.opacity(0.45))
            Spacer()
            Text(value)
                .foregroundStyle(.white)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func enqueueDownload(versionID: String?) {
        do {
            var decrypt = app.asDecryptApp()
            // Prefer adam id for store download.
            if let adam = app.adamId {
                decrypt = DecryptApp(
                    id: "owned-\(adam)",
                    name: app.name,
                    bundle: app.bundleID,
                    icon: app.iconURL,
                    dev: app.developer,
                    version: app.version,
                    url: app.storeURL
                )
            }
            try manager.enqueueStore(app: decrypt)
            // If a specific external version was requested, tip the user — pin happens inside purchaseAndDownload when possible.
            _ = versionID
            AppNav.shared.goDownloads()
        } catch {
            enqueueError = error.localizedDescription
        }
    }

    private func loadListing() async {
        if let fresh = try? await IPadnStoreClient.lookupPublic(id: app.id, country: app.country) {
            var merged = fresh
            if merged.screenshotURLs.isEmpty { merged.screenshotURLs = app.screenshotURLs }
            if merged.description.isEmpty { merged.description = app.description }
            app = merged
        }
    }

    private func loadVersions() async {
        versionsLoading = true
        versionError = nil
        versionNote = nil
        defer { versionsLoading = false }
        let result = await DeviceDecryptService.shared.versionList(for: app.asDecryptApp())
        let list = result?.versions ?? []
        versions = list
        if list.isEmpty {
            versionError = DeviceDecryptService.shared.lastVersionError
                ?? "Couldn’t load version history. Try Refresh."
        } else if !official {
            versionNote = "Showing public version sources. Turn on Apple’s full list for owned builds."
        } else if store.isSignedIn == false {
            versionNote = "This account has not obtained this app yet. Below is public version data. Get it to see the full list."
        }
    }
}
