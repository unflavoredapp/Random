//
// Brand: AppAssassin · https://fastdecrypt.ai
//  FairPlayDecryptReadiness.swift
//  Pre-Get readiness strip (Search) + FairPlay smoke checklist (Account).
//

import SwiftUI

/// Shared FairPlay / companion readiness for Search strip + Account smoke checklist.
@MainActor
enum FairPlayDecryptReadiness {
    /// Best-effort target bid for live-path checks (Search selection → stamps).
    static func targetBundleID() -> String {
        let selected = (DecryptClient.shared.selected?.bundle ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty { return selected }
        let stamped = (DecryptCompanionHandoff.readLiveInstallPath()?.bundleID
            ?? DecryptCompanionHandoff.readEncryptedIPAPath()?.bundleID
            ?? DecryptCompanionHandoff.readTargetStamp()?.bundleID
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stamped
    }

    static var appleIDReady: Bool { AppleIDStore.shared.isSignedIn }

    static var storeSessionReady: Bool {
        let store = AppleIDStore.shared
        return store.isSignedIn
            && !store.storeNeedsVerification
            && store.storeReady
            && store.hasStoreDownloadSession
    }

    static var keysReady: Bool {
        FairPlayKeyGate.isReady
    }

    static var pairReady: Bool {
        DevicePairingStore.hasSavedPairing && NativeInstaller.isSelected
    }

    /// Stamped live path that matches `bundleID` (empty bid → any stamp).
    static func stampedLivePath(matching bundleID: String) -> String? {
        let bid = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if bid.isEmpty {
            return DecryptCompanionHandoff.readLiveInstallPath()?.path
        }
        return DecryptCompanionHandoff.readLiveInstallPath(matchingBundleID: bid)?.path
    }

    /// Resolve / refresh live Store `.app` for `bundleID`. Stamps on success.
    @discardableResult
    static func refreshLivePath(bundleID: String) async -> URL? {
        let bid = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bid.isEmpty else { return nil }
        if let live = await FairPlayKeyGate.resolveLiveInstallURL(bundleID: bid) {
            DecryptCompanionHandoff.publishLiveInstallPath(live.path, bundleID: bid)
            return live
        }
        return nil
    }
}

// MARK: - Search: compact pre-Get strip

/// One-line readiness before Get: Apple ID · Store · Keys (live path is optional hint).
struct FairPlayPreGetReadinessStrip: View {
    @ObservedObject private var store = AppleIDStore.shared
    @ObservedObject private var keys = FairPlayKeysFetcher.shared
    @ObservedObject private var client = DecryptClient.shared
    @State private var liveOK: Bool?
    @State private var liveLabel = "Live (opt)"
    @State private var probing = false

    private var bid: String {
        let selected = (client.selected?.bundle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty { return selected }
        return FairPlayDecryptReadiness.targetBundleID()
    }

    private var allGreen: Bool {
        // Live path is optional — FairPlayed remaps from EmbeddedPayload.
        FairPlayDecryptReadiness.appleIDReady
            && FairPlayDecryptReadiness.storeSessionReady
            && FairPlayDecryptReadiness.keysReady
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: allGreen ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(allGreen ? TetherlessPalette.accent : Color.orange.opacity(0.9))
                Text(allGreen ? "Ready for Get" : "Before Get")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
                if probing {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white.opacity(0.7))
                } else {
                    Button("Refresh") {
                        Task { await refreshLive(force: true) }
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
                    .buttonStyle(.plain)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(
                        title: "Apple ID",
                        ok: FairPlayDecryptReadiness.appleIDReady,
                        action: { AppNav.shared.goAppleIDLogin() }
                    )
                    chip(
                        title: "Store",
                        ok: FairPlayDecryptReadiness.storeSessionReady,
                        action: { AppNav.shared.goStoreUnlock() }
                    )
                    chip(
                        title: "Keys",
                        ok: FairPlayDecryptReadiness.keysReady,
                        action: { FairPlayKeysFetcher.shared.presentCaptureSheet() }
                    )
                    chip(
                        title: liveLabel,
                        ok: liveOK == true,
                        pending: liveOK == nil && !bid.isEmpty,
                        action: {
                            if bid.isEmpty {
                                AppNav.shared.goAccount()
                            } else {
                                Task { await refreshLive(force: true) }
                            }
                        }
                    )
                }
            }

            if !allGreen {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        )
        .onAppear {
            keys.refreshFromAck()
            Task { await refreshLive(force: false) }
        }
        .onChange(of: client.selected?.bundle ?? "") { _ in
            Task { await refreshLive(force: true) }
        }
        .onChange(of: store.email) { _ in
            keys.refreshFromAck()
            Task { await refreshLive(force: false) }
        }
    }

    private var hint: String {
        if !FairPlayDecryptReadiness.appleIDReady {
            return "Sign in with Apple ID under Account."
        }
        if !FairPlayDecryptReadiness.storeSessionReady {
            return "Finish Store login (second Allow + code) under Account."
        }
        if !FairPlayDecryptReadiness.keysReady {
            return "Confirm FairPlay keys after Media & Purchases."
        }
        if bid.isEmpty {
            return "Select an app (or Probe on Account) so Get knows which bid to embed."
        }
        if liveOK != true {
            return "Ready — live path optional. Enable Developer Mode; Get embeds Mach-Os + SC_Info for FairPlay."
        }
        return ""
    }

    private func chip(title: String, ok: Bool, pending: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: ok ? "checkmark.circle.fill" : (pending ? "circle.dotted" : "xmark.circle.fill"))
                    .font(.caption2.weight(.semibold))
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(ok ? TetherlessPalette.accent : (pending ? Color.white.opacity(0.55) : Color.orange.opacity(0.95)))
            .padding(.horizontal, 10)
            .frame(minHeight: 28)
            .background(Color.white.opacity(0.10), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }

    private func refreshLive(force: Bool) async {
        let want = bid
        if want.isEmpty {
            liveOK = nil
            liveLabel = "Live (opt)"
            return
        }
        if !force, let stamped = FairPlayDecryptReadiness.stampedLivePath(matching: want) {
            liveOK = true
            liveLabel = shortPath(stamped)
            return
        }
        probing = true
        defer { probing = false }
        if let live = await FairPlayDecryptReadiness.refreshLivePath(bundleID: want) {
            liveOK = true
            liveLabel = shortPath(live.path)
        } else {
            liveOK = false
            liveLabel = "Live (opt)"
        }
    }

    private func shortPath(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if name.hasSuffix(".app") { return name }
        return "Live ✓"
    }
}

// MARK: - Account: FairPlay smoke checklist

/// Device smoke path: Pair → Installed → Store → Keys → Probe → Get → companion → clear IPA.
struct FairPlaySmokeChecklistSection: View {
    @ObservedObject private var store = AppleIDStore.shared
    @ObservedObject private var keys = FairPlayKeysFetcher.shared
    @ObservedObject private var library = DeviceLibrary.shared
    @State private var liveOK = false
    @State private var liveDetail = "No live path stamped yet"
    @State private var probing = false
    @State private var refreshingLibrary = false

    private var bid: String { FairPlayDecryptReadiness.targetBundleID() }

    private var companionPending: Bool {
        DecryptCompanionHandoff.pendingOpen() != nil
    }

    private var clearIPAReady: Bool {
        DecryptClient.shared.finished != nil
            || DecryptClient.shared.phase == .done
    }

    var body: some View {
        Section {
            checklistRow(
                done: FairPlayDecryptReadiness.pairReady,
                title: "1. Pair Native",
                detail: FairPlayDecryptReadiness.pairReady
                    ? "Native pairing selected"
                    : "Open Pair → connect Native so installd Path is visible",
                actionTitle: FairPlayDecryptReadiness.pairReady ? nil : "Open Pair"
            ) {
                AppNav.shared.goPair()
            }
            checklistRow(
                done: library.lastLoaded != nil && !library.apps.isEmpty,
                title: "2. Refresh Installed",
                detail: library.apps.isEmpty
                    ? (refreshingLibrary ? "Refreshing…" : "Pull Installed / tap Refresh so Store apps appear")
                    : "\(library.apps.count) app(s) loaded",
                actionTitle: refreshingLibrary ? nil : "Refresh"
            ) {
                Task {
                    refreshingLibrary = true
                    _ = await DeviceLibrary.shared.refreshAwaiting()
                    refreshingLibrary = false
                }
            }
            checklistRow(
                done: FairPlayDecryptReadiness.storeSessionReady,
                title: "3. Store unlock",
                detail: FairPlayDecryptReadiness.storeSessionReady
                    ? "Store download session ready"
                    : "Finish Store login (second Allow + code)",
                actionTitle: FairPlayDecryptReadiness.storeSessionReady ? nil : "Store login"
            ) {
                AppNav.shared.goStoreUnlock()
            }
            checklistRow(
                done: FairPlayDecryptReadiness.keysReady,
                title: "4. Confirm keys",
                detail: FairPlayDecryptReadiness.keysReady
                    ? "FairPlay keys acknowledged"
                    : "Media & Purchases → Confirm keys",
                actionTitle: FairPlayDecryptReadiness.keysReady ? nil : "Confirm keys"
            ) {
                FairPlayKeysFetcher.shared.presentCaptureSheet()
            }
            checklistRow(
                done: liveOK,
                title: "5. Probe live path (optional)",
                detail: liveDetail,
                actionTitle: probing ? nil : "Probe"
            ) {
                Task { await probeLive() }
            }
            checklistRow(
                done: companionPending || clearIPAReady || DecryptClient.shared.phase == .running,
                title: "6. Get → FastDecryptBot",
                detail: companionPending
                    ? "Companion pending open / Trust"
                    : (DecryptClient.shared.phase == .running
                        ? "Get in progress…"
                        : "Search → Get embeds Mach-Os + SC_Info; FairPlay remaps EmbeddedPayload"),
                actionTitle: "Open Search"
            ) {
                AppNav.shared.goSearch()
            }
            checklistRow(
                done: clearIPAReady,
                title: "7. Clear IPA back",
                detail: clearIPAReady
                    ? "Clear IPA imported / finished"
                    : "After companion finishes, host imports clear IPA (or Share on free cert)",
                actionTitle: clearIPAReady ? nil : "Check export"
            ) {
                _ = DecryptCompanionHandoff.consumePendingClearIPAExport()
                AppNav.shared.goSearch()
            }
        } header: {
            Text("FairPlay smoke checklist")
        } footer: {
            Text("On-device FairPlay (iOS 17.4+ · Developer Mode) remaps from EmbeddedPayload inside FastDecryptBot. Live path is optional. Confirm keys, then Get. Native pairing stays iOS 27+.")
        }
        .onAppear {
            keys.refreshFromAck()
            hydrateLive()
            Task { await probeLive(quiet: true) }
        }
        .onChange(of: store.email) { _ in
            keys.refreshFromAck()
            hydrateLive()
        }
    }

    private func hydrateLive() {
        if let path = FairPlayDecryptReadiness.stampedLivePath(matching: bid) {
            liveOK = true
            liveDetail = path
        } else if bid.isEmpty {
            liveOK = false
            liveDetail = "Pick an app on Search or Probe a Store install"
        } else {
            liveOK = false
            liveDetail = "No live path for \(bid) (optional — EmbeddedPayload is enough)"
        }
    }

    private func probeLive(quiet: Bool = false) async {
        let want = bid
        guard !want.isEmpty else {
            if !quiet {
                liveOK = false
                liveDetail = "Pick an app on Search (or Probe under FairPlay keys) first"
            }
            return
        }
        probing = true
        defer { probing = false }
        if let live = await FairPlayDecryptReadiness.refreshLivePath(bundleID: want) {
            liveOK = true
            liveDetail = live.path
        } else {
            liveOK = false
            liveDetail = FairPlayDecryptReadiness.pairReady
                ? "None for \(want) — install from App Store if missing, then refresh Installed"
                : "None for \(want) — Pair Native so installd Path is visible"
        }
    }

    @ViewBuilder
    private func checklistRow(
        done: Bool,
        title: String,
        detail: String,
        actionTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(done ? Color.accentColor : Color.secondary)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .font(.caption.weight(.semibold))
                }
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
