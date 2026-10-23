//
//  NativeBatchInstaller.swift
//  Installs several signed apps in one native session: one VPN/tunnel for the whole batch,
//  two apps in flight at a time (the next one uploads while the previous one installs).
//

import Combine
import Foundation
import SwiftUI
import UIKit
import UserNotifications
import IDeviceSwift

@MainActor
final class NativeBatchInstaller: ObservableObject {
    static let shared = NativeBatchInstaller()

    enum Status: Equatable { case queued, installing, done, failed(String) }

    struct Item: Identifiable {
        let entry: SignedEntry
        var status: Status = .queued
        var progress: Double = 0
        var id: String { entry.id }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false
    @Published var isPaused = false

    var doneCount: Int { items.filter { $0.status == .done }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { return true }; return false }.count }
    var finished: Bool { !items.isEmpty && !isRunning }
    var fraction: Double {
        guard !items.isEmpty else { return 0 }
        let sum = items.reduce(0.0) { acc, i in
            switch i.status { case .done, .failed: return acc + 1; case .installing: return acc + i.progress * 0.95; case .queued: return acc }
        }
        return sum / Double(items.count)
    }

    private var observers: [String: AnyCancellable] = [:]
    private init() {}

    // MARK: Resume after iOS kills AirShare mid-batch
    private static let pendingKey = "AirShare.batch.install.pending"

    /// Signed apps a previous, interrupted batch hadn't installed yet.
    static var pendingEntries: [SignedEntry] {
        let ids = UserDefaults.standard.stringArray(forKey: pendingKey) ?? []
        return ids.compactMap { id in SignedStore.shared.entries.first { $0.id == id } }
    }
    static func discardPending() { UserDefaults.standard.removeObject(forKey: pendingKey) }
    func resumePending() { start(Self.pendingEntries) }

    private func persist() {
        let ids = items.filter { $0.status == .queued || $0.status == .installing }.map { $0.entry.id }
        if ids.isEmpty { Self.discardPending() } else { UserDefaults.standard.set(ids, forKey: Self.pendingKey) }
    }

    func start(_ entries: [SignedEntry]) {
        guard !isRunning, !entries.isEmpty, !NativeInstaller.shared.isActive else { return }
        items = entries.map { Item(entry: $0) }
        isPaused = false
        isRunning = true
        persist()
        Task { await run() }
    }

    func reset() { if !isRunning { items = []; isPaused = false } }

    private func run() async {
        let manager = DeviceInstallationManager.shared
        let batchID = UUID()
        manager.retainWorkflow(batchID)          // keeps the VPN / tunnel up between installs
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "airshare-batch") {
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(2, items.count) { group.addTask { await self.worker() } }
        }
        manager.releaseWorkflow(batchID)
        if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        isRunning = false
        persist()
        if doneCount > 0 {
            let c = UNMutableNotificationContent()
            c.title = "AirShare"
            c.body = failedCount == 0 ? "Installed \(doneCount) apps" : "Installed \(doneCount) apps, \(failedCount) failed"
            c.sound = .default
            let request = UNNotificationRequest(identifier: "airshare.batch", content: c,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            Task { try? await UNUserNotificationCenter.current().add(request) }
            UINotificationFeedbackGenerator().notificationOccurred(failedCount == 0 ? .success : .warning)
        }
    }

    private func worker() async {
        while true {
            while isPaused { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard let idx = items.firstIndex(where: { $0.status == .queued }) else { return }
            items[idx].status = .installing
            let id = items[idx].id
            do {
                try await installOne(items[idx].entry)
                setStatus(id, .done)
            } catch {
                setStatus(id, .failed(error.localizedDescription))
            }
        }
    }

    private func setStatus(_ id: String, _ status: Status) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = status
        if status == .done { items[i].progress = 1 }
        observers[id] = nil
        persist()
    }

