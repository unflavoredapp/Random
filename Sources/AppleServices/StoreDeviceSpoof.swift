//
//  StoreDeviceSpoof.swift
//  Optional App Store request identity (iOS version / device model) used by
//  AppStoreClient so Apple can serve a compatible IPA variant.
//

import Foundation
import UIKit

/// Which User-Agent shape to send on MZFinance / CDN requests.
enum StoreUserAgentStyle: String, Codable, CaseIterable, Sendable {
    /// Classic itunesstored UA — historically what Apple used for variant selection.
    case itunesstored
    /// Modern App Store / AMS-style UA.
    case appStore
    /// Apple Configurator (macOS) — legacy ipatool default; weak for iOS variant picking.
    case configurator

    var label: String {
        switch self {
        case .itunesstored: return "iTunes Store (best)"
        case .appStore: return "App Store / AMS"
        case .configurator: return "Configurator"
        }
    }
}

/// One-tap spoof profile (iOS + optional build + model).
struct StoreSpoofProfile: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let iosVersion: String
    let build: String
    let deviceModel: String?
    let style: StoreUserAgentStyle

    static func builtIn(realModel: String) -> [StoreSpoofProfile] {
        [
            .init(id: "device", title: "This iPhone", detail: "iOS \(UIDevice.current.systemVersion)",
                  iosVersion: UIDevice.current.systemVersion, build: "", deviceModel: realModel, style: .itunesstored),
            .init(id: "newest", title: "Newest iOS", detail: "Claim iOS 99 — unlock latest packages",
                  iosVersion: "99.0", build: "99A999", deviceModel: "iPhone17,1", style: .itunesstored),
            .init(id: "ios18", title: "iOS 18.2", detail: "Recent iPhone 16 Pro",
                  iosVersion: "18.2", build: "22C152", deviceModel: "iPhone17,1", style: .itunesstored),
            .init(id: "ios17", title: "iOS 17.6", detail: "iPhone 15",
                  iosVersion: "17.6.1", build: "21G93", deviceModel: "iPhone15,4", style: .itunesstored),
            .init(id: "ios16", title: "iOS 16.7", detail: "Older package window",
                  iosVersion: "16.7.10", build: "20H350", deviceModel: "iPhone14,5", style: .itunesstored),
            .init(id: "ios15", title: "iOS 15.8", detail: "Legacy / lower installs",
                  iosVersion: "15.8.3", build: "19H386", deviceModel: "iPhone13,2", style: .itunesstored),
            .init(id: "ios14", title: "iOS 14.8", detail: "Very old IPAs",
                  iosVersion: "14.8.1", build: "18H107", deviceModel: "iPhone12,1", style: .itunesstored),
        ]
    }
}

/// Spoofed device profile for MZFinance / App Store download requests.
struct StoreDeviceSpoof: Codable, Equatable, Sendable {
    var enabled: Bool
    /// e.g. "18.2" — claimed iOS version in the store User-Agent.
    var iosVersion: String
    /// Hardware identifier, e.g. "iPhone16,2".
    var deviceModel: String
    /// Optional build string, e.g. "22C152".
    var build: String
    /// Optional hardware platform token (hwp/…). Empty → derived from model when known.
    var hardwarePlatform: String
    /// UA shape. Default itunesstored for best variant selection.
    var style: StoreUserAgentStyle

    static let defaultsKey = "tetherless.storeDeviceSpoof.v2"
    private static let legacyKey = "tetherless.storeDeviceSpoof"

    static var `default`: StoreDeviceSpoof {
        StoreDeviceSpoof(
            enabled: false,
            iosVersion: UIDevice.current.systemVersion,
            deviceModel: Self.realModelIdentifier(),
            build: "",
            hardwarePlatform: "",
            style: .itunesstored
        )
    }

