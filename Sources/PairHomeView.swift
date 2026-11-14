//
//  PairHomeView.swift
//  TetherLess-style Pair tab — wraps DeviceInstallationManager / DevicePairingService.
//

import SwiftUI

struct PairHomeView: View {
    @ObservedObject private var manager = DeviceInstallationManager.shared
    @ObservedObject private var installer = NativeInstaller.shared

    @State private var confirmReset = false

    private var linked: Bool { manager.phase == .ready || manager.phase == .configured }
    private var busy: Bool { manager.isBusy || installer.isActive || manager.showsSetup }
    private static let onIOS27 = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
    )

    private var phaseSubtitle: String {
        switch manager.phase {
        case .idle: return "Tap Start Pairing below, then on this iPhone go to Settings → Privacy & Security → Developer Mode."
        case .connecting: return "Starting the local VPN tunnel…"
        case .pairing: return "Enter the pairing code under Settings → Privacy & Security → Developer Mode."
        case .ready, .configured: return "Native install connection is ready."
        case .failed(let msg): return msg
        }
    }

    var body: some View {
        ScreenScroll(title: "TetherLess") {
            VStack(spacing: 10) {
                Image(systemName: "iphone")
                    .font(.system(size: 76, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                Text("No computer. Ever.")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.top, 8)
            .padding(.bottom, 8)

            GlassCard {
                if linked {
                    StatusRow(kind: .ok, title: "Paired", subtitle: phaseSubtitle)
                } else if case .failed = manager.phase {
                    StatusRow(kind: .warning, title: "Pairing failed", subtitle: phaseSubtitle)
                } else if busy {
                    StatusRow(kind: .busy, title: "Pairing…", subtitle: phaseSubtitle)
                } else {
                    StatusRow(kind: .info, title: "Not paired yet", subtitle: phaseSubtitle)
                }
            }

            Button {
                Task { await manager.setUp() }
            } label: {
                if busy {
                    ProgressView().tint(.white)
                } else {
                    Label(linked ? "Pair Again" : "Start Pairing",
                          systemImage: "dot.radiowaves.left.and.right")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(busy || !Self.onIOS27)
            .opacity(Self.onIOS27 ? 1 : 0.55)

            if !Self.onIOS27 {
                GlassCard {
                    StatusRow(kind: .warning, title: "iOS 27 required",
                              subtitle: "On-device pairing needs iOS 27 or later. You're on iOS \(UIDevice.current.systemVersion). Use OTA install from Settings until then.")
                }
            }

            if busy {
                Button("Cancel") { manager.cancelSetup() }
                    .buttonStyle(SecondaryButtonStyle())
            }

            if linked {
                Button("Forget pairing", role: .destructive) { confirmReset = true }
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
            }

            if let notice = manager.setupNotice, !notice.isEmpty {
                GlassCard { StatusRow(kind: .info, title: notice) }
            }
        }
        .confirmationDialog("Forget this device's saved pairing?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Forget Pairing", role: .destructive) { Task { await manager.resetPairing() } }
        }
    }
}
