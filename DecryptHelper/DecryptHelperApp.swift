//
// Brand: AppAssassin · https://fastdecrypt.ai
//  DecryptHelperApp.swift
//  Lean FastDecryptBot shell — UIKit-only entry (no SwiftUI App lifecycle).
//  Embedded into the host and cloned by DecryptCompanionPackager instead of
//  the ~45 MB host Mach-O. This process *is* the subordinate FairPlay worker
//  (installed companion app — not XPC; free-cert / FairPlay friendly).
//

import UIKit

@main
final class DecryptHelperAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = DecryptCompanionConsoleViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
