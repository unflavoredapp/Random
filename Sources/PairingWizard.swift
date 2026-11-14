//
//  PairingWizard.swift
//  First-run / recover pairing: verify path, save pairing, self-heal when it drops.
//

import SwiftUI

@MainActor
enum PairingWizard {
    static let seenKey = "tetherless.pairingWizard.seen"

    static var shouldOffer: Bool {
        !UserDefaults.standard.bool(forKey: seenKey)
            && !DevicePairingStore.hasSavedPairing
    }

    static func markSeen() {
        UserDefaults.standard.set(true, forKey: seenKey)
    }

    /// Re-evaluate install method after pairing changes.
    static func selfHeal() {
        _ = InstallAutopilot.apply()
    }
}

struct PairingWizardCard: View {
    @ObservedObject private var manager = DeviceInstallationManager.shared
    @State private var status = ""

    var body: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pairing wizard")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Pair once so Native install works. If Pair dies after re-signing TetherLess, Install Autopilot falls back to OTA.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                if DevicePairingStore.hasSavedPairing {
                    StatusRow(kind: .ok, title: "Pairing saved",
                              subtitle: InstallAutopilot.statusLabel)
                } else {
                    StatusRow(kind: .info, title: "Not paired",
                              subtitle: "Start on the Pair tab, then return here to verify.")
                }

                HStack(spacing: 10) {
                    Button {
                        AppNav.shared.go(AppTab.pair.rawValue)
                        PairingWizard.markSeen()
                    } label: {
                        Text(DevicePairingStore.hasSavedPairing ? "Open Pair" : "Start pairing")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(TetherlessPalette.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        PairingWizard.selfHeal()
                        status = InstallAutopilot.statusLabel
                        PairingWizard.markSeen()
                    } label: {
                        Text("Verify")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if !status.isEmpty {
                    Text(status).font(.caption2).foregroundStyle(TetherlessPalette.accent)
                }
            }
        }
        .onAppear {
            PairingWizard.selfHeal()
            status = InstallAutopilot.statusLabel
        }
        .onChange(of: manager.phase) { _ in
            PairingWizard.selfHeal()
            status = InstallAutopilot.statusLabel
        }
    }
}
