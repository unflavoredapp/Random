import Foundation

// Widget support: App Group snapshot for a cert-days / Refresh All widget.
// The installable build may ship without a widget extension; hooks stay harmless.
@MainActor
final class WidgetDataManager {
    static let shared = WidgetDataManager()

    private let suiteName = "group.dev.tetherless.app"
    private var defaults: UserDefaults? { UserDefaults(suiteName: suiteName) }

    func refresh() {
        let days = SideloadSurvival.activeCertDaysLeft
        let label = SideloadSurvival.countdownLabel
        let signedCount = SignedStore.shared.entries.count
        let tracked = AppAutoUpdater.shared.tracked.count
        defaults?.set(days ?? -999, forKey: "widget.certDays")
        defaults?.set(label, forKey: "widget.certLabel")
        defaults?.set(signedCount, forKey: "widget.signedCount")
        defaults?.set(tracked, forKey: "widget.trackedCount")
        defaults?.set(Date().timeIntervalSince1970, forKey: "widget.updatedAt")
        defaults?.set(InstallAutopilot.statusLabel, forKey: "widget.installMethod")
    }

    func setBulkState(running: Int, failed: Int) {
        defaults?.set(running, forKey: "widget.bulkRunning")
        defaults?.set(failed, forKey: "widget.bulkFailed")
        refresh()
    }

    func updateAfterSigning() {
        refresh()
    }
}
