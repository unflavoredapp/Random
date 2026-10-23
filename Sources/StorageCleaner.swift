//
//  StorageCleaner.swift
//  Keeps AirShare from slowly eating the phone: old inbox IPAs, extra signed builds, stale sign-cache
//  entries, orphaned download pieces and leftover temp folders. Runs quietly at most twice a day.
//

import Foundation
import SwiftUI

nonisolated enum StorageCleaner {
    static let enabledKey = "AirShare.autoClean"
    static let daysKey = "AirShare.autoCleanDays"
    static let lastKey = "AirShare.autoCleanLast"
    static let freedKey = "AirShare.autoCleanFreed"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var keepDays: Int { max(1, UserDefaults.standard.object(forKey: daysKey) as? Int ?? 14) }

    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let f as URL in e { total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        }
        return total
    }

    /// Everything AirShare could clean right now, for the Settings readout.
    static func reclaimable() -> Int64 {
        var n: Int64 = size(of: SignCache.dir)
        n += staleInbox(days: keepDays).reduce(0) { $0 + $1.size }
        return n
    }

    private static func staleInbox(days: Int) -> [(url: URL, size: Int64)] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        var out: [(URL, Int64)] = []
        for u in (try? fm.contentsOfDirectory(at: AppPaths.dir("inbox"), includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where u.pathExtension.lowercased() == "ipa" {
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if m < cutoff { out.append((u, size(of: u))) }
        }
        return out
    }

    /// Runs the cleanup. `force` ignores the twice-a-day throttle and the on/off switch (the "Clean now" button).
    @discardableResult
    static func run(force: Bool = false) async -> Int64 {
        if !force {
            guard enabled else { return 0 }
            let last = UserDefaults.standard.double(forKey: lastKey)
            if last > 0, Date().timeIntervalSince1970 - last < 12 * 3600 { return 0 }
        }
        let fm = FileManager.default
        var freed: Int64 = 0

        // 1 · old downloaded IPAs (and their icon sidecars)
        for item in staleInbox(days: force ? min(keepDays, 7) : keepDays) {
            try? fm.removeItem(at: item.url)
            try? fm.removeItem(at: URL(fileURLWithPath: item.url.path + ".icon"))
            freed += item.size
        }

        // 2 · extra signed builds: keep the newest two per app (the second one is what rollback uses)
        freed += await MainActor.run { () -> Int64 in
            let store = SignedStore.shared
            var seen: [String: Int] = [:]
            var n: Int64 = 0
            for e in store.entries.sorted(by: { $0.signedAt > $1.signedAt }) {
                let c = (seen[e.bundleID] ?? 0) + 1
                seen[e.bundleID] = c
                if c > 2 {
                    n += size(of: e.ipaURL)
                    store.delete(e)
                }
            }
            return n
        }

        // 3 · sign cache older than the keep window
        freed += SignCache.trim(maxEntries: force ? 0 : SignCache.maxEntries)

        // 4 · orphaned download pieces
        freed += IPADownloader.shared.pruneOrphans(olderThan: force ? 60 : 86_400)

        // 5 · leftover temp work folders from interrupted signs/unpacks
        let tmp = fm.temporaryDirectory
        for u in (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let n = u.lastPathComponent
            guard n.hasPrefix("sign-") || n.hasPrefix("meta-") || n.hasPrefix("appupdate-") || n.contains("-signed-") else { continue }
            let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            guard Date().timeIntervalSince(m) > 3600 else { continue }
            freed += size(of: u)
            try? fm.removeItem(at: u)
        }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
        UserDefaults.standard.set(freed, forKey: freedKey)
        return freed
    }
}

/// Settings card: auto-clean switch, how long to keep downloads, "Clean now".
struct StorageCleanCard: View {
    @ObservedObject private var liveTheme = AppTheme.shared
    @AppStorage(StorageCleaner.enabledKey) private var on = true
    @AppStorage(StorageCleaner.daysKey) private var days = 14
    @AppStorage(StorageCleaner.freedKey) private var lastFreed = 0
    @State private var working = false
    @State private var reclaimable: Int64 = 0

    private func fmt(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 38, height: 38)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.5)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-clean storage").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(working ? "Cleaning…" : "\(fmt(reclaimable)) can be cleaned" + (lastFreed > 0 ? " · last run freed \(fmt(Int64(lastFreed)))" : ""))
                        .font(.system(size: 12)).foregroundStyle(Theme.subtle).lineLimit(2)
                }
                Spacer(minLength: 4)
                Toggle("", isOn: $on).labelsHidden().tint(Theme.accent)
            }
            if on {
                Stepper(value: $days, in: 1...90) {
                    Text("Delete downloads older than \(days) day\(days == 1 ? "" : "s")")
                        .font(.system(size: 13)).foregroundStyle(Theme.subtle)
                }
            }
            Button {
                working = true
                Task {
                    let n = await StorageCleaner.run(force: true)
                    reclaimable = StorageCleaner.reclaimable()
                    lastFreed = Int(n); working = false
                }
            } label: {
                Text(working ? "Cleaning…" : "Clean now").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 8).background(Theme.accent).clipShape(Capsule())
            }
            .disabled(working)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
        .task { reclaimable = await Task.detached { StorageCleaner.reclaimable() }.value }
    }
}
