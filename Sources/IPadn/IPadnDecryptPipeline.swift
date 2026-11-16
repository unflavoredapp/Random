//
// Brand: Tetherless · https://tetherless.dev
//  IPadnDecryptPipeline.swift
//  Get / Download → iPadn store download queue → FairPlay (DeviceDecryptService).
//  Keeps mengangs/ipadn Downloads UI while decrypt “just works” after the IPA lands.
//

import Foundation

@MainActor
enum IPadnDecryptPipeline {
    /// Search Get, App Detail Download, Purchased cloud — enqueue iPadn store job.
    /// IPadnDownloadManager auto-handoffs the finished IPA to FairPlay.
    static func get(
        _ app: DecryptApp,
        externalVersionId: String? = nil,
        openDownloads: Bool = true
    ) {
        if !app.countryCode.isEmpty {
            AppleIDStore.shared.selectAccountMatching(countryCode: app.countryCode)
        }
        do {
            try IPadnDownloadManager.shared.enqueueStore(
                app: app,
                externalVersionId: externalVersionId
            )
            if openDownloads {
                AppNav.shared.goDownloads()
            }
        } catch {
            // Already queued, or enqueue rejected — still run the proven device decrypt path.
            DeviceDecryptService.shared.decryptFromSearch(
                app,
                externalVersionId: externalVersionId
            )
            if openDownloads {
                AppNav.shared.goDownloads()
            }
        }
    }

    static func getOwned(_ app: OwnedStoreApp, openDownloads: Bool = true) {
        get(app.asDecryptApp, openDownloads: openDownloads)
    }
}
