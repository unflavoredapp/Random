//
//  OTAInstaller.swift
//  Serves a locally-signed IPA over the on-device Vapor HTTPS server and hands
//  iOS the itms-services URL directly. That URL is handled entirely by the
//  system — it shows Apple's own native "<host> would like to install <app>"
//  alert right on top of AirShare, with no app-switch and no Safari UI ever
//  visible, as long as the TLS/DNS preconditions below are actually met.
//  Keeps the server alive under a background task for the ~90s installd needs.
//
//  Cert source follows ServerConfig.certMode:
//    "public" → the ACME (airshare.lol-style) cert, refreshed from the certs repo.
//    "local"  → our own root CA's leaf (LocalCAManager) — no network needed,
//               covers whatever host it was last issued for.
//  The "does this cert actually cover this host" check reads whichever cert
//  is active for the current mode, so a public-cert host mismatch never gets
//  reported while you're on Local, and vice versa.
//

import Foundation
import UIKit
import ZIPFoundation

@MainActor
final class OTAInstaller: ObservableObject {
    static let shared = OTAInstaller()
    private init() {}

    private var current: LocalOTAServer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    /// Result of the last install attempt, filled ~25s after the sheet opens.
    struct Report: Identifiable, Sendable {
        let id = UUID()
        let requests: [OTATrace.Entry]
        let diagnosis: String
        let profileNote: String?
        var delivered: Bool { requests.contains { $0.path.hasSuffix(".ipa") } }
    }
    @Published var lastReport: Report?
    @Published var tracing = false

    enum InstallError: LocalizedError {
        case ipaMissing, openFailed
        case hostNotCovered(host: String, mode: String, sans: [String])
        case noLocalLeaf(host: String)
        case hostNotLoopback(host: String)
        case rootNotTrusted
        case trollStoreNotInstalled

        var errorDescription: String? {
            switch self {
            case .trollStoreNotInstalled:
                return "TrollStore isn't installed on this device (or it's hidden under a disguised icon iOS doesn't recognize by its usual name)."
            case .rootNotTrusted:
                return "Your local root CA isn't trusted on this device yet, so Safari would reject the install silently. Settings › AirShare › Local CA: Install trust profile, then enable it in Settings › General › About › Certificate Trust Settings."
            case .hostNotCovered(let h, let mode, let sans):
                let covering = sans.isEmpty ? "nothing readable" : sans.joined(separator: ", ")
                if mode == "local" {
                    return "Your local leaf covers \(covering) — not \(h). Settings › Local CA: set host to \(h) and Re-issue leaf (instant, no profile needed again)."
                }
                return "The loaded ACME cert covers \(covering) — not \(h). Set the AirShare domain to match, or renew a cert for it in Settings › AirShare Domain. Or switch Cert mode to Fully local."
            case .noLocalLeaf(let h):
                return "Cert mode is Fully local but no leaf has been issued yet. Settings › Local CA: create the CA and issue a leaf for \(h)."
            case .hostNotLoopback(let h):
                return "\(h) doesn't resolve to 127.0.0.1, so iOS silently drops the install prompt — there's no error dialog for this, it just never appears. Point a DNS A record for \(h) at 127.0.0.1, or use a free loopback name (e.g. 127-0-0-1.nip.io). Check it in Settings › Local CA / AirShare Domain."
            case .ipaMissing: return "Signed IPA not found on disk."
            case .openFailed:
                return "iOS refused the itms-services URL. Check the AirShare host resolves to 127.0.0.1 and matches the active cert (see Settings › AirShare Domain — Active cert)."
            }
        }
    }

    func install(_ app: SignedEntry) async throws {
        let icon = app.iconURL.flatMap { try? Data(contentsOf: $0) }
        try await install(ipaURL: app.ipaURL, bundleID: app.bundleID, name: app.name, version: app.version, iconData: icon)
    }

