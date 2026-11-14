//
//  TetherLessShortcuts.swift
//  Shortcuts: Refresh All, decrypt App Store link, cert countdown.
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
        SideloadSurvival.refreshAllWithKeepAlive()
        return .result(dialog: IntentDialog("Refresh All started. TetherLess is re-signing your tracked apps."))
    }
}

@available(iOS 16.0, *)
struct DecryptStoreLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Decrypt App Store Link"
    static var description = IntentDescription("Silent-download and decrypt an App Store URL you own.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "App Store URL")
    var storeURL: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = storeURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("apps.apple.com") || trimmed.contains("itunes.apple.com") else {
            return .result(dialog: IntentDialog("Paste a full apps.apple.com link."))
        }
        AppNav.shared.go(AppTab.decrypt.rawValue)
        let app = DecryptApp(id: trimmed, name: "App Store link", bundle: "", icon: nil, dev: "", version: "", url: trimmed)
        DecryptPipeline.shared.run(app: app)
        return .result(dialog: IntentDialog("Decrypt pipeline started for that App Store link."))
    }
}

@available(iOS 16.0, *)
struct CertDaysIntent: AppIntent {
    static var title: LocalizedStringResource = "Signing Certificate Days Left"
    static var description = IntentDescription("Report how many days remain on the active free Apple ID certificate.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        SideloadSurvival.refreshExpiryLoop()
        let label = SideloadSurvival.countdownLabel
        return .result(dialog: IntentDialog("\(label)"))
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
        AppShortcut(
            intent: DecryptStoreLinkIntent(),
            phrases: [
                "Decrypt App Store link in \(.applicationName)",
                "Decrypt this app with \(.applicationName)"
            ],
            shortTitle: "Decrypt Link",
            systemImageName: "lock.open.fill"
        )
        AppShortcut(
            intent: CertDaysIntent(),
            phrases: [
                "Certificate days left in \(.applicationName)",
                "How long is my \(.applicationName) certificate"
            ],
            shortTitle: "Cert Days",
            systemImageName: "calendar.badge.clock"
        )
    }
}
