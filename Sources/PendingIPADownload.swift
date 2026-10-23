//
//  PendingIPADownload.swift
//  An IPA that is still downloading while the signing sheet is already open. The sheet lets you set
//  everything up and keeps Sign IPA locked until the file is on the device.
//

import SwiftUI

@MainActor
final class PendingIPADownload: ObservableObject {
    let app: SourceApp
    @Published private(set) var progress: Double = 0
    @Published private(set) var ready = false
    @Published private(set) var failure: String?
    private var running = false
    private static var all: [String: PendingIPADownload] = [:]

    /// One download per app version, shared by the detail page and the signing sheet.
    static func current(for app: SourceApp) -> PendingIPADownload {
        if let d = all[app.id], !(d.ready && !IPAInbox.has(app)) { return d }
        let d = PendingIPADownload(app: app)
        all[app.id] = d
        return d
    }

    var url: URL { IPAInbox.url(for: app) }
    var meta: IPAMeta { IPAMeta(name: app.name, bundleID: app.bundle, version: app.version, iconPNG: nil) }

    init(app: SourceApp) {
        self.app = app
        if IPAInbox.has(app) { ready = true; progress = 1 }
    }

    func start() {
        guard !ready, !running else { return }
        running = true; failure = nil; progress = 0
        Task {
            do {
                _ = try await IPADownloader.shared.download(app) { p in Task { @MainActor in self.progress = p } }
                await IPAInbox.storeIcon(for: app)
                AppStatsStore.shared.noteDownload(app)
                progress = 1; ready = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                failure = error.localizedDescription
            }
            running = false
        }
    }
}

/// Strip at the top of the signing sheet while the IPA is still coming down.
struct PendingDownloadBanner: View {
    @ObservedObject var download: PendingIPADownload

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: download.failure == nil ? "arrow.down.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(download.failure == nil ? Theme.accent : Color.orange)
                Text(download.failure == nil ? "Downloading \(download.app.name)" : "Download failed")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.white).lineLimit(1)
                Spacer()
                if download.failure == nil {
                    Text("\(Int(download.progress * 100))%").font(.system(size: 13, weight: .bold)).monospacedDigit().foregroundStyle(Theme.accent)
                }
            }
            if let failure = download.failure {
                Text(failure).font(.caption).foregroundStyle(.orange)
                Button { download.start() } label: {
                    Text("Try again").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            } else {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(Theme.accent).frame(width: max(6, g.size.width * download.progress))
                    }
                }
                .frame(height: 6)
                Text("Set your options now. Tap Sign IPA any time and it starts as soon as the download finishes.")
                    .font(.system(size: 11)).foregroundStyle(Theme.subtle)
            }
        }
        .padding(12)
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