    /// Every TLS/DNS precondition an on-device HTTPS fetch (manifest+IPA for a
    /// normal OTA install, or just the IPA for a TrollStore handoff) depends on.
    /// Shared by both install paths so they fail with the same explainable
    /// errors instead of silently hanging — iOS reports neither the loopback-DNS
    /// nor the host-not-covered case as an error of its own, it just never shows
    /// a prompt (or, for TrollStore, the fetch just times out).
    private func validateServerPreconditions() async throws {
        let host = ServerConfig.installHost
        let mode = ServerConfig.certMode

        if let loop = await ZefvCert.resolvesToLoopback(host), loop == false {
            throw InstallError.hostNotLoopback(host: host)
        }

        if mode == "local" {
            guard LocalCAManager.hasLeaf else { throw InstallError.noLocalLeaf(host: host) }
            guard LocalCAManager.isRootTrusted() else { throw InstallError.rootNotTrusted }
            // Auto-reissue when within 30 days of the 397-day cap (iOS TLS limit).
            if LocalCAManager.reissueIfNeeded() { /* fresh leaf issued */ }
            guard LocalCAManager.covers(host) else {
                throw InstallError.hostNotCovered(host: host, mode: mode, sans: LocalCAManager.leafSANs())
            }
        } else if mode == "custom" {
            guard ZefvCert.hasCustom else { throw ZefvCert.CertError.badPack("No custom cert imported yet — Settings › AirShare Domain › Own TLS cert.") }
            let sans = ZefvCert.customSANs
            guard ZefvCert.covers(host, sans: sans) else {
                throw InstallError.hostNotCovered(host: host, mode: mode, sans: sans)
            }
        } else {
            // Near expiry: pull the freshly renewed pair from the VPS (no-op offline; cached/bundled pair still works).
            if ZefvCert.needsRefresh { await ZefvCert.refreshIfNeeded() }
            guard ZefvCert.isAvailable else { throw ZefvCert.CertError.unavailable }
            let sans = ZefvCert.effectiveSANs
            guard ZefvCert.covers(host, sans: sans) else {
                throw InstallError.hostNotCovered(host: host, mode: mode, sans: sans)
            }
        }
    }

