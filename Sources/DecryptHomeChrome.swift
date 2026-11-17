//
// Brand: Tetherless · https://tetherless.dev
//  DecryptHomeChrome.swift
//  TetherLess Decrypt tab chrome — centered header, DRM-free hero, signed-in
//  store card, search field, and pick-encrypted-IPA card.
//

import IDeviceSwift
import SwiftUI

/// Left-aligned title + settings gear (matches reference Decrypt header).
struct DecryptChromeHeader: View {
    var onSettings: (() -> Void)?

    var body: some View {
        HStack {
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
            Text("Sign in under Account (add each country’s Apple ID you use). Search shows listings from every linked storefront — free apps or anything those IDs already purchased. Tetherless downloads and decrypts on-device. No Mac. No jailbreak.")
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
    @ObservedObject private var decrypting = DeviceDecryptService.shared

    private var storeReady: Bool { store.hasStoreDownloadSession }

    var body: some View {
        GlassCard(corner: 24) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: storeReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(storeReady ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(storeReady ? "Store ready for downloads" : "Store not connected yet")
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

                Text(storeReady
                     ? "Tap Test download to pull free TestFlight, install the companion, and run FairPlay."
                     : "Connect Store first (uses your Sign In trust token). Then Test download runs the full path.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                if storeReady {
                    Button {
                        DeviceDecryptService.shared.runStoreConnectionSmokeTest()
                    } label: {
                        HStack {
                            if decrypting.busy {
                                ProgressView().tint(.white)
                            }
                            Text(decrypting.busy ? "Testing…" : "Test download → companion")
                                .font(.body.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(TetherlessPalette.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(decrypting.busy || store.isBusy || store.storeConnecting)
                } else {
                    Button {
                        AppNav.shared.goAccount()
                    } label: {
                        Text("Sign in under Account")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(TetherlessPalette.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isBusy || decrypting.busy)
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

                    Text("Purchase history from Account — tap Decrypt to silent-download and FairPlay without opening the App Store.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)

                    if let loadError, !loadError.isEmpty {
                        let soft = loadError.localizedCaseInsensitiveContains("404")
                            || loadError.localizedCaseInsensitiveContains("204")
                            || loadError.localizedCaseInsensitiveContains("non-plist")
                            || loadError.localizedCaseInsensitiveContains("owned")
                            || loadError.localizedCaseInsensitiveContains("token expired")
                            || loadError.localizedCaseInsensitiveContains("session expired")
                            || loadError.localizedCaseInsensitiveContains("search still works")
                            || loadError.localizedCaseInsensitiveContains("search works")
                        Text(soft
                             ? "Owned list couldn’t load from Apple right now. Search still works for free & purchased apps — Account can stay signed in."
                             : loadError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        if loadError.localizedCaseInsensitiveContains("verification")
                            || loadError.localizedCaseInsensitiveContains("2fa")
                            || loadError.localizedCaseInsensitiveContains("two-factor")
                            || AppleIDStore.shared.storeNeedsVerification {
                            OwnedStoreTrustHint(onRetry: { await refresh() })
                        } else if soft || loadError.localizedCaseInsensitiveContains("403")
                            || loadError.localizedCaseInsensitiveContains("expired")
                            || loadError.localizedCaseInsensitiveContains("token") {
                            Text("Tip: pull to refresh here, or sign in again under Account. Search still works.")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
            if owned.isEmpty, AppleIDStore.shared.storefrontSession()?.isUsable == true {
                // Soft empty — keep tip mild when Store Access is already green.
                loadError = nil
            }
        } catch AppStoreClientError.needsTwoFactor {
            owned = []
            loadError = "Store needs the first Sign In trust — Sign Out, then Sign In once under Account. The Allow / verification code unlocks Store automatically (no second text)."
            AppleIDStore.shared.noteStoreNeedsVerification()
        } catch {
            owned = []
            let detail = error.localizedDescription
            if AppleIDStore.shared.storefrontSession()?.isUsable == true {
                loadError = "Owned list couldn’t load right now. Account is still signed in — Search works for free & purchased apps."
            } else if detail.localizedCaseInsensitiveContains("token expired")
                        || detail.localizedCaseInsensitiveContains("session expired") {
                loadError = "Store session needs a refresh — Sign Out → Sign In once under Account."
            } else {
                loadError = detail
            }
            if detail.localizedCaseInsensitiveContains("verification")
                || AppleIDStore.shared.storefrontSession()?.isUsable != true {
                // Only flag verification when we truly have no usable Store session.
                if AppleIDStore.shared.storefrontSession()?.isUsable != true {
                    AppleIDStore.shared.noteStoreNeedsVerification()
                }
            }
        }
    }
}

/// Store must piggyback the first Allow/code — no second Store OTP here.
private struct OwnedStoreTrustHint: View {
    var onRetry: () async -> Void
    @ObservedObject private var store = AppleIDStore.shared
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Store piggybacks the Allow / verification code from Sign In — it should not ask for another text.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task {
                    busy = true
                    defer { busy = false }
                    await store.requestStoreVerificationPrompt()
                    await onRetry()
                }
            } label: {
                Text(busy ? "Retrying…" : "Retry Store unlock")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
            }
            .buttonStyle(.plain)
            .disabled(busy || store.isBusy || store.storeConnecting)
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

                Text("Decrypts from the live install with this iPhone’s FairPlay keys — Account login is not required. Watch + App Clips skipped. Pair with Native if the list is empty.")
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
                    Button("Open Pair") { AppNav.shared.goPair() }
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
                TextField("Name, App ID, or apps.apple.com link", text: $query)
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


/// One-time App Store sign-in — guided capture sheet with verify + confirm.
struct DecryptAppStoreSignInHint: View {
    /// Compact layout for decrypt-failure callouts.
    var compact: Bool = false
    @ObservedObject private var store = AppleIDStore.shared
    @ObservedObject private var keys = FairPlayKeysFetcher.shared

    private var email: String { store.email }

    var body: some View {
        Group {
            if compact {
                compactBody
            } else {
                switch keys.phase {
                case .grabbed:
                    grabbedBody
                case .confirmSignIn:
                    confirmBody
                case .waitingForReturn, .redirecting, .verifying:
                    waitingBody
                default:
                    if !email.isEmpty, AppStoreDecryptGuide.isAcknowledged(email: email) {
                        grabbedBody
                    } else {
                        fullBody
                    }
                }
            }
        }
        .onAppear { keys.refreshFromAck() }
        .onChange(of: store.email) { _ in keys.refreshFromAck() }
        .animation(.easeInOut(duration: 0.2), value: keys.phase)
    }

    private var fullBody: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "key.fill")
                        .font(.title3)
                        .foregroundStyle(TetherlessPalette.accent)
                    Text("Get FairPlay keys")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                Text("Open App Store account or Media & Purchases with your session Apple ID. When you return, TetherLess verifies on-device license folders and asks you to confirm before companion decrypt.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                Text("iOS stores the keys on this iPhone; afterward you can switch the active App Store account. The account still has to own the app.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)

                if !email.isEmpty {
                    Text("Session: \(email)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TetherlessPalette.accent.opacity(0.9))
                }
                fetchButtons
                if let banner = keys.banner {
                    Text(banner)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var waitingBody: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(TetherlessPalette.accent)
                    Text(waitingTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                Text(keys.banner
                     ?? "Sign in with \(email.isEmpty ? "your Apple ID" : email), then return — we’ll verify and ask you to confirm.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
                if !keys.verifyLines.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(keys.verifyLines.enumerated()), id: \.offset) { _, line in
                            Text("· \(line)")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                }
                Button {
                    keys.presentCaptureSheet()
                } label: {
                    Text("Open capture sheet")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(.white.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                }
                .buttonStyle(.plain)
                if case .waitingForReturn = keys.phase {
                    Button {
                        keys.markGrabbedManually()
                    } label: {
                        Text("I’ve signed in — verify now")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var confirmBody: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Confirm key capture", systemImage: "checkmark.shield")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                if case .confirmSignIn(let e, let hints) = keys.phase {
                    Text(hints > 0
                         ? "Found \(hints) license folder(s). Confirm you signed in as \(e)."
                         : "Confirm you signed in to Media & Purchases as \(e).")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.62))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    keys.confirmGrabbed()
                } label: {
                    Text("Confirm keys grabbed")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(TetherlessPalette.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                Button {
                    keys.presentCaptureSheet()
                } label: {
                    Text("Open capture sheet")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !email.isEmpty {
                Text("Session: \(email)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent.opacity(0.9))
            }
            if case .grabbed = keys.phase {
                Label("Keys grabbed for this session", systemImage: "checkmark.seal.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.success)
            } else if case .confirmSignIn = keys.phase {
                Label("Confirm key capture", systemImage: "checkmark.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
            } else if keys.isWaiting {
                Label("Capturing FairPlay keys…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
            } else {
                Text(AppStoreDecryptGuide.failureHint)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            fetchButtons
        }
        .padding(.top, 4)
    }

    private var grabbedBody: some View {
        GlassCard(corner: 18) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(TetherlessPalette.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keys grabbed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(grabbedDetail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Button("Refresh") {
                    keys.presentCaptureSheet()
                    keys.startFetchFromSession()
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(TetherlessPalette.accent)
            }
        }
    }

    private var grabbedDetail: String {
        if case .grabbed(let e, _, let hints) = keys.phase {
            let base = e.isEmpty
                ? "FairPlay keys ready for companion decrypt."
                : "Grabbed for \(e)."
            return hints > 0 ? "\(base) \(hints) license folder(s) seen." : base
        }
        return email.isEmpty
            ? "FairPlay keys ready for companion decrypt."
            : "Grabbed for \(email). Companion handoff will confirm this before packaging."
    }

    private var waitingTitle: String {
        switch keys.phase {
        case .redirecting: return "Opening App Store…"
        case .verifying: return "Verifying keys…"
        default: return "Waiting for App Store…"
        }
    }

    private var fetchButtons: some View {
        VStack(spacing: 8) {
            Button {
                keys.presentCaptureSheet()
                keys.startFetchFromSession(preferSettings: false)
            } label: {
                Label(
                    keys.isWaiting ? "Reopen capture" : "Get keys",
                    systemImage: "key.fill"
                )
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(TetherlessPalette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(email.isEmpty && !store.isSignedIn)

            Button {
                keys.presentCaptureSheet()
                keys.startFetchFromSession(preferSettings: true)
            } label: {
                Text("Open Media & Purchases")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(.white.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
            }
            .buttonStyle(.plain)

            if case .confirmSignIn = keys.phase {
                Button {
                    keys.confirmGrabbed()
                } label: {
                    Text("Confirm keys grabbed")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TetherlessPalette.accent)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            } else if !keys.isGrabbed, !email.isEmpty, !keys.isWaiting {
                Button {
                    keys.presentCaptureSheet()
                    keys.markGrabbedManually()
                } label: {
                    Text("Already signed in — verify & confirm")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
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
                        Text("Apple Account needed")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text("Sign in under Account, and make sure that same Apple ID has signed in to this iPhone’s App Store at least once (App Store app, or Settings → your name → Media & Purchases). That’s how iOS stores the decryption keys — a one-time step per Apple ID.")
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
