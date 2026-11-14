//
//  SideloadSurvival.swift
//  7-day survival loop: cert countdown, expiry push, Refresh All with KeepAlive.
//

import Foundation
import SwiftUI

@MainActor
enum SideloadSurvival {
    static let lastScheduleKey = "tetherless.survival.lastSchedule"

    /// Schedule cert expiry notifications and refresh widget snapshot.
    static func refreshExpiryLoop() {
        NotificationManager.shared.scheduleExpiryNotifications(for: CertificateStore.shared.certificates)
        WidgetDataManager.shared.refresh()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastScheduleKey)
    }

    /// Days until the active (or preferred Apple ID) signing cert expires.
    static var activeCertDaysLeft: Int? {
        guard let cert = CertificateStore.shared.preferredCertificate(forSigningMethod: "appleid")
                ?? CertificateStore.shared.active,
              let data = try? Data(contentsOf: cert.provisionURL) else { return nil }
        return CertificateStore.profileInfo(data).daysUntilExpiry
    }

    static var countdownLabel: String {
        guard let d = activeCertDaysLeft else { return "No signing certificate" }
        if d < 0 { return "Certificate expired" }
        if d == 0 { return "Expires today" }
        if d == 1 { return "1 day left" }
        return "\(d) days left"
    }

    /// Refresh All with background keep-alive so resign finishes after leaving the app.
    static func refreshAllWithKeepAlive() {
        refreshExpiryLoop()
        FreeAppleIDSigning.preferAppleIDSigningMethodIfPossible()
        let hold = "survival-refresh-\(UUID().uuidString)"
        BackgroundKeepAlive.shared.start(hold)
        AppleIDStore.shared.activatePreferredSigningCertificate()
        AppAutoUpdater.shared.refreshAll()
        Task {
            // Keep alive while updater reports busy; stop shortly after it settles.
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !AppAutoUpdater.shared.busy { break }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            BackgroundKeepAlive.shared.stop(hold)
            refreshExpiryLoop()
        }
    }
}

struct SideloadSurvivalCard: View {
    @ObservedObject private var certs = CertificateStore.shared
    @ObservedObject private var updater = AppAutoUpdater.shared
    @State private var label = SideloadSurvival.countdownLabel

    var body: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "heart.text.square.fill")
                        .font(.title2)
                        .foregroundStyle(TetherlessPalette.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("7-day survival")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(daysColor)
                    }
                    Spacer()
                }
                Text("Push before expiry, then Refresh All re-signs tracked apps in the background so installs survive free Apple ID renewals.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    SideloadSurvival.refreshAllWithKeepAlive()
                    label = SideloadSurvival.countdownLabel
                } label: {
                    HStack {
                        if updater.busy { ProgressView().tint(.white) }
                        else { Text("Refresh All now").font(.title3.weight(.semibold)) }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(TetherlessPalette.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(updater.busy)
            }
        }
        .onAppear {
            SideloadSurvival.refreshExpiryLoop()
            label = SideloadSurvival.countdownLabel
        }
        .onChange(of: certs.certificates) { _ in
            label = SideloadSurvival.countdownLabel
            SideloadSurvival.refreshExpiryLoop()
        }
    }

    private var daysColor: Color {
        guard let d = SideloadSurvival.activeCertDaysLeft else { return .white.opacity(0.55) }
        if d <= 1 { return .orange }
        if d <= 3 { return TetherlessPalette.accent }
        return .white.opacity(0.7)
    }
}
