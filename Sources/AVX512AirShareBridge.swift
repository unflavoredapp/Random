import Foundation
import SwiftUI

/// Bridge contract between AirShare signing and the AVX512 experimental tooling.
///
/// The bridge intentionally carries metadata and job intent, not signing secrets.
/// AVX512 can observe the notification when its bridge component is loaded into
/// the same process, or consume the serialized payload through its own transport.
@MainActor
final class AVX512AirShareBridge: ObservableObject {
    static let shared = AVX512AirShareBridge()

    @Published private(set) var lastContext: Context?
    @Published var enabled = UserDefaults.standard.bool(forKey: "msign.avx512.bridge.enabled")

    struct Context: Codable, Equatable {
        let version: Int
        let bundleID: String
        let appName: String
        let ipaPath: String
        let mdid: String
        let role: String
        let source: String
        let timestamp: Date
    }

    static let notification = Notification.Name("mSign.AVX512.Bridge.Context")

    private init() {}

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: "msign.avx512.bridge.enabled")
    }

    func makeContext(bundleID: String, appName: String, ipaURL: URL? = nil) -> Context {
        Context(
            version: 2,
            bundleID: bundleID,
            appName: appName,
            ipaPath: ipaURL?.path ?? "",
            mdid: StaffGate.shared.mdid,
            role: StaffGate.shared.role.rawValue,
            source: "mSign.signing",
            timestamp: Date()
        )
    }

    func manifestData(bundleID: String, appName: String) -> Data? {
        guard enabled, staffRoleAllowsBridge else { return nil }
        let context = makeContext(bundleID: bundleID, appName: appName)
        lastContext = context
        let payload: [String: Any] = [
            "version": context.version,
            "bundleID": context.bundleID,
            "appName": context.appName,
            "mdid": context.mdid,
            "role": context.role,
            "source": context.source,
            "timestamp": context.timestamp.timeIntervalSince1970
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    func publish(bundleID: String, appName: String, ipaURL: URL) {
        guard enabled, staffRoleAllowsBridge else { return }
        let context = makeContext(bundleID: bundleID, appName: appName, ipaURL: ipaURL)
        lastContext = context
        NotificationCenter.default.post(
            name: Self.notification,
            object: nil,
            userInfo: ["context": context]
        )
    }

    var staffRoleAllowsBridge: Bool {
        StaffGate.shared.role >= .developer
    }

    var mdidForDisplay: String {
        StaffGate.shared.mdid
    }
}

struct AVX512ExperimentalSection: View {
    let ipaURL: URL
    let appName: String
    let bundleID: String
    @Binding var dylibURL: URL?
    @Binding var showPicker: Bool
    @ObservedObject private var bridge = AVX512AirShareBridge.shared
    @ObservedObject private var staff = StaffGate.shared

    var body: some View {
        if staff.isStaff {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AVX512 EXPERIMENTAL")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Staff/admin bridge for signing + AVX512")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { bridge.enabled },
                        set: { value in
                            bridge.setEnabled(value)
                            if value, let url = AVX512DylibStore.storedURL {
                                dylibURL = url
                            }
                        }
                    ))
                    .labelsHidden()
                }

                HStack(spacing: 8) {
                    Image(systemName: dylibURL == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(dylibURL == nil ? .orange : .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dylibURL?.lastPathComponent ?? "No AVX512 dylib attached")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(dylibURL == nil
                             ? "Choose the AVX512 dylib once; enabled sign jobs attach it automatically."
                             : "Will be attached to this signed app when the bridge is enabled.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose") { showPicker = true }
                        .font(.system(size: 11, weight: .semibold))
                        .buttonStyle(.bordered)
                }

                if bridge.enabled {
                    Label("ADID \(bridge.mdidForDisplay)", systemImage: "person.badge.key.fill")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.cyan)

                    Text("The signed app receives a small AVX512.msign.json manifest containing the ADID, role, app identity and timestamp. No certificate, P12, private key or password is included.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.055))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}
