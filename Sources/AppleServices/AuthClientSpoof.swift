//
//  AuthClientSpoof.swift
//  GrandSlam / HSA2 AuthKit identity: claim a MacBook or iPhone + OS so Apple’s
//  Allow (map) + verification-code sheets target this phone (or another device).
//

import Foundation

/// Family of AuthKit `X-MMe-Client-Info` identities used for GSA 2FA.
enum AuthClientKind: String, Codable, CaseIterable, Sendable {
    case mac
    case iPhone

    var label: String {
        switch self {
        case .mac: return "MacBook"
        case .iPhone: return "iPhone"
        }
    }
}

/// One-tap AuthKit identity for trusted-device push / code sheets.
struct AuthClientProfile: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let kind: AuthClientKind
    /// Hardware id, e.g. MacBookPro18,3 or iPhone17,1.
    let model: String
    /// OS marketing version, e.g. 14.3 or 18.2.
    let osVersion: String
    /// Build, e.g. 23D56 or 22C152.
    let build: String
    /// Xcode / Settings app version embedded in Client-Info.
    let appVersion: String
    let userAgent: String

    var clientInfo: String {
        switch kind {
        case .mac:
            // Coherent Mac + macOS + Xcode — incoherent pairs make Apple skip HSA2 UI.
            return "<\(model)> <macOS;\(osVersion);\(build)> <com.apple.AuthKit/1 (com.apple.dt.Xcode/\(appVersion))>"
        case .iPhone:
            return "<\(model)> <iPhone OS;\(osVersion);\(build)> <com.apple.AuthKit/1 (com.apple.Preferences/\(appVersion))>"
        }
    }

    static let builtIn: [AuthClientProfile] = [
        // Default: proven MacBook Pro shape that overlays Allow + code on this iPhone.
        .init(
            id: "mbp16-m2-sonoma",
            title: "MacBook Pro 16\" M2",
            detail: "macOS 14.3 · Xcode 15.3",
            kind: .mac,
            model: "MacBookPro18,3",
            osVersion: "14.3",
            build: "23D56",
            appVersion: "15.3.0",
            userAgent: "Xcode"
        ),
        .init(
            id: "mbp14-m3-sonoma",
            title: "MacBook Pro 14\" M3",
            detail: "macOS 14.5 · Xcode 15.4",
            kind: .mac,
            model: "Mac15,7",
            osVersion: "14.5",
            build: "23F79",
            appVersion: "15.4.0",
            userAgent: "Xcode"
        ),
        .init(
            id: "mbp16-m3-sequoia",
            title: "MacBook Pro 16\" M3",
            detail: "macOS 15.2 · Xcode 16.2",
            kind: .mac,
            model: "Mac15,9",
            osVersion: "15.2",
            build: "24C101",
            appVersion: "16.2.0",
            userAgent: "Xcode"
        ),
        .init(
            id: "mba-m2-sonoma",
            title: "MacBook Air M2",
            detail: "macOS 14.4 · Xcode 15.3",
            kind: .mac,
            model: "Mac14,2",
            osVersion: "14.4",
            build: "23E214",
            appVersion: "15.3.0",
            userAgent: "Xcode"
        ),
        .init(
            id: "mbp16-intel-ventura",
            title: "MacBook Pro 16\" Intel",
            detail: "macOS 13.6 · Xcode 15.0",
            kind: .mac,
            model: "MacBookPro16,1",
            osVersion: "13.6.3",
            build: "22G436",
            appVersion: "15.0.0",
            userAgent: "Xcode"
        ),
        .init(
            id: "iphone16pro-18",
            title: "iPhone 16 Pro",
            detail: "iOS 18.2 · Settings",
            kind: .iPhone,
            model: "iPhone17,1",
            osVersion: "18.2",
            build: "22C152",
            appVersion: "1.0",
            userAgent: "Settings"
        ),
        .init(
            id: "iphone15pro-17",
            title: "iPhone 15 Pro",
            detail: "iOS 17.6 · Settings",
            kind: .iPhone,
            model: "iPhone16,1",
            osVersion: "17.6.1",
            build: "21G93",
            appVersion: "1.0",
            userAgent: "Settings"
        ),
        .init(
            id: "iphone14-16",
            title: "iPhone 14",
            detail: "iOS 16.7 · Settings",
            kind: .iPhone,
            model: "iPhone14,7",
            osVersion: "16.7.10",
            build: "20H350",
            appVersion: "1.0",
            userAgent: "Settings"
        ),
        .init(
            id: "iphone13-15",
            title: "iPhone 13",
            detail: "iOS 15.8 · Settings",
            kind: .iPhone,
            model: "iPhone14,5",
            osVersion: "15.8.3",
            build: "19H386",
            appVersion: "1.0",
            userAgent: "Settings"
        ),
    ]
}

