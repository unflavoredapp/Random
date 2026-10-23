//
//  NativeBatchUninstaller.swift
//  Uninstalls several apps in one native session, the same way NativeBatchInstaller installs them:
//  one VPN/tunnel for the whole batch, two apps in flight at a time, pause/resume, a background hold
//  so you can leave AirShare, and a summary notification.
//

import Combine
import Foundation
import SwiftUI
import UIKit
import UserNotifications
import IDeviceSwift

@MainActor
final class NativeBatchUninstaller: ObservableObject {
    static let shared = NativeBatchUninstaller()

    enum Status: Equatable { case queued, removing, done, failed(String) }

    struct Item: Identifiable {
        let app: DeviceApp
        var status: Status = .queued
        var progress: Double = 0
        var id: String { app.bundleID }
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
            switch i.status {
            case .done, .failed: return acc + 1
            case .removing: return acc + i.progress * 0.95
            case .queued: return acc
            }
        }
        return sum / Double(items.count)
    }

    private init() {}

    // MARK: Resume after iOS kills AirShare mid-batch
    private static let pendingKey = "AirShare.batch.uninstall.pending"

    /// Apps a previous, interrupted batch hadn't uninstalled yet.
    static var pendingApps: [DeviceApp] {
        UserDefaults.standard.data(forKey: pendingKey).flatMap { try? JSONDecoder().decode([DeviceApp].self, from: $0) } ?? []
    }
    static func discardPending() { UserDefaults.standard.removeObject(forKey: pendingKey) }
    func resumePending() { start(Self.pendingApps) }

    private func persist() {
        let left = items.filter { $0.status == .queued || $0.status == .removing }.map(\.app)
        if left.isEmpty { Self.discardPending() }
        else if let data = try? JSONEncoder().encode(left) { UserDefaults.standard.set(data, forKey: Self.pendingKey) }
    }

    /// Never overlaps with an install, another batch, or an auto-update: they all share the one tunnel.
    var canStart: Bool {
        !isRunning && !NativeInstaller.shared.isActive && !NativeBatchInstaller.shared.isRunning
            && !AppAutoUpdater.shared.busy && !InstallQueue.shared.isRunning
    }

    func start(_ apps: [DeviceApp]) {
        let apps = apps.filter { $0.bundleID != Bundle.main.bundleIdentifier }
        guard canStart, !apps.isEmpty else { return }
        items = apps.map { Item(app: $0) }
        isPaused = false
        isRunning = true
        persist()
        Task { await run() }
    }

    func reset() { if !isRunning { items = []; isPaused = false } }

    private func run() async {
        let manager = DeviceInstallationManager.shared
        let batchID = UUID()
        manager.retainWorkflow(batchID)          // keeps the VPN / tunnel up between uninstalls
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "airshare-batch-uninstall") {
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
        }
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<min(2, items.count) { group.addTask { await self.worker() } }
        }
        manager.releaseWorkflow(batchID)
        if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        isRunning = false
        persist()
        DeviceLibrary.shared.reloadAfterBatch()
        if doneCount > 0 || failedCount > 0 {
            let c = UNMutableNotificationContent()
            c.title = "AirShare"
            c.body = failedCount == 0
                ? "Uninstalled \(doneCount) app\(doneCount == 1 ? "" : "s")"
                : "Uninstalled \(doneCount), \(failedCount) failed"
            c.sound = .default
            let request = UNNotificationRequest(identifier: "airshare.batch.uninstall", content: c,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            Task { try? await UNUserNotificationCenter.current().add(request) }
            UINotificationFeedbackGenerator().notificationOccurred(failedCount == 0 ? .success : .warning)
        }
    }

    private func worker() async {
        while true {
            while isPaused { try? await Task.sleep(nanoseconds: 200_000_000) }
            guard let idx = items.firstIndex(where: { $0.status == .queued }) else { return }
            items[idx].status = .removing
            let app = items[idx].app
            do {
                let manager = DeviceInstallationManager.shared
                try await manager.uninstall(bundleIdentifier: app.bundleID, mode: manager.mode) { [weak self] value in
                    Task { @MainActor in self?.setProgress(app.bundleID, value) }
                }
                setStatus(app.bundleID, .done)
            } catch {
                setStatus(app.bundleID, .failed(error.localizedDescription))
            }
        }
    }

    private func setProgress(_ id: String, _ value: Double) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].status == .removing else { return }
        items[i].progress = max(items[i].progress, value)
    }

    private func setStatus(_ id: String, _ status: Status) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = status
        if status == .done { items[i].progress = 1 }
        persist()
    }
}

// MARK: - Bottom sheet

struct BatchUninstallSheet: View {
    @ObservedObject private var batch = NativeBatchUninstaller.shared
    @Environment(\.dismiss) private var dismiss
    private let green = Color(red: 0.2, green: 1.0, blue: 0.45)
    private let red = Color(red: 1, green: 0.42, blue: 0.38)

    private var title: String {
        if batch.isRunning { return batch.isPaused ? "Paused" : "Uninstalling" }
        return batch.failedCount == 0 ? "Uninstalled" : "Finished with errors"
    }
    private var titleColor: Color { batch.isRunning ? Theme.accent : (batch.failedCount == 0 ? green : red) }

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
            Text("\(batch.doneCount) of \(batch.items.count) uninstalled").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.accent)

            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: 4), spacing: 14) {
                    ForEach(batch.items) { item in tile(item) }
                }
                .padding(16)
            }
            .background(Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            if batch.isRunning {
                if BackgroundKeepAlive.enabled {
                    Label("You can leave AirShare. Uninstalls continue in the background.", systemImage: "checkmark.shield.fill")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(green)
                } else {
                    Label("Keep AirShare open until every app is uninstalled.", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(red: 1, green: 0.8, blue: 0.3))
                }
            } else if batch.failedCount > 0 {
                Text(batch.items.compactMap { i -> String? in
                    if case .failed(let m) = i.status { return "\(i.app.name): \(m)" }; return nil
                }.joined(separator: "\n")).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 10)
        .background(Color(red: 0.035, green: 0.043, blue: 0.043).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(batch.isRunning)
    }

    private func tile(_ item: NativeBatchUninstaller.Item) -> some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.accent.opacity(0.2))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(Image(systemName: "app.fill").font(.system(size: 22)).foregroundStyle(Theme.accent))
                switch item.status {
                case .queued:
                    RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.black.opacity(0.55))
                case .removing:
                    RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.black.opacity(0.5))
                    Circle().stroke(Color.white.opacity(0.25), lineWidth: 4).padding(18)
                    Circle().trim(from: 0, to: max(0.05, item.progress)).stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90)).padding(18)
                case .done:
                    RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.black.opacity(0.55))
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).foregroundStyle(green)
                case .failed:
                    RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Color.black.opacity(0.4))
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(red).font(.system(size: 22))
                }
            }
            Text(item.app.name).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.subtle).lineLimit(1)
        }
    }
}
