//
//  InstallQueue.swift
//  Tap "Queue" on as many apps as you like and walk away: each one is downloaded, signed (with the
//  options it was signed with last time, else defaults) and installed, one after another. The keep-alive
//  hold (your song) runs for the whole queue, and a progress pill / notification tells you how it went.
//

import Combine
import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class InstallQueue: ObservableObject {
    static let shared = InstallQueue()

    enum Status: Equatable { case queued, downloading, signing, installing, done, failed(String) }

    struct Item: Identifiable {
        let app: SourceApp
        var status: Status = .queued
        var progress: Double = 0      // 0...1 across download + sign + install for this app
        var id: String { app.id }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var isRunning = false

    var doneCount: Int { items.filter { $0.status == .done }.count }
    var failedCount: Int { items.filter { if case .failed = $0.status { return true }; return false }.count }
    var finished: Bool { !items.isEmpty && !isRunning }
    var fraction: Double {
        guard !items.isEmpty else { return 0 }
        return items.reduce(0.0) { acc, i in
            switch i.status { case .done, .failed: return acc + 1; case .queued: return acc; default: return acc + i.progress }
        } / Double(items.count)
    }
    var current: Item? { items.first { [.downloading, .signing, .installing].contains($0.status) } }
    var title: String { "Installing \(items.count) App\(items.count == 1 ? "" : "s")" }
    var summary: String {
        guard let c = current else { return "\(doneCount)/\(items.count) done" }
        let step: String
        switch c.status { case .downloading: step = "Downloading"; case .signing: step = "Signing"; default: step = "Installing" }
        return "\(doneCount + 1)/\(items.count) · \(step) \(c.app.name) \(Int((c.progress * 100).rounded()))%"
    }

    /// Short form for the lock-screen player line ("Signing Aiko 42%").
    var compact: String {
        guard let c = current else { return "\(doneCount)/\(items.count) done" }
        let step: String
        switch c.status { case .downloading: step = "Downloading"; case .signing: step = "Signing"; default: step = "Installing" }
        return "\(step) \(Int((c.progress * 100).rounded()))%"
    }

    private init() {}

    func contains(_ app: SourceApp) -> Bool { items.contains { $0.app.id == app.id && !isFinal($0.status) } }
    private func isFinal(_ s: Status) -> Bool { if case .done = s { return true }; if case .failed = s { return true }; return false }

    func enqueue(_ app: SourceApp) {
        guard !contains(app) else { return }
        if !isRunning { items.removeAll() }          // fresh run: forget the previous, finished one
        items.append(Item(app: app))
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if !isRunning { isRunning = true; Task { await run() } }
    }

    func dismiss() { if !isRunning { items = [] } }

    private func set(_ id: String, _ status: Status? = nil, progress: Double? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let status { items[i].status = status }
        if let progress { items[i].progress = max(items[i].progress, min(progress, 1)) }
    }

    private func run() async {
        let holdID = "queue-\(UUID().uuidString)"
        BackgroundKeepAlive.shared.start(holdID)           // song / silence for the whole queue
        var bg: UIBackgroundTaskIdentifier = .invalid
        bg = UIApplication.shared.beginBackgroundTask(withName: "airshare-queue") {
            if bg != .invalid { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
        }
        var failures: [String] = []
        while let next = items.first(where: { $0.status == .queued }) {
            // Never overlap with another install already running (batch, auto-update, manual).
            while NativeInstaller.shared.isActive || NativeBatchInstaller.shared.isRunning || AppAutoUpdater.shared.busy {
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
            do { try await process(next.app); set(next.id, .done, progress: 1) }
            catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                set(next.id, .failed(msg)); failures.append("\(next.app.name): \(msg)")
            }
        }
        BackgroundKeepAlive.shared.stop(holdID)
        if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
        isRunning = false
        announce(failures: failures)
    }

    private func process(_ app: SourceApp) async throws {
        let id = app.id
        // 1 · download (0 → 40%)
        set(id, .downloading, progress: 0.01)
        let ipa: URL
        if IPAInbox.has(app) { ipa = IPAInbox.url(for: app) }
        else {
            ipa = try await IPADownloader.shared.download(app) { p in Task { @MainActor in InstallQueue.shared.set(id, progress: p * 0.4) } }
            await IPAInbox.storeIcon(for: app)
            AppStatsStore.shared.noteDownload(app)
        }
        set(id, progress: 0.4)

        // 2 · sign (40 → 60%)
        set(id, .signing, progress: 0.42)
        let material = try CertificateStore.shared.activeMaterial()
        let meta = try? IPAMeta.read(ipa)
        let options: SignOptions
        if let profile = SignProfileStore.shared.profile(forSigned: meta?.bundleID ?? app.bundle) ?? SignProfileStore.shared.profile(forSigned: app.bundle) {
            options = SignProfileStore.shared.options(for: profile, newVersion: app.version, fallbackName: app.name)
        } else {
            var o = SignOptions(); o.name = app.name; options = o
        }
        let outcome = try await Task.detached(priority: .userInitiated) {
            try await Signer.signDetached(ipaURL: ipa, material: material, options: options, onLog: nil, captureOutput: false)
        }.value
        let entry = try SignedStore.shared.add(outcome: outcome, icon: meta?.iconPNG, certName: material.name)
        NativeInstaller.registerOriginal(ipa, forSigned: entry.ipaURL)
        SignProfileStore.shared.save(options: options, signedBundleID: entry.bundleID,
                                     sourceBundleID: meta?.bundleID ?? app.bundle, sourceVersion: meta?.version ?? app.version)
        ZefvAccount.shared.recordSign()
        set(id, progress: 0.6)

        // 3 · install (60 → 100%)
        set(id, .installing, progress: 0.62)
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                InstallQueue.shared.set(id, progress: 0.6 + 0.4 * min(max(NativeInstaller.shared.progress, 0), 1))
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        defer { poll.cancel() }
        try await OTAInstaller.shared.install(entry)
        // Native: wait for the device to report the install finished before moving on.
        if NativeInstaller.isSelected {
            var waited = 0.0
            while NativeInstaller.shared.isActive && waited < 600 { try? await Task.sleep(nanoseconds: 500_000_000); waited += 0.5 }
            if case .failed(let m) = NativeInstaller.shared.stage { throw NSError(domain: "AirShare", code: 1, userInfo: [NSLocalizedDescriptionKey: m]) }
        }
    }

    private func announce(failures: [String]) {
        let ok = doneCount
        if UIApplication.shared.applicationState != .active {
            let c = UNMutableNotificationContent()
            c.title = "AirShare"
            if failures.isEmpty { c.body = ok == 1 ? "Installed \(items.first?.app.name ?? "app")" : "Installed \(ok) apps" }
            else { c.body = "\(ok) installed, \(failures.count) failed — \(failures[0])" }
            c.sound = .default
            let r = UNNotificationRequest(identifier: "airshare.queue.done", content: c, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
            Task { try? await UNUserNotificationCenter.current().add(r) }
        }
        UINotificationFeedbackGenerator().notificationOccurred(failures.isEmpty ? .success : .warning)
    }
}

/// Floating progress pill for the queue: app icon wrapped in a transparent progress ring, percentage on the right.
struct InstallQueuePill: View {
    @ObservedObject private var q = InstallQueue.shared
    @ObservedObject private var liveTheme = AppTheme.shared

    private var percent: Int { Int(((q.isRunning ? q.fraction : 1) * 100).rounded()) }

    var body: some View {
        if !q.items.isEmpty {
            HStack(spacing: 12) {
                ZStack {
                    SourceIcon(url: (q.current?.app ?? q.items.last?.app)?.iconURL, side: 34, fallback: (q.current?.app ?? q.items.last?.app)?.name ?? "")
                    Circle().stroke(Color.clear, lineWidth: 3)                       // transparent track
                    Circle().trim(from: 0, to: max(0.03, q.isRunning ? q.fraction : 1))
                        .stroke(q.failedCount > 0 && !q.isRunning ? Color.orange : Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(q.isRunning ? q.title : (q.failedCount == 0 ? "Installed \(q.doneCount) app\(q.doneCount == 1 ? "" : "s")" : "\(q.doneCount) installed · \(q.failedCount) failed"))
                        .font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(q.isRunning ? q.summary : (q.items.compactMap { i -> String? in if case .failed(let m) = i.status { return "\(i.app.name): \(m)" }; return nil }.first ?? "All done"))
                        .font(.system(size: 11)).foregroundStyle(Theme.subtle).lineLimit(1)
                }
                Spacer(minLength: 6)
                if q.isRunning {
                    Text("\(percent)%").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.accent).monospacedDigit()
                } else {
                    Button { q.dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.subtle) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.accent.opacity(0.4), lineWidth: 1))
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.2), value: q.items.count)
        }
    }
}
