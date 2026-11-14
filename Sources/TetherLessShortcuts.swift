//
//  TetherLessShortcuts.swift
//  Shortcuts: Refresh All tracked apps (re-sign + update).
//

import AppIntents
import Foundation

@available(iOS 16.0, *)
struct RefreshAllAppsIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh All"
    static var description = IntentDescription(
        "Re-sign every tracked app with your active or free Apple ID certificate, then check for updates."
    )
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppleIDStore.shared.activatePreferredSigningCertificate()
        AppAutoUpdater.shared.refreshAll()
        return .result(dialog: IntentDialog("Refresh All started. TetherLess is re-signing your tracked apps."))
    }
}

@available(iOS 16.0, *)
struct TetherLessShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RefreshAllAppsIntent(),
            phrases: [
                "Refresh All in \(.applicationName)",
                "Re-sign my apps in \(.applicationName)",
                "Keep apps alive with \(.applicationName)"
            ],
            shortTitle: "Refresh All",
            systemImageName: "arrow.clockwise.circle.fill"
        )
    }
}
