//
// Brand: AppAssassin · https://fastdecrypt.ai
//  App.swift
//  AppAssassin — on-device sign, decrypt, and install.
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
        // 3.8: unstick Mac-only default so stock iPad companion FairPlay is used again.
        DecryptMacRouting.migrateStickyServerOnlyIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            if DecryptCompanionRuntime.isCompanionProcess {
                // Installed “FastDecryptBot” companion (DecryptHelper / host fallback + EmbeddedPayload).
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
                    .onOpenURL { url in
                        let scheme = url.scheme?.lowercased() ?? ""
                        // Custom schemes are handled by RootView; only ingest real files here.
                        // Companion → host clear-IPA / server-fallback (appassassin + tetherless).
                        if DecryptCompanionHandoff.handleIncomingHostDeepLink(url) {
                            AppNav.shared.goSearch()
                            return
                        }
                        if scheme == "appassassin" || scheme == "tetherless" || scheme == "airshare" || scheme == "msign"
                            || scheme == "sideloader" || scheme == "fastdecryptbot"
                            || scheme == "appassassin-decrypt" || scheme == "tetherless-decrypt" {
                            return
                        }
                        // Shared / Open-in IPA from companion → treat as clear decrypt import.
                        if url.pathExtension.lowercased() == "ipa" {
                            Task { @MainActor in
                                if DecryptCompanionHandoff.importSharedClearIPA(url) != nil {
                                    AppNav.shared.goSearch()
                                } else {
                                    session.receiveIncoming(url)
                                }
                            }
                            return
                        }
                        session.receiveIncoming(url)
                    }
                    .overlay { BetaRevokedOverlay() }
                    .overlay { AccountBannedOverlay() }
                    .overlay(alignment: .bottom) { VStack(spacing: 8) { ResumeBatchBanner(); UndoUninstallBanner(); InstallQueuePill(); NativeInstallBanner() } }
                    .onChange(of: scenePhase) { phase in
                        if phase == .active {
                            ZefvAccount.shared.restoreFromKeychainIfNeeded()
                            PhoneDecryptWorker.shared.startIfNeeded()
                            // Unsigned → Account + login once (FairPlay / Store need Apple ID).
                            AppNav.shared.nudgeAccountLoginIfNeeded()
                            // Companion may have published a clear IPA while we were backgrounded.
                            if DecryptCompanionHandoff.consumePendingClearIPAExport() != nil {
                                AppNav.shared.goSearch()
                            }
                            if DecryptCompanionHandoff.consumePendingServerFallback() {
                                AppNav.shared.goSearch()
                            }
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
        .backgroundTask(.appRefresh("bot.fastdecrypt.ai.scan")) {
            await LocalSourceUpdateWatcher.shared.scanAllSources(reason: "background")
        }
    }
}
