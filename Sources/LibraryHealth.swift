//
//  LibraryHealth.swift
//  Cert days left, installed vs signed version, last refresh, spoof/min-iOS fit.
//

import Foundation
import SwiftUI

struct LibraryHealthRow: Identifiable, Equatable {
    let id: String
    let name: String
    let bundleID: String
    let signedVersion: String
    let installedVersion: String?
    let certDaysLeft: Int?
    let lastRefresh: Date?
    let spoofFit: String

    var certLabel: String {
        guard let d = certDaysLeft else { return "No cert window" }
        if d < 0 { return "Cert expired" }
        if d == 0 { return "Expires today" }
        return "\(d)d cert"
    }

    var versionLabel: String {
        if let installed = installedVersion, !installed.isEmpty {
            if installed == signedVersion { return "v\(signedVersion) · installed" }
            return "signed \(signedVersion) · device \(installed)"
        }
        return "v\(signedVersion) · not installed"
    }
}

@MainActor
enum LibraryHealth {
    static func rows(
        signed: [SignedEntry] = SignedStore.shared.entries,
        installed: [DeviceApp] = DeviceLibrary.shared.apps
    ) -> [LibraryHealthRow] {
        let installedByBundle = Dictionary(uniqueKeysWithValues: installed.map { ($0.bundleID, $0) })
        let tracked = Dictionary(uniqueKeysWithValues: AppAutoUpdater.shared.tracked.map { ($0.bundleID, $0) })
        let spoof = StoreDeviceSpoof.current
        let spoofFit: String = {
            if !spoof.enabled { return "Spoof off" }
            return "Spoof \(spoof.summaryLabel)"
        }()

        return signed.map { entry in
            var certDays: Int?
            if let cert = CertificateStore.shared.certificates.first(where: { $0.name == entry.certName }),
               let data = try? Data(contentsOf: cert.provisionURL) {
                certDays = CertificateStore.profileInfo(data).daysUntilExpiry
            } else if let active = CertificateStore.shared.active,
                      let data = try? Data(contentsOf: active.provisionURL) {
                certDays = CertificateStore.profileInfo(data).daysUntilExpiry
            }
            _ = tracked[entry.bundleID]
            return LibraryHealthRow(
                id: entry.id,
                name: entry.name,
                bundleID: entry.bundleID,
                signedVersion: entry.version,
                installedVersion: installedByBundle[entry.bundleID]?.version,
                certDaysLeft: certDays,
                lastRefresh: entry.signedAt,
                spoofFit: spoofFit
            )
        }
    }
}

struct LibraryHealthSection: View {
    @ObservedObject private var signed = SignedStore.shared
    @ObservedObject private var device = DeviceLibrary.shared
    @ObservedObject private var certs = CertificateStore.shared

    private var rows: [LibraryHealthRow] {
        LibraryHealth.rows(signed: signed.entries, installed: device.apps)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("HEALTH")
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(1.1)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text(SideloadSurvival.countdownLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(TetherlessPalette.accent)
            }

            if rows.isEmpty {
                GlassCard {
                    StatusRow(kind: .info, title: "No signed apps yet",
                              subtitle: "After you sign, cert days and install status show here.")
                }
            } else {
                ForEach(rows.prefix(8)) { row in
                    GlassCard(corner: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(row.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Spacer()
                                Text(row.certLabel)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(certColor(row.certDaysLeft))
                            }
                            Text(row.versionLabel)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                            HStack {
                                if let last = row.lastRefresh {
                                    Text("Signed \(last.formatted(date: .abbreviated, time: .omitted))")
                                        .font(.caption2)
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                                Spacer()
                                Text(row.spoofFit)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.4))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { device.refreshIfStale() }
        .onChange(of: certs.certificates) { _ in }
    }

    private func certColor(_ days: Int?) -> Color {
        guard let d = days else { return .white.opacity(0.45) }
        if d <= 1 { return .orange }
        if d <= 3 { return TetherlessPalette.accent }
        return .white.opacity(0.7)
    }
}
