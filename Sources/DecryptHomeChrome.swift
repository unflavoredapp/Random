//
//  DecryptHomeChrome.swift
//  TetherLess Decrypt tab chrome — centered header, DRM-free hero, signed-in
//  store card, search field, and pick-encrypted-IPA card.
//

import IDeviceSwift
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
            Text("All in one app — silent Store download + FairPlay decrypt on this iPhone. No helper app and no App Store UI. Telegram Bot is an optional remote fallback only.")
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
    @ObservedObject private var store = AppleIDStore.shared
    @State private var showManage = false

    var body: some View {
        GlassCard(corner: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.accounts.count > 1 ? "Store account" : "Signed in")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 4)
                    if store.accounts.count > 1 {
                        Menu {
                            ForEach(store.accounts) { account in
                                Button {
                                    store.selectAccount(id: account.id)
                                } label: {
                                    if store.activeAccountID == account.id {
                                        Label(account.email, systemImage: "checkmark")
                                    } else {
                                        Text(account.email)
                                    }
                                }
                            }
                        } label: {
                            Text("Switch")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(TetherlessPalette.accent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(TetherlessPalette.accent.opacity(0.15), in: Capsule())
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button { showManage = true } label: {
                        Text("Manage")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.white.opacity(0.10), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                    }
                    .buttonStyle(.plain)

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
        .sheet(isPresented: $showManage) {
            NavigationStack {
                AppleIDManageView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showManage = false }
                        }
                    }
            }
            .preferredColorScheme(.dark)
        }
    }
}


/// Apps this Apple ID owns in purchase/download history (silent redownload targets).
struct DecryptOwnedStoreAppsSection: View {
    @ObservedObject private var decrypting = DeviceDecryptService.shared
    @AppStorage("uzd_decrypt_channel") private var channelRaw = DecryptChannel.device.rawValue
    @State private var owned: [OwnedStoreApp] = []
    @State private var loading = false
    @State private var loadError: String?

    private var channel: DecryptChannel { DecryptChannel(rawValue: channelRaw) ?? .device }

