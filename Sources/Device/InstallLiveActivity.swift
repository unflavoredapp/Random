//
//  InstallLiveActivity.swift
//  Drives the lock-screen / Dynamic Island progress for downloads, signing and installs.
//  Started and stopped by BackgroundKeepAlive (so it lives exactly as long as the song does).
//

import ActivityKit
import UIKit

@MainActor
final class InstallLiveActivity {
    static let shared = InstallLiveActivity()
    private var activity: Any?            // Activity<AirShareActivityAttributes> (iOS 16.1+)
    private var lastKey: String?
    private var lastSnapshot: Snapshot?
    private var lastIcon: Data?
    private var icons: [String: Data] = [:]
    private var loading = Set<String>()
    private init() {}
    var isActive: Bool { activity != nil }

    struct Snapshot {
        var title: String, detail: String, progress: Double, symbol: String
        var iconURL: URL? = nil
        var accentHex: String? = nil          // nil = current theme accent
    }

    // MARK: App icon thumbnail (the widget can't download anything, so the icon travels inside the state)

    /// Cached thumbnail, or nil while it loads (the activity refreshes itself when it arrives).
    private func thumbnail(for url: URL?) -> Data? {
        guard let url else { return nil }
        let key = url.absoluteString
        if let d = icons[key] { return d }
        guard !loading.contains(key) else { return nil }
        loading.insert(key)
        Task { [weak self] in
            let raw: Data?
            if url.isFileURL { raw = try? Data(contentsOf: url) }
            else { raw = (try? await URLSession.shared.data(from: url))?.0 }
            let small = raw.flatMap { Self.shrink($0) }
            await MainActor.run {
                guard let self else { return }
                self.loading.remove(key)
                if let small { self.icons[key] = small; if let s = self.lastSnapshot { self.update(s) } }
            }
        }
        return nil
    }

    /// 40×40 JPEG kept under ~1.5 KB so the whole state stays far below ActivityKit's 4 KB limit.
    nonisolated private static func shrink(_ data: Data) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        for side in [44.0, 36.0, 28.0] {
            let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1; fmt.opaque = true
            let r = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: fmt)
            let small = r.image { _ in img.draw(in: CGRect(x: 0, y: 0, width: side, height: side)) }
            for q in [0.6, 0.4, 0.25] {
                if let d = small.jpegData(compressionQuality: q), d.count <= 1500 { return d }
            }
        }
        return nil
    }

    // MARK: Activity

    func update(_ s: Snapshot) {
        lastSnapshot = s
        guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let icon = thumbnail(for: s.iconURL) ?? (s.iconURL == nil ? lastIcon : nil)
        if let icon { lastIcon = icon }
        let state = AirShareActivityAttributes.ContentState(title: s.title, detail: s.detail, progress: min(max(s.progress, 0), 1),
                                                           symbol: s.symbol, finished: false, failed: false,
                                                           iconData: icon, accentHex: s.accentHex ?? AppTheme.shared.accentHex)
        let key = "\(state.title)|\(state.detail)|\(Int(state.progress * 100))|\(icon?.count ?? 0)"
        guard key != lastKey else { return }
        lastKey = key
        if let a = activity as? Activity<AirShareActivityAttributes> {
            Task { await a.update(ActivityContent(state: state, staleDate: nil)) }
        } else {
            activity = try? Activity.request(attributes: AirShareActivityAttributes(startedAt: Date()),
                                             content: ActivityContent(state: state, staleDate: nil), pushType: nil)
        }
    }

    func end(title: String, detail: String, failed: Bool) {
        let icon = lastIcon
        lastSnapshot = nil; lastIcon = nil
        guard #available(iOS 16.2, *), let a = activity as? Activity<AirShareActivityAttributes> else { activity = nil; lastKey = nil; return }
        let state = AirShareActivityAttributes.ContentState(title: title, detail: detail, progress: 1,
                                                           symbol: failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                                                           finished: !failed, failed: failed, iconData: icon, accentHex: AppTheme.shared.accentHex)
        activity = nil; lastKey = nil
        Task { await a.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(8))) }
    }
}
