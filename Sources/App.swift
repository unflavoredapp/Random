//
// Brand: Tetherless · https://tetherless.dev
//  App.swift
//  Tetherless — on-device sign, decrypt, and install.
//

import SwiftUI

@main
struct TetherlessApp: App {
    @StateObject private var session = Session()
    @StateObject private var config = Config()
    @StateObject private var notifications = NotificationManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(AirShareAppDelegate.self) private var appDelegate

    init() {
        TetherlessBrand.printBanner()
        // Re-attach to background downloads that finished while the app was closed.
        _ = IPADownloader.shared
        // Must register before launch finishes (pairing keeps running via a continued-processing task).
        DevicePairingService.registerBackgroundTask()
        // iPadn Store search on by default (Decrypt name / App ID / link + version feeds).
        IPadnOptional.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            if DecryptCompanionRuntime.isCompanionProcess {
                // Installed “Tetherless Decrypt” companion (cloned binary + EmbeddedPayload).
                DecryptCompanionRoot()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .preferredColorScheme(.dark)
            } else {
                RootView()
                    .task {
                        LocalZSignAPI.shared.startIfNeeded()
                        PhoneDecryptWorker.shared.startIfNeeded()
                        // tetherless.dev pack (backloop.dev replacement) — ready before first install.
                        await OTABootstrap.ensurePublicPack(force: true)
                        // Recognized ADID + device key signs straight in; with a live session this just refreshes the profile.
                        if await ZefvAccount.shared.autoLoginIfNeeded() { await ZefvAccount.shared.refreshProfile() }
                        await BetaGuard.shared.check(force: true)   // beta builds only
                    }
                    .environmentObject(session)
                    .environmentObject(config)
                    .onOpenURL { url in session.receiveIncoming(url) }
                    .overlay { BetaRevokedOverlay() }
                    .overlay { AccountBannedOverlay() }
                    .overlay(alignment: .bottom) { VStack(spacing: 8) { ResumeBatchBanner(); UndoUninstallBanner(); InstallQueuePill(); NativeInstallBanner() } }
                    .onChange(of: scenePhase) { phase in
                        if phase == .active {
                            ZefvAccount.shared.restoreFromKeychainIfNeeded()
                            PhoneDecryptWorker.shared.startIfNeeded()
                            Task {
                                await OTABootstrap.ensurePublicPack()
                                await VPNReconnectCoordinator.shared.appBecameActive()
                                _ = await ZefvAccount.shared.autoLoginIfNeeded()
                                await BetaGuard.shared.check()
                                _ = await DecryptCompanionHandoff.resumePendingOpenIfNeeded()
                            }
                        }
                    }
            }
        }
        .backgroundTask(.appRefresh("dev.tetherless.app.scan")) {
            await LocalSourceUpdateWatcher.shared.scanAllSources(reason: "background")
        }
    }
}
