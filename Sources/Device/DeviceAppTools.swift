//
//  DeviceAppTools.swift
//  Undo after an uninstall, clean reinstall, and the signing-expiry radar for apps on this device.
//  All of them lean on the signed IPAs AirShare keeps: an app can be put back only if you signed it here.
//

import Combine
import Foundation
import IDeviceSwift
import SwiftUI
import UserNotifications

// MARK: - Signed copy lookup

enum SignedLookup {
    /// Newest signed IPA of this bundle that still exists on disk.
    @MainActor static func latestEntry(for bundleID: String) -> SignedEntry? {
        SignedStore.shared.entries
            .filter { $0.bundleID == bundleID && FileManager.default.fileExists(atPath: $0.ipaURL.path) }
            .max { $0.signedAt < $1.signedAt }
    }
}

// MARK: - Undo / clean reinstall

@MainActor
final class DeviceAppActions: ObservableObject {
    static let shared = DeviceAppActions()

    struct UndoItem: Identifiable {
        let id = UUID()
        let name: String
        let entry: SignedEntry
    }

    @Published private(set) var undo: UndoItem?
    @Published private(set) var restoring = false
    @Published var error: String?
    private var dismissTask: Task<Void, Never>?
    private init() {}

    /// Offer "Undo" for ten seconds, but only when AirShare has a signed copy to put back. Batches don't prompt.
    func noteUninstalled(_ app: DeviceApp) {
        guard !NativeBatchUninstaller.shared.isRunning, let entry = SignedLookup.latestEntry(for: app.bundleID) else { return }
        let item = UndoItem(name: app.name, entry: entry)
        undo = item
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            if self?.undo?.id == item.id, self?.restoring == false { self?.undo = nil }
        }
    }

    func dismissUndo() { dismissTask?.cancel(); if !restoring { undo = nil } }

    /// Reinstalls the signed copy. The app's data is not restored: uninstalling deleted it.
    func performUndo() {
        guard let item = undo, !restoring else { return }
        restoring = true
        error = nil
        Task {
            do {
                try await OTAInstaller.shared.install(item.entry)
                undo = nil
                DeviceLibrary.shared.refresh()
            } catch is CancellationError {
            } catch {
                self.error = "Couldn't restore \(item.name): \(error.localizedDescription)"
            }
            restoring = false
        }
    }

    /// Uninstall, then install the newest signed copy: a fix for an app that's misbehaving or won't update.
    func cleanReinstall(_ app: DeviceApp) async {
        guard let entry = SignedLookup.latestEntry(for: app.bundleID) else {
            error = "There's no signed copy of \(app.name) in AirShare to reinstall."
            return
        }
        error = nil
        let library = DeviceLibrary.shared
        await library.uninstall(app, offerUndo: false)
        guard library.error == nil else { error = library.error; return }
        do {
            try await OTAInstaller.shared.install(entry)
            library.refresh()
        } catch is CancellationError {
        } catch {
            self.error = "\(app.name) was uninstalled but couldn't be reinstalled: \(error.localizedDescription)"
        }
    }
}

struct UndoUninstallBanner: View {
    @ObservedObject private var actions = DeviceAppActions.shared

    var body: some View {
        if let item = actions.undo {
            HStack(spacing: 12) {
                Image(systemName: "trash.fill").foregroundStyle(Theme.subtle)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.name) uninstalled").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(actions.restoring ? "Reinstalling…" : "Undo reinstalls it without its data.")
                        .font(.system(size: 11)).foregroundStyle(Theme.subtle).lineLimit(1)
                }
                Spacer(minLength: 6)
                if actions.restoring { ProgressView().tint(Theme.accent) }
                else {
                    Button("Undo") { actions.performUndo() }
                        .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accent)
                    Button { actions.dismissUndo() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.subtle)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.accent.opacity(0.35), lineWidth: 1))
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: actions.restoring)
        }
    }
}

// MARK: - Expiry radar

enum ExpiryRadar {
    static let remindersKey = "AirShare.expiryReminders"
    static var remindersOn: Bool { UserDefaults.standard.object(forKey: remindersKey) as? Bool ?? true }

    /// When the profile that signed this app expires. Known only for apps signed in AirShare.
    @MainActor static func expiry(for bundleID: String) -> Date? {
        guard let entry = SignedLookup.latestEntry(for: bundleID),
              let cert = CertificateStore.shared.certificates.first(where: { $0.name == entry.certName }),
              let data = try? Data(contentsOf: cert.provisionURL) else { return nil }
        return CertificateStore.profileInfo(data).expires
    }

    /// "3d" · "5h" (time left; "0h" once expired).
    static func remaining(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "0h" }
        if seconds < 86_400 { return "\(max(1, Int(seconds / 3600)))h" }
        return "\(Int(seconds / 86_400))d"
    }

    /// "Expires in 3d" · "Expires in 5h" · "Expired".
    static func label(_ date: Date) -> String {
        date.timeIntervalSinceNow <= 0 ? "Expired" : "Expires in \(remaining(date))"
    }

    /// One reminder per signing certificate, two days before it expires, naming how many installed apps it covers.
    @MainActor static func scheduleReminders(for apps: [DeviceApp]) {
        let center = UNUserNotificationCenter.current()
        var byCert: [String: (date: Date, count: Int)] = [:]
        for app in apps {
            guard let entry = SignedLookup.latestEntry(for: app.bundleID), let date = expiry(for: app.bundleID) else { continue }
            let current = byCert[entry.certName]
            byCert[entry.certName] = (date, (current?.count ?? 0) + 1)
        }
        let known = CertificateStore.shared.certificates.map(\.name)
        center.removePendingNotificationRequests(withIdentifiers: known.map { "airshare.expiry.\($0)" })
        guard remindersOn else { return }
        for (cert, info) in byCert where info.date.timeIntervalSinceNow > 0 {
            let fire = max(info.date.addingTimeInterval(-2 * 86_400), Date().addingTimeInterval(60))
            let content = UNMutableNotificationContent()
            content.title = "Signing certificate expiring"
            content.body = "\(info.count) app\(info.count == 1 ? "" : "s") signed with \(cert) expire in \(remaining(info.date)). Re-sign \(info.count == 1 ? "it" : "them") in AirShare."
            content.sound = .default
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire)
            let request = UNNotificationRequest(identifier: "airshare.expiry.\(cert)", content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
            center.add(request)
        }
    }
}
