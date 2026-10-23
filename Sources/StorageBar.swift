import SwiftUI

/// Snapshot of this device's storage. AirShare runs on the phone it manages, so the local volume is the device's.
struct StorageInfo: Equatable {
    var total: Int64
    var free: Int64
    var used: Int64 { max(0, total - free) }
    var isLow: Bool { Double(free) / Double(total) < 0.1 }

    static func read() -> StorageInfo? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }
        let free = values.volumeAvailableCapacityForImportantUsage ?? 0
        return StorageInfo(total: Int64(total), free: min(max(0, free), Int64(total)))
    }

    static func text(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// Storage row for the account dropdown: free space, then Apps / Other / free bar.
struct StorageRow: View {
    @ObservedObject private var device = DeviceLibrary.shared
    @State private var info = StorageInfo.read()
    @Environment(\.scenePhase) private var scenePhase

    private var appsBytes: Int64 { device.apps.reduce(0) { $0 + ($1.sizeBytes ?? 0) } }

    var body: some View {
        Group {
            if let info {
                let apps = min(appsBytes, info.used)
                let other = max(0, info.used - apps)
                VStack(alignment: .leading, spacing: 8) {
                    Text("STORAGE")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced)).kerning(1.4).foregroundStyle(Theme.subtle)
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(StorageInfo.text(info.free)) free")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(info.isLow ? Color.orange : Theme.text)
                        Spacer(minLength: 4)
                        Text("of \(StorageInfo.text(info.total))").font(.system(size: 10)).foregroundStyle(Theme.subtle)
                    }
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            Capsule().fill(Theme.accent).frame(width: width(apps, info, geo.size.width))
                            Capsule().fill(Theme.subtle.opacity(0.55)).frame(width: width(other, info, geo.size.width))
                            Capsule().fill(Theme.stroke)
                        }
                    }
                    .frame(height: 8)
                    HStack(spacing: 10) {
                        legend(Theme.accent, "Apps \(StorageInfo.text(apps))")
                        legend(Theme.subtle.opacity(0.55), "Other \(StorageInfo.text(other))")
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .accessibilityElement(children: .combine)
            }
        }
        .onAppear { info = StorageInfo.read() }
        .onChange(of: scenePhase) { phase in if phase == .active { info = StorageInfo.read() } }
    }

    private func width(_ bytes: Int64, _ info: StorageInfo, _ full: CGFloat) -> CGFloat {
        guard bytes > 0 else { return 0 }
        return max(4, full * CGFloat(Double(bytes) / Double(info.total)))
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.subtle).lineLimit(1)
        }
    }
}

/// Orange pill under the Library header, shown only when free space is under 10%.
struct LowStorageBanner: View {
    @State private var info = StorageInfo.read()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let info, info.isLow {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Low storage · \(StorageInfo.text(info.free)) free — uninstall apps to make room")
                        .lineLimit(2)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.4), lineWidth: 1))
                .padding(.horizontal, 16).padding(.vertical, 6)
            }
        }
        .onAppear { info = StorageInfo.read() }
        .onChange(of: scenePhase) { phase in if phase == .active { info = StorageInfo.read() } }
    }
}
