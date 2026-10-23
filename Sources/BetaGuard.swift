//
//  BetaGuard.swift
//  Closed-beta builds of AirShare only. Every beta build asks the server whether this device's ADID still has beta
//  access. If the account was banned or taken out of the beta group, the build locks itself and removes itself from
//  the device through the same on-device installer the Library uses. Release builds never run any of this.
//
//  Marking a build as beta (any one is enough):
//    • compile it with the BETA Swift flag (Build Settings > Active Compilation Conditions), or
//    • add the Info.plist key AirShareBetaBuild = YES, or
//    • give it a bundle id that contains "beta".
//
//  Safety rules: only this app's own build is ever removed. An unreachable server or an unknown ADID never counts as
//  revoked, so a bad connection can't lock anyone out.
//

import SwiftUI

@MainActor
final class BetaGuard: ObservableObject {
    static let shared = BetaGuard()

    nonisolated static var isBetaBuild: Bool {
        #if BETA
        return true
        #else
        if (Bundle.main.object(forInfoDictionaryKey: "AirShareBetaBuild") as? Bool) == true { return true }
        return (Bundle.main.bundleIdentifier ?? "").lowercased().contains("beta")
        #endif
    }

    @Published private(set) var revoked: Bool
    @Published private(set) var reason = ""
    @Published private(set) var removing = false
    @Published private(set) var removeError: String?

    private static let revokedKey = "AirShare.beta.revoked"
    private var lastCheck = Date.distantPast
    private var checking = false

    private init() { revoked = Self.isBetaBuild && UserDefaults.standard.bool(forKey: Self.revokedKey) }

    /// Asks the server; at most every 10 minutes unless `force`. Locked builds retry the removal each time.
    func check(force: Bool = false) async {
        guard Self.isBetaBuild, !checking else { return }
        if revoked { await removeSelf(); if !force { return } }
        guard force || Date().timeIntervalSince(lastCheck) > 600 else { return }
        checking = true; defer { checking = false }
        guard var c = URLComponents(string: ZefvAccount.apiBase + "beta/status") else { return }
        c.queryItems = [URLQueryItem(name: "adid", value: MDID.current)]
        guard let url = c.url else { return }
        var req = URLRequest(url: url); req.timeoutInterval = 15; req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = o["status"] as? String else { return }   // offline or odd answer: do nothing
        lastCheck = Date()
        switch status {
        case "revoked":
            reason = (o["reason"] as? String) ?? ""
            UserDefaults.standard.set(true, forKey: Self.revokedKey)
            revoked = true
            await removeSelf()
        case "ok":
            UserDefaults.standard.set(false, forKey: Self.revokedKey)
            revoked = false; removeError = nil
        default: break   // "unknown": no account owns this ADID, nothing to enforce
        }
    }

    /// Uninstalls this build (and its data) through the on-device installer.
    func removeSelf() async {
        guard Self.isBetaBuild, revoked, !removing, let id = Bundle.main.bundleIdentifier else { return }
        removing = true; removeError = nil
        defer { removing = false }
        let m = DeviceInstallationManager.shared
        do { try await m.uninstall(bundleIdentifier: id, mode: m.mode, allowSelf: true) }
        catch is CancellationError {}
        catch { removeError = error.localizedDescription }
    }
}

/// Full-screen lock shown while a revoked beta build is still on the device.
struct BetaRevokedOverlay: View {
    @ObservedObject var guardState = BetaGuard.shared

    var body: some View {
        if guardState.revoked {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(Theme.accent)
                    Text(guardState.reason == "banned" ? "Account banned" : "Beta access ended")
                        .font(.system(size: 22, weight: .bold)).foregroundStyle(Theme.text)
                    Text("This beta build is no longer available to this device, and it is being removed.")
                        .font(.system(size: 15)).foregroundStyle(Theme.subtle).multilineTextAlignment(.center)
                    if guardState.removing { ProgressView().tint(Theme.accent) }
                    if let e = guardState.removeError {
                        Text("Couldn't remove it automatically: \(e)\nDelete AirShare from the Home Screen to finish.")
                            .font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
                        Button("Try again") { Task { await BetaGuard.shared.removeSelf() } }
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                }
                .padding(32)
            }
            .transition(.opacity)
        }
    }
}
