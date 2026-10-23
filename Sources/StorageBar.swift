import SwiftUI

/// Snapshot of this device's storage. AirShare runs on the phone it manages, so the local volume is the device's.
struct StorageInfo: Equatable {
    var total: Int64
    var free: Int64
    var used: Int64 { max(0, total - free) }

    static func read() -> StorageInfo? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        return StorageInfo(total: Int64(total), free: min(free, Int64(total)))
    }
}

/// Fixed strip under the top bar: apps (from the device list), everything else, and free space.
struct StorageBar: View {
    var appsBytes: Int64
    @State private var info = StorageInfo.read()
    @Environment(\.scenePhase) private var scenePhase

    private func text(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    var body: some View {
        Group {
            if let info {
                let apps = min(appsBytes, info.used)
                let other = max(0, info.used - apps)
                let low = Double(info.free) / Double(info.total) < 0.1
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            Capsule().fill(Theme.accent).frame(width: width(apps, info, geo.size.width))
                            Capsule().fill(Theme.subtle.opacity(0.55)).frame(width: width(other, info, geo.size.width))
                            Capsule().fill(Theme.stroke)
                        }
                    }
                    .frame(height: 6)
                    HStack(spacing: 10) {
                        legend(Theme.accent, "Apps \(text(apps))")
                        legend(Theme.subtle.opacity(0.55), "Other \(text(other))")
                        Spacer(minLength: 4)
                        Text("\(text(info.free)) free")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(low ? Color.orange : Theme.accent)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Theme.bg)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Storage: \(text(info.free)) free of \(text(info.total))")
            }
        }
        .onChange(of: scenePhase) { phase in if phase == .active { info = StorageInfo.read() } }
    }

    private func width(_ bytes: Int64, _ info: StorageInfo, _ full: CGFloat) -> CGFloat {
        guard bytes > 0 else { return 0 }
        return max(4, full * CGFloat(Double(bytes) / Double(info.total)))
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.subtle)
        }
    }
}
