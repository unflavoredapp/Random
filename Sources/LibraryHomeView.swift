//
//  LibraryHomeView.swift
//  TetherLess-style Library tab with Unsigned / Signed / Installed segments.
//  Reuses LibraryView (downloaded IPAs), SignedView (signed), DeviceLibrary (installed).
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

private enum LibrarySegment: String, CaseIterable, Identifiable {
    case unsigned = "Unsigned"
    case signed = "Signed"
    case installed = "Installed"
    var id: String { rawValue }
}

struct LibraryHomeView: View {
    @ObservedObject private var signed = SignedStore.shared
    @ObservedObject private var device = DeviceLibrary.shared
    @State private var segment: LibrarySegment = .unsigned
    @State private var unsignedItems: [LibraryItem] = []
    @State private var importing = false
    @State private var installing: String?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                segmentControl
                Button { importing = true } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 14) {
                    if let error {
                        GlassCard { StatusRow(kind: .warning, title: error) }
                    }
                    switch segment {
                    case .unsigned: unsignedSection
                    case .signed: signedSection
                    case .installed: installedSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 120)
            }
        }
        .task {
            unsignedItems = await LibraryCache.shared.refresh()
            device.refreshIfStale()
        }
        .sheet(isPresented: $importing) {
            DocPicker(types: [UTType(filenameExtension: "ipa") ?? .item]) { urls in
                Task { await importIPAs(urls) }
            }
        }
    }

    private var segmentControl: some View {
        HStack(spacing: 0) {
            ForEach(LibrarySegment.allCases) { s in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { segment = s }
                } label: {
                    Text(s.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            if segment == s {
                                Capsule().fill(.white.opacity(0.18))
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
    }

    @ViewBuilder private var unsignedSection: some View {
        if unsignedItems.isEmpty {
            GlassCard {
                StatusRow(kind: .info, title: "No unsigned apps yet",
                          subtitle: "Tap + to import an .ipa. Then tap it and choose Sign.")
            }
        } else {
            ForEach(unsignedItems) { item in
                GlassCard(corner: 22) {
                    HStack(spacing: 12) {
                        appIcon(item.icon)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.headline).foregroundStyle(.white)
                            Text("\(item.version) · \(item.bundle)")
                                .font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        }
                        Spacer()
                        Button("Sign") { SignQueue.shared.enqueue(item.url) }
                            .buttonStyle(.borderedProminent)
                            .tint(TetherlessPalette.accent)
                            .disabled(installing != nil)
                    }
                }
            }
        }
    }

    @ViewBuilder private var signedSection: some View {
        if signed.entries.isEmpty {
            GlassCard {
                StatusRow(kind: .info, title: "No signed apps yet",
                          subtitle: "Sign an IPA from Unsigned — it lands here ready to install.")
            }
        } else {
            ForEach(signed.entries) { entry in
                GlassCard(corner: 22) {
                    HStack(spacing: 12) {
                        appIcon(entry.iconURL.flatMap { try? Data(contentsOf: $0) })
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(.headline).foregroundStyle(.white)
                            Text("v\(entry.version) · \(entry.bundleID)")
                                .font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        }
                        Spacer()
                        Button {
                            Task { await installSigned(entry) }
                        } label: {
                            if installing == entry.id { ProgressView().tint(.white) }
                            else { Text("Install") }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(TetherlessPalette.accent)
                        .disabled(installing != nil)
                    }
                }
            }
        }
    }

    @ViewBuilder private var installedSection: some View {
        if device.apps.isEmpty {
            GlassCard {
                StatusRow(kind: .info, title: "No installed apps listed",
                          subtitle: "Pair the device, then refresh — apps installed on this iPhone show here.")
            }
        } else {
            ForEach(device.apps) { app in
                GlassCard(corner: 22) {
                    HStack(spacing: 12) {
                        appIcon(device.icons[app.bundleID])
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).font(.headline).foregroundStyle(.white)
                            Text(app.bundleID)
                                .font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private func appIcon(_ data: Data?) -> some View {
        Group {
            if let data, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Image(systemName: "app.fill").foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: 44, height: 44)
        .background(.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func importIPAs(_ urls: [URL]) async {
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = AppPaths.dir("inbox").appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        unsignedItems = await LibraryCache.shared.refresh()
        segment = .unsigned
    }

    private func installSigned(_ entry: SignedEntry) async {
        installing = entry.id; error = nil
        defer { installing = nil }
        do {
            LocalZSignAPI.shared.startIfNeeded()
            try await OTAInstaller.shared.install(entry)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
