//
//  InstallAutopilot.swift
//  Prefer Native when paired; otherwise OTA. Self-heals method after resign.
//

import Foundation
import SwiftUI

@MainActor
enum InstallAutopilot {
    static let autoKey = "tetherless.installMethod.auto"
    static let modeKey = NativeInstaller.methodKey // "ota" | "native"

    static var autoEnabled: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }

    /// Apply Native if pairing is healthy, else OTA. Returns the chosen method.
    @discardableResult
    static func apply() -> String {
        guard autoEnabled else {
            return UserDefaults.standard.string(forKey: modeKey) ?? "ota"
        }
        let paired = DevicePairingStore.hasSavedPairing
        let method = paired ? "native" : "ota"
        UserDefaults.standard.set(method, forKey: modeKey)
        return method
    }

    /// Mid-flight fallback when Native fails because pairing/VPN died.
    static func fallbackToOTAIfNeeded(error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        let looksPairing = text.contains("pair") || text.contains("vpn") || text.contains("tunnel")
            || text.contains("connection") || text.contains("idevice") || text.contains("lockdownd")
        guard looksPairing else { return false }
        UserDefaults.standard.set("ota", forKey: modeKey)
        return true
    }

    static var statusLabel: String {
        let method = UserDefaults.standard.string(forKey: modeKey) ?? "ota"
        if !autoEnabled { return method.uppercased() + " (manual)" }
        return method == "native" ? "Native (paired)" : "OTA (no pairing)"
    }
}

struct InstallAutopilotCard: View {
    @State private var auto = InstallAutopilot.autoEnabled
    @State private var label = InstallAutopilot.statusLabel

    var body: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(
                    get: { auto },
                    set: {
                        auto = $0
                        InstallAutopilot.autoEnabled = $0
                        label = InstallAutopilot.apply()
                        label = InstallAutopilot.statusLabel
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Install method autopilot")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Use Native when this iPhone is paired; otherwise OTA via tetherless.dev. Survives re-signing TetherLess when Pair dies.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.45))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(TetherlessPalette.accent)

                Text("Current: \(label)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)

                Button {
                    label = InstallAutopilot.statusLabel
                    _ = InstallAutopilot.apply()
                    label = InstallAutopilot.statusLabel
                } label: {
                    Text("Re-evaluate now")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(TetherlessPalette.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            auto = InstallAutopilot.autoEnabled
            _ = InstallAutopilot.apply()
            label = InstallAutopilot.statusLabel
        }
    }
}