    static var current: StoreDeviceSpoof {
        get {
            if let data = UserDefaults.standard.data(forKey: defaultsKey),
               let decoded = try? JSONDecoder().decode(StoreDeviceSpoof.self, from: data) {
                return decoded
            }
            // Migrate v1 (no style / hwp).
            if let data = UserDefaults.standard.data(forKey: legacyKey),
               let legacy = try? JSONDecoder().decode(LegacyStoreDeviceSpoof.self, from: data) {
                var migrated = StoreDeviceSpoof.default
                migrated.enabled = legacy.enabled
                migrated.iosVersion = legacy.iosVersion
                migrated.deviceModel = legacy.deviceModel
                migrated.build = legacy.build
                migrated.style = .itunesstored
                Self.current = migrated
                return migrated
            }
            return .default
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
        }
    }

    /// Apply a one-tap profile and turn spoof on (except “This iPhone”, which mirrors device and disables).
    mutating func apply(_ profile: StoreSpoofProfile) {
        iosVersion = profile.iosVersion
        build = profile.build
        if let model = profile.deviceModel, !model.isEmpty {
            deviceModel = model
        }
        style = profile.style
        hardwarePlatform = Self.hardwarePlatform(forModel: deviceModel) ?? hardwarePlatform
        enabled = profile.id != "device"
        if profile.id == "device" {
            iosVersion = UIDevice.current.systemVersion
            deviceModel = Self.realModelIdentifier()
            build = ""
            hardwarePlatform = Self.hardwarePlatform(forModel: deviceModel) ?? ""
        }
    }

    /// Effective iOS version sent to the store (spoofed or real).
    var effectiveIOSVersion: String {
        let v = (enabled ? iosVersion : UIDevice.current.systemVersion)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? UIDevice.current.systemVersion : v
    }

    var effectiveModel: String {
        let m = (enabled ? deviceModel : Self.realModelIdentifier())
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? Self.realModelIdentifier() : m
    }

