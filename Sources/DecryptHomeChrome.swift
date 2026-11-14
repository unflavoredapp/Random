//
//  DecryptHomeChrome.swift
//  TetherLess Decrypt tab chrome — centered header, DRM-free hero, signed-in
//  store card, search field, and pick-encrypted-IPA card.
//

import SwiftUI

/// Centered title + settings gear (reference Decrypt header).
struct DecryptChromeHeader: View {
    var onSettings: (() -> Void)?

    var body: some View {
        ZStack {
            Text("Decrypt")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
            HStack {
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
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

struct DecryptSignedInCard: View {
    let email: String
    var onSignOut: () -> Void

    var body: some View {
        GlassCard(corner: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Signed in")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
                Button(action: onSignOut) {
                    Text("Sign Out")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct DecryptSearchBar: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    var onSearch: () -> Void

    var body: some View {
        GlassCard(corner: 22) {
            HStack(spacing: 12) {
                TextField("App name", text: $query)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .foregroundStyle(.white)
                    .focused(focused)
                    .submitLabel(.search)
                    .onSubmit(onSearch)
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(TetherlessPalette.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search")
            }
        }
    }
}

struct DecryptPickIPACard: View {
    var onPick: () -> Void

    var body: some View {
        GlassCard(corner: 24) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Already have an encrypted IPA?")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Button(action: onPick) {
                    Label("Pick an Encrypted IPA…", systemImage: "folder.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(TetherlessPalette.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct DecryptStoreGateCard: View {
    var onOpenSettings: () -> Void

    var body: some View {
        GlassCard(corner: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "bag.fill")
                        .font(.title2)
                        .foregroundStyle(TetherlessPalette.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Store Access needed")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Sign in with your Apple ID under Settings › Store Access so Decrypt can download apps you own.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
                Button(action: onOpenSettings) {
                    Text("Open Settings")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(TetherlessPalette.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
