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
        /// Alias for live install (legacy snapshot value).
        case automatic
        /// Only read from a live App Store install (fail if missing) — the only supported path.
        case liveInstall
        /// Legacy — remapped to live install (EncryptedSource / stamped IPA EPERM without fairplayd).
        case stampedIPA
        /// Legacy — remapped to live install (EmbeddedPayload alone usually EPERMs).
        case embeddedPayload

        var id: String { rawValue }

        /// FairPlay mremap always uses the live App Store install.
        var effective: SourceMode { .liveInstall }

        var title: String {
            switch self {
            case .automatic, .liveInstall: return "Live install only"
            case .stampedIPA: return "Stamped IPA (legacy → live)"
            case .embeddedPayload: return "EmbeddedPayload (legacy → live)"
            }
        }

        var detail: String {
            "FairPlay mremap only from the on-device App Store install. EncryptedSource / EmbeddedPayload are never used as the FairPlay read path — install the app from the Store (same Apple ID) before Get."
        }
    }

    static let sourceModeKey = "tetherless.fairplay.sourceMode"
    static let verboseKey = "tetherless.fairplay.verboseConsole"
    static let keepEncryptedIPAKey = "tetherless.fairplay.keepEncryptedIPA"
    static let retryRoundsKey = "tetherless.fairplay.retryRounds"
    static let pathDiagnosticsKey = "tetherless.fairplay.pathDiagnostics"
    static let requireAllFrameworksKey = "tetherless.fairplay.requireAllFrameworks"
    static let includeTestFlightKey = "tetherless.fairplay.includeTestFlight"
    static let forceSerialKey = "tetherless.fairplay.forceSerial"
    static let bounceLargeCryptKey = "tetherless.fairplay.bounceLargeCrypt"
    static let partialOnLowRAMKey = "tetherless.fairplay.partialOnLowRAM"

    /// Default retry schedule length when unset (matches buddy3).
    static let defaultRetryRounds = 5

    static var sourceMode: SourceMode {
        get {
            let raw = UserDefaults.standard.string(forKey: sourceModeKey) ?? SourceMode.liveInstall.rawValue
            return (SourceMode(rawValue: raw) ?? .liveInstall).effective
        }
        set { UserDefaults.standard.set(SourceMode.liveInstall.rawValue, forKey: sourceModeKey) }
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

    /// Always decrypt Mach-Os one at a time (companion default; host can override).
    static var forceSerialDecrypt: Bool {
        get {
            if UserDefaults.standard.object(forKey: forceSerialKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: forceSerialKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: forceSerialKey) }
    }

    /// Preflight-bounce to Phone Worker when largest crypt exceeds the Jetsam threshold.
    /// Default off — match Tetherless: always try on-device (PARTIAL if needed), never auto-bounce.
    static var bounceLargeCryptToServer: Bool {
        get {
            if UserDefaults.standard.object(forKey: bounceLargeCryptKey) == nil { return false }
            return UserDefaults.standard.bool(forKey: bounceLargeCryptKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: bounceLargeCryptKey) }
    }

    /// On low RAM, prefer PARTIAL IPA (main clear) over failing the whole job on framework Jetsam.
    static var preferPartialOnLowRAM: Bool {
        get {
            if UserDefaults.standard.object(forKey: partialOnLowRAMKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: partialOnLowRAMKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: partialOnLowRAMKey) }
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
        var forceSerialDecrypt: Bool
        var bounceLargeCryptToServer: Bool
        var preferPartialOnLowRAM: Bool

        static var current: Resolved {
            Resolved(
                sourceMode: .liveInstall,
                verboseConsole: FairPlayAdvancedOptions.verboseConsole,
                keepEncryptedIPA: FairPlayAdvancedOptions.keepEncryptedIPA,
                retryRounds: FairPlayAdvancedOptions.retryRounds,
                pathDiagnostics: FairPlayAdvancedOptions.pathDiagnostics,
                requireAllFrameworks: FairPlayAdvancedOptions.requireAllFrameworks,
                includeTestFlightApps: FairPlayAdvancedOptions.includeTestFlightApps,
                forceSerialDecrypt: FairPlayAdvancedOptions.forceSerialDecrypt,
                bounceLargeCryptToServer: FairPlayAdvancedOptions.bounceLargeCryptToServer,
                preferPartialOnLowRAM: FairPlayAdvancedOptions.preferPartialOnLowRAM
            )
        }

        static func from(snapshot: [String: Any]?) -> Resolved {
            var r = Resolved.current
            r.sourceMode = .liveInstall
            guard let snapshot else { return r }
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
            if let v = snapshot["fpForceSerial"] as? Bool { r.forceSerialDecrypt = v }
            if let v = snapshot["fpBounceLargeCrypt"] as? Bool { r.bounceLargeCryptToServer = v }
            if let v = snapshot["fpPartialOnLowRAM"] as? Bool { r.preferPartialOnLowRAM = v }
            return r
        }

        func snapshotFields() -> [String: Any] {
            [
                "fpSourceMode": SourceMode.liveInstall.rawValue,
                "fpVerbose": verboseConsole,
                "fpKeepEncryptedIPA": keepEncryptedIPA,
                "fpRetryRounds": retryRounds,
                "fpPathDiagnostics": pathDiagnostics,
                "fpRequireAllFrameworks": requireAllFrameworks,
                "fpIncludeTestFlight": includeTestFlightApps,
                "fpForceSerial": forceSerialDecrypt,
                "fpBounceLargeCrypt": bounceLargeCryptToServer,
                "fpPartialOnLowRAM": preferPartialOnLowRAM,
            ]
        }

        /// buddy3-style backoff truncated/extended to `retryRounds`.
        var retryBackoffSeconds: [TimeInterval] {
            let base: [TimeInterval] = [0.10, 0.25, 0.50, 1.0, 2.0, 3.0, 4.0, 5.0]
            return Array(base.prefix(retryRounds))
        }
    }

    static func resetToDefaults() {
        sourceMode = .liveInstall
        verboseConsole = false
        keepEncryptedIPA = true
        retryRounds = defaultRetryRounds
        pathDiagnostics = false
        requireAllFrameworks = false
        includeTestFlightApps = false
        forceSerialDecrypt = true
        bounceLargeCryptToServer = false
        preferPartialOnLowRAM = true
    }
}
