//
// Brand: Tetherless · https://tetherless.dev
//  PairHomeView.swift
//  TetherLess-style Pair tab — wraps DeviceInstallationManager / DevicePairingService.
//  Uses the built-in local VPN (AirShareDeviceTunnel), never an external LocalDevVPN app.
//

import SwiftUI

struct PairHomeView: View {
    @ObservedObject private var manager = DeviceInstallationManager.shared
    @ObservedObject private var installer = NativeInstaller.shared
    @ObservedObject private var pairing = DevicePairingService.shared

    @State private var confirmReset = false
    @State private var savedUDID: String?

    private var linked: Bool { manager.phase == .ready || manager.phase == .configured }
    private var hasPairing: Bool { DevicePairingStore.hasSavedPairing || savedUDID != nil }
    private var busy: Bool { manager.isBusy || installer.isActive || manager.showsSetup }
    private static let onIOS27 = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
    )

    private var phaseSubtitle: String {
        switch manager.phase {
        case .idle:
            return "Tap Start Pairing below, then on this iPhone go to Settings → Privacy & Security → Developer Mode."
        case .connecting:
            return "Starting TetherLess’s local VPN tunnel…"
        case .pairing:
            if pairing.pin != nil {
                return "Enter this code under Settings → Privacy & Security → Developer Mode → Pair with TetherLess."
            }
            return "Open Settings → Privacy & Security → Developer Mode and choose Pair with TetherLess…"
        case .ready, .configured:
            return savedUDID ?? "Native install connection is ready."
        case .failed(let msg):
            return msg
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
                if linked || hasPairing {
                    StatusRow(
                        kind: .ok,
                        title: "Paired",
                        subtitle: savedUDID ?? phaseSubtitle
                    )
                } else if case .failed = manager.phase {
                    StatusRow(kind: .warning, title: "Pairing failed", subtitle: phaseSubtitle)
                } else if manager.phase == .pairing, let pin = pairing.pin {
                    VStack(alignment: .leading, spacing: 14) {
                        StatusRow(kind: .busy, title: "Pairing…", subtitle: "Enter this code in Settings")
                        Text(pin)
                            .font(.system(size: 44, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .accessibilityLabel("Pairing code \(pin)")
                        Text(phaseSubtitle)
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                } else if busy {
                    StatusRow(kind: .busy, title: "Pairing…", subtitle: phaseSubtitle)
                } else {
                    StatusRow(kind: .info, title: "Not paired yet", subtitle: phaseSubtitle)
                }
            }

            // Paired but tunnel not ready: finish with built-in local VPN (not LocalDevVPN).
            if hasPairing, !linked {
                GlassCard {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "globe")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(TetherlessPalette.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("One more step to finish setup")
                                    .font(.headline.weight(.semibold))
                                    .foregroundStyle(.white)
                                Text("Allow TetherLess’s local VPN when iOS asks, then tap Connect below. No separate VPN app.")
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.6))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Button {
                            Task { await manager.setUp() }
                        } label: {
                            if busy {
                                ProgressView().tint(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            } else {
                                Label("Connect", systemImage: "globe")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .background(TetherlessPalette.accent, in: Capsule())
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(busy || !Self.onIOS27)
                    }
                }
            } else if !hasPairing {
                Button {
                    Task { await manager.setUp() }
                } label: {
                    if busy {
                        ProgressView().tint(.white)
                    } else {
                        Label("Start Pairing", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy || !Self.onIOS27)
                .opacity(Self.onIOS27 ? 1 : 0.55)
            } else if linked {
                Button {
                    Task { await manager.setUp() }
                } label: {
                    if busy {
                        ProgressView().tint(.white)
                    } else {
                        Label("Pair Again", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy || !Self.onIOS27)
            }

            if !Self.onIOS27 {
                GlassCard {
                    StatusRow(
                        kind: .warning,
                        title: "iOS 27 required",
                        subtitle: "On-device pairing needs iOS 27 or later. You're on iOS \(UIDevice.current.systemVersion). Use OTA install from Settings until then."
                    )
                }
            }

            if busy {
                Button("Cancel") { manager.cancelSetup() }
                    .buttonStyle(SecondaryButtonStyle())
            }

            if hasPairing || linked {
                Button {
                    confirmReset = true
                } label: {
                    Label("Forget Pairing", systemImage: "trash")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            if let notice = manager.setupNotice, !notice.isEmpty {
                GlassCard { StatusRow(kind: .info, title: notice) }
            }
        }
        .confirmationDialog("Forget this device's saved pairing?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Forget Pairing", role: .destructive) {
                Task {
                    await manager.resetPairing()
                    savedUDID = nil
                }
            }
        }
        .onAppear { refreshUDID() }
        .onChange(of: manager.phase) { _ in refreshUDID() }
    }

    private func refreshUDID() {
        savedUDID = try? DevicePairingStore.load()?.device_udid
    }
}
