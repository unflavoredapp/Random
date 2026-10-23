//
//  NativeInstaller.swift
//  On-device installation through AirShare's built-in local VPN + pairing
//  (iDevice). Same call shape as OTAInstaller so every install entry point can
//  route here when "Install method" is set to Native in Settings.
//

import Combine
import Foundation
import IDeviceSwift
import SwiftUI
import ZIPFoundation

@MainActor
final class NativeInstaller: ObservableObject {
    static let shared = NativeInstaller()
    static let methodKey = "AirShare.installMethod"   // "ota" (default) | "native"

    /// Original (compressed) IPA each signed IPA was made from, so the upload can reuse its compressed bytes.
    /// Set by whoever signs, keyed by the signed IPA's path. In memory only.
    private static var originals: [String: URL] = [:]
    static func original(forSigned url: URL) -> URL? { originals[url.path] }
    static func registerOriginal(_ original: URL, forSigned signed: URL) { originals[signed.path] = original }
    /// A re-signed copy keeps the same unsigned original for the fast repack.
    static func carryOriginal(from old: URL, to new: URL) { if let o = originals[old.path] { originals[new.path] = o } }

    static var isSelected: Bool {
        UserDefaults.standard.string(forKey: methodKey) == "native"
    }

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let bundleID: String
    }

    enum Stage: Equatable, Hashable {
        case idle, packing, connecting, uploading, installing, done, failed(String)
        var label: String {
            switch self {
            case .idle: return ""
            case .packing: return "Compressing for a faster upload…"
            case .connecting: return "Connecting to this device…"
            case .uploading: return "Sending IPA…"
            case .installing: return "Installing…"
            case .done: return "Installed"
            case .failed(let m): return m
            }
        }
    }

    @Published private(set) var job: Job?
    @Published private(set) var stage: Stage = .idle
    @Published private(set) var progress: Double = 0
    /// Per-stage seconds of the last finished install, e.g. [("Connect", 1.2), ("Upload", 4.0), ("Install", 6.1)].
    @Published private(set) var timings: [(label: String, seconds: Double)] = []
    private var marks: [(stage: Stage, at: Date)] = []

    /// "Connect 1.2s · Upload 4.0s · Install 6.1s · Total 11.3s"
    var timingSummary: String {
        guard !timings.isEmpty else { return "" }
        let total = timings.reduce(0) { $0 + $1.seconds }
        return (timings.map { String(format: "%@ %.1fs", $0.label, $0.seconds) } + [String(format: "Total %.1fs", total)])
            .joined(separator: " · ")
    }

    /// True while an install is being pre-staged during signing: device events must not move the stage clock.
    private var holdStages = false

    private func enter(_ new: Stage) {
        guard stage != new else { return }
        stage = new
        if !marks.contains(where: { $0.stage == new }) { marks.append((new, Date())) }
    }

    private func finishTimings() {
        let end = Date()
        let labels: [Stage: String] = [.packing: "Pack", .connecting: "Connect", .uploading: "Upload", .installing: "Install"]
        let ordered = marks.compactMap { m in labels[m.stage].map { (label: $0, at: m.at) } }
        var out: [(label: String, seconds: Double)] = []
        for (idx, e) in ordered.enumerated() {
            let next = idx + 1 < ordered.count ? ordered[idx + 1].at : end
            out.append((e.label, max(0, next.timeIntervalSince(e.at))))
        }
        timings = out
    }

    var isActive: Bool {
        switch stage { case .packing, .connecting, .uploading, .installing: return true; default: return false }
    }

    private var observer: AnyCancellable?
    private var workflowID: UUID?
    private init() {}

    enum InstallError: LocalizedError {
        case ipaMissing, busy
        var errorDescription: String? {
            switch self {
            case .ipaMissing: return "Signed IPA not found on disk."
            case .busy: return "A native install is already running."
            }
        }
    }

    func install(_ app: SignedEntry) async throws {
        try await install(ipaURL: app.ipaURL, bundleID: app.bundleID, name: app.name, version: app.version)
    }

    func install(ipaURL: URL, bundleID: String, name: String, version: String) async throws {
        guard FileManager.default.fileExists(atPath: ipaURL.path) else { throw InstallError.ipaMissing }
        if let p = pre, let original = Self.originals[ipaURL.path], original == p.original {
            do {
                try await finishPrestaged(p, signed: ipaURL, bundleID: bundleID, name: name, version: version)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch let final as FinalInstallError {
                throw final.underlying
            } catch {
                // Pre-staging didn't work out (e.g. signing changed a file we'd already sent):
                // clean up and do a normal install of the signed IPA instead.
                discardPrestage(p)
            }
        }
        guard !isActive else { throw InstallError.busy }

        let manager = DeviceInstallationManager.shared
        let viewModel = InstallerStatusViewModel(isIdevice: true)
        let id = UUID()
        workflowID = id
        job = Job(name: name, bundleID: bundleID)
        timings = []
        marks = []
        enter(.packing)
        progress = 0

        observer = viewModel.objectWillChange.sink { [weak self, weak viewModel] _ in
            // objectWillChange fires before the value lands; read on the next turn.
            DispatchQueue.main.async {
                guard let self, let viewModel, self.workflowID == id else { return }
                self.progress = viewModel.overallProgress
                switch viewModel.status {
                case .sendingManifest, .sendingPayload: self.enter(.uploading)
                case .installing: self.enter(.installing)
                default: break
                }
            }
        }

        manager.retainWorkflow(id)
        defer {
            manager.releaseWorkflow(id)
            observer = nil
            workflowID = nil
        }
        var packedDir: URL?
        defer { if let packedDir { try? FileManager.default.removeItem(at: packedDir) } }
        do {
            // The signer writes IPAs uncompressed (~2× the size). The device link is the bottleneck,
            // so compress first when it saves more than it costs.
            var sendURL = ipaURL
            if let packed = try await Self.packedCopy(of: ipaURL, original: Self.originals[ipaURL.path]) {
                sendURL = packed
                packedDir = packed.deletingLastPathComponent()
            }
            try Task.checkCancellation()
            enter(.connecting)
            try await manager.install(at: sendURL, viewModel: viewModel,
                                      suspend: bundleID == Bundle.main.bundleIdentifier,
                                      mode: manager.mode, bundleIdentifier: bundleID,
                                      isCurrent: { true })
            progress = 1
            finishTimings()
            AppAutoUpdater.shared.recordInstalled(bundleID: bundleID, name: name, version: version)
            stage = .done
            ZefvVPS.report(bundle: bundleID, version: version, name: name, stage: "installed")
        } catch is CancellationError {
            stage = .idle
            job = nil
            throw CancellationError()
        } catch {
            stage = .failed(error.localizedDescription)
            throw error
        }
    }


    // MARK: Pre-staging (upload while signing)

    private final class Pre {
        let id = UUID()
        let original: URL
        let dir: URL
        let streamed = StreamedIPA()
        let viewModel = InstallerStatusViewModel(isIdevice: true)
        var prefixTask: Task<ZipDelta.Prefix, Error>?
        var installTask: Task<Void, Error>?
        init(original: URL) {
            self.original = original
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("native-pre-\(UUID().uuidString)", isDirectory: true)
        }
    }
    private var pre: Pre?

    /// Call when signing starts: connects to the device and uploads every file signing won't change,
    /// so only the few changed files are left to send once signing finishes.
    func beginPrestage(original: URL, bundleID: String, name: String) {
        guard Self.isSelected, pre == nil, !isActive else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: original.path)[.size] as? Int64) ?? 0
        guard size > 20_000_000 else { return }
        let p = Pre(original: original)
        try? FileManager.default.createDirectory(at: p.dir, withIntermediateDirectories: true)
        pre = p
        let manager = DeviceInstallationManager.shared
        job = Job(name: name, bundleID: bundleID)
        timings = []; marks = []
        holdStages = true
        enter(.connecting)
        progress = 0
        observer = p.viewModel.objectWillChange.sink { [weak self, weak p] _ in
            DispatchQueue.main.async {
                guard let self, let p, self.pre?.id == p.id else { return }
                self.progress = p.viewModel.overallProgress
                guard !self.holdStages else { return }
                switch p.viewModel.status {
                case .sendingManifest, .sendingPayload: self.enter(.uploading)
                case .installing: self.enter(.installing)
                default: break
                }
            }
        }
        manager.retainWorkflow(p.id)
        let prefixURL = p.dir.appendingPathComponent("prefix.bin")
        let streamed = p.streamed
        p.prefixTask = Task.detached(priority: .userInitiated) {
            do {
                let prefix = try ZipDelta.stage(original: original, to: prefixURL)
                streamed.setPrefix(.success(prefix.url))
                return prefix
            } catch {
                streamed.setPrefix(.failure(error))
                throw error
            }
        }
        p.installTask = Task {
            try await manager.install(at: original, viewModel: p.viewModel, suspend: false,
                                      mode: manager.mode, bundleIdentifier: bundleID, streamed: streamed,
                                      isCurrent: { true })
        }
    }

    /// Signing failed or was cancelled.
    func cancelPrestage() { if let p = pre { discardPrestage(p) } }

    private func discardPrestage(_ p: Pre) {
        guard pre?.id == p.id else { return }
        pre = nil
        holdStages = false
        p.streamed.setPrefix(.failure(CancellationError()))
        p.streamed.setTail(.failure(CancellationError()))
        p.prefixTask?.cancel()
        p.installTask?.cancel()
        DeviceInstallationManager.shared.releaseWorkflow(p.id)
        observer = nil
        try? FileManager.default.removeItem(at: p.dir)
        stage = .idle; job = nil
    }

    private func finishPrestaged(_ p: Pre, signed: URL, bundleID: String, name: String, version: String) async throws {
        // From here on the clock shows only what happens after signing.
        holdStages = false
        marks = []; timings = []
        stage = .idle
        enter(.packing)
        let tailURL = p.dir.appendingPathComponent("tail.bin")
        do {
            let prefix = try await p.prefixTask!.value
            let original = p.original
            _ = try await Task.detached(priority: .userInitiated) {
                try ZipDelta.repack(signed: signed, original: original, to: tailURL, prefix: prefix)
            }.value
        } catch {
            p.streamed.setTail(.failure(error))
            throw error
        }
        try Task.checkCancellation()
        enter(.uploading)
        p.streamed.setTail(.success(tailURL))
        do {
            try await p.installTask!.value
            progress = 1
            finishTimings()
            AppAutoUpdater.shared.recordInstalled(bundleID: bundleID, name: name, version: version)
            stage = .done
            ZefvVPS.report(bundle: bundleID, version: version, name: name, stage: "installed")
        } catch is CancellationError {
            stage = .idle; job = nil
            pre = nil
            DeviceInstallationManager.shared.releaseWorkflow(p.id); observer = nil
            try? FileManager.default.removeItem(at: p.dir)
            throw CancellationError()
        } catch {
            // A device/installer error is final: don't retry a commit iOS may have seen.
            stage = .failed(error.localizedDescription)
            pre = nil
            DeviceInstallationManager.shared.releaseWorkflow(p.id); observer = nil
            try? FileManager.default.removeItem(at: p.dir)
            throw FinalInstallError(underlying: error)
        }
        pre = nil
        DeviceInstallationManager.shared.releaseWorkflow(p.id)
        observer = nil
        try? FileManager.default.removeItem(at: p.dir)
    }

    /// A failure after the install reached iOS — the normal install path must not run again.
    private struct FinalInstallError: LocalizedError {
        let underlying: Error
        var errorDescription: String? { underlying.localizedDescription }
    }

    /// Smaller copy of a signed IPA in a temp folder, or nil if it's small / not worth it.
    /// Fast path: copy the original's compressed bytes for unchanged files (ZipDelta).
    /// Fallback: unpack and deflate everything.
    nonisolated static func packedCopy(of ipa: URL, original: URL?) async throws -> URL? {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let size = (try? fm.attributesOfItem(atPath: ipa.path)[.size] as? Int64) ?? 0
            guard size > 30_000_000 else { return nil }
            // Already compressed (the signer's fast packer): nothing to gain.
            if let list = try? ZipDelta.entries(of: ipa) {
                let u = list.reduce(UInt64(0)) { $0 + UInt64($1.uncomp) }, c = list.reduce(UInt64(0)) { $0 + UInt64($1.comp) }
                if u > 0, c * 10 < u * 9 { return nil }
            }
            if let original, fm.fileExists(atPath: original.path) {
                let root = fm.temporaryDirectory.appendingPathComponent("native-pack-\(UUID().uuidString)", isDirectory: true)
                try? fm.createDirectory(at: root, withIntermediateDirectories: true)
                let out = root.appendingPathComponent("app.ipa")
                do {
                    try ZipDelta.repack(signed: ipa, original: original, to: out)
                    let newSize = (try? fm.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? size
                    if newSize < size * 9 / 10 { return out }
                } catch { /* fall through to the full recompress */ }
                try? fm.removeItem(at: root)
            }
            let root = fm.temporaryDirectory.appendingPathComponent("native-pack-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            do {
                let src = root.appendingPathComponent("src", isDirectory: true)
                try fm.unzipItem(at: ipa, to: src)
                let out = root.appendingPathComponent("app.ipa")
                try fm.zipItem(at: src.appendingPathComponent("Payload", isDirectory: true), to: out,
                               shouldKeepParent: true, compressionMethod: .deflate)
                try? fm.removeItem(at: src)
                let newSize = (try? fm.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? size
                guard newSize < size * 9 / 10 else { try? fm.removeItem(at: root); return nil }
                return out
            } catch {
                try? fm.removeItem(at: root)
                return nil   // fall back to sending the original
            }
        }.value
    }

    func dismiss() {
        guard !isActive else { return }
        stage = .idle
        job = nil
        progress = 0
    }
}

