//
//  FilesHomeView.swift
//  TetherLess-style Files tab — Signed / Unsigned folders over existing stores.
//

import SwiftUI
import UniformTypeIdentifiers

struct FilesHomeView: View {
    @ObservedObject private var signed = SignedStore.shared
    @State private var unsignedItems: [LibraryItem] = []
    @State private var importing = false
    @State private var path: FilesPath = .root
    @State private var importNote: String?

    private enum FilesPath: Equatable {
        case root, signed, unsigned
    }

    var body: some View {
        Group {
            switch path {
            case .root: root
            case .signed: folderList(title: "Signed", items: signedEntries, empty: "No signed IPAs yet.")
            case .unsigned: folderList(title: "Unsigned", items: unsignedEntries, empty: "No unsigned IPAs yet. Tap + to import.")
            }
        }
        .sheet(isPresented: $importing) {
            DocPicker(types: [UTType(filenameExtension: "ipa") ?? .item]) { urls in
                Task { await importIPAs(urls) }
            }
        }
        .task { unsignedItems = await LibraryCache.shared.refresh() }
    }

    private var signedEntries: [(id: String, name: String, detail: String, url: URL)] {
        signed.entries.map {
            (id: $0.id, name: $0.name, detail: "v\($0.version) · \($0.bundleID)", url: $0.ipaURL)
        }
    }

    private var unsignedEntries: [(id: String, name: String, detail: String, url: URL)] {
        unsignedItems.map {
            (id: $0.id, name: $0.name, detail: "\($0.version) · \($0.bundle)", url: $0.url)
        }
    }

    private var root: some View {
        ScreenScroll(title: "Files", trailing: AnyView(toolbar)) {
            if let importNote {
                GlassCard { StatusRow(kind: .info, title: importNote) }
            }

            Button { path = .signed } label: {
                GlassPillRow {
                    HStack(spacing: 14) {
                        Image(systemName: "folder.fill")
                            .font(.title2)
                            .foregroundStyle(Color(red: 0.55, green: 0.75, blue: 1.0))
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Signed").font(.title3.weight(.semibold)).foregroundStyle(.white)
                            Text("Folder").font(.footnote).foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                        Text("\(signedEntries.count)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.5))
                        Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            .buttonStyle(.plain)

            Button { path = .unsigned } label: {
                GlassPillRow {
                    HStack(spacing: 14) {
                        Image(systemName: "folder.fill")
                            .font(.title2)
                            .foregroundStyle(Color(red: 0.55, green: 0.75, blue: 1.0))
                            .frame(width: 36)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Unsigned").font(.title3.weight(.semibold)).foregroundStyle(.white)
                            Text("Folder").font(.footnote).foregroundStyle(.white.opacity(0.55))
                        }
                        Spacer()
                        Text("\(unsignedEntries.count)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.5))
                        Image(systemName: "chevron.right").foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { importing = true } label: {
                Image(systemName: "plus")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Button { path = .root; importNote = nil } label: {
                Image(systemName: "checkmark.circle")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .opacity(0.001) // layout balance on root; real back lives in folder views
            .disabled(true)
        }
    }

    private func folderList(title: String, items: [(id: String, name: String, detail: String, url: URL)], empty: String) -> some View {
        ScreenScroll(title: title, trailing: AnyView(
            Button { path = .root } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
            }
        )) {
            if items.isEmpty {
                GlassCard { StatusRow(kind: .info, title: empty) }
            } else {
                ForEach(items, id: \.id) { item in
                    GlassCard(corner: 22) {
                        HStack(spacing: 12) {
                            Image(systemName: "app.gift.fill")
                                .font(.title2)
                                .foregroundStyle(TetherlessPalette.accent)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name).font(.headline).foregroundStyle(.white).lineLimit(1)
                                Text(item.detail).font(.caption).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                            }
                            Spacer()
                            ShareLink(item: item.url) {
                                Image(systemName: "square.and.arrow.up").foregroundStyle(.white.opacity(0.8))
                            }
                        }
                    }
                }
            }
        }
    }

    private func importIPAs(_ urls: [URL]) async {
        var ok = 0
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let inbox = AppPaths.dir("inbox")
            let dest = inbox.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                ok += 1
            } catch {
                importNote = error.localizedDescription
            }
        }
        unsignedItems = await LibraryCache.shared.refresh()
        if ok > 0 {
            importNote = "Imported \(ok) IPA\(ok == 1 ? "" : "s") into Unsigned."
            path = .unsigned
        }
    }
}