    var body: some View {
        if channel != .device { EmptyView() }
        else {
            GlassCard(corner: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("OWNED ON THIS APPLE ID")
                            .font(.system(size: 12, weight: .semibold))
                            .kerning(1.1)
                            .foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        if loading || decrypting.busy {
                            ProgressView().tint(TetherlessPalette.accent)
                        } else {
                            Button {
                                Task { await refresh() }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(TetherlessPalette.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Text("Purchase history from Store Access — tap Decrypt to silent-download and FairPlay without opening the App Store.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)

                    if let loadError, !loadError.isEmpty {
                        Text(loadError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if owned.isEmpty && !loading {
                        Text("No purchase history yet, or Apple didn’t return items for this session. Search still works for free/owned apps.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.45))
                    }

                    ForEach(owned.prefix(16)) { app in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text([app.version.isEmpty ? nil : "v\(app.version)",
                                       app.bundleId.isEmpty ? "id\(app.adamId)" : app.bundleId]
                                    .compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.45))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Button {
                                DeviceDecryptService.shared.decryptFromSearch(app.asDecryptApp)
                            } label: {
                                Text("Decrypt")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(TetherlessPalette.accent, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(decrypting.busy || DecryptClient.shared.busy)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            owned = try await DeviceDecryptService.shared.ownedStoreApps()
        } catch {
            owned = []
            loadError = error.localizedDescription
        }
    }
}

/// Installed App Store (DRM) apps on this device — primary on-device decrypt targets.
struct DecryptDeviceAppsSection: View {
    @ObservedObject private var device = DeviceLibrary.shared
    @ObservedObject private var decrypting = DeviceDecryptService.shared
    @AppStorage("uzd_decrypt_channel") private var channelRaw = DecryptChannel.device.rawValue

    private var drm: [DeviceApp] { device.apps.filter(\.isAppStore) }
    private var channel: DecryptChannel { DecryptChannel(rawValue: channelRaw) ?? .device }

    var body: some View {
        if channel != .device { EmptyView() }
        else {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("ON THIS DEVICE")
                        .font(.system(size: 12, weight: .semibold))
                        .kerning(1.1)
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer()
                    if device.loading || decrypting.busy {
                        ProgressView().tint(TetherlessPalette.accent)
                    } else {
                        Button {
                            device.refresh()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TetherlessPalette.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("Decrypts main, frameworks, widgets, Watch, and App Clips with this device’s FairPlay keys. Pair with Native install if the list is empty.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                if !drm.isEmpty {
                    Button {
                        Task { await DeviceDecryptService.shared.decryptAllInstalled() }
                    } label: {
                        Text(decrypting.busy ? "Decrypting…" : "Decrypt All")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .foregroundStyle(.white)
                            .background(TetherlessPalette.accent.opacity(decrypting.busy ? 0.45 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(decrypting.busy || DecryptClient.shared.busy || !NativeInstaller.isSelected || !(DevicePairingStore.hasSavedPairing))
                }

                if let err = decrypting.lastError ?? device.error, !err.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !decrypting.status.isEmpty {
                    Text(decrypting.status)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
                if !decrypting.lastReportSummary.isEmpty, decrypting.status.isEmpty {
                    Text(decrypting.lastReportSummary)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }

                if !NativeInstaller.isSelected {
                    Text("Set Install method to Native in Settings, then pair this iPhone — Decrypt lists App Store apps from the device connection.")
                        .font(.footnote)
                        .foregroundStyle(.orange.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                } else if !(DevicePairingStore.hasSavedPairing) {
                    Text("Pair this iPhone on the Pair tab first. On-device decrypt needs the Native connection.")
                        .font(.footnote)
                        .foregroundStyle(.orange.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Pair") { AppNav.shared.go(AppTab.pair.rawValue) }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TetherlessPalette.accent)
                } else if drm.isEmpty && !device.loading {
                    Text("No App Store apps listed yet. Tap refresh after pairing completes.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.45))
                }

                ForEach(drm.prefix(12)) { app in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text([app.version.isEmpty ? nil : "v\(app.version)", app.bundleID].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Button {
                            Task { await DeviceDecryptService.shared.decryptInstalled(app) }
                        } label: {
                            Text("Decrypt")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(TetherlessPalette.accent, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(decrypting.busy || DecryptClient.shared.busy || !NativeInstaller.isSelected || !(DevicePairingStore.hasSavedPairing))
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .onAppear {
            if NativeInstaller.isSelected { device.refreshIfStale() }
        }
        } // device channel
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


/// One-time App Store sign-in requirement for decrypt keys on this device.
struct DecryptAppStoreSignInHint: View {
    /// Compact layout for decrypt-failure callouts.
    var compact: Bool = false
    @ObservedObject private var store = AppleIDStore.shared
    @State private var ackTick = false

    private var email: String { store.email }
    private var acknowledged: Bool {
        _ = ackTick
        return AppStoreDecryptGuide.isAcknowledged(email: email)
    }

    var body: some View {
        if compact {
            compactBody
        } else if !acknowledged || email.isEmpty {
            fullBody
        } else {
            acknowledgedBody
        }
    }

    private var fullBody: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .font(.title3)
                        .foregroundStyle(TetherlessPalette.accent)
                    Text("One-time App Store sign-in")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                Text("To decrypt an app you own, the Apple ID you use in TetherLess must have been signed in to this iPhone’s App Store at least once — open the App Store app (or Settings → your name → Media & Purchases) and sign in with it one time.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                Text("This is a one-time step per Apple ID: iOS stores that account’s decryption keys the first time it signs in and keeps them, so afterward you can switch your active App Store account back and decrypting still works. The account also has to own the app.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Decrypt itself stays inside TetherLess — no helper app. Without that one-time App Store sign-in, decrypting fails after download because iOS has no keys for that account yet.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)

                if !email.isEmpty {
                    Text("Active Store account: \(email)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TetherlessPalette.accent.opacity(0.9))
                }
                actionButtons(showAck: !email.isEmpty)
            }
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !email.isEmpty {
                Text("Active Store account: \(email)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent.opacity(0.9))
            }
            Text(AppStoreDecryptGuide.failureHint)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true)
            actionButtons(showAck: !email.isEmpty)
        }
        .padding(.top, 4)
    }

    private var acknowledgedBody: some View {
        GlassCard(corner: 18) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(TetherlessPalette.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text("App Store sign-in noted")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(email.isEmpty ? "Keys should be on this device for your Store account." : "Marked for \(email). You can reopen the App Store anytime if decrypt still fails after download.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button("Open") { AppStoreDecryptGuide.openAppStore() }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
            }
        }
    }

    private func actionButtons(showAck: Bool) -> some View {
        VStack(spacing: 8) {
            Button { AppStoreDecryptGuide.openAppStore() } label: {
                Label("Open App Store", systemImage: "bag.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(TetherlessPalette.accent, in: Capsule())
            }
            .buttonStyle(.plain)

            if showAck {
                Button {
                    AppStoreDecryptGuide.setAcknowledged(true, email: email)
                    ackTick.toggle()
                } label: {
                    Text("I’ve signed in on this iPhone")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(.white.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
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
                        Text("Sign in under Settings › Store Access, and make sure that same Apple ID has signed in to this iPhone’s App Store at least once (App Store app, or Settings → your name → Media & Purchases). That’s how iOS stores the decryption keys — a one-time step per Apple ID.")
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