// MARK: - Progress banner (shown over any tab while a native install runs)

struct NativeInstallBanner: View {
    @ObservedObject private var installer = NativeInstaller.shared
    @ObservedObject private var queue = InstallQueue.shared
    @ObservedObject private var reconnect = VPNReconnectCoordinator.shared
    @ObservedObject private var manager = DeviceInstallationManager.shared
    @ObservedObject private var pairing = DevicePairingService.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: 8) {
            if let job = installer.job, installer.stage != .idle, !queue.isRunning {
                card(job)
            }
            if reconnect.pendingShortcutName != nil, !installer.isActive {
                Button {
                    Task { await reconnect.runPendingShortcut() }
                } label: {
                    Label("Reconnect VPN", systemImage: "network").font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .disabled(!manager.canReconnectVPN)
            }
        }
        .padding(.bottom, 88)      // sits just above the tab bar
        .animation(.easeInOut(duration: 0.2), value: installer.stage)
        .task { AppAutoUpdater.shared.autoCheckIfDue() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { AppAutoUpdater.shared.autoCheckIfDue() }
        }
    }

    private func card(_ job: NativeInstaller.Job) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                icon
                Text(job.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                if !installer.isActive {
                    Button { installer.dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                }
            }
            if case .failed = installer.stage {
                Text(installer.stage.label).font(.caption).foregroundStyle(.red).lineLimit(4)
            } else if manager.phase == .pairing {
                if let pin = pairing.pin {
                    Text("Pairing code \(pin) — enter it in Settings › Developer Mode.")
                        .font(.caption.monospacedDigit())
                } else {
                    Text("Open Settings › Privacy & Security › Developer Mode and choose Pair with AirShare.")
                        .font(.caption)
                }
            } else if installer.stage == .done, !installer.timingSummary.isEmpty {
                Text("Installed").font(.caption).foregroundStyle(.secondary)
                Text(installer.timingSummary).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text(installer.stage.label).font(.caption).foregroundStyle(.secondary)
                if installer.isActive { ProgressView(value: installer.progress) }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 14)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    @ViewBuilder private var icon: some View {
        switch installer.stage {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        default: Image(systemName: "arrow.down.app.fill")
        }
    }
}

/// Hides OTA-only UI (domain / TLS cert tiles) while Native install is selected.
struct HiddenWhenNative<Content: View>: View {
    @AppStorage(NativeInstaller.methodKey) private var method: String = "ota"
    @ViewBuilder var content: () -> Content
    var body: some View {
        if method != "native" { content() }
    }
}
