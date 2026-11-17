//
// Brand: Tetherless · https://tetherless.dev
//  FairPlayKeysFetcher.swift
//  Guided capture of FairPlay keys for the active Apple ID session:
//  deep-link to App Store account / Media & Purchases → return → verify → confirm.
//
//  TetherLess cannot mint FairPlay keys from the Store login token — iOS only
//  installs them after a real App Store / Media & Purchases sign-in.
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
    }

    enum Phase: Equatable {
        case idle
        case redirecting(email: String, destination: Destination)
        case waitingForReturn(email: String, destination: Destination)
        case verifying(email: String)
        /// Soft checks done — user must confirm they signed in as this Apple ID.
        case confirmSignIn(email: String, licenseHints: Int)
        case grabbed(email: String, at: Date, licenseHints: Int)
        case needsAccount
    }

    @Published private(set) var phase: Phase = .idle
    @Published var banner: String?
    @Published var verifyLines: [String] = []

    private var foregroundObserver: NSObjectProtocol?
    private var openedAt: Date?
    private var armReturnAfter: Date?
    private var verifyTask: Task<Void, Never>?

    private static let grabbedAtPrefix = "tetherless.decrypt.keysGrabbedAt."
    private static let hintsPrefix = "tetherless.decrypt.keysLicenseHints."

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
            let hints = licenseHints(email: email)
            if case .grabbed(let current, _, _) = phase, current == email { return }
            phase = .grabbed(email: email, at: at, licenseHints: hints)
        } else if case .grabbed = phase {
            phase = .idle
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

        // Brief beat so UI can show “Opening…” before we leave.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard case .redirecting(let e, let d) = self.phase, e == email else { return }
            self.phase = .waitingForReturn(email: email, destination: d)
            switch d {
            case .appStoreAccount:
                AppStoreDecryptGuide.openAppStoreAccountSheet()
            case .mediaAndPurchases:
                AppStoreDecryptGuide.openMediaAndPurchases()
            }
        }
    }

    /// User confirmed they signed in as the session Apple ID.
    func confirmGrabbed() {
        let email: String
        let hints: Int
        switch phase {
        case .confirmSignIn(let e, let h):
            email = e; hints = h
        case .verifying(let e):
            email = e; hints = 0
        case .waitingForReturn(let e, _):
            email = e; hints = 0
        default:
            email = activeEmail(); hints = 0
        }
        guard !email.isEmpty else {
            phase = .needsAccount
            return
        }
        finishGrab(email: email, licenseHints: hints, source: "confirm")
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
            banner = "Checking this iPhone for App Store licenses…"
            let hints = await softProbeLicenseHints()
            phase = .confirmSignIn(email: email, licenseHints: hints)
            banner = hints > 0
                ? "Found \(hints) App Store license folder(s) on device. Confirm you signed in as \(email)."
                : "Confirm you signed in to Media & Purchases as \(email)."
        }
    }

    func cancelCapture() {
        verifyTask?.cancel()
        openedAt = nil
        armReturnAfter = nil
        verifyLines = []
        banner = nil
        // Drop in-progress states so refreshFromAck can sync the ack bit.
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
        banner = "Back in TetherLess — verifying key capture for \(email)…"
        verifyLines = ["Returned from App Store"]
        verifyTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            verifyLines.append("Matching session \(email)")
            cacheEmail(email)

            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            verifyLines.append("Scanning on-device App Store licenses…")
            let hints = await softProbeLicenseHints()

            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            if hints > 0 {
                verifyLines.append("Found \(hints) SC_Info license folder(s)")
            } else {
                verifyLines.append("No local license folders yet — sign-in still required")
            }

            phase = .confirmSignIn(email: email, licenseHints: hints)
            banner = hints > 0
                ? "Almost done — confirm keys for \(email)."
                : "Sign-in done? Confirm keys for \(email) to unlock companion decrypt."
            openedAt = nil
            armReturnAfter = nil
        }
    }

    private func finishGrab(email: String, licenseHints: Int, source: String) {
        AppStoreDecryptGuide.setAcknowledged(true, email: email)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.grabbedAtPrefix + email.lowercased())
        UserDefaults.standard.set(licenseHints, forKey: Self.hintsPrefix + email.lowercased())
        DecryptCompanionHandoff.publishHostSnapshot()
        phase = .grabbed(email: email, at: Date(), licenseHints: licenseHints)
        banner = source == "confirm"
            ? "Keys grabbed for \(email)\(licenseHints > 0 ? " · \(licenseHints) license folder(s) seen" : "")."
            : "Keys marked ready for \(email)."
        verifyLines = []
        openedAt = nil
        armReturnAfter = nil
        AppNav.shared.presentFairPlayKeysCapture = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            if case .grabbed = self.phase { self.banner = nil }
        }
    }

    // MARK: - Soft probe

    /// Best-effort: count live App Store installs that expose an SC_Info folder.
    /// Not proof of fairplayd keys, but a useful on-device signal after Media & Purchases.
    private func softProbeLicenseHints() async -> Int {
        _ = await DeviceLibrary.shared.refreshAwaiting()
        var bids = DeviceLibrary.shared.apps.filter(\.isAppStore).map(\.bundleID)
        if bids.isEmpty {
            // Fallback sample of common system-visible store apps from recent decrypt history.
            bids = DecryptClient.shared.history.compactMap { app in
                let b = app.bundle.trimmingCharacters(in: .whitespacesAndNewlines)
                return b.isEmpty ? nil : b
            }
        }
        var seen = Set<String>()
        var hits = 0
        for bid in bids where seen.insert(bid).inserted {
            guard hits < 12 else { break }
            guard let live = FairPlayDecrypt.installedAppURL(bundleID: bid) else { continue }
            let sc = live.appendingPathComponent("SC_Info", isDirectory: true)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: sc.path, isDirectory: &isDir), isDir.boolValue {
                hits += 1
            }
        }
        return hits
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

    private func licenseHints(email: String) -> Int {
        UserDefaults.standard.integer(forKey: Self.hintsPrefix + email.lowercased())
    }
}
