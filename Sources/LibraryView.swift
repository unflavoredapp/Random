//
//  LibraryView.swift
//  Library tab — imported/downloaded IPAs, AirShare-style rows in floating glass chrome.
//

import IDeviceSwift
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject private var liveTheme = AppTheme.shared   // re-read the accent live (auto-cycle) without rebuilding
    @ObservedObject private var ota = OTAInstaller.shared
    @ObservedObject private var store = SourceStore.shared   // re-renders the update pills as sources load
    @ObservedObject private var device = DeviceLibrary.shared  // apps installed on this device
    @ObservedObject private var appActions = DeviceAppActions.shared
    @State private var items: [LibraryItem]
    @State private var loading: Bool
    @State private var search = ""
    @State private var importing = false
    @State private var installing: String?
    @State private var error: String?
    @State private var sheetItem: LibraryItem?
    @State private var showSearch = false
    @State private var confirmDeleteAll = false
    @State private var deviceSheet: DeviceApp?
    @State private var uninstallTarget: DeviceApp?
    @State private var scope: LibraryScope = .library

    init() {
        // Whatever was loaded last time shows on the very first frame — the tab opens instantly.
        let cached = LibraryCache.shared.items
        _items = State(initialValue: cached ?? [])
        _loading = State(initialValue: cached == nil)
    }

    private var inbox: URL { AppPaths.dir("inbox") }

    /// Newest version of this app found in any of your sources, if it's newer than the downloaded one.
    private func newestVersion(for it: LibraryItem) -> String? {
        var best: String?
        for (_, repo) in store.allCached() {
            guard let v = repo.group(bundle: it.bundle)?.latest.version,
                  VersionCompare.isNewer(remote: v, than: it.version) else { continue }
            if let b = best, !VersionCompare.isNewer(remote: v, than: b) { continue }
            best = v
        }
        return best
    }

    private var filtered: [LibraryItem] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? items : items.filter { $0.name.lowercased().contains(q) || $0.bundle.lowercased().contains(q) }
    }

    /// Device apps that don't already have a downloaded copy in the Library (those show up above, as Downloaded).
    private var deviceOnly: [DeviceApp] {
        let have = Set(items.map { $0.bundle })
        return device.apps.filter { !have.contains($0.bundleID) }
    }

    private var deviceApps: [DeviceApp] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? deviceOnly : deviceOnly.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if (!items.isEmpty || !device.apps.isEmpty) && showSearch {
                        AirShareSearchField(placeholder: "Search", text: $search).padding(.bottom, 8)
                    }
                    if let error { Card { Text(error).font(.caption).foregroundStyle(.orange) }.padding(.bottom, 8) }
                    if loading {
                        HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }.padding(.top, 60)
                    } else {
                        if scope == .library && items.isEmpty {
                            Card { Text("No downloaded apps yet. Download one in Browse, or tap + to import an .ipa.").font(.caption).foregroundStyle(Theme.subtle) }
                        }
                        ForEach(Array((scope == .library ? filtered : []).enumerated()), id: \.element.id) { idx, it in
                            AirShareRow(
                                icon: it.icon,
                                title: it.name,
                                subtitle: "\(it.version) • \(it.bundle)",
                                badge: "Downloaded",
                                updatePill: newestVersion(for: it).map { "\(it.version) → \($0)" },
                                busy: installing == it.id,
                                accent: SSTheme.tintColor,
                                onAction: { sheetItem = it },
                                onTap: { sheetItem = it }
                            )
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { delete(it) } label: { Label("Delete", systemImage: "trash") }
                            }
                            if idx < filtered.count - 1 {
                                Divider().overlay(Theme.stroke).padding(.leading, 78)
                            }
                        }
                        if scope == .device { deviceSection }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 20)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    header
                    LowStorageBanner()
                }
            }
        }
        .task {
            await reload(); device.refreshIfStale()
            if items.isEmpty && !deviceOnly.isEmpty { scope = .device }
        }
        .sheet(isPresented: $importing) {
            DocPicker(types: [UTType(filenameExtension: "ipa") ?? .item]) { urls in
                Task { await importIPAs(urls) }
            }
        }
        .sheet(item: $sheetItem) { it in
            AppActionSheet(
                name: it.name, bundle: it.bundle, icon: it.icon,
                actions: [
                    .init(title: "Install", icon: "square.and.arrow.down", role: .normal) {
                        sheetItem = nil; Task { await install(it) }
                    },
                    .init(title: "Sign", icon: "signature", role: .normal) {
                        sheetItem = nil; SignQueue.shared.enqueue(it.url)
                    },
                    .init(title: "Delete", icon: "trash", role: .destructive) {
                        sheetItem = nil; delete(it)
                    },
                ]
            )
            .presentationDetents([.height(340)])
            .then { view in
                if #available(iOS 16.0, *) {
                    view.presentationDragIndicator(.visible)
                } else {
                    view
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(item: $deviceSheet) { app in
            AppActionSheet(
                name: app.name, bundle: app.bundleID, icon: device.icons[app.bundleID],
                actions: deviceActions(for: app)
            )
            .presentationDetents([.height(CGFloat(160 + 70 * deviceActions(for: app).count))])
            .presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
        }
        .confirmationDialog(uninstallTarget.map { "Uninstall \($0.name)?" } ?? "", isPresented: Binding(
            get: { uninstallTarget != nil }, set: { if !$0 { uninstallTarget = nil } }), titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) {
                if let app = uninstallTarget { Task { await device.uninstall(app) } }
                uninstallTarget = nil
            }
            Button("Cancel", role: .cancel) { uninstallTarget = nil }
        } message: {
            Text("This removes the app and all of its data from this device.")
        }
    }

    // MARK: - Apps on this device

    private func deviceActions(for app: DeviceApp) -> [AppActionSheet.Action] {
        var list: [AppActionSheet.Action] = []
        if app.isAppStore {
            // Encrypted (FairPlay) and no decrypted copy in the Library: hand it to the Decrypt tab by name.
            list.append(.init(title: "Decrypt", icon: "lock.open.fill", role: .normal) {
                deviceSheet = nil
                DecryptClient.sendToDecrypt(name: app.name)
            })
        }
        if SignedLookup.latestEntry(for: app.bundleID) != nil {
            // You signed this app in AirShare, so it can be put back: uninstall, then install the newest signed copy.
            list.append(.init(title: "Clean Reinstall", icon: "arrow.triangle.2.circlepath", role: .normal) {
                deviceSheet = nil
                Task { await DeviceAppActions.shared.cleanReinstall(app) }
            })
        }
        list.append(.init(title: "Uninstall", icon: "trash", role: .destructive) {
            deviceSheet = nil
            uninstallTarget = app
        })
        return list
    }

    /// Orange pill when a signing profile you used is about to run out (or already has): "Expires in 3d".
    private func expiryPill(for app: DeviceApp) -> String? {
        guard let date = ExpiryRadar.expiry(for: app.bundleID), date.timeIntervalSinceNow < 7 * 86_400 else { return nil }
        return ExpiryRadar.label(date)
    }

    @ViewBuilder private var deviceSection: some View {
        HStack(spacing: 8) {
            Text("ON THIS DEVICE").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.subtle)
            if !deviceOnly.isEmpty {
                Text("\(deviceOnly.count)").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.subtle)
            }
            Spacer()
            if device.loading { ProgressView().tint(Theme.accent) }
            else {
                Button { device.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4).padding(.bottom, 6)
        if let e = device.error ?? appActions.error { Card { Text(e).font(.caption).foregroundStyle(.orange) }.padding(.bottom, 8) }
        if device.apps.isEmpty && !device.loading {
            Card {
                Text(NativeInstaller.isSelected
                     ? "Tap refresh to list the apps installed on this device. This uses the Native connection (built-in VPN + pairing)."
                     : "Set Install method to Native in Settings to list the apps installed on this device.")
                    .font(.caption).foregroundStyle(Theme.subtle)
            }
        }
        ForEach(Array(deviceApps.enumerated()), id: \.element.id) { idx, app in
            AirShareRow(
                icon: device.icons[app.bundleID],
                title: app.name,
                subtitle: ([app.version.isEmpty ? nil : app.version, app.sizeText].compactMap { $0 } + [app.bundleID]).joined(separator: " • "),
                badge: app.isAppStore ? "DRM · Locked" : "Installed",
                badgeAccented: app.isAppStore,
                badgeSymbol: app.isAppStore ? "lock.fill" : nil,
                locked: app.isAppStore,
                updatePill: expiryPill(for: app),
                accent: app.isAppStore ? Color(red: 1, green: 0.35, blue: 0.32) : SSTheme.tintColor,
                onAction: { deviceSheet = app },
                onTap: { deviceSheet = app }
            )
            if idx < deviceApps.count - 1 {
                Divider().overlay(Theme.stroke).padding(.leading, 78)
            }
        }
    }

    private var header: some View {
        TabTitleBar(title: "Library",
                    center: "\(scope == .library ? items.count : deviceOnly.count) Apps",
                    custom: AnyView(LibraryTitleSwitch(scope: $scope))) {
            HStack(spacing: 14) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { showSearch.toggle(); if !showSearch { search = "" } }
                } label: {
                    Image(systemName: showSearch ? "xmark" : "magnifyingglass")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)

                Menu {
                    Button { importing = true } label: { Label("Import .ipa", systemImage: "square.and.arrow.down") }
                    Button { device.refresh() } label: { Label("Refresh device apps", systemImage: "arrow.clockwise") }
                    if !items.isEmpty {
                        Divider()
                        Menu {
                            ForEach(items) { it in
                                Button(role: .destructive) { delete(it) } label: { Label(it.name, systemImage: "trash") }
                            }
                        } label: { Label("Delete app…", systemImage: "trash") }
                        Button(role: .destructive) { confirmDeleteAll = true } label: {
                            Label("Delete all (\(items.count))", systemImage: "trash.fill")
                        }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .confirmationDialog("Delete every app in the Library?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete \(items.count) apps", role: .destructive) { deleteAll() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Data

    private func reload() async {
        loading = LibraryCache.shared.items == nil
        let list = await LibraryCache.shared.refresh()
        if list != items { items = list }
        loading = false
    }

    private func importIPAs(_ urls: [URL]) async {
        let fm = FileManager.default
        for u in urls {
            let dest = inbox.appendingPathComponent(u.lastPathComponent)
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: u, to: dest)
        }
        await reload()
    }

    private func delete(_ it: LibraryItem) {
        try? FileManager.default.removeItem(at: it.url)
        LibraryCache.shared.remove(id: it.id)
        items.removeAll { $0.id == it.id }
    }

    private func deleteAll() {
        for it in items { try? FileManager.default.removeItem(at: it.url) }
        LibraryCache.shared.removeAll()
        items.removeAll()
        search = ""; showSearch = false
    }

    private func install(_ it: LibraryItem) async {
        installing = it.id; error = nil
        do {
            try await OTAInstaller.shared.install(ipaURL: it.url, bundleID: it.bundle, name: it.name, version: it.version,
                                                 iconData: it.icon)
        } catch { self.error = error.localizedDescription }
        installing = nil
    }
}

// MARK: - Library item (on-disk IPA in the inbox)

nonisolated struct LibraryItem: Identifiable, Equatable, Sendable {
    let id: String            // file path
    let url: URL
    let name: String
    let bundle: String
    let version: String
    let sizeBytes: Int64
    let icon: Data?
    var sizeString: String { sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) : "" }
}


// MARK: - Library cache (keeps the list in memory so the tab opens instantly)

nonisolated struct LibraryStamp: Equatable, Sendable {
    let size: Int64
    let mtime: Date
}

@MainActor
final class LibraryCache {
    static let shared = LibraryCache()
    private(set) var items: [LibraryItem]?
    private var memo: [String: LibraryItem] = [:]
    private var stamps: [String: LibraryStamp] = [:]
    private var running: Task<Void, Never>?

    /// Rescans the inbox. Files that haven't changed reuse what was read last time, so only new IPAs are opened.
    @discardableResult
    func refresh() async -> [LibraryItem] {
        if let running { await running.value; return items ?? [] }
        let dir = AppPaths.dir("inbox")
        let oldItems = memo, oldStamps = stamps
        let work = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> ([LibraryItem], [String: LibraryStamp]) in
                let fm = FileManager.default
                let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
                guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))
                    .filter({ $0.pathExtension.lowercased() == "ipa" }) else { return ([], [:]) }
                var out: [(Date, LibraryItem)] = []
                var newStamps: [String: LibraryStamp] = [:]
                for u in files {
                    let v = try? u.resourceValues(forKeys: keys)
                    let stamp = LibraryStamp(size: Int64(v?.fileSize ?? 0), mtime: v?.contentModificationDate ?? .distantPast)
                    newStamps[u.path] = stamp
                    if let item = oldItems[u.path], oldStamps[u.path] == stamp { out.append((stamp.mtime, item)); continue }
                    let item: LibraryItem
                    if let m = try? IPAMeta.read(u) {
                        item = LibraryItem(id: u.path, url: u, name: m.name, bundle: m.bundleID, version: m.version, sizeBytes: stamp.size, icon: m.iconPNG)
                    } else {
                        let base = u.deletingPathExtension().lastPathComponent
                        item = LibraryItem(id: u.path, url: u, name: base, bundle: "—", version: "—", sizeBytes: stamp.size, icon: nil)
                    }
                    out.append((stamp.mtime, item))
                }
                out.sort { $0.0 > $1.0 }
                return (out.map { $0.1 }, newStamps)
            }.value
            items = result.0
            stamps = result.1
            memo = Dictionary(uniqueKeysWithValues: result.0.map { ($0.id, $0) })
        }
        running = work
        await work.value
        running = nil
        return items ?? []
    }

    func remove(id: String) {
        items?.removeAll { $0.id == id }
        memo[id] = nil; stamps[id] = nil
    }

    func removeAll() {
        items = []; memo = [:]; stamps = [:]
    }
}


enum LibraryScope: Hashable { case library, device }

/// The top-bar title split by a divider: "Library | Device". The active side is bright with an accent underline;
/// tapping the other side switches the list and the app count underneath.
struct LibraryTitleSwitch: View {
    @Binding var scope: LibraryScope

    var body: some View {
        HStack(spacing: 10) {
            side("Library", .library)
            Rectangle().fill(Theme.stroke).frame(width: 1, height: 20)
            side("Device", .device)
        }
        .frame(maxWidth: .infinity)
    }

    private func side(_ title: String, _ value: LibraryScope) -> some View {
        let on = scope == value
        return Button {
            guard !on else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeInOut(duration: 0.15)) { scope = value }
        } label: {
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(on ? Theme.text : Theme.subtle)
                    .lineLimit(1).minimumScaleFactor(0.8)
                Capsule().fill(on ? Theme.accent : Color.clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? [.isSelected, .isHeader] : [])
    }
}
