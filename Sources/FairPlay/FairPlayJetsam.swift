//
// Brand: AppAssassin · https://fastdecrypt.ai
//  FairPlayJetsam.swift
//  Preflight, purge, pressure, and server-bounce helpers for on-device mremap.
//

import Foundation
import Darwin
#if canImport(UIKit)
import UIKit
#endif

/// Jetsam / memory policy for on-device FairPlay decrypt.
enum FairPlayJetsam {
    /// Cryptsize (bytes) above which we prefer Phone Worker / unfairplay over on-device mremap.
    static let serverBounceCryptBytes: UInt64 = 96 * 1024 * 1024
    /// Available-memory floor before starting a large decrypt (lean + headroom).
    static let minAvailableBytes: UInt64 = 96 * 1024 * 1024
    /// Soft threshold: prefer PARTIAL (main-only) when free RAM is below this and option is on.
    static let partialPreferAvailableBytes: UInt64 = 180 * 1024 * 1024

    static var availableMemory: UInt64 { fp_available_memory() }

    static func largestCryptsize(of path: String) -> Int64 {
        fp_largest_cryptsize(path)
    }

    static func canDecrypt(cryptsize: UInt64) -> Bool {
        fp_memory_can_decrypt(cryptsize) != 0
    }

    static func isTight(forCryptsize cryptsize: UInt64 = 48 * 1024 * 1024) -> Bool {
        fp_memory_tight_for(cryptsize) != 0
    }

    /// Stronger reclaim than URLCache alone — CFURL / URLSession / image caches.
    static func purgeTransientMemory() {
        URLCache.shared.removeAllCachedResponses()
        URLCache.shared.diskCapacity = 0
        URLCache.shared.memoryCapacity = 0
        URLCache.shared.diskCapacity = 20 * 1024 * 1024
        URLCache.shared.memoryCapacity = 4 * 1024 * 1024
        #if canImport(UIKit)
        URLSession.shared.reset { }
        #endif
        // Encourage allocator reclaim before the next mremap window.
        malloc_zone_pressure_relief(nil, 0)
    }

    /// Brief pause + purge when the process is near Jetsam.
    static func pauseIfMemoryPressure(progress: ((String) -> Void)?) {
        let avail = availableMemory
        if avail > 0 && avail < minAvailableBytes {
            progress?("Low memory (\(avail / (1024 * 1024)) MB free) — reclaiming before next Mach-O…")
            purgeTransientMemory()
            Thread.sleep(forTimeInterval: 1.6)
        } else if isTight(forCryptsize: 64 * 1024 * 1024) {
            progress?("Low memory — pausing before next Mach-O…")
            purgeTransientMemory()
            Thread.sleep(forTimeInterval: 1.2)
        } else if isTight(forCryptsize: 48 * 1024 * 1024) {
            progress?("Low memory — pausing before next Mach-O…")
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    /// Preflight: bounce early when lean decrypt is near-impossible for the largest crypt.
    enum Preflight {
        case ok
        /// Recommend Phone Worker / unfairplay — crypt too large or RAM too low.
        case bounceToServer(reason: String)
        /// Soft: prefer shipping PARTIAL (main clear, frameworks optional).
        case preferPartial(reason: String)
    }

    static func preflight(
        largestCrypt: Int64,
        allowPartialOnLowRAM: Bool
    ) -> Preflight {
        let crypt = UInt64(max(0, largestCrypt))
        if crypt >= serverBounceCryptBytes {
            return .bounceToServer(
                reason: String(
                    format: "Main cryptsize is %.0f MB — on-device mremap is Jetsam-prone. Bounce to Phone Worker / unfairplay.",
                    Double(crypt) / (1024.0 * 1024.0)
                )
            )
        }
        if crypt > 0 && !canDecrypt(cryptsize: crypt) {
            let avail = availableMemory
            return .bounceToServer(
                reason: String(
                    format: "Only %llu MB free for a %.0f MB crypt — Jetsam likely. Close apps or use Phone Worker / unfairplay.",
                    avail / (1024 * 1024),
                    Double(crypt) / (1024.0 * 1024.0)
                )
            )
        }
        let avail = availableMemory
        if allowPartialOnLowRAM, avail > 0, avail < partialPreferAvailableBytes, crypt > 24 * 1024 * 1024 {
            return .preferPartial(
                reason: String(
                    format: "Low RAM (%llu MB) — decrypting main first and allowing PARTIAL if frameworks Jetsam.",
                    avail / (1024 * 1024)
                )
            )
        }
        return .ok
    }

    /// Force single-worker when any secondary crypt looks large or RAM is tight.
    static func shouldForceSerial(maxSecondaryCrypt: UInt64) -> Bool {
        if maxSecondaryCrypt >= 24 * 1024 * 1024 { return true }
        if isTight(forCryptsize: max(maxSecondaryCrypt, 32 * 1024 * 1024)) { return true }
        if FairPlayAdvancedOptions.forceSerialDecrypt { return true }
        return false
    }
}

#if canImport(UIKit)
/// Observes `UIApplication.didReceiveMemoryWarningNotification` during a decrypt run.
final class FairPlayMemoryPressureObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?
    private(set) var warningCount = 0
    var onWarning: (() -> Void)?

    func start() {
        stop()
        token = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.warningCount += 1
            self.lock.unlock()
            FairPlayJetsam.purgeTransientMemory()
            self.onWarning?()
        }
    }

    func stop() {
        if let token {
            NotificationCenter.default.removeObserver(token)
            self.token = nil
        }
    }

    deinit { stop() }
}
#endif
