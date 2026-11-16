//
// Brand: Tetherless · https://tetherless.dev
//  FairPlaySelfHeal.swift
//  Detect FairPlay failure class and automatically remediate (live install switch,
//  SINF restage, memory pause) before surfacing Media & Purchases guidance.
//

import Foundation

/// Outer heal loop around `FairPlayDecrypt.decryptMachOs`.
/// Keeps the decrypt engine pure; companion/host call this when they want auto-recovery.
enum FairPlaySelfHeal {
    enum Strategy: String, Sendable {
        case preferLiveInstall
        case fallbackEmbedded
        case restageSinfs
        case memoryPauseAndRetry
        case switchLiveAfterPartial
    }

    struct Context: Sendable {
        /// Preferred first input (usually live install when known).
        var readingFrom: URL
        var writingTo: URL
        /// Live App Store install for the same bundle, if readable.
        var liveInstall: URL? = nil
        /// EmbeddedPayload / IPA app tree fallback.
        var embeddedOrIPA: URL? = nil
        var maxRounds: Int = 3
        var progress: (@Sendable (String) -> Void)? = nil
    }

    struct Outcome: Sendable {
        var report: FairPlayDecryptReport
        var strategiesApplied: [Strategy]
    }

    /// Classify an error + optional fpcore log lines into a healable failure class.
    static func classify(error: Error, logs: [String] = []) -> FairPlayFailureClass {
        if let fp = error as? FairPlayDecryptError {
            switch fp {
            case .outOfMemory: return .outOfMemory
            case .missingLicense: return .licenseOrKeys
            case .stillEncrypted, .mainExecutableFailed:
                break
            default:
                break
            }
        }
        var lines = logs
        lines.append(error.localizedDescription)
        return FairPlayFailureClass.current(fromLogs: lines)
    }

