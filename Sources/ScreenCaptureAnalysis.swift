import Foundation

/// Finds screenshot and screen-recording observation code for authorized review.
nonisolated enum ScreenCaptureAnalysis {
    static let profile = ProtectionProfile(
        category: "Screen-capture response",
        title: "Capture observer / response indicators",
        importTerms: ["addobserver", "capturedidchangenotification", "userdidtakescreenshotnotification", "uiscreen", "isCaptured"],
        stringTerms: ["capturedDidChangeNotification", "isCaptured", "userDidTakeScreenshotNotification", "screenrecording", "screenshot", "capturestate", "recordingstate", "UIScreenCapturedDidChangeNotification"],
        note: "Follow observer registration to the callback and then to UI state changes, access revocation, or logging. Static matches cannot prove that content is blanked or a session is terminated."
    )
}