    func install(ipaURL: URL, bundleID: String, name: String, version: String, iconData: Data?) async throws {
        guard FileManager.default.fileExists(atPath: ipaURL.path) else { throw InstallError.ipaMissing }

        // Settings › Install Method › Native: install straight over the built-in
        // local VPN + device pairing, skipping the itms-services/OTA path.
        if NativeInstaller.isSelected {
            try await NativeInstaller.shared.install(ipaURL: ipaURL, bundleID: bundleID, name: name, version: version)
            return
        }
        try await validateServerPreconditions()

        let icon57  = Self.squarePNG(iconData, side: 57)
        let icon512 = Self.squarePNG(iconData, side: 512)

        tearDown()
        let server = try LocalOTAServer(package: ipaURL,
                                        metadata: InstallAppData(id: bundleID, version: version, name: name),
                                        imageSmall: icon57, imageLarge: icon512)
        current = server

        bgTask = UIApplication.shared.beginBackgroundTask(withName: "ota-install") { [weak self] in
            self?.tearDown()
        }

        lastReport = nil; tracing = true
        // Straight to itms-services — this is what actually produces Apple's own
        // native install alert directly over AirShare (no Safari, no app-switch),
        // same as every other sideloading tool on iOS. The earlier "route it
        // through Safari first" detour traded that native alert for a full
        // Safari takeover, which isn't what should happen on a device where the
        // preconditions above are actually satisfied — so back to the direct
        // open. When the prompt doesn't appear, it's almost always one of the
        // explainable failures validateServerPreconditions() already guards
        // against (TLS/host mismatch, DNS not pointing at loopback, untrusted
        // local root), not something a different launch mechanism fixes.
        let opened = await UIApplication.shared.open(server.itmsServicesURL)
        guard opened else { tearDown(); tracing = false; throw InstallError.openFailed }
        ZefvVPS.report(bundle: bundleID, version: version, name: name, stage: "prompted")

        let ipaSize = (try? FileManager.default.attributesOfItem(atPath: ipaURL.path)[.size] as? Int64) ?? 0
        let activeCertName = CertificateStore.shared.active?.name
        let profileNote = Self.profileNote(ipaURL: ipaURL, certName: activeCertName)

        // Give installd time to fetch manifest + IPA, then report what it did.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 25 * 1_000_000_000)
            guard let self else { return }
            let t = OTATrace.shared
            self.lastReport = Report(requests: t.all, diagnosis: t.diagnosis(ipaSize: ipaSize), profileNote: profileNote)
            self.tracing = false
            if t.ipaFetched { ZefvVPS.report(bundle: bundleID, version: version, name: name, stage: "installed") }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
            if let self, self.current === server { self.tearDown() }
        }
    }

    // MARK: - TrollStore handoff

    /// Whether TrollStore is actually installed on this device, detected via its
    /// own documented inter-app install scheme (`apple-magnifier://`). TrollStore
    /// keeps this scheme registered under every one of its disguised icons/names,
    /// so this works regardless of what it's hidden as. Requires the scheme to be
    /// declared in LSApplicationQueriesSchemes (Info.plist) or -canOpenURL: always
    /// reports false.
    static var trollStoreAvailable: Bool {
        guard let url = URL(string: "apple-magnifier://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    func installWithTrollStore(_ app: SignedEntry) async throws {
        try await installWithTrollStore(ipaURL: app.ipaURL, bundleID: app.bundleID, name: app.name, version: app.version)
    }

    /// Skips itms-services and the manifest entirely — TrollStore wants only a
    /// direct, reachable URL to the raw .ipa (same on-device HTTPS server, same
    /// `/ota/<id>/app.ipa` route a normal install already serves) and re-signs
    /// and installs it itself via its own CoreTrust-bypass persistence, so none
    /// of this device's own signing/provisioning limits (UDID list, 3-app cap,
    /// 7-day free-account expiry) apply to an app installed this way.
    func installWithTrollStore(ipaURL: URL, bundleID: String, name: String, version: String) async throws {
        guard FileManager.default.fileExists(atPath: ipaURL.path) else { throw InstallError.ipaMissing }
        guard Self.trollStoreAvailable else { throw InstallError.trollStoreNotInstalled }
        try await validateServerPreconditions()

        tearDown()
        let server = try LocalOTAServer(package: ipaURL,
                                        metadata: InstallAppData(id: bundleID, version: version, name: name),
                                        imageSmall: Data(), imageLarge: Data())
        current = server

        bgTask = UIApplication.shared.beginBackgroundTask(withName: "trollstore-install") { [weak self] in
            self?.tearDown()
        }

        let ipaURLString = "https://\(LocalOTAServer.host()):\(LocalZSignAPI.shared.port)/ota/\(server.id.uuidString)/app.ipa"
        guard var comps = URLComponents(string: "apple-magnifier://install") else { tearDown(); throw InstallError.openFailed }
        comps.queryItems = [URLQueryItem(name: "url", value: ipaURLString)]
        guard let trollURL = comps.url else { tearDown(); throw InstallError.openFailed }

        let opened = await UIApplication.shared.open(trollURL)
        guard opened else { tearDown(); throw InstallError.openFailed }
        ZefvVPS.report(bundle: bundleID, version: version, name: name, stage: "prompted")

        // TrollStore takes over entirely from here — it downloads the IPA itself
        // and installs it with no system "Install" prompt and nothing more for
        // this app to poll for, so there's no 25s diagnosis report to build (that
        // report is built from itms-services/installd traffic, which TrollStore
        // never generates). Just keep the IPA reachable long enough for it to fetch.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90 * 1_000_000_000)
            if let self, self.current === server { self.tearDown() }
        }
    }

    /// Reads embedded.mobileprovision out of the signed IPA and reports the facts
    /// that most often cause "Unable to Install": device count, expiry, team, entitlements.
    private static func profileNote(ipaURL: URL, certName: String?) -> String? {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("prof-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            try fm.unzipItem(at: ipaURL, to: work)
            let payload = work.appendingPathComponent("Payload", isDirectory: true)
            guard let app = try fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }) else { return nil }
            let prov = app.appendingPathComponent("embedded.mobileprovision")
            guard let data = try? Data(contentsOf: prov) else { return "No embedded.mobileprovision in the signed app — installd will refuse it." }
            let info = CertificateStore.profileInfo(data)
            var parts: [String] = []
            if let n = info.name { parts.append("Profile: \(n)") }
            if let t = info.team { parts.append("Team: \(t)") }
            if let e = info.expires {
                let d = Calendar.current.dateComponents([.day], from: Date(), to: e).day ?? 0
                parts.append(d < 0 ? "⚠️ Profile EXPIRED \(-d)d ago" : "Profile expires in \(d)d")
            }
            if info.udids.isEmpty {
                parts.append("Profile has no device list → Enterprise/in-house (any device OK, needs 'trust developer' in Settings) — or a broken profile.")
            } else {
                let udid = CertificateStore.knownUDID(certName: certName)
                switch CertificateStore.profileIncludesDevice(info, udid: udid) {
                case .some(true):  parts.append("✅ This device (\(udid!)) IS in the profile's \(info.udids.count) device(s). UDID is not the problem.")
                case .some(false): parts.append("❌ This device (\(udid!)) is NOT in the profile's \(info.udids.count) device(s) — that's the install failure. Regenerate the profile with this UDID on the developer portal and re-import it.")
                case .none:        parts.append("Profile lists \(info.udids.count) device(s). Enter your UDID in Settings › Certificates to check it definitively.")
                }
            }
            let bundleID = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))?["CFBundleIdentifier"] as? String ?? "?"
            parts.append("Signed bundle ID: \(bundleID). If any app with this ID is already installed from a different team, delete it first.")
            return parts.joined(separator: "\n")
        } catch { return nil }
    }

    private func tearDown() {
        current?.shutdown(); current = nil
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    /// Square PNG for the manifest (installd wants valid PNGs); dark tile if no icon.
    private static func squarePNG(_ data: Data?, side: CGFloat) -> Data {
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if let data, let img = UIImage(data: data) { img.draw(in: CGRect(origin: .zero, size: size)) }
        }.pngData() ?? Data()
    }
}
