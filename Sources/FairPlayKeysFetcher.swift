//
// Brand: Tetherless · https://tetherless.dev
//  FairPlayKeysFetcher.swift
//  Guided FairPlay readiness for companion decrypt (on-device mremap).
//
//  What open-source tools actually do (and what we can / cannot copy):
//  • EthanArbuckle/fairplay-decrypt + londek/ipadecrypt — mint a reusable
//    16-byte account credential from a *jailbroken* device (SIDB + SINF).
//    Requires ≥1 owned App Store app installed. We cannot mint that credential
//    from a sideloaded host (no root / fairplayd private state).
//  • fouldecrypt / FairPlayed / TrollDecrypt — decrypt on-device while fairplayd
//    has the account enrolled; keys never leave the device as a file. TetherLess
//    companion uses the same class of path (mremap next to SC_Info on a live
//    install). Prerequisites: Media & Purchases / App Store sign-in for the
//    owning Apple ID, plus an App Store install that carries SC_Info.
//
//  This fetcher therefore: (1) deep-links App Store Account / Media & Purchases,
//  (2) checks for ≥1 App Store install via installd Path when paired,
//  (3) soft-probes SC_Info beside those paths, (4) requires explicit confirm.
//

import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class FairPlayKeysFetcher: ObservableObject {
    static let shared = FairPlayKeysFetcher()

    enum Destination: String, Equatable {
        case appStoreAccount
        case mediaAndPurchases
        case seedApp
    }

    /// One App Store install visible for the active session (installd / history).
    struct LicenseEntry: Equatable, Identifiable {
        var id: String { bundleID }
        var name: String
        var bundleID: String
        var version: String
        var hasSCInfo: Bool
        /// Short path tail for debugging (last 2 components), empty when unknown.
        var pathTail: String
    }

    /// Open-source-style readiness snapshot (install + SC_Info), not a credential.
    struct Readiness: Equatable {
        var storeApps: Int
        var scInfoHits: Int
        var licenses: [LicenseEntry]

        static let empty = Readiness(storeApps: 0, scInfoHits: 0, licenses: [])
    }

    enum Phase: Equatable {
        case idle
        case redirecting(email: String, destination: Destination)
        case waitingForReturn(email: String, destination: Destination)
        case verifying(email: String)
        /// Soft checks done — user must confirm they signed in as this Apple ID.
        case confirmSignIn(email: String, readiness: Readiness)
        case grabbed(email: String, at: Date, readiness: Readiness)
        case needsAccount
    }

    @Published private(set) var phase: Phase = .idle
    @Published var banner: String?
    @Published var verifyLines: [String] = []
    /// Last readiness probe (also shown while idle after a scan).
    @Published private(set) var lastReadiness: Readiness = .empty
    /// App Store licenses / installs visible for this session (detail for the capture sheet).
    @Published private(set) var sessionLicenses: [LicenseEntry] = []
    @Published private(set) var licensesScanning = false

    private var foregroundObserver: NSObjectProtocol?
    private var openedAt: Date?
    private var armReturnAfter: Date?
    private var verifyTask: Task<Void, Never>?

    private static let grabbedAtPrefix = "tetherless.decrypt.keysGrabbedAt."
    private static let hintsPrefix = "tetherless.decrypt.keysLicenseHints."
    private static let storeAppsPrefix = "tetherless.decrypt.keysStoreApps."

    private init() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDidBecomeActive() }
        }
        refreshFromAck()
    }

    var isWaiting: Bool {
        switch phase {
        case .redirecting, .waitingForReturn, .verifying: return true
        default: return false
        }
    }

    var isGrabbed: Bool {
        if case .grabbed = phase { return true }
        return false
    }

    var needsConfirm: Bool {
        if case .confirmSignIn = phase { return true }
        return false
    }

    /// Sync phase with the per-email ack bit (Search tab / Account switch).
    func refreshFromAck() {
        let email = activeEmail()
        guard AppleIDStore.shared.isSignedIn, !email.isEmpty else {
            if case .waitingForReturn = phase { return }
            if case .verifying = phase { return }
            if case .confirmSignIn = phase { return }
            if case .redirecting = phase { return }
            phase = .idle
            sessionLicenses = []
            return
        }
        switch phase {
        case .waitingForReturn, .verifying, .confirmSignIn, .redirecting:
            return
        default:
            break
        }
        if AppStoreDecryptGuide.isAcknowledged(email: email) {
            let at = grabbedAt(email: email) ?? Date()
            var readiness = storedReadiness(email: email)
            // Keep any live license list we already probed this session.
            if readiness.licenses.isEmpty, !sessionLicenses.isEmpty {
                readiness.licenses = sessionLicenses
                readiness.storeApps = max(readiness.storeApps, sessionLicenses.count)
                readiness.scInfoHits = max(readiness.scInfoHits, sessionLicenses.filter(\.hasSCInfo).count)
            }
            lastReadiness = readiness
            if case .grabbed(let current, _, _) = phase, current == email { return }
            phase = .grabbed(email: email, at: at, readiness: readiness)
        } else if case .grabbed = phase {
            phase = .idle
        }
    }

    /// Refresh the on-device App Store license list for the capture sheet (does not change phase).
    func refreshSessionLicenses() {
        Task { @MainActor in
            licensesScanning = true
            defer { licensesScanning = false }
            let readiness = await probeReadiness()
            lastReadiness = readiness
            sessionLicenses = readiness.licenses
        }
    }

    /// Present the dedicated capture sheet (Search / gate failures).
    func presentCaptureSheet() {
        AppNav.shared.presentFairPlayKeysCapture = true
        AppNav.shared.goSearch()
    }

    /// Open App Store account sheet or Media & Purchases for the active session.
    func startFetchFromSession(preferSettings: Bool = false) {
        guard AppleIDStore.shared.isSignedIn else {
            phase = .needsAccount
            banner = "Sign in under Account first, then grab FairPlay keys."
            AppNav.shared.goAccount()
            return
        }
        let email = activeEmail()
        guard !email.isEmpty else {
            phase = .needsAccount
            banner = "Sign in under Account first, then grab FairPlay keys."
            AppNav.shared.goAccount()
            return
        }

        cacheEmail(email)
        verifyTask?.cancel()
        verifyLines = []

        let dest: Destination = preferSettings ? .mediaAndPurchases : .appStoreAccount
        openedAt = Date()
        armReturnAfter = Date().addingTimeInterval(1.4)
        phase = .redirecting(email: email, destination: dest)
        banner = dest == .mediaAndPurchases
            ? "Opening Media & Purchases — sign in with \(email), then return here."
            : "Opening App Store account — sign in with \(email), then return here."

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard case .redirecting(let e, let d) = self.phase, e == email else { return }
            self.phase = .waitingForReturn(email: email, destination: d)
            switch d {
            case .appStoreAccount:
                AppStoreDecryptGuide.openAppStoreAccountSheet()
            case .mediaAndPurchases:
                AppStoreDecryptGuide.openMediaAndPurchases()
            case .seedApp:
                AppStoreDecryptGuide.openAppStoreListing(DeviceDecryptService.smokeTestApp.url)
            }
        }
    }

    /// Open a free App Store listing (TestFlight) so the account can install ≥1 store app —
    /// same prerequisite as fairplay-decrypt / ipadecrypt mint (“≥1 owned App Store app”).
    func openSeedAppStoreApp() {
        let email = activeEmail()
        guard !email.isEmpty else {
            phase = .needsAccount
            return
        }
        cacheEmail(email)
        verifyTask?.cancel()
        openedAt = Date()
        armReturnAfter = Date().addingTimeInterval(1.4)
        phase = .redirecting(email: email, destination: .seedApp)
        banner = "Open TestFlight (free) and Install with \(email), then return here."
        verifyLines = []
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard case .redirecting(let e, .seedApp) = self.phase, e == email else { return }
            self.phase = .waitingForReturn(email: email, destination: .seedApp)
            AppStoreDecryptGuide.openAppStoreListing(DeviceDecryptService.smokeTestApp.url)
        }
    }

    /// User confirmed they signed in as the session Apple ID.
    func confirmGrabbed() {
        let email: String
        let readiness: Readiness
        switch phase {
        case .confirmSignIn(let e, let r):
            email = e; readiness = r
        case .verifying(let e):
            email = e; readiness = lastReadiness
        case .waitingForReturn(let e, _):
            email = e; readiness = lastReadiness
        default:
            email = activeEmail(); readiness = lastReadiness
        }
        guard !email.isEmpty else {
            phase = .needsAccount
            return
        }
        finishGrab(email: email, readiness: readiness, source: "confirm")
    }

    /// Manual path when already signed in (skips redirect).
    func markGrabbedManually() {
        let email = activeEmail()
        guard !email.isEmpty else {
            phase = .needsAccount
            return
        }
        Task { @MainActor in
            phase = .verifying(email: email)
            banner = "Checking installd for App Store apps + SC_Info…"
            let readiness = await probeReadiness()
            presentConfirm(email: email, readiness: readiness, fromReturn: false)
        }
    }

    func cancelCapture() {
        verifyTask?.cancel()
        openedAt = nil
        armReturnAfter = nil
        verifyLines = []
        banner = nil
        phase = .idle
        refreshFromAck()
    }

    // MARK: - Lifecycle

    private func handleDidBecomeActive() {
        guard case .waitingForReturn(let email, _) = phase else { return }
        if let armReturnAfter, Date() < armReturnAfter { return }
        if let openedAt, Date().timeIntervalSince(openedAt) < 2.0 { return }
        beginVerify(email: email)
    }

    private func beginVerify(email: String) {
        verifyTask?.cancel()
        phase = .verifying(email: email)
        banner = "Back in TetherLess — checking readiness for \(email)…"
        verifyLines = ["Returned from App Store"]
        verifyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            verifyLines.append("Matching session \(email)")
            cacheEmail(email)

            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            verifyLines.append("Probing App Store installs (installd Path)…")
            let readiness = await probeReadiness()

            guard !Task.isCancelled else { return }
            if readiness.storeApps > 0 {
                verifyLines.append("Found \(readiness.storeApps) App Store install(s)")
            } else {
                verifyLines.append("No App Store installs visible — install a free app under \(email)")
            }
            if readiness.scInfoHits > 0 {
                verifyLines.append("SC_Info readable beside \(readiness.scInfoHits) install(s)")
            } else if readiness.storeApps > 0 {
                verifyLines.append("SC_Info not readable from host — companion still uses live install path")
            } else {
                verifyLines.append("Install ≥1 App Store app (open-source mint prerequisite), then Confirm")
            }

            presentConfirm(email: email, readiness: readiness, fromReturn: true)
            openedAt = nil
            armReturnAfter = nil
        }
    }

    private func presentConfirm(email: String, readiness: Readiness, fromReturn: Bool) {
        lastReadiness = readiness
        phase = .confirmSignIn(email: email, readiness: readiness)
        if readiness.scInfoHits > 0 {
            banner = "Ready — confirm keys for \(email)."
        } else if readiness.storeApps > 0 {
            banner = "App Store installs found. If Account Settings showed \(email), tap Confirm."
        } else if fromReturn {
            banner = "Sign-in step done. Install a free App Store app under \(email) if you haven’t, then Confirm."
        } else {
            banner = "Confirm Media & Purchases / App Store for \(email). Prefer ≥1 installed store app."
        }
    }

    private func finishGrab(email: String, readiness: Readiness, source: String) {
        AppStoreDecryptGuide.setAcknowledged(true, email: email)
        let key = email.lowercased()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.grabbedAtPrefix + key)
        UserDefaults.standard.set(readiness.scInfoHits, forKey: Self.hintsPrefix + key)
        UserDefaults.standard.set(readiness.storeApps, forKey: Self.storeAppsPrefix + key)
        DecryptCompanionHandoff.publishHostSnapshot()
        lastReadiness = readiness
        phase = .grabbed(email: email, at: Date(), readiness: readiness)
        var detail = "Keys grabbed for \(email)"
        if readiness.storeApps > 0 {
            detail += " · \(readiness.storeApps) store app(s)"
        }
        if readiness.scInfoHits > 0 {
            detail += " · \(readiness.scInfoHits) SC_Info"
        }
        banner = source == "confirm" ? detail : "Keys marked ready for \(email)."
        verifyLines = []
        openedAt = nil
        armReturnAfter = nil
        AppNav.shared.presentFairPlayKeysCapture = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if case .grabbed = self.phase { self.banner = nil }
        }
    }

    // MARK: - Readiness probe (installd-oriented)

    /// Aligns with foulwrapper / FairPlayed: find live App Store installs and SC_Info
    /// beside installd `Path`. Bounded refresh — never hang the sheet on pairing.
    private func probeReadiness() async -> Readiness {
        await refreshDeviceLibraryBounded(seconds: 2.5)

        let includeTF = FairPlayAdvancedOptions.includeTestFlightApps
        let storeApps = DeviceLibrary.shared.apps.filter {
            $0.isDecryptTarget(includeTestFlight: includeTF)
        }
        struct Candidate {
            var bundleID: String
            var name: String
            var version: String
            var path: String?
        }
        var candidates: [Candidate] = storeApps.map {
            Candidate(bundleID: $0.bundleID, name: $0.name, version: $0.version, path: $0.installPath)
        }
        if candidates.isEmpty {
            candidates = DecryptClient.shared.history.compactMap { app in
                let b = app.bundle.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !b.isEmpty else { return nil }
                return Candidate(
                    bundleID: b,
                    name: app.name.isEmpty ? b : app.name,
                    version: app.version,
                    path: nil
                )
            }
        }

        var seen = Set<String>()
        var licenses: [LicenseEntry] = []
        for item in candidates where seen.insert(item.bundleID).inserted {
            guard licenses.count < 40 else { break }
            let live: URL?
            if let path = item.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
                live = FairPlayDecrypt.installedAppURL(bundleID: item.bundleID, knownPath: path)
                    ?? URL(fileURLWithPath: path)
            } else {
                live = FairPlayDecrypt.installedAppURL(bundleID: item.bundleID)
            }
            let hasSC = live.map { scInfoExists(beside: $0) } ?? false
            licenses.append(LicenseEntry(
                name: item.name,
                bundleID: item.bundleID,
                version: item.version,
                hasSCInfo: hasSC,
                pathTail: pathTail(live)
            ))
        }

        // Also include library apps we skipped if candidate list came from history only.
        let storeCount = max(storeApps.count, licenses.count)
        let hits = licenses.filter(\.hasSCInfo).count
        let readiness = Readiness(storeApps: storeCount, scInfoHits: hits, licenses: licenses)
        lastReadiness = readiness
        sessionLicenses = licenses
        return readiness
    }

    private func scInfoExists(beside appURL: URL) -> Bool {
        let sc = appURL.appendingPathComponent("SC_Info", isDirectory: true)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: sc.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func pathTail(_ url: URL?) -> String {
        guard let url else { return "" }
        let parts = url.path.split(separator: "/").suffix(2).map(String.init)
        return parts.joined(separator: "/")
    }

    /// Await DeviceLibrary refresh at most `seconds`; keep cache on timeout/failure.
    private func refreshDeviceLibraryBounded(seconds: Double) async {
        guard NativeInstaller.isSelected, DevicePairingStore.hasSavedPairing else {
            DeviceLibrary.shared.refreshIfStale()
            return
        }
        let nanos = UInt64(max(0.5, seconds) * 1_000_000_000)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                _ = await DeviceLibrary.shared.refreshAwaiting()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: nanos)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Helpers

    private func activeEmail() -> String {
        AppleIDStore.shared.email.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cacheEmail(_ email: String) {
        UserDefaults.standard.set(email, forKey: "tetherless.appleid.activeEmailCache")
        UserDefaults(suiteName: "group.dev.tetherless.app")?
            .set(email, forKey: "tetherless.appleid.activeEmailCache")
    }

    private func grabbedAt(email: String) -> Date? {
        let key = Self.grabbedAtPrefix + email.lowercased()
        let t = UserDefaults.standard.double(forKey: key)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private func storedReadiness(email: String) -> Readiness {
        let key = email.lowercased()
        return Readiness(
            storeApps: UserDefaults.standard.integer(forKey: Self.storeAppsPrefix + key),
            scInfoHits: UserDefaults.standard.integer(forKey: Self.hintsPrefix + key),
            licenses: sessionLicenses
        )
    }
}