    /// Decrypt with automatic detection + heal retries.
    @discardableResult
    static func healAndDecrypt(context: Context) throws -> Outcome {
        var applied: [Strategy] = []
        var readingFrom = context.readingFrom
        var lastError: Error?
        let progress = context.progress

        // Prefer live install up front when the caller started on an embed copy.
        if let live = context.liveInstall,
           !pathsEqual(readingFrom, live),
           FairPlayDecrypt.isLiveAppStoreInstall(live) {
            progress?("Self-heal: preferring live App Store install for FairPlay keys…")
            readingFrom = live
            applied.append(.preferLiveInstall)
        }

        for round in 1...max(1, context.maxRounds) {
            do {
                // Proactive memory heal before each attempt (Jetsam / mremap ENOMEM).
                if fp_memory_tight_for(64 * 1024 * 1024) != 0 {
                    progress?("Self-heal: low memory — pausing before decrypt…")
                    if !applied.contains(.memoryPauseAndRetry) {
                        applied.append(.memoryPauseAndRetry)
                    }
                    Thread.sleep(forTimeInterval: 0.9)
                }

                if !FairPlayDecrypt.isLiveAppStoreInstall(readingFrom) {
                    let staged = FairPlayDecrypt.replicateSinfs(in: readingFrom)
                    if staged > 0 {
                        progress?("Self-heal: restaged \(staged) SINF license(s)…")
                        if !applied.contains(.restageSinfs) { applied.append(.restageSinfs) }
                    }
                }

                let label = FairPlayDecrypt.isLiveAppStoreInstall(readingFrom)
                    ? "live install"
                    : readingFrom.lastPathComponent
                progress?("Self-heal round \(round)/\(context.maxRounds): decrypting from \(label)…")

                let report = try FairPlayDecrypt.decryptMachOs(
                    readingFrom: readingFrom,
                    writingTo: context.writingTo,
                    progress: progress
                )

                // Partial / leftover required binaries — one more pass from live if unused.
                if (!report.failed.isEmpty || report.isPartial),
                   let live = context.liveInstall,
                   !pathsEqual(readingFrom, live) {
                    progress?("Self-heal: partial decrypt — retrying required binaries from live install…")
                    applied.append(.switchLiveAfterPartial)
                    readingFrom = live
                    lastError = FairPlayDecryptError.stillEncrypted(
                        "Partial decrypt (\(report.failed.count) leftover); retrying live install."
                    )
                    continue
                }

                if !applied.isEmpty {
                    progress?("Self-heal applied: \(applied.map(\.rawValue).joined(separator: ", "))")
                }
                return Outcome(report: report, strategiesApplied: applied)
            } catch {
                lastError = error
                let klass = classify(error: error)
                progress?("Self-heal detected \(klass.rawValue): \(shortError(error))")

                switch klass {
                case .outOfMemory:
                    progress?("Self-heal: ENOMEM — pausing for free memory, then retrying…")
                    if !applied.contains(.memoryPauseAndRetry) {
                        applied.append(.memoryPauseAndRetry)
                    }
                    Thread.sleep(forTimeInterval: 1.6)
                    // Same readingFrom next round.
                    continue

                case .licenseOrKeys:
                    if let live = context.liveInstall, !pathsEqual(readingFrom, live) {
                        progress?("Self-heal: EPERM/license — switching to live App Store install…")
                        readingFrom = live
                        if !applied.contains(.preferLiveInstall) {
                            applied.append(.preferLiveInstall)
                        }
                        continue
                    }
                    if let embed = context.embeddedOrIPA, !pathsEqual(readingFrom, embed) {
                        progress?("Self-heal: restaging SINFs on EmbeddedPayload and retrying…")
                        _ = FairPlayDecrypt.replicateSinfs(in: embed)
                        readingFrom = embed
                        applied.append(.fallbackEmbedded)
                        applied.append(.restageSinfs)
                        continue
                    }
                    // Exhausted heal paths — distinguish missing live install vs missing keys.
                    if context.liveInstall == nil {
                        throw FairPlayDecryptError.mainExecutableFailed(
                            "Couldn't decrypt after self-heal (licenseOrKeys): no live App Store install of this app was readable on this iPhone. Install the app from the App Store with the same Apple ID (so FairPlay can use the live install path), keep Media & Purchases signed in, then open Tetherless Decrypt again. EmbeddedPayload alone often returns mremap EPERM."
                        )
                    }
                    throw FairPlayDecryptError.mainExecutableFailed(
                        "Couldn't decrypt after self-heal (\(klass.rawValue)). \(FairPlayFailureClass.licenseOrKeys.userMessage)"
                    )

                case .stillEncrypted:
                    if let live = context.liveInstall, !pathsEqual(readingFrom, live) {
                        progress?("Self-heal: still encrypted — retrying from live install…")
                        readingFrom = live
                        if !applied.contains(.preferLiveInstall) {
                            applied.append(.preferLiveInstall)
                        }
                        continue
                    }
                    if let embed = context.embeddedOrIPA, !pathsEqual(readingFrom, embed) {
                        progress?("Self-heal: still encrypted — restaging embed SINFs…")
                        _ = FairPlayDecrypt.replicateSinfs(in: embed)
                        readingFrom = embed
                        applied.append(.fallbackEmbedded)
                        continue
                    }
                    throw error

                case .io, .other, .none:
                    if let live = context.liveInstall, !pathsEqual(readingFrom, live) {
                        progress?("Self-heal: retrying from live install…")
                        readingFrom = live
                        if !applied.contains(.preferLiveInstall) {
                            applied.append(.preferLiveInstall)
                        }
                        continue
                    }
                    throw error
                }
            }
        }

        throw lastError ?? FairPlayDecryptError.failed(
            "FairPlay self-heal exhausted after \(context.maxRounds) round(s). \(AppStoreDecryptGuide.failureHint)"
        )
    }

    // MARK: - Helpers

    private static func pathsEqual(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func shortError(_ error: Error) -> String {
        let t = error.localizedDescription
        if t.count <= 160 { return t }
        return String(t.prefix(157)) + "…"
    }
}
