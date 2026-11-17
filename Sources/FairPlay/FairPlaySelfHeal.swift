//
// Brand: Tetherless · https://tetherless.dev
//  FairPlaySelfHeal.swift
//  FairPlayed-style heal loop: EmbeddedPayload + SINF restage first (happy path),
//  then optional live App Store install / memory pause before Media & Purchases UX.
//

import Foundation

/// Outer heal loop around `FairPlayDecrypt.decryptMachOs`.
/// Keeps the decrypt engine pure; companion/host call this when they want auto-recovery.
enum FairPlaySelfHeal {
    enum Strategy: String, Sendable {
        /// FairPlayed happy path: decrypt from EmbeddedPayload / IPA tree.
        case preferEmbedded
        /// Optional heal when embed mremap EPERMs — same app's live Store container.
        case tryLiveInstall
        case restageSinfs
        case memoryPauseAndRetry
        case switchLiveAfterPartial
    }

    struct Context: Sendable {
        /// First input — FairPlayed modern path uses EmbeddedPayload / IPA, not live.
        var readingFrom: URL
        var writingTo: URL
        /// Live App Store install for the same bundle (optional heal, not required).
        var liveInstall: URL? = nil
        /// EmbeddedPayload / IPA app tree (FairPlayed happy path).
        var embeddedOrIPA: URL? = nil
        var maxRounds: Int = 4
        /// Companion console: only forward `[DECRYPTED]` / `[plain]` / `[FAILED]` / Mach-O count.
        var quietConsole: Bool = false
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