    var effectiveBuild: String {
        let b = (enabled ? build : "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !b.isEmpty { return b }
        return Self.defaultBuild(forIOS: effectiveIOSVersion) ?? "22A3354"
    }

    var effectiveHardwarePlatform: String {
        let h = (enabled ? hardwarePlatform : "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !h.isEmpty { return h }
        return Self.hardwarePlatform(forModel: effectiveModel) ?? "t8110"
    }

    var effectiveDeviceType: Int {
        // itunesstored “dt” — iPhone family commonly uses values in the 1xx–2xx range;
        // 232 is a modern iPhone token seen with AppStore AMS UAs.
        if effectiveModel.hasPrefix("iPad") { return 83 }
        if effectiveModel.hasPrefix("iPod") { return 7 }
        return 232
    }

    var summaryLabel: String {
        if !enabled {
            return "Off · real iOS \(UIDevice.current.systemVersion)"
        }
        return "iOS \(effectiveIOSVersion) · \(effectiveModel)"
    }

    /// Primary store User-Agent for MZFinance + CDN.
    func storeUserAgent(fallbackConfigurator: String) -> String {
        let ios = effectiveIOSVersion
        let model = effectiveModel
        let build = effectiveBuild
        let hwp = effectiveHardwarePlatform
        let dt = effectiveDeviceType
        switch enabled ? style : StoreUserAgentStyle.itunesstored {
        case .itunesstored:
            return "itunesstored/1.0 iOS/\(ios) model/\(model) hwp/\(hwp) build/\(build) (6; dt:\(dt))"
        case .appStore:
            return "AppStore/3.0 iOS/\(ios) model/\(model) hwp/\(hwp) build/\(build) (6; dt:\(dt)) AMS/1"
        case .configurator:
            return fallbackConfigurator
        }
    }

    /// Extra identity headers AMS / buy.itunes often honor alongside UA.
    func storeIdentityHeaders() -> [String: String] {
        var headers: [String: String] = [
            "X-Apple-I-Device-Type": effectiveModel.hasPrefix("iPad") ? "2" : "1",
            "X-Apple-Client-Application": "Software",
            "X-Apple-I-Requested-Model": effectiveModel,
            "X-Apple-I-OS-Version": effectiveIOSVersion,
            "X-Apple-Software-Version": effectiveBuild,
            "X-Apple-I-Software-Build": effectiveBuild,
        ]
        if enabled {
            headers["X-Apple-I-Client-Application"] = "com.apple.AppStore"
            headers["X-Apple-Client-Versions"] = "iOS/\(effectiveIOSVersion)"
        }
        return headers
    }

    static let modelPresets: [(label: String, model: String)] = [
        ("This iPhone", realModelIdentifier()),
        ("iPhone 16 Pro", "iPhone17,1"),
        ("iPhone 16", "iPhone17,3"),
        ("iPhone 15 Pro", "iPhone16,1"),
        ("iPhone 15", "iPhone15,4"),
        ("iPhone 14 Pro", "iPhone15,2"),
        ("iPhone 14", "iPhone14,7"),
        ("iPhone 13", "iPhone14,5"),
        ("iPhone 12", "iPhone13,2"),
        ("iPhone 11", "iPhone12,1"),
        ("iPhone XS", "iPhone11,2"),
        ("iPhone X", "iPhone10,3"),
        ("iPhone 8", "iPhone10,1"),
        ("iPad Pro 11\"", "iPad14,3"),
    ]

    static let iosVersionPresets: [String] = [
        "99.0", "18.4", "18.2", "18.0", "17.6.1", "17.0", "16.7.10", "16.0", "15.8.3", "15.0", "14.8.1", "14.0"
    ]

    static func realModelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let id = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return id.isEmpty ? "iPhone" : id
    }

    /// Known hwp tokens for common models (best-effort).
    static func hardwarePlatform(forModel model: String) -> String? {
        let map: [String: String] = [
            "iPhone17,1": "t8130", "iPhone17,2": "t8130", "iPhone17,3": "t8130", "iPhone17,4": "t8130",
            "iPhone16,1": "t8120", "iPhone16,2": "t8120",
            "iPhone15,2": "t8120", "iPhone15,3": "t8120", "iPhone15,4": "t8110", "iPhone15,5": "t8110",
            "iPhone14,2": "t8110", "iPhone14,3": "t8110", "iPhone14,4": "t8110", "iPhone14,5": "t8110",
            "iPhone14,7": "t8110", "iPhone14,8": "t8110",
            "iPhone13,1": "t8101", "iPhone13,2": "t8101", "iPhone13,3": "t8101", "iPhone13,4": "t8101",
            "iPhone12,1": "t8030", "iPhone12,3": "t8030", "iPhone12,5": "t8030",
            "iPhone11,2": "t8020", "iPhone11,4": "t8020", "iPhone11,6": "t8020", "iPhone11,8": "t8020",
            "iPhone10,1": "t8015", "iPhone10,2": "t8015", "iPhone10,3": "t8015", "iPhone10,4": "t8015",
            "iPhone10,5": "t8015", "iPhone10,6": "t8015",
        ]
        return map[model]
    }

    /// Plausible build when the user leaves Build blank.
    static func defaultBuild(forIOS ios: String) -> String? {
        let v = ios.trimmingCharacters(in: .whitespacesAndNewlines)
        let known: [(prefix: String, build: String)] = [
            ("99.", "99A999"),
            ("18.4", "22E240"),
            ("18.3", "22D63"),
            ("18.2", "22C152"),
            ("18.1", "22B83"),
            ("18.0", "22A3354"),
            ("17.6", "21G93"),
            ("17.5", "21F79"),
            ("17.4", "21E219"),
            ("17.0", "21A329"),
            ("16.7", "20H350"),
            ("16.6", "20G75"),
            ("16.0", "20A362"),
            ("15.8", "19H386"),
            ("15.7", "19H12"),
            ("15.0", "19A346"),
            ("14.8", "18H107"),
            ("14.0", "18A373"),
        ]
        for row in known where v.hasPrefix(row.prefix) || v == row.prefix.trimmingCharacters(in: CharacterSet(charactersIn: ".")) {
            return row.build
        }
        if v.hasPrefix("18") { return "22C152" }
        if v.hasPrefix("17") { return "21G93" }
        if v.hasPrefix("16") { return "20H350" }
        if v.hasPrefix("15") { return "19H386" }
        if v.hasPrefix("14") { return "18H107" }
        return nil
    }
}

/// v1 persistence shape (pre style/hwp).
private struct LegacyStoreDeviceSpoof: Codable {
    var enabled: Bool
    var iosVersion: String
    var deviceModel: String
    var build: String
}
