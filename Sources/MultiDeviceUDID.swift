//
//  MultiDeviceUDID.swift
//  Register this iPhone + a spare UDID under the free Apple ID without digging the portal.
//

import SwiftUI

struct MultiDeviceUDIDCard: View {
    @ObservedObject private var store = AppleIDStore.shared
    @State private var spareUDID = ""
    @State private var status: String?
    @State private var busy = false

    private var known: String {
        CertificateStore.knownUDID()
            ?? (try? DevicePairingStore.load())?.device_udid
            ?? ""
    }

    private var listed: [String] {
        store.activeAccount?.deviceUDIDs ?? []
    }

    var body: some View {
        GlassCard(corner: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Devices on this Apple ID")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("Register this iPhone and a spare UDID for free 7-day profiles — no Developer Portal digging.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)

                if !known.isEmpty {
                    Text("This iPhone: \(known)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.7))
                        .textSelection(.enabled)
                }

                ForEach(listed, id: \.self) { u in
                    Text(u)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.45))
                }

                TextField("Spare UDID (optional)", text: $spareUDID)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.caption.monospaced())
                    .padding(10)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)

                Button {
                    Task { await register() }
                } label: {
                    if busy { ProgressView().tint(.white) }
                    else {
                        Text("Register device(s)")
                            .font(.footnote.weight(.semibold))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(TetherlessPalette.accent, in: Capsule())
                .buttonStyle(.plain)
                .disabled(busy || store.activeAccount == nil)

                if let status {
                    Text(status).font(.caption2).foregroundStyle(TetherlessPalette.accent)
                }
            }
        }
    }

    private func register() async {
        busy = true
        defer { busy = false }
        do {
            var auth = store.portalSession()
            if auth == nil {
                auth = try await store.refreshPortalSession()
            }
            guard let auth else {
                status = "Sign in under Store Access first."
                return
            }
            let teams = try await DeveloperPortalClient.shared.listTeams(auth: auth)
            guard let team = teams.first else {
                status = "No developer team."
                return
            }
            var registered = 0
            if !known.isEmpty {
                CertificateStore.setKnownUDID(known)
                store.addDeviceUDID(known)
                do {
                    _ = try await DeveloperPortalClient.shared.addDevice(
                        udid: known, name: UIDevice.current.name, auth: auth, team: team
                    )
                    registered += 1
                } catch let e as AppleAuthError {
                    if case .portal(35, _) = e { registered += 1 }
                    else { throw e }
                }
            }
            let spare = spareUDID.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !spare.isEmpty {
                store.addDeviceUDID(spare)
                do {
                    _ = try await DeveloperPortalClient.shared.addDevice(
                        udid: spare, name: "Spare", auth: auth, team: team
                    )
                    registered += 1
                } catch let e as AppleAuthError {
                    if case .portal(35, _) = e { registered += 1 }
                    else { throw e }
                }
            }
            status = registered > 0 ? "Registered \(registered) device(s) on the free team." : "Nothing to register — set UDID or Pair first."
            spareUDID = ""
        } catch {
            status = error.localizedDescription
        }
    }
}