/// Persisted AuthKit identity for GrandSlam trusted-device / 2FA requests.
struct AuthClientSpoof: Equatable, Codable, Sendable {
    /// Profile id from `AuthClientProfile.builtIn`, or `custom`.
    var profileID: String
    var kind: AuthClientKind
    var model: String
    var osVersion: String
    var build: String
    var appVersion: String
    var userAgent: String

    static let defaultsKey = "tetherless.authClientSpoof.v1"

    static var `default`: AuthClientSpoof {
        let p = AuthClientProfile.builtIn[0]
        return AuthClientSpoof(
            profileID: p.id,
            kind: p.kind,
            model: p.model,
            osVersion: p.osVersion,
            build: p.build,
            appVersion: p.appVersion,
            userAgent: p.userAgent
        )
    }

    static var current: AuthClientSpoof {
        get {
            if let data = UserDefaults.standard.data(forKey: defaultsKey),
               let decoded = try? JSONDecoder().decode(AuthClientSpoof.self, from: data) {
                return decoded.sanitized
            }
            return .default
        }
        set {
            let value = newValue.sanitized
            if let data = try? JSONEncoder().encode(value) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
        }
    }

    mutating func apply(_ profile: AuthClientProfile) {
        profileID = profile.id
        kind = profile.kind
        model = profile.model
        osVersion = profile.osVersion
        build = profile.build
        appVersion = profile.appVersion
        userAgent = profile.userAgent
    }

    var clientInfo: String {
        switch kind {
        case .mac:
            return "<\(model)> <macOS;\(osVersion);\(build)> <com.apple.AuthKit/1 (com.apple.dt.Xcode/\(appVersion))>"
        case .iPhone:
            return "<\(model)> <iPhone OS;\(osVersion);\(build)> <com.apple.AuthKit/1 (com.apple.Preferences/\(appVersion))>"
        }
    }

    var summaryLabel: String {
        switch kind {
        case .mac:
            return "\(displayName) · macOS \(osVersion)"
        case .iPhone:
            return "\(displayName) · iOS \(osVersion)"
        }
    }

    /// Short name for UI / 2FA help copy (“Allow · MacBook Pro near …”).
    var displayName: String {
        if let match = AuthClientProfile.builtIn.first(where: { $0.id == profileID }) {
            return match.title
        }
        switch kind {
        case .mac:
            if model.hasPrefix("MacBookPro") || model.hasPrefix("Mac1") || model.hasPrefix("Mac15") {
                return "MacBook Pro"
            }
            if model.hasPrefix("MacBookAir") || model.hasPrefix("Mac14,2") {
                return "MacBook Air"
            }
            return model
        case .iPhone:
            return model
        }
    }

    /// Fallback profiles to try when the selected identity gets 403/500 on trusteddevice.
    var fallbackClientInfos: [(clientInfo: String, userAgent: String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        let primary = (clientInfo, userAgent)
        seen.insert(primary.0)
        out.append(primary)
        for profile in AuthClientProfile.builtIn where profile.kind == .mac {
            let info = profile.clientInfo
            guard !seen.contains(info) else { continue }
            seen.insert(info)
            out.append((info, profile.userAgent))
            if out.count >= 4 { break }
        }
        return out
    }

    private var sanitized: AuthClientSpoof {
        var copy = self
        copy.model = copy.model.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.osVersion = copy.osVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.build = copy.build.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.appVersion = copy.appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.userAgent = copy.userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.model.isEmpty || copy.osVersion.isEmpty || copy.build.isEmpty {
            return .default
        }
        if copy.appVersion.isEmpty {
            copy.appVersion = copy.kind == .mac ? "15.3.0" : "1.0"
        }
        if copy.userAgent.isEmpty {
            copy.userAgent = copy.kind == .mac ? "Xcode" : "Settings"
        }
        return copy
    }
}
