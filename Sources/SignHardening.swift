//
//  SignHardening.swift
//  Keeps TrustCore signing alive on very large IPAs (2–3 GB+):
//    • SignGate        – heavy IPAs sign strictly one at a time, in order
//    • free-space preflight before anything is extracted
//    • keep-awake + background-time assertion for the length of the job
//    • stale temp sweep (crashed / killed runs can't fill the disk)
//    • thermal cool-down wait instead of signing into a throttled device
//    • post-pack integrity check of the signed IPA
//    • one automatic retry on the conservative path (no fast zip, no parallel)
//

import Foundation
import UIKit
import Darwin

/// FIFO async mutex. `release()` hands the lane straight to the next waiter.
nonisolated actor SignGate {
    static let shared = SignGate()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

nonisolated final class SignJobToken: @unchecked Sendable {
    var background: UIBackgroundTaskIdentifier = .invalid
    var activity: NSObjectProtocol?
}

nonisolated enum SignGuard {
    /// IPAs at or above this size use the one-at-a-time lane.
    static let heavyIPABytes: Int64 = 400 * 1_024 * 1_024
    /// IPAs at or above this size are never copied into the sign cache (the copy costs more than it saves).
    static let cacheCeilingBytes: Int64 = 1_024 * 1_024 * 1_024

    private static let lock = NSLock()
    nonisolated(unsafe) private static var activeDirs = Set<String>()
    nonisolated(unsafe) private static var liveJobs = 0

    // MARK: Sizes

    static func ipaSize(_ url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(v?.fileSize ?? 0)
    }

    static func isHeavy(_ url: URL) -> Bool { ipaSize(url) >= heavyIPABytes }

    private static func fmt(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    // MARK: Free space

    static func availableBytes() -> Int64? {
        let v = try? FileManager.default.temporaryDirectory
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = v?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        if let plain = v?.volumeAvailableCapacity { return Int64(plain) }
        return nil
    }

    /// Throws before extraction if the device can't hold: extracted tree + signed output + headroom.
    static func preflight(ipa: URL, onLog: (@Sendable (String) -> Void)?) throws {
        let ipaBytes = ipaSize(ipa)
        guard ipaBytes > 0, let free = availableBytes() else { return }
        let fastPath = UserDefaults.standard.bool(forKey: ZipFast.enabledKey)
        var uncompressed = Int64(Double(ipaBytes) * 1.3)
        if let entries = try? ZipDelta.entries(of: ipa) {
            uncompressed = entries.reduce(Int64(0)) { $0 + Int64($1.uncomp) }
        }
        let output = fastPath ? ipaBytes : max(ipaBytes, uncompressed)     // stored repack ≈ uncompressed size
        let headroom: Int64 = 256 * 1_024 * 1_024
        let need = uncompressed + output + headroom
        onLog?(">>> Storage check: need ≈ \(fmt(need)), free \(fmt(free))")
        if free < need {
            throw SignEngineError.storage("Not enough free storage to sign this IPA: needs about \(fmt(need)) of working space, only \(fmt(free)) is free. Free up space and try again.")
        }
    }

    // MARK: Temp hygiene

    static func registerWork(_ url: URL) { lock.lock(); activeDirs.insert(url.path); lock.unlock() }
    static func unregisterWork(_ url: URL) { lock.lock(); activeDirs.remove(url.path); lock.unlock() }

    /// Removes leftovers of crashed / killed signing runs. Anything touched recently or owned by a live job stays.
    @discardableResult
    static func sweepStaleTemp(olderThan age: TimeInterval = 3_600) -> Int64 {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        lock.lock(); let active = activeDirs; lock.unlock()
        var freed: Int64 = 0
        let items = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey])) ?? []
        for u in items {
            let n = u.lastPathComponent
            let isWork = n.hasPrefix("sign-") || n.hasPrefix("meta-") || n.hasPrefix("parallel-size-")
            let isOrphanIPA = n.hasSuffix(".ipa") && n.contains("-signed-")
            guard isWork || isOrphanIPA, !active.contains(u.path) else { continue }
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            guard Date().timeIntervalSince(m) > age else { continue }
            freed += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            try? fm.removeItem(at: u)
        }
        return freed
    }

    // MARK: Keep-awake / background time

    static func begin(_ label: String) async -> SignJobToken {
        let t = SignJobToken()
        t.activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: label)
        lock.lock(); liveJobs += 1; lock.unlock()
        await MainActor.run {
            UIApplication.shared.isIdleTimerDisabled = true      // auto-lock would suspend the app mid-sign
            t.background = UIApplication.shared.beginBackgroundTask(withName: label) {
                let id = t.background; t.background = .invalid
                if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
            }
        }
        return t
    }

    static func end(_ t: SignJobToken) async {
        if let a = t.activity { ProcessInfo.processInfo.endActivity(a); t.activity = nil }
        lock.lock(); liveJobs = max(0, liveJobs - 1); let remaining = liveJobs; lock.unlock()
        await MainActor.run {
            let id = t.background; t.background = .invalid
            if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
            if remaining == 0 { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    // MARK: Thermal

    /// Waits (up to ~2 min) for a device in `.critical` thermal state to come down before starting a heavy job.
    static func waitForCoolDown(onLog: (@Sendable (String) -> Void)?) async {
        var waited = 0
        while ProcessInfo.processInfo.thermalState == .critical, waited < 120, !Task.isCancelled {
            if waited == 0 { onLog?(">>> Device is very hot — pausing until it cools down…") }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            waited += 5
        }
    }

    // MARK: Integrity

    /// Verifies the packaged IPA is a complete zip (end-of-central-directory present) and, when the
    /// directory is readable, that it contains the app's Info.plist and CodeResources seal.
    static func verifyPackaged(_ ipa: URL, appFolderName: String) throws {
        let size = ipaSize(ipa)
        guard size > 64 else { throw SignEngineError.failed("TrustCore: the signed IPA came out empty.") }
        let handle = try FileHandle(forReadingFrom: ipa)
        defer { try? handle.close() }
        let tail = min(UInt64(size), 70_000)
        try handle.seek(toOffset: UInt64(size) - tail)
        let data = try handle.read(upToCount: Int(tail)) ?? Data()
        guard data.range(of: Data([0x50, 0x4B, 0x05, 0x06])) != nil else {
            throw SignEngineError.failed("TrustCore: the signed IPA is incomplete (zip directory missing). The device may have run out of storage.")
        }
        if let entries = try? ZipDelta.entries(of: ipa) {
            let names = Set(entries.map(\.name))
            let base = "Payload/\(appFolderName)/"
            guard names.contains(base + "Info.plist"), names.contains(base + "_CodeSignature/CodeResources") else {
                throw SignEngineError.failed("TrustCore: the signed IPA is missing its code signature seal.")
            }
        }
    }

    // MARK: Retry policy

    static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let e = error as? SignEngineError, case .storage = e { return false }
        if let e = error as? ZsignError {
            switch e {
            case .fileNotFound, .appBundleNotFound: return false
            default: return true
            }
        }
        return true
    }

    // MARK: Orchestration

    /// Runs `work` inside the full guard rail. `work(true)` is the conservative profile used for the single retry.
    static func runHardened(
        ipa: URL,
        onLog: (@Sendable (String) -> Void)?,
        _ work: (_ safeProfile: Bool) async throws -> SignOutcome
    ) async throws -> SignOutcome {
        let heavy = isHeavy(ipa)
        if heavy {
            onLog?(">>> Large IPA (\(fmt(ipaSize(ipa)))) — TrustCore signs it on the one-at-a-time lane")
            await SignGate.shared.acquire()
        }
        let token = await begin("TrustCore signing")
        var outcome: SignOutcome?
        var failure: Error?
        do {
            sweepStaleTemp()
            if heavy { await waitForCoolDown(onLog: onLog) }
            try preflight(ipa: ipa, onLog: onLog)
            do {
                outcome = try await work(false)
            } catch {
                guard isRetryable(error), !Task.isCancelled else { throw error }
                onLog?(">>> Signing hit a problem (\(error.localizedDescription)) — retrying once on the safe profile (no fast zip, no parallel signing)…")
                sweepStaleTemp(olderThan: 0)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                try preflight(ipa: ipa, onLog: nil)
                outcome = try await work(true)
            }
        } catch {
            failure = error
        }
        await end(token)
        if heavy { await SignGate.shared.release() }
        if let failure { throw failure }
        return outcome!
    }
}