    private func installOne(_ entry: SignedEntry) async throws {
        let manager = DeviceInstallationManager.shared
        guard FileManager.default.fileExists(atPath: entry.ipaURL.path) else { throw NativeInstaller.InstallError.ipaMissing }
        let vm = InstallerStatusViewModel(isIdevice: true)
        let id = entry.id
        observers[id] = vm.objectWillChange.sink { [weak self, weak vm] _ in
            DispatchQueue.main.async {
                guard let self, let vm, let i = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[i].progress = vm.overallProgress
            }
        }
        var sendURL = entry.ipaURL
        var packedDir: URL?
        if let packed = try await NativeInstaller.packedCopy(of: entry.ipaURL, original: NativeInstaller.original(forSigned: entry.ipaURL)) {
            sendURL = packed
            packedDir = packed.deletingLastPathComponent()
        }
        defer { if let packedDir { try? FileManager.default.removeItem(at: packedDir) } }
        try await manager.install(at: sendURL, viewModel: vm, suspend: false, mode: manager.mode,
                                  bundleIdentifier: entry.bundleID, isCurrent: { true })
        AppAutoUpdater.shared.recordInstalled(bundleID: entry.bundleID, name: entry.name, version: entry.version)
    }
}

// MARK: - Bottom sheet

struct BatchInstallSheet: View {
    @ObservedObject private var batch = NativeBatchInstaller.shared
    @Environment(\.dismiss) private var dismiss
    private let green = Color(red: 0.2, green: 1.0, blue: 0.45)

    private var title: String {
        if batch.isRunning { return batch.isPaused ? "Paused" : "Installing" }
        return batch.failedCount == 0 ? "Installed" : "Finished with errors"
    }
    private var titleColor: Color {
        batch.isRunning ? Theme.accent : (batch.failedCount == 0 ? green : Color(red: 1, green: 0.42, blue: 0.38))
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text(title).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(titleColor)
                Spacer()
                if batch.isRunning {
                    Button { batch.isPaused.toggle() } label: {
                        Image(systemName: batch.isPaused ? "play.fill" : "pause.fill").font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black).frame(width: 40, height: 40).background(Theme.accent).clipShape(Circle())
                    }
                } else {
                    Button("Done") { batch.reset(); dismiss() }.font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.accent)
                }
            }
            HStack(spacing: 10) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(green).frame(width: g.size.width * batch.fraction)
                    }
                }
                .frame(height: 6)
                Text("\(batch.doneCount)/\(batch.items.count)").font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.subtle)
            }
            .animation(.easeInOut(duration: 0.25), value: batch.fraction)
            Text("\(batch.doneCount) of \(batch.items.count) installed").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.accent)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 4), spacing: 14) {
                    ForEach(batch.items) { item in tile(item) }
                }
                .padding(16)
            }
            .background(Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            if batch.isRunning {
                if BackgroundKeepAlive.enabled {
                    Label("You can leave AirShare. Installs continue in the background.", systemImage: "checkmark.shield.fill")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(red: 0.2, green: 1.0, blue: 0.45))
                } else {
                    Label("Keep AirShare open until every app is installed.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(red: 1, green: 0.8, blue: 0.3))
                }
            } else if batch.failedCount > 0 {
                Text(batch.items.compactMap { i -> String? in
                    if case .failed(let m) = i.status { return "\(i.entry.name): \(m)" }; return nil
                }.joined(separator: "\n")).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
        .background(Color(red: 0.035, green: 0.043, blue: 0.043).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(batch.isRunning)
    }

    private func tile(_ item: NativeBatchInstaller.Item) -> some View {
        let icon = item.entry.iconURL.flatMap { UIImage(contentsOfFile: $0.path) }
        return ZStack {
            Group {
                if let icon { Image(uiImage: icon).resizable().scaledToFill() }
                else { RoundedRectangle(cornerRadius: 14).fill(Theme.accent.opacity(0.2)).overlay(Image(systemName: "app.fill").foregroundStyle(Theme.accent)) }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            switch item.status {
            case .queued:
                RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.black.opacity(0.55))
            case .installing:
                RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.black.opacity(0.5))
                Circle().stroke(Color.white.opacity(0.25), lineWidth: 4).padding(18)
                Circle().trim(from: 0, to: max(0.05, item.progress)).stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90)).padding(18)
            case .done:
                Circle().fill(green).frame(width: 16, height: 16).overlay(Circle().stroke(Color.black, lineWidth: 2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).offset(x: 4, y: -4)
            case .failed:
                RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.black.opacity(0.4))
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(red: 1, green: 0.42, blue: 0.38)).font(.system(size: 22))
            }
        }
    }
}
