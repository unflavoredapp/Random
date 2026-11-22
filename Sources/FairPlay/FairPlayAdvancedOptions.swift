//
// Brand: Tetherless · https://tetherless.dev
//  FairPlayAdvancedOptions.swift
//  Power-user FairPlay decrypt controls — source preference, verbose console,
//  encrypted-IPA retention, and targeted retry depth. Host stamps these into
//  the companion snapshot (no secrets).
//

import Foundation

/// Advanced FairPlay decrypt preferences (UserDefaults + companion hostSnapshot).
enum FairPlayAdvancedOptions {
    enum SourceMode: String, CaseIterable, Identifiable, Sendable {
        /// Live install → stamped encrypted IPA → EmbeddedPayload.
        case automatic
        /// Only read from a live App Store install (fail if missing).
        case liveInstall
        /// Only unpack the host-stamped encrypted IPA temp URL.
        case stampedIPA
        /// Only decrypt EmbeddedPayload inside the companion.
        case embeddedPayload

        var id: String { rawValue }

        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .liveInstall: return "Live install only"
            case .stampedIPA: return "Stamped IPA only"
            case .embeddedPayload: return "EmbeddedPayload only"
            }
        }

        var detail: String {
            switch self {
            case .automatic:
                return "Prefer live App Store path, then durable EncryptedIPAs temp, then EmbeddedPayload."
            case .liveInstall:
                return "FairPlay mremap only from the on-device App Store install (best for Roblox-style EPERM)."
            case .stampedIPA:
                return "Unpack the stamped encrypted IPA temp URL the host held after Get."
            case .embeddedPayload:
                return "Decrypt only the companion’s EmbeddedPayload copy (often EPERM without live licenses)."
            }
        }
    }

    static let sourceModeKey = "tetherless.fairplay.sourceMode"
    static let verboseKey = "tetherless.fairplay.verboseConsole"
    static let keepEncryptedIPAKey = "tetherless.fairplay.keepEncryptedIPA"
    static let retryRoundsKey = "tetherless.fairplay.retryRounds"
    static let pathDiagnosticsKey = "tetherless.fairplay.pathDiagnostics"
    static let requireAllFrameworksKey = "tetherless.fairplay.requireAllFrameworks"
    static let includeTestFlightKey = "tetherless.fairplay.includeTestFlight"

    /// Default retry schedule length when unset (matches buddy3).
    static let defaultRetryRounds = 5

    static var sourceMode: SourceMode {
        get {
            let raw = UserDefaults.standard.string(forKey: sourceModeKey) ?? SourceMode.automatic.rawValue
            return SourceMode(rawValue: raw) ?? .automatic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sourceModeKey) }
    }

    static var verboseConsole: Bool {
        get { UserDefaults.standard.bool(forKey: verboseKey) }
        set { UserDefaults.standard.set(newValue, forKey: verboseKey) }
    }

    /// When true (default), leave EncryptedIPAs after a successful clear export.
    static var keepEncryptedIPA: Bool {
        get {
            if UserDefaults.standard.object(forKey: keepEncryptedIPAKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: keepEncryptedIPAKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: keepEncryptedIPAKey) }
    }

    /// Targeted cryptid-retry rounds (3…8).
    static var retryRounds: Int {
        get {
            let n = UserDefaults.standard.integer(forKey: retryRoundsKey)
            if n == 0 { return defaultRetryRounds }
            return min(8, max(3, n))
        }
        set { UserDefaults.standard.set(min(8, max(3, newValue)), forKey: retryRoundsKey) }
    }

    static var pathDiagnostics: Bool {
        get { UserDefaults.standard.bool(forKey: pathDiagnosticsKey) }
        set { UserDefaults.standard.set(newValue, forKey: pathDiagnosticsKey) }
    }

    /// When true, optional framework soft-fails become hard failures.
    static var requireAllFrameworks: Bool {
        get { UserDefaults.standard.bool(forKey: requireAllFrameworksKey) }
        set { UserDefaults.standard.set(newValue, forKey: requireAllFrameworksKey) }
    }

    /// When true, installed TestFlight betas appear as FairPlay decrypt targets.
    /// Default off — Apple system / TestFlight titles often hit mremap ENOMEM and are gated.
    static var includeTestFlightApps: Bool {
        get {
            if UserDefaults.standard.object(forKey: includeTestFlightKey) == nil { return false }
            return UserDefaults.standard.bool(forKey: includeTestFlightKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: includeTestFlightKey) }
    }

    /// Resolved options for one decrypt run (host defaults or companion snapshot).
    struct Resolved: Sendable, Equatable {
        var sourceMode: SourceMode
        var verboseConsole: Bool
        var keepEncryptedIPA: Bool
        var retryRounds: Int
        var pathDiagnostics: Bool
        var requireAllFrameworks: Bool
        var includeTestFlightApps: Bool

        static var current: Resolved {
            Resolved(
                sourceMode: FairPlayAdvancedOptions.sourceMode,
                verboseConsole: FairPlayAdvancedOptions.verboseConsole,
                keepEncryptedIPA: FairPlayAdvancedOptions.keepEncryptedIPA,
                retryRounds: FairPlayAdvancedOptions.retryRounds,
                pathDiagnostics: FairPlayAdvancedOptions.pathDiagnostics,
                requireAllFrameworks: FairPlayAdvancedOptions.requireAllFrameworks,
                includeTestFlightApps: FairPlayAdvancedOptions.includeTestFlightApps
            )
        }

        static func from(snapshot: [String: Any]?) -> Resolved {
            var r = Resolved.current
            guard let snapshot else { return r }
            if let raw = snapshot["fpSourceMode"] as? String,
               let mode = SourceMode(rawValue: raw) {
                r.sourceMode = mode
            }
            if let v = snapshot["fpVerbose"] as? Bool { r.verboseConsole = v }
            if let v = snapshot["fpKeepEncryptedIPA"] as? Bool { r.keepEncryptedIPA = v }
            if let n = snapshot["fpRetryRounds"] as? Int {
                r.retryRounds = min(8, max(3, n))
            } else if let n = snapshot["fpRetryRounds"] as? NSNumber {
                r.retryRounds = min(8, max(3, n.intValue))
            }
            if let v = snapshot["fpPathDiagnostics"] as? Bool { r.pathDiagnostics = v }
            if let v = snapshot["fpRequireAllFrameworks"] as? Bool { r.requireAllFrameworks = v }
            if let v = snapshot["fpIncludeTestFlight"] as? Bool { r.includeTestFlightApps = v }
            return r
        }

        func snapshotFields() -> [String: Any] {
            [
                "fpSourceMode": sourceMode.rawValue,
                "fpVerbose": verboseConsole,
                "fpKeepEncryptedIPA": keepEncryptedIPA,
                "fpRetryRounds": retryRounds,
                "fpPathDiagnostics": pathDiagnostics,
                "fpRequireAllFrameworks": requireAllFrameworks,
                "fpIncludeTestFlight": includeTestFlightApps,
            ]
        }

        /// buddy3-style backoff truncated/extended to `retryRounds`.
        var retryBackoffSeconds: [TimeInterval] {
            let base: [TimeInterval] = [0.10, 0.25, 0.50, 1.0, 2.0, 3.0, 4.0, 5.0]
            return Array(base.prefix(retryRounds))
        }
    }

    static func resetToDefaults() {
        sourceMode = .automatic
        verboseConsole = false
        keepEncryptedIPA = true
        retryRounds = defaultRetryRounds
        pathDiagnostics = false
        requireAllFrameworks = false
        includeTestFlightApps = true
    }
}
