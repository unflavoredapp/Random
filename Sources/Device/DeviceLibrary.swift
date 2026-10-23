//
//  DeviceLibrary.swift
//  Every user-installed app on this device, for the Library tab. Read through the native connection
//  (built-in VPN + pairing), cached on disk so the Library opens instantly. App Store apps that don't have a
//  decrypted copy in the Library are flagged DRM, and can be sent to the Decrypt tab by name.
//

import Combine
import Foundation
import IDeviceSwift
import SwiftUI

@MainActor
final class DeviceLibrary: ObservableObject {
    static let shared = DeviceLibrary()

    @Published private(set) var apps: [DeviceApp] = []
    @Published private(set) var icons: [String: Data] = [:]
    @Published private(set) var loading = false
    @Published private(set) var lastLoaded: Date?
    @Published var error: String?

    private static let appsKey = "AirShare.deviceLibrary.apps"
    private static let dateKey = "AirShare.deviceLibrary.date"
    private var task: Task<Void, Never>?

    private var iconDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("device-app-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.appsKey), let list = try? JSONDecoder().decode([DeviceApp].self, from: data) {
            apps = list
            for app in list { if let png = try? Data(contentsOf: iconURL(app)) { icons[app.bundleID] = png } }
        }
        lastLoaded = d.object(forKey: Self.dateKey) as? Date
    }

    private func iconURL(_ app: DeviceApp) -> URL {
        iconDir.appendingPathComponent("\(app.bundleID)-\(app.version).png")
    }

    /// Opening the Library must not start the VPN on its own: only refresh by itself when Native is selected
    /// and the list is old. Everything else is an explicit tap.
    func refreshIfStale() {
        guard NativeInstaller.isSelected, !loading, !NativeBatchUninstaller.shared.isRunning else { return }
        if let lastLoaded, Date().timeIntervalSince(lastLoaded) < 300 { return }
        refresh()
    }

    func refresh() {
        guard !loading, !NativeBatchUninstaller.shared.isRunning, !NativeInstaller.shared.isActive else { return }
        loading = true
        error = nil
        task = Task {
            let manager = DeviceInstallationManager.shared
            do {
                let list = try await manager.installedApps(mode: manager.mode)
                    .filter { $0.bundleID != Bundle.main.bundleIdentifier }
                apps = list
                lastLoaded = Date()
                persist()
                ExpiryRadar.scheduleReminders(for: list)
                loading = false
                await loadMissingIcons(for: list)
            } catch is CancellationError {
                loading = false
            } catch {
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Forget an app another screen just uninstalled, without reconnecting to the device.
    func drop(_ bundleID: String) {
        apps.removeAll { $0.bundleID == bundleID }
        persist()
    }

    private func loadMissingIcons(for list: [DeviceApp]) async {
        let missing = list.filter { icons[$0.bundleID] == nil }
        guard !missing.isEmpty else { return }
        let manager = DeviceInstallationManager.shared
        let found = await manager.deviceIcons(for: missing.map(\.bundleID), mode: manager.mode)
        for app in missing {
            guard let png = found[app.bundleID] else { continue }
            icons[app.bundleID] = png
            try? png.write(to: iconURL(app), options: .atomic)
        }
    }

    /// After a batch uninstall the cached list is stale: take the removed apps out right away, then re-read the device.
    func reloadAfterBatch() {
        let removed = Set(NativeBatchUninstaller.shared.items.filter { $0.status == .done }.map(\.id))
        apps.removeAll { removed.contains($0.bundleID) }
        persist()
        refresh()
    }

    func uninstall(_ app: DeviceApp, offerUndo: Bool = true) async {
        error = nil
        let manager = DeviceInstallationManager.shared
        do {
            try await manager.uninstall(bundleIdentifier: app.bundleID, mode: manager.mode)
            apps.removeAll { $0.bundleID == app.bundleID }
            persist()
            if offerUndo { DeviceAppActions.shared.noteUninstalled(app) }
        } catch is CancellationError {
        } catch {
            self.error = "Couldn't uninstall \(app.name): \(error.localizedDescription)"
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(apps) { UserDefaults.standard.set(data, forKey: Self.appsKey) }
        UserDefaults.standard.set(lastLoaded, forKey: Self.dateKey)
    }
}

// MARK: - Hand-off to the Decrypt tab

extension DecryptClient {
    /// Opens the Decrypt tab with this app's name already in the search box.
    @MainActor static func sendToDecrypt(name: String) {
        shared.pendingQuery = name
        AppNav.shared.go(2)
    }
}

extension DeviceApp {
    /// "412 MB", or nil when the device didn't report a size.
    var sizeText: String? {
        sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}
