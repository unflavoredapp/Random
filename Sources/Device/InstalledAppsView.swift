//
//  InstalledAppsView.swift
//  Lists the user apps installed on this device (never system apps) and uninstalls them through the same
//  built-in VPN + pairing connection the Native installer uses. No Apple prompt.
//  One app: swipe / long-press. Several: Select, pick, Uninstall (NativeBatchUninstaller).
//  Also: sizes + sort, signing-expiry labels, Save Set / App sets, Clean Reinstall, leftover-upload cleanup.
//

import Combine
import IDeviceSwift
import SwiftUI
import UIKit

@MainActor
final class InstalledAppsModel: ObservableObject {
    @Published private(set) var apps: [DeviceApp] = []
    @Published private(set) var loading = false
    @Published private(set) var loadedOnce = false
    @Published private(set) var removing: [String: Double] = [:]   // bundle ID -> 0…1
    @Published private(set) var cleaning = false
    @Published var error: String?
    @Published var cleanupNote: String?

    private let manager = DeviceInstallationManager.shared
    private var loadTask: Task<Void, Never>?

    var isBusy: Bool { loading || cleaning || !removing.isEmpty }
    var totalBytes: Int64 { apps.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }

    func reload() {
        guard !loading, removing.isEmpty, !NativeBatchUninstaller.shared.isRunning else { return }
        loading = true
        error = nil
        loadTask = Task {
            do {
                let list = try await manager.installedApps(mode: manager.mode)
                apps = list.filter { $0.bundleID != Bundle.main.bundleIdentifier }
                loadedOnce = true
                ExpiryRadar.scheduleReminders(for: apps)
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    func cancel() { loadTask?.cancel() }

    func uninstall(_ app: DeviceApp) {
        guard removing[app.bundleID] == nil, NativeBatchUninstaller.shared.canStart else { return }
        removing[app.bundleID] = 0
        error = nil
        Task {
            do {
                try await manager.uninstall(bundleIdentifier: app.bundleID, mode: manager.mode) { [weak self] value in
                    Task { @MainActor in
                        guard self?.removing[app.bundleID] != nil else { return }
                        self?.removing[app.bundleID] = value
                    }
                }
                apps.removeAll { $0.bundleID == app.bundleID }
                DeviceLibrary.shared.drop(app.bundleID)
                DeviceAppActions.shared.noteUninstalled(app)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch is CancellationError {
            } catch {
                self.error = "Couldn't uninstall \(app.name): \(error.localizedDescription)"
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            removing[app.bundleID] = nil
        }
    }

    func cleanReinstall(_ app: DeviceApp) {
        guard !isBusy else { return }
        cleaning = true
        Task {
            await DeviceAppActions.shared.cleanReinstall(app)
            error = DeviceAppActions.shared.error
            cleaning = false
            reload()
        }
    }

    /// Deletes IPAs stranded in the device's upload folder by interrupted installs.
    func cleanStaging() {
        guard !isBusy else { return }
        cleaning = true
        cleanupNote = nil
        error = nil
        Task {
            do {
                let result = try await manager.cleanStaging(mode: manager.mode)
                cleanupNote = result.removed == 0
                    ? "Nothing to clean up. The device's upload folder is empty."
                    : "Removed \(result.removed) leftover upload\(result.removed == 1 ? "" : "s") (\(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file)))."
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            cleaning = false
        }
    }
}

struct InstalledAppsScreen: View {
    private enum Sort: String { case name, size }

    @StateObject private var model = InstalledAppsModel()
    @ObservedObject private var batch = NativeBatchUninstaller.shared
    @ObservedObject private var sets = AppSetStore.shared
    @AppStorage("AirShare.installedAppsSort") private var sortRaw = Sort.name.rawValue
    @AppStorage(ExpiryRadar.remindersKey) private var reminders = true
    @State private var search = ""
    @State private var pending: DeviceApp?
    @State private var reinstallTarget: DeviceApp?
    @State private var selecting = false
    @State private var selected: Set<String> = []
    @State private var confirmBatch = false
    @State private var showBatch = false
    @State private var showSetAlert = false
    @State private var setName = ""

    private var sort: Sort { Sort(rawValue: sortRaw) ?? .name }

    private var filtered: [DeviceApp] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let list = q.isEmpty ? model.apps
            : model.apps.filter { $0.name.lowercased().contains(q) || $0.bundleID.lowercased().contains(q) }
        switch sort {
        case .name: return list   // already sorted by name by the device layer
        case .size: return list.sorted { ($0.sizeBytes ?? -1) > ($1.sizeBytes ?? -1) }
        }
    }

    var body: some View {
        List {
            if let error = model.error {
                Text(error).font(.footnote).foregroundStyle(.orange).listRowBackground(Theme.card)
            }
            if model.loading && !model.loadedOnce {
                HStack(spacing: 12) {
                    ProgressView().tint(Theme.accent)
                    Text("Connecting to this device…").foregroundStyle(Theme.subtle)
                }
                .listRowBackground(Theme.card)
            } else if model.loadedOnce && model.apps.isEmpty {
                Text("No user-installed apps found.").foregroundStyle(Theme.subtle).listRowBackground(Theme.card)
            } else {
                Section {
                    ForEach(filtered) { app in row(app) }
                } footer: {
                    Text("\(model.apps.count) apps\(model.totalBytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: model.totalBytes, countStyle: .file) : ""). Swipe left or long-press an app to uninstall it, or tap Select to remove several at once. Uninstalling also deletes the app's data, and AirShare stops auto-updating it. System apps and AirShare itself aren't listed.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                }
            }
            if model.loadedOnce {
                Section {
                    Button { model.cleanStaging() } label: {
                        HStack(spacing: 12) {
                            if model.cleaning { ProgressView().tint(Theme.accent) } else { Image(systemName: "sparkles") }
                            Text("Clean up leftover uploads").fontWeight(.semibold)
                            Spacer()
                        }
                        .foregroundStyle(model.isBusy ? Theme.subtle : Theme.accent)
                    }
                    .disabled(model.isBusy || batch.isRunning).listRowBackground(Theme.card)
                    Toggle(isOn: $reminders) {
                        Label("Remind me before certificates expire", systemImage: "bell.badge").foregroundStyle(Theme.text)
                    }
                    .tint(Theme.accent).listRowBackground(Theme.card)
                } footer: {
                    Text((model.cleanupNote.map { $0 + " " } ?? "") + "Interrupted installs can leave IPAs in the device's upload folder. Expiry labels and reminders cover apps you signed in AirShare.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle(selecting ? "\(selected.count) Selected" : "Installed apps")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    if model.loading { ProgressView().tint(Theme.accent) }
                    else if !selecting {
                        Menu {
                            Picker("Sort by", selection: $sortRaw) {
                                Label("Name", systemImage: "textformat").tag(Sort.name.rawValue)
                                Label("Size", systemImage: "internaldrive").tag(Sort.size.rawValue)
                            }
                            Button { model.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                                .disabled(model.isBusy || batch.isRunning)
                        } label: { Image(systemName: "arrow.up.arrow.down.circle") }
                        NavigationLink { AppSetsScreen() } label: { Image(systemName: "square.stack.3d.up") }
                    }
                    if !model.apps.isEmpty {
                        Button(selecting ? "Cancel" : "Select") {
                            withAnimation(.easeInOut(duration: 0.16)) { selecting.toggle(); selected = [] }
                        }
                        .disabled(model.isBusy || batch.isRunning)
                    }
                }
                .tint(Theme.accent)
            }
        }
        .safeAreaInset(edge: .bottom) { if selecting { batchBar } }
        .refreshable { model.reload() }
        .confirmationDialog(pending.map { "Uninstall \($0.name)?" } ?? "", isPresented: Binding(
            get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { if let app = pending { model.uninstall(app) }; pending = nil }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("This removes the app and all of its data from this device.")
        }
        .confirmationDialog(reinstallTarget.map { "Clean reinstall \($0.name)?" } ?? "", isPresented: Binding(
            get: { reinstallTarget != nil }, set: { if !$0 { reinstallTarget = nil } }), titleVisibility: .visible) {
            Button("Uninstall and reinstall", role: .destructive) { if let app = reinstallTarget { model.cleanReinstall(app) }; reinstallTarget = nil }
            Button("Cancel", role: .cancel) { reinstallTarget = nil }
        } message: {
            Text("Deletes the app and its data, then installs the newest copy you signed in AirShare.")
        }
        .confirmationDialog("Uninstall \(selected.count) app\(selected.count == 1 ? "" : "s")?",
                            isPresented: $confirmBatch, titleVisibility: .visible) {
            Button("Uninstall \(selected.count)", role: .destructive) {
                let picked = model.apps.filter { selected.contains($0.bundleID) }
                batch.start(picked)
                selecting = false; selected = []
                showBatch = batch.isRunning
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected apps and all of their data from this device.")
        }
        .alert("Save as set", isPresented: $showSetAlert) {
            TextField("Set name", text: $setName)
            Button("Save") {
                sets.add(name: setName, apps: model.apps.filter { selected.contains($0.bundleID) })
                setName = ""; selecting = false; selected = []
            }
            Button("Cancel", role: .cancel) { setName = "" }
        } message: {
            Text("Install or uninstall these \(selected.count) app\(selected.count == 1 ? "" : "s") together later from App sets.")
        }
        .sheet(isPresented: $showBatch, onDismiss: { model.reload() }) {
            BatchUninstallSheet().presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .task { if !model.loadedOnce { model.reload() } }
        .onChange(of: batch.isRunning) { running in if running { showBatch = true } }
        .onChange(of: reminders) { _ in ExpiryRadar.scheduleReminders(for: model.apps) }
        .onDisappear { model.cancel() }
        .preferredColorScheme(.dark)
    }

    private var batchBar: some View {
        let all = Set(filtered.map(\.bundleID))
        return HStack(spacing: 12) {
            Button(!all.isEmpty && selected.isSuperset(of: all) ? "Select None" : "Select All") {
                selected = (!all.isEmpty && selected.isSuperset(of: all)) ? selected.subtracting(all) : selected.union(all)
            }
            .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            Button("Save Set") { showSetAlert = true }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(selected.isEmpty ? Theme.subtle : Theme.accent)
                .disabled(selected.isEmpty)
            Spacer()
            Button { confirmBatch = true } label: {
                Text(selected.isEmpty ? "Pick apps" : "Uninstall \(selected.count)")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(Capsule().fill(Color(red: 1, green: 0.30, blue: 0.25).opacity(selected.isEmpty ? 0.35 : 1)))
            }
            .disabled(selected.isEmpty || !batch.canStart)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func row(_ app: DeviceApp) -> some View {
        let progress = model.removing[app.bundleID]
        let expiry = ExpiryRadar.expiry(for: app.bundleID)
        let detail = [app.version.isEmpty ? nil : "v\(app.version)", app.sizeText].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 12) {
            if selecting {
                Image(systemName: selected.contains(app.bundleID) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24)).foregroundStyle(selected.contains(app.bundleID) ? Theme.accent : Theme.subtle)
            }
            Image(systemName: "app.fill").font(.system(size: 20)).foregroundStyle(Theme.accent)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).foregroundStyle(Theme.text).lineLimit(1)
                Text(detail.isEmpty ? app.bundleID : detail + " · " + app.bundleID)
                    .font(.caption.monospaced()).foregroundStyle(Theme.subtle).lineLimit(1)
                if let expiry {
                    Text(ExpiryRadar.label(expiry)).font(.caption.weight(.semibold))
                        .foregroundStyle(expiry.timeIntervalSinceNow < 3 * 86_400 ? Color.orange : Theme.subtle)
                }
                if let progress { ProgressView(value: progress).tint(Theme.accent) }
            }
            Spacer(minLength: 0)
            if progress != nil { Text("Removing…").font(.caption).foregroundStyle(Theme.subtle) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard selecting else { return }
            if selected.contains(app.bundleID) { selected.remove(app.bundleID) } else { selected.insert(app.bundleID) }
        }
        .listRowBackground(Theme.card)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !selecting {
                Button(role: .destructive) { pending = app } label: { Label("Uninstall", systemImage: "trash") }
                    .disabled(progress != nil)
            }
        }
        .contextMenu {
            if !selecting {
                Button(role: .destructive) { pending = app } label: { Label("Uninstall", systemImage: "trash") }
                    .disabled(progress != nil)
                if SignedLookup.latestEntry(for: app.bundleID) != nil {
                    Button { reinstallTarget = app } label: { Label("Clean Reinstall", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(model.isBusy)
                }
                Button { selecting = true; selected = [app.bundleID] } label: { Label("Select Several", systemImage: "checkmark.circle") }
            }
        }
    }
}
