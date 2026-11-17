//
// Brand: Tetherless · https://tetherless.dev
//  FairPlayKeysFetcher.swift
//  Guided App Store redirect so iOS can store FairPlay keys for the active
//  Apple ID session, then mark them grabbed when the user returns.
//
//  TetherLess cannot mint FairPlay keys from the Store login token — iOS only
//  installs them after a real App Store / Media & Purchases sign-in. This flow
//  opens that path for the signed-in account and records success on return.
//

import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class FairPlayKeysFetcher: ObservableObject {
    static let shared = FairPlayKeysFetcher()

    enum Phase: Equatable {
        case idle
        /// App Store (or Settings) opened — waiting for the user to come back.
        case waitingForReturn(email: String)
        /// User returned; keys marked ready for companion decrypt.
        case grabbed(email: String, at: Date)
        case needsAccount
    }

    @Published private(set) var phase: Phase = .idle
    @Published var banner: String?

    private var foregroundObserver: NSObjectProtocol?
    private var openedAt: Date?
    /// Ignore foreground events that fire while still leaving for App Store.
    private var armReturnAfter: Date?

    private init() {
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDidBecomeActive() }
        }
        // Restore grabbed UI if already acknowledged for the active account.
        refreshFromAck()
    }

    var isWaiting: Bool {
        if case .waitingForReturn = phase { return true }
        return false
    }

    var isGrabbed: Bool {
        if case .grabbed = phase { return true }
        return false
    }

    /// Sync phase with the per-email ack bit (Search tab / Account switch).
    func refreshFromAck() {
        let email = AppleIDStore.shared.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AppleIDStore.shared.isSignedIn, !email.isEmpty else {
            if case .waitingForReturn = phase { return }
            phase = .idle
            return
        }
        if case .waitingForReturn = phase { return }
        if AppStoreDecryptGuide.isAcknowledged(email: email) {
            if case .grabbed(let current, _) = phase, current == email { return }
            phase = .grabbed(email: email, at: Date())
        } else if case .grabbed = phase {
            phase = .idle
        }
    }

    /// Open App Store for the active TetherLess Apple ID session, then wait for return.
    func startFetchFromSession(preferSettings: Bool = false) {
        guard AppleIDStore.shared.isSignedIn else {
            phase = .needsAccount
            banner = "Sign in under Account first, then grab FairPlay keys."
            AppNav.shared.goAccount()
            return
        }
        let email = AppleIDStore.shared.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            phase = .needsAccount
            banner = "Sign in under Account first, then grab FairPlay keys."
            AppNav.shared.goAccount()
            return
        }

        // Cache email for companion failure copy before leaving.
        UserDefaults.standard.set(email, forKey: "tetherless.appleid.activeEmailCache")
        UserDefaults(suiteName: "group.dev.tetherless.app")?
            .set(email, forKey: "tetherless.appleid.activeEmailCache")

        openedAt = Date()
        armReturnAfter = Date().addingTimeInterval(1.2)
        phase = .waitingForReturn(email: email)
        banner = preferSettings
            ? "Opening Settings — sign in under your name → Media & Purchases with \(email), then return here."
            : "Opening App Store — sign in with \(email) (Media & Purchases), then return here."

        if preferSettings {
            AppStoreDecryptGuide.openSystemSettings()
        } else {
            AppStoreDecryptGuide.openAppStore()
        }
    }

    /// Manual confirm if the user already signed in without using the redirect.
    func markGrabbedManually() {
        let email = AppleIDStore.shared.email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty else {
            phase = .needsAccount
            return
        }
        finishGrab(email: email, source: "manual")
    }

    private func handleDidBecomeActive() {
        guard case .waitingForReturn(let email) = phase else { return }
        if let armReturnAfter, Date() < armReturnAfter { return }
        // Require a short absence so we don't ack while App Store is still opening.
        if let openedAt, Date().timeIntervalSince(openedAt) < 1.5 { return }
        finishGrab(email: email, source: "return")
    }

    private func finishGrab(email: String, source: String) {
        AppStoreDecryptGuide.setAcknowledged(true, email: email)
        DecryptCompanionHandoff.publishHostSnapshot()
        phase = .grabbed(email: email, at: Date())
        banner = source == "return"
            ? "Keys grabbed for \(email) — companion decrypt can use this session."
            : "Keys marked ready for \(email)."
        openedAt = nil
        armReturnAfter = nil
        // Clear banner after a beat so Search stays clean.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if case .grabbed = self.phase {
                self.banner = nil
            }
        }
    }
}
