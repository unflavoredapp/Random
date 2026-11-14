//
//  TetherLessVaultBackup.swift
//  Encrypted export/import of Store Access sessions + certificates/profiles.
//

import Foundation
import CryptoKit
import UIKit
import SwiftUI

struct VaultPayload: Codable {
    var version: Int = 1
    var createdAt: Date
    var deviceName: String
    var accounts: [VaultAccount]
    var certificates: [VaultCert]
}

struct VaultAccount: Codable {
    var id: String
    var email: String
    var password: String?
    var storeSessionJSON: Data?
    var deviceUDIDs: [String]
}

struct VaultCert: Codable {
    var id: String
    var name: String
    var p12Data: Data
    var provisionData: Data
    var password: String
}

@MainActor
enum TetherLessVaultBackup {
    static func exportVault() throws -> URL {
        var accounts: [VaultAccount] = []
        for a in AppleIDStore.shared.accounts {
            let pw = Keychain.getSecret("tetherless.appleid.password." + a.id)
            accounts.append(VaultAccount(
                id: a.id,
                email: a.email,
                password: pw,
                storeSessionJSON: a.storeSessionJSON,
                deviceUDIDs: a.deviceUDIDs
            ))
        }
        var certs: [VaultCert] = []
        for c in CertificateStore.shared.certificates where !c.isLocked {
            guard let p12 = try? Data(contentsOf: c.p12URL),
                  let mp = try? Data(contentsOf: c.provisionURL),
                  let password = Keychain.get("cert-" + c.id) else { continue }
            certs.append(VaultCert(id: c.id, name: c.name, p12Data: p12, provisionData: mp, password: password))
        }
        let payload = VaultPayload(
            createdAt: Date(),
            deviceName: UIDevice.current.name,
            accounts: accounts,
            certificates: certs
        )
        let data = try JSONEncoder().encode(payload)
        let key = try vaultKey()
        let box = try AES.GCM.seal(data, using: key)
        guard let combined = box.combined else {
            throw BackupError.encryptionFailed
        }
        let url = AppPaths.dir("backups").appendingPathComponent("tetherless-vault-\(UUID().uuidString.prefix(8)).tlv")
        try combined.write(to: url, options: .atomic)
        return url
    }

    static func importVault(from url: URL) throws {
        let encrypted = try Data(contentsOf: url)
        let key = try vaultKey()
        let box = try AES.GCM.SealedBox(combined: encrypted)
        let data = try AES.GCM.open(box, using: key)
        let payload = try JSONDecoder().decode(VaultPayload.self, from: data)

        for c in payload.certificates {
            _ = try? CertificateStore.shared.importPair(
                name: c.name,
                p12: c.p12Data,
                password: c.password,
                provision: c.provisionData,
                makeActive: false
            )
        }
        // Accounts: restore passwords into Keychain for matching emails when possible.
        for a in payload.accounts {
            if let pw = a.password, !pw.isEmpty {
                if let existing = AppleIDStore.shared.accounts.first(where: {
                    $0.email.caseInsensitiveCompare(a.email) == .orderedSame
                }) {
                    _ = Keychain.setSecret("tetherless.appleid.password." + existing.id, pw)
                    for u in a.deviceUDIDs { AppleIDStore.shared.addDeviceUDID(u, toAccountID: existing.id) }
                }
            }
        }
        _ = try? BackupManager.shared.createBackup(certificates: CertificateStore.shared.certificates)
    }

    private static func vaultKey() throws -> SymmetricKey {
        let keyName = "tetherless.vault.aes"
        if let existing = Keychain.getSecret(keyName), let raw = Data(base64Encoded: existing), raw.count == 32 {
            return SymmetricKey(data: raw)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        _ = Keychain.setSecret(keyName, data.base64EncodedString())
        return key
    }
}

struct VaultBackupCard: View {
    @State private var status: String?
    @State private var busy = false
    @State private var exportURL: URL?

    var body: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Encrypted vault backup")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Export Store Access passwords + free signing certs to a device-locked vault file. Restore after reinstall.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        busy = true
                        defer { busy = false }
                        do {
                            exportURL = try TetherLessVaultBackup.exportVault()
                            status = "Exported \(exportURL?.lastPathComponent ?? "vault")"
                        } catch {
                            status = error.localizedDescription
                        }
                    } label: {
                        Text(busy ? "Working…" : "Export vault")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(TetherlessPalette.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)

                    Button {
                        _ = try? BackupManager.shared.createBackup(certificates: CertificateStore.shared.certificates)
                        status = "Certificate backup saved"
                        NotificationManager.shared.scheduleBackupReminder()
                    } label: {
                        Text("Certs only")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if let status {
                    Text(status).font(.caption2).foregroundStyle(TetherlessPalette.accent)
                }
                if let exportURL {
                    ShareLink(item: exportURL) {
                        Text("Share vault file")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(TetherlessPalette.accent)
                    }
                }
            }
        }
    }
}
