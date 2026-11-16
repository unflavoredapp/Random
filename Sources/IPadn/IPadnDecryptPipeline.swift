//
// Brand: Tetherless · https://tetherless.dev
//  IPadnDecryptPipeline.swift
//  Get / Download → Downloads queue (stack many) → IPA download → companion push FIFO.
//

import Foundation

@MainActor
enum IPadnDecryptPipeline {
    /// Search Get, App Detail Download, Purchased — enqueue a Downloads job.
    /// Jobs stack: Store downloads run up to maxConcurrent; companion pushes serialize.
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
        } catch IPadnDownloadError.duplicate {
            // Already stacked — just show the queue; never bypass into decryptFromSearch.
        } catch {
            DecryptClient.shared.phase = .failed
            DecryptClient.shared.error = error.localizedDescription
            DecryptClient.shared.message = error.localizedDescription
        }
        if openDownloads {
            AppNav.shared.goDownloads()
        }
    }

    static func getOwned(_ app: OwnedStoreApp, openDownloads: Bool = true) {
        get(app.asDecryptApp, openDownloads: openDownloads)
    }
}
