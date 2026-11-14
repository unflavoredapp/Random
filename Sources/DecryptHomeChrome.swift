//
//  DecryptHomeChrome.swift
//  TetherLess Decrypt tab chrome — header, DRM-free hero, and one-time setup card
//  matching the glassmorphism reference screenshots.
//

import SwiftUI

/// Soft chrome wrapper: gradient-friendly title row matching the Decrypt screenshot.
struct DecryptChromeHeader: View {
    var onSettings: (() -> Void)?

    var body: some View {
        HStack(alignment: .center) {
            Text("Decrypt")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            if let onSettings {
                Button(action: onSettings) {
                    Image(systemName: "gearshape.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .accessibilityLabel("Settings")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

/// Centered hero: open lock + “Get a DRM-free app” copy.
struct DecryptHeroBlock: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.open")
                .font(.system(size: 56, weight: .regular))
                .foregroundStyle(.white.opacity(0.95))
            Text("Get a DRM-free app")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
            Text("Search for an app you own, and TetherLess downloads and decrypts it — fully on-device, no Mac, no jailbreak.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .padding(.bottom, 8)
    }
}

/// One-time setup card (screenshot 3) or in-progress status (screenshot 4).
struct DecryptSetupCard: View {
    enum Phase {
        case needed
        case running(subtitle: String)
    }

    let phase: Phase
    var onBegin: (() -> Void)?

    var body: some View {
        GlassCard(corner: 24) {
            switch phase {
            case .needed:
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(TetherlessPalette.accent)
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("One-time setup needed")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
                            Text("Needed once before you can sign in and download.")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    Button(action: { onBegin?() }) {
                        Text("Begin Setup")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(TetherlessPalette.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            case .running(let subtitle):
                HStack(alignment: .top, spacing: 14) {
                    ProgressView()
                        .tint(TetherlessPalette.accent)
                        .frame(width: 28, height: 28)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Setting up…")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
    }
}
