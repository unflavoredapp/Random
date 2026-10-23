import Foundation

// Widget support is intentionally disabled in the installable AirShare build.
// Kept as a compatibility shim so existing activity hooks remain harmless.
@MainActor
final class WidgetDataManager {
    static let shared = WidgetDataManager()

    func refresh() {}
    func setBulkState(running: Int, failed: Int) {}
    func updateAfterSigning() {}
}