    /// Decrypt with FairPlayed-style auto-recovery:
    /// 1) EmbeddedPayload + SINF restage
    /// 2) optional live install if embed EPERMs
    /// 3) Media & Purchases guidance when keys are missing
    @discardableResult
    static func healAndDecrypt(context: Context) throws -> Outcome {
        var applied: [Strategy] = []
        var readingFrom = context.readingFrom
        var lastError: Error?
        let quiet = context.quietConsole
        let note: (@Sendable (String) -> Void)? = quiet ? nil : context.progress
        let decryptProgress: (@Sendable (String) -> Void)? = {
            guard let progress = context.progress else { return nil }
            if !quiet { return progress }
            return { msg in
                if Self.isConsoleLine(msg) { progress(msg) }
            }
        }()
        var triedLiveForLicense = false
        var triedEmbedForLicense = false

        // FairPlayed happy path: start on EmbeddedPayload / IPA when available.
        if let embed = context.embeddedOrIPA,
           !pathsEqual(readingFrom, embed),
           !FairPlayDecrypt.isLiveAppStoreInstall(embed) {
            note?("Self-heal: FairPlayed path — decrypting from EmbeddedPayload…")
            readingFrom = embed
            applied.append(.preferEmbedded)
        } else if !FairPlayDecrypt.isLiveAppStoreInstall(readingFrom) {
            applied.append(.preferEmbedded)
        }

        for round in 1...max(1, context.maxRounds) {
            do {
                if fp_memory_tight_for(64 * 1024 * 1024) != 0 {
                    note?("Self-heal: low memory — pausing before decrypt…")
                    if !applied.contains(.memoryPauseAndRetry) {
                        applied.append(.memoryPauseAndRetry)
                    }
                    Thread.sleep(forTimeInterval: 0.9)
                }

                // FairPlayed embed_ipa.sh + buddy3: restage SINFs before every embed attempt.
                if !FairPlayDecrypt.isLiveAppStoreInstall(readingFrom) {
                    let staged = stageAllSinfs(in: readingFrom)
                    if staged > 0, !applied.contains(.restageSinfs) {
                        applied.append(.restageSinfs)
                    }
                }

                let label = FairPlayDecrypt.isLiveAppStoreInstall(readingFrom)
                    ? "live install"
                    : "EmbeddedPayload/\(readingFrom.lastPathComponent)"
                note?("Self-heal round \(round)/\(context.maxRounds): decrypting from \(label)…")

                let report = try FairPlayDecrypt.decryptMachOs(
                    readingFrom: readingFrom,
                    writingTo: context.writingTo,
                    quietConsole: quiet,
                    progress: decryptProgress
                )

                if (!report.failed.isEmpty || report.isPartial),
                   let live = context.liveInstall,
                   !pathsEqual(readingFrom, live) {
                    note?("Self-heal: partial decrypt — trying live App Store install…")
                    applied.append(.switchLiveAfterPartial)
                    readingFrom = live
                    lastError = FairPlayDecryptError.stillEncrypted(
                        "Partial decrypt (\(report.failed.count) leftover); trying live install."
                    )
                    continue
                }

                if !applied.isEmpty {
                    note?("Self-heal applied: \(applied.map(\.rawValue).joined(separator: ", "))")
                }
                return Outcome(report: report, strategiesApplied: applied)
            } catch {
                lastError = error
                let klass = classify(error: error)
                note?("Self-heal detected \(klass.rawValue): \(shortError(error))")

                switch klass {
                case .outOfMemory:
                    note?("Self-heal: ENOMEM — pausing for free memory, then retrying…")
                    if !applied.contains(.memoryPauseAndRetry) {
                        applied.append(.memoryPauseAndRetry)
                    }
                    Thread.sleep(forTimeInterval: 1.6)
                    continue

                case .licenseOrKeys:
                    // Embed first (FairPlayed): restage once more from EmbeddedPayload.
                    if !triedEmbedForLicense,
                       let embed = context.embeddedOrIPA ?? embedCandidate(readingFrom),
                       !FairPlayDecrypt.isLiveAppStoreInstall(embed) {
                        triedEmbedForLicense = true
                        note?("Self-heal: EPERM/license — restaging EmbeddedPayload SINFs and retrying…")
                        _ = stageAllSinfs(in: embed)
                        readingFrom = embed
                        if !applied.contains(.preferEmbedded) { applied.append(.preferEmbedded) }
                        if !applied.contains(.restageSinfs) { applied.append(.restageSinfs) }
                        continue
                    }
                    // Optional live Store container if embed still EPERMs.
                    if !triedLiveForLicense,
                       let live = context.liveInstall,
                       !pathsEqual(readingFrom, live) {
                        triedLiveForLicense = true
                        note?("Self-heal: EPERM/license — trying live App Store install…")
                        readingFrom = live
                        if !applied.contains(.tryLiveInstall) {
                            applied.append(.tryLiveInstall)
                        }
                        continue
                    }
                    // Don't surface "self-heal" jargon — keys guidance is the actionable fix.
                    throw FairPlayDecryptError.missingLicense(
                        FairPlayFailureClass.licenseOrKeys.userMessage
                    )

                case .stillEncrypted:
                    if let embed = context.embeddedOrIPA, !pathsEqual(readingFrom, embed) {
                        note?("Self-heal: still encrypted — restaging embed SINFs…")
                        _ = stageAllSinfs(in: embed)
                        readingFrom = embed
                        if !applied.contains(.preferEmbedded) { applied.append(.preferEmbedded) }
                        if !applied.contains(.restageSinfs) { applied.append(.restageSinfs) }
                        continue
                    }
                    if let live = context.liveInstall, !pathsEqual(readingFrom, live) {
                        note?("Self-heal: still encrypted — trying live App Store install…")
                        readingFrom = live
                        if !applied.contains(.tryLiveInstall) {
                            applied.append(.tryLiveInstall)
                        }
                        continue
                    }
                    throw error

                case .io, .other, .none:
                    if let embed = context.embeddedOrIPA, !pathsEqual(readingFrom, embed) {
                        note?("Self-heal: retrying from EmbeddedPayload…")
                        readingFrom = embed
                        if !applied.contains(.preferEmbedded) { applied.append(.preferEmbedded) }
                        continue
                    }
                    if let live = context.liveInstall, !pathsEqual(readingFrom, live) {
                        note?("Self-heal: retrying from live App Store install…")
                        readingFrom = live
                        if !applied.contains(.tryLiveInstall) {
                            applied.append(.tryLiveInstall)
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

    /// Lean companion console lines (match TetherlessiOS decrypt log).
    private static func isConsoleLine(_ msg: String) -> Bool {
        msg.hasPrefix("[DECRYPTED]")
            || msg.hasPrefix("[plain]")
            || msg.hasPrefix("[FAILED]")
            || msg.hasPrefix("Decrypting ") && msg.contains("Mach-O file")
    }

    /// Manifest SinfReplicationPaths + per-binary SC_Info/<exe>.sinf (FairPlayed / buddy3).
    @discardableResult
    private static func stageAllSinfs(in app: URL) -> Int {
        var n = FairPlayDecrypt.replicateSinfs(in: app)
        if let bins = try? FairPlayDecrypt.collectMachOsForCompanion(under: app) {
            n += FairPlayDecrypt.stageSinfsForEncryptedBinaries(bins, in: app)
        }
        return n
    }

    private static func embedCandidate(_ url: URL) -> URL? {
        FairPlayDecrypt.isLiveAppStoreInstall(url) ? nil : url
    }

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
