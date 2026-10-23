//
//  AppSets.swift
//  Named groups of apps ("My tweaks") you can install or uninstall in one tap, using the same batch
//  installers as multi-select. Installing needs a signed copy of each app in AirShare.
//

import Combine
import Foundation
import IDeviceSwift
import SwiftUI

struct AppSetApp: Codable, Hashable {
    let bundleID: String
    let name: String
}

struct AppSet: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var apps: [AppSetApp]
}

@MainActor
final class AppSetStore: ObservableObject {
    static let shared = AppSetStore()
    private static let key = "AirShare.appSets"
    @Published private(set) var sets: [AppSet] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([AppSet].self, from: data) { sets = list }
    }

    func add(name: String, apps: [DeviceApp]) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !apps.isEmpty else { return }
        let members = apps.map { AppSetApp(bundleID: $0.bundleID, name: $0.name) }
        if let i = sets.firstIndex(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
            var merged = sets[i].apps
            for m in members where !merged.contains(where: { $0.bundleID == m.bundleID }) { merged.append(m) }
            sets[i].apps = merged
        } else {
            sets.append(AppSet(name: clean, apps: members))
        }
        persist()
    }

    func remove(_ set: AppSet) { sets.removeAll { $0.id == set.id }; persist() }
    func remove(app: AppSetApp, from set: AppSet) {
        guard let i = sets.firstIndex(where: { $0.id == set.id }) else { return }
        sets[i].apps.removeAll { $0 == app }
        if sets[i].apps.isEmpty { sets.remove(at: i) }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sets) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

struct AppSetsScreen: View {
    @ObservedObject private var store = AppSetStore.shared
    @ObservedObject private var device = DeviceLibrary.shared
    @ObservedObject private var installs = NativeBatchInstaller.shared
    @ObservedObject private var removals = NativeBatchUninstaller.shared
    @State private var installSheet = false
    @State private var uninstallSheet = false
    @State private var confirmUninstall: AppSet?
    @State private var note: String?

    private var busy: Bool { installs.isRunning || removals.isRunning }

    var body: some View {
        List {
            if let note { Text(note).font(.footnote).foregroundStyle(.orange).listRowBackground(Theme.card) }
            if store.sets.isEmpty {
                Text("No sets yet. In Installed apps tap Select, pick some apps, then Save Set.")
                    .foregroundStyle(Theme.subtle).listRowBackground(Theme.card)
            }
            ForEach(store.sets) { set in
                Section {
                    ForEach(set.apps, id: \.bundleID) { app in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name).foregroundStyle(Theme.text)
                            Text(app.bundleID).font(.caption.monospaced()).foregroundStyle(Theme.subtle)
                        }
                        .swipeActions { Button(role: .destructive) { store.remove(app: app, from: set) } label: { Label("Remove", systemImage: "minus.circle") } }
                        .listRowBackground(Theme.card)
                    }
                    Button { install(set) } label: {
                        Label("Install set", systemImage: "arrow.down.app.fill").fontWeight(.semibold)
                    }
                    .disabled(busy || !NativeInstaller.isSelected).listRowBackground(Theme.card).tint(Theme.accent)
                    Button(role: .destructive) { confirmUninstall = set } label: {
                        Label("Uninstall set", systemImage: "trash").fontWeight(.semibold)
                    }
                    .disabled(busy).listRowBackground(Theme.card)
                } header: {
                    HStack {
                        Text(set.name).font(.footnote.weight(.bold)).foregroundStyle(Theme.subtle)
                        Spacer()
                        Button(role: .destructive) { store.remove(set) } label: { Image(systemName: "trash") }
                            .font(.footnote).disabled(busy)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("App sets")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(confirmUninstall.map { "Uninstall \($0.name)?" } ?? "", isPresented: Binding(
            get: { confirmUninstall != nil }, set: { if !$0 { confirmUninstall = nil } }), titleVisibility: .visible) {
            Button("Uninstall apps in this set", role: .destructive) { if let set = confirmUninstall { uninstall(set) }; confirmUninstall = nil }
            Button("Cancel", role: .cancel) { confirmUninstall = nil }
        } message: { Text("This removes each app in the set that's on this device, along with its data.") }
        .sheet(isPresented: $installSheet) { BatchInstallSheet().presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        .sheet(isPresented: $uninstallSheet) { BatchUninstallSheet().presentationDetents([.medium, .large]).presentationDragIndicator(.visible) }
        .preferredColorScheme(.dark)
    }

    private func install(_ set: AppSet) {
        let entries = set.apps.compactMap { SignedLookup.latestEntry(for: $0.bundleID) }
        let missing = set.apps.filter { app in !entries.contains { $0.bundleID == app.bundleID } }.map(\.name)
        note = missing.isEmpty ? nil : "No signed copy in AirShare for: \(missing.joined(separator: ", ")). Sign \(missing.count == 1 ? "it" : "them") first."
        guard !entries.isEmpty else { return }
        installs.start(entries)
        installSheet = installs.isRunning
    }

    private func uninstall(_ set: AppSet) {
        let ids = Set(set.apps.map(\.bundleID))
        let present = device.apps.filter { ids.contains($0.bundleID) }
        guard !present.isEmpty else {
            note = device.apps.isEmpty ? "Load the apps on this device first (Library › On this device)." : "None of these apps are installed on this device."
            return
        }
        note = nil
        removals.start(present)
        uninstallSheet = removals.isRunning
    }
}
