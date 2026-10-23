//
//  App.swift
//  unzip-drop — drop a zip, extract on-device, push it to a repo.
//

import SwiftUI

@main
struct UnzipDropApp: App {
    @StateObject private var session = Session()
    @StateObject private var config = Config()
    @StateObject private var notifications = NotificationManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AirShareAppDelegate.self) private var appDelegate

    init() {
        // Re-attach to background downloads that finished while the app was closed.
        _ = IPADownloader.shared
        // Must register before launch finishes (pairing keeps running via a continued-processing task).
        DevicePairingService.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .task {
                    LocalZSignAPI.shared.startIfNeeded()
                    // Recognized ADID + device key signs straight in; with a live session this just refreshes the profile.
                    if await ZefvAccount.shared.autoLoginIfNeeded() { await ZefvAccount.shared.refreshProfile() }
                    await BetaGuard.shared.check(force: true)   // beta builds only
                }
                .environmentObject(session)
                .environmentObject(config)
                .onOpenURL { url in session.receiveIncoming(url) }
                .overlay { BetaRevokedOverlay() }
                .overlay(alignment: .bottom) { VStack(spacing: 8) { ResumeBatchBanner(); UndoUninstallBanner(); InstallQueuePill(); NativeInstallBanner() } }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        ZefvAccount.shared.restoreFromKeychainIfNeeded()
                        Task {
                            await VPNReconnectCoordinator.shared.appBecameActive()
                            _ = await ZefvAccount.shared.autoLoginIfNeeded()
                            await BetaGuard.shared.check()
                        }
                    }
                }
        }
        .backgroundTask(.appRefresh("com.mrzefv.airshare.source-scan")) {
            await LocalSourceUpdateWatcher.shared.scanAllSources(reason: "background")
        }
    }
}
