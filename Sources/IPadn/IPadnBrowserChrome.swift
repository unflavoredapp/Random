//
// Brand: Tetherless · https://tetherless.dev
//  IPadnBrowserChrome.swift
//  In-app iPadn region/platform controls + quick search (mengangs/ipadn).
//  Main Decrypt search bar already uses IPadnStoreClient when enabled.
//

import SwiftUI

@MainActor
final class IPadnBrowserModel: ObservableObject {
    @Published var query = ""
    @Published var country: String = UserDefaults.standard.string(forKey: IPadnOptional.countryKey) ?? "US"
    @Published var platform: IPadnPlatform = {
        let raw = UserDefaults.standard.string(forKey: IPadnOptional.platformKey) ?? IPadnPlatform.iOS.rawValue
        return IPadnPlatform(rawValue: raw) ?? .iOS
    }()
    @Published var results: [IPadnStoreApp] = []
    @Published var searching = false
    @Published var error: String?
    @Published var status = ""

    static let countries = [
        "US", "CN", "HK", "TW", "JP", "GB", "SG", "CA", "AU", "KR", "DE", "FR", "IN", "BR", "MX"
    ]

    func persistContext() {
        UserDefaults.standard.set(country, forKey: IPadnOptional.countryKey)
        UserDefaults.standard.set(platform.rawValue, forKey: IPadnOptional.platformKey)
    }

    func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 1 else {
            error = "Enter an app name, App ID, or App Store link."
            return
        }
        persistContext()
        searching = true
        error = nil
        status = "Searching…"
        defer { searching = false }
        do {
            let accountCountry = AppleIDStore.shared.linkedStorefrontCountryCodes().first?.uppercased()
            let ctx = IPadnStoreContext(country: country, platform: platform)
            let apps = try await IPadnStoreClient.search(
                q,
                context: ctx,
                accountCountry: accountCountry,
                limit: 30
            )
            results = apps
            status = apps.isEmpty
                ? "No results."
                : "\(apps.count) result\(apps.count == 1 ? "" : "s")"
            if apps.contains(where: \.delisted) {
                status += " · includes delisted stub(s) — owned download may still work"
            }
        } catch {
            results = []
            self.error = error.localizedDescription
            status = ""
        }
    }

    func decrypt(_ app: IPadnStoreApp) {
        let decryptApp = app.asDecryptApp()
        AppNav.shared.goSearch()
        DeviceDecryptService.shared.decryptFromSearch(
            decryptApp,
            version: app.version.isEmpty ? nil : app.version,
            externalVersionId: app.externalVersionID
        )
    }
}

/// Region / platform for iPadn-backed Decrypt search + optional quick results.
struct IPadnBrowserSection: View {
    @AppStorage(IPadnOptional.defaultsKey) private var enabled = true
    @StateObject private var model = IPadnBrowserModel()

    var body: some View {
        if enabled {
            GlassCard(corner: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("APP STORE")
                            .font(.system(size: 12, weight: .semibold))
                            .kerning(1.1)
                            .foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        if model.searching {
                            ProgressView().tint(TetherlessPalette.accent)
                        }
                    }

                    Text("Decrypt’s search bar uses App Store lookup (App ID, store link, multi-region, delisted). Pick region / platform here — also used by the main search field.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 8) {
                        Picker("Region", selection: $model.country) {
                            ForEach(IPadnBrowserModel.countries, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .tint(TetherlessPalette.accent)
                        .onChange(of: model.country) { _ in model.persistContext() }

                        Picker("Platform", selection: $model.platform) {
                            ForEach(IPadnPlatform.allCases.filter { $0 != .macOS && $0 != .tvOS }) { p in
                                Text(p.title).tag(p)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(TetherlessPalette.accent)
                        .onChange(of: model.platform) { _ in model.persistContext() }
                    }

                    HStack(spacing: 8) {
                        TextField("Quick search — name, App ID, or link", text: $model.query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.28), in: Capsule())
                            .onSubmit { Task { await model.search() } }

                        Button {
                            Task { await model.search() }
                        } label: {
                            Text("Search")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(TetherlessPalette.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(model.searching)
                    }

                    if !model.status.isEmpty {
                        Text(model.status)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    if let error = model.error, !error.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(model.results.prefix(20)) { app in
                        HStack(spacing: 12) {
                            AsyncImage(url: app.iconURL) { phase in
                                switch phase {
                                case .success(let img):
                                    img.resizable().scaledToFill()
                                default:
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(Color.white.opacity(0.08))
                                        .overlay {
                                            Image(systemName: "app.fill")
                                                .foregroundStyle(.white.opacity(0.4))
                                        }
                                }
                            }
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text([
                                    app.bundleID.isEmpty ? nil : app.bundleID,
                                    app.version.isEmpty ? nil : "v\(app.version)",
                                    app.country,
                                    app.delisted ? "delisted" : nil,
                                    app.isFree ? "Free" : (app.price.isEmpty ? nil : app.price)
                                ].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.45))
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Button {
                                model.decrypt(app)
                            } label: {
                                Text("Decrypt")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(TetherlessPalette.accent, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(DeviceDecryptService.shared.busy || DecryptClient.shared.busy)
                        }
                    }
                }
            }
            .onAppear {
                IPadnOptional.registerDefaults()
                model.persistContext()
            }
        }
    }
}
