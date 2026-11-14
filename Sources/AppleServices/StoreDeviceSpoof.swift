//
//  StoreDeviceSpoof.swift
//  Optional App Store request identity (iOS version / device model) used by
//  AppStoreClient so Apple can serve a compatible IPA variant.
//

import Foundation
import UIKit

/// Which User-Agent shape to send on MZFinance / CDN requests.
enum StoreUserAgentStyle: String, Codable, CaseIterable, Sendable {
    /// Configurator base + `iOS/… hwp/…` — proven by ipatool-py for variant selection.
    case configuratorIOS
    /// Classic itunesstored UA.
    case itunesstored
    /// Modern App Store / AMS-style UA.
    case appStore
    /// Plain Apple Configurator (macOS only) — weakest for iOS package picking.
    case configurator

    var label: String {
        switch self {
        case .configuratorIOS: return "Configurator + iOS (recommended)"
        case .itunesstored: return "iTunes Store"
        case .appStore: return "App Store / AMS"
        case .configurator: return "Configurator only"
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
        let style = StoreUserAgentStyle.configuratorIOS
        return [
            .init(id: "device", title: "This iPhone", detail: "iOS \(UIDevice.current.systemVersion)",
                  iosVersion: UIDevice.current.systemVersion, build: "", deviceModel: realModel, style: style),
            .init(id: "newest", title: "Newest iOS", detail: "Claim iOS 99 — unlock latest packages",
                  iosVersion: "99.0", build: "99A999", deviceModel: "iPhone17,1", style: style),
            .init(id: "ios18", title: "iOS 18.2", detail: "Recent iPhone 16 Pro",
                  iosVersion: "18.2", build: "22C152", deviceModel: "iPhone17,1", style: style),
            .init(id: "ios17", title: "iOS 17.6", detail: "iPhone 15",
                  iosVersion: "17.6.1", build: "21G93", deviceModel: "iPhone15,4", style: style),
            .init(id: "ios16", title: "iOS 16.7", detail: "Older package window",
                  iosVersion: "16.7.10", build: "20H350", deviceModel: "iPhone14,5", style: style),
            .init(id: "ios15", title: "iOS 15.8", detail: "Legacy / lower installs",
                  iosVersion: "15.8.3", build: "19H386", deviceModel: "iPhone13,2", style: style),
            .init(id: "ios14", title: "iOS 14.8", detail: "Very old IPAs",
                  iosVersion: "14.8.1", build: "18H107", deviceModel: "iPhone12,1", style: style),
        ]
    }
}

/// Spoofed device profile for MZFinance / App Store download requests.
struct StoreDeviceSpoof: Equatable, Sendable {
    var enabled: Bool
    /// e.g. "18.2" — claimed iOS version in the store User-Agent.
    var iosVersion: String
    /// Hardware identifier, e.g. "iPhone16,2".
    var deviceModel: String
    /// Optional build string, e.g. "22C152".
    var build: String
    /// Optional hardware platform token (hwp/…). Empty → derived from model when known.
    var hardwarePlatform: String
    /// UA shape. Default configuratorIOS when spoofing.
    var style: StoreUserAgentStyle
    /// When true (default), unpinned downloads auto-select an externalVersionId
    /// whose min iOS fits the claimed OS.
    var autoSelectCompatibleVersion: Bool

    static let defaultsKey = "tetherless.storeDeviceSpoof.v3"
    private static let legacyKeys = ["tetherless.storeDeviceSpoof.v2", "tetherless.storeDeviceSpoof"]

    static var `default`: StoreDeviceSpoof {
        StoreDeviceSpoof(
            enabled: false,
            iosVersion: UIDevice.current.systemVersion,
            deviceModel: Self.realModelIdentifier(),
            build: "",
            hardwarePlatform: "",
            style: .configuratorIOS,
            autoSelectCompatibleVersion: true
        )
    }

    static var current: StoreDeviceSpoof {
        get {
            if let data = UserDefaults.standard.data(forKey: defaultsKey),
               let decoded = try? JSONDecoder().decode(StoreDeviceSpoof.self, from: data) {
                return decoded
            }
            for key in legacyKeys {
                guard let data = UserDefaults.standard.data(forKey: key) else { continue }
                if let v2 = try? JSONDecoder().decode(LegacyV2.self, from: data) {
                    var m = StoreDeviceSpoof.default
                    m.enabled = v2.enabled
                    m.iosVersion = v2.iosVersion
                    m.deviceModel = v2.deviceModel
                    m.build = v2.build
                    m.hardwarePlatform = v2.hardwarePlatform ?? ""
                    m.style = v2.style ?? .configuratorIOS
                    m.autoSelectCompatibleVersion = true
                    Self.current = m
                    return m
                }
                if let v1 = try? JSONDecoder().decode(LegacyV1.self, from: data) {
                    var m = StoreDeviceSpoof.default
                    m.enabled = v1.enabled
                    m.iosVersion = v1.iosVersion
                    m.deviceModel = v1.deviceModel
                    m.build = v1.build
                    m.style = .configuratorIOS
                    Self.current = m
                    return m
                }
            }
            return .default
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
        }
    }

    /// Apply a one-tap profile and turn spoof on (except “This iPhone”).
    mutating func apply(_ profile: StoreSpoofProfile) {
        iosVersion = profile.iosVersion
        build = profile.build
        if let model = profile.deviceModel, !model.isEmpty {
            deviceModel = model
        }
        style = profile.style
        hardwarePlatform = Self.hardwarePlatform(forModel: deviceModel) ?? hardwarePlatform
        autoSelectCompatibleVersion = true
        enabled = profile.id != "device"
        if profile.id == "device" {
            iosVersion = UIDevice.current.systemVersion
            deviceModel = Self.realModelIdentifier()
            build = ""
            hardwarePlatform = Self.hardwarePlatform(forModel: deviceModel) ?? ""
        }
    }

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
        if effectiveModel.hasPrefix("iPad") { return 83 }
        if effectiveModel.hasPrefix("iPod") { return 7 }
        return 232
    }

    /// True when claiming a “get the absolute latest” OS (AppStoreTroller-style).
    var claimsNewestOS: Bool {
        guard enabled else { return false }
        return (Self.versionTuple(effectiveIOSVersion).first ?? 0) >= 90
            || Self.compareVersions(effectiveIOSVersion, UIDevice.current.systemVersion) == .orderedDescending
                && (Self.versionTuple(effectiveIOSVersion).first ?? 0)
                    >= (Self.versionTuple(UIDevice.current.systemVersion).first ?? 0) + 2
    }

    var summaryLabel: String {
        if !enabled {
            return "Off · real iOS \(UIDevice.current.systemVersion)"
        }
        let auto = autoSelectCompatibleVersion ? " · auto-version" : ""
        return "iOS \(effectiveIOSVersion) · \(effectiveModel)\(auto)"
    }

    /// Primary store User-Agent for MZFinance + CDN.
    func storeUserAgent(fallbackConfigurator: String) -> String {
        let ios = effectiveIOSVersion
        let model = effectiveModel
        let build = effectiveBuild
        let hwp = effectiveHardwarePlatform
        let dt = effectiveDeviceType
        let activeStyle = enabled ? style : StoreUserAgentStyle.configuratorIOS
        let configuratorBase = fallbackConfigurator.isEmpty
            ? "Configurator/2.15 (Macintosh; OS X 11.0.0; 16A5288f) AppleWebKit/0605.2.7.5"
            : fallbackConfigurator

        switch activeStyle {
        case .configuratorIOS:
            // ipatool-py pattern: Configurator UA + iOS/hwp tokens Apple’s store still honors.
            return "\(configuratorBase) iOS/\(ios) model/\(model) hwp/\(hwp) build/\(build)"
        case .itunesstored:
            return "itunesstored/1.0 iOS/\(ios) model/\(model) hwp/\(hwp) build/\(build) (6; dt:\(dt))"
        case .appStore:
            return "AppStore/3.0 iOS/\(ios) model/\(model) hwp/\(hwp) build/\(build) (6; dt:\(dt)) AMS/1"
        case .configurator:
            return configuratorBase
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
            "X-Apple-I-Device-Model": effectiveModel,
        ]
        if enabled {
            headers["X-Apple-I-Client-Application"] = "com.apple.AppStore"
            headers["X-Apple-Client-Versions"] = "iOS/\(effectiveIOSVersion)"
            headers["X-Apple-Model"] = effectiveModel
            headers["X-Apple-Hardware-Model"] = effectiveHardwarePlatform
        }
        return headers
    }

    /// Rewrite anisette `X-MMe-Client-Info` so store requests claim the spoofed device/OS.
    /// Keeps AuthKit product tokens intact; only swaps model + OS version/build segments.
    func rewritingClientInfo(_ original: String) -> String {
        guard enabled else { return original }
        var info = original
        let model = effectiveModel
        let ios = effectiveIOSVersion
        let build = effectiveBuild

        // `<iPhone14,2> <iPhone OS;16.0;20A362> <com.apple…>`
        if let re = try? NSRegularExpression(pattern: #"<[^>]+>\s*<iPhone OS;[^>]+>"#) {
            let range = NSRange(info.startIndex..<info.endIndex, in: info)
            info = re.stringByReplacingMatches(
                in: info, range: range,
                withTemplate: "<\(model)> <iPhone OS;\(ios);\(build)>"
            )
        }
        // `<Mac…> <Mac OS X;…;…>` → still rewrite OS token if present so headers agree.
        if let re = try? NSRegularExpression(pattern: #"<Mac OS X;[^>]+>"#) {
            let range = NSRange(info.startIndex..<info.endIndex, in: info)
            info = re.stringByReplacingMatches(
                in: info, range: range,
                withTemplate: "<iPhone OS;\(ios);\(build)>"
            )
        }
        // Windows / PC anisette fallback from some providers.
        if info.contains("<PC>") || info.contains("Windows;") {
            return "<\(model)> <iPhone OS;\(ios);\(build)> <com.apple.AuthKit/1 (com.apple.AppStore/1.0)>"
        }
        if !info.contains("iPhone OS;") {
            return "<\(model)> <iPhone OS;\(ios);\(build)> <com.apple.AuthKit/1 (com.apple.AppStore/1.0)>"
        }
        return info
    }

    /// Plist fields merged into buy/download bodies when spoofing.
    func storeRequestBodyFields(guid: String) -> [String: Any] {
        guard enabled else { return [:] }
        return [
            "osVersion": effectiveIOSVersion,
            "serialNumber": "0",
            "guid": guid,
            "deviceType": effectiveModel.hasPrefix("iPad") ? "iPad" : "iPhone",
            "softwareVersionBuddy": effectiveBuild,
        ]
    }

    /// Whether `minOS` from store metadata is installable under the claimed iOS.
    func acceptsMinimumOS(_ minOS: String?) -> Bool {
        guard let minOS, !minOS.isEmpty else { return true }
        if claimsNewestOS { return true }
        return Self.compareVersions(minOS, effectiveIOSVersion) != .orderedDescending
    }

    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let aa = versionTuple(a)
        let bb = versionTuple(b)
        let n = max(aa.count, bb.count)
        for i in 0..<n {
            let x = i < aa.count ? aa[i] : 0
            let y = i < bb.count ? bb[i] : 0
            if x < y { return .orderedAscending }
            if x > y { return .orderedDescending }
        }
        return .orderedSame
    }

    static func versionTuple(_ s: String) -> [Int] {
        s.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
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

    static func defaultBuild(forIOS ios: String) -> String? {
        let v = ios.trimmingCharacters(in: .whitespacesAndNewlines)
        let known: [(prefix: String, build: String)] = [
            ("99.", "99A999"),
            ("18.4", "22E240"), ("18.3", "22D63"), ("18.2", "22C152"), ("18.1", "22B83"), ("18.0", "22A3354"),
            ("17.6", "21G93"), ("17.5", "21F79"), ("17.4", "21E219"), ("17.0", "21A329"),
            ("16.7", "20H350"), ("16.6", "20G75"), ("16.0", "20A362"),
            ("15.8", "19H386"), ("15.7", "19H12"), ("15.0", "19A346"),
            ("14.8", "18H107"), ("14.0", "18A373"),
        ]
        for row in known where v.hasPrefix(row.prefix) {
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

private struct LegacyV1: Codable {
    var enabled: Bool
    var iosVersion: String
    var deviceModel: String
    var build: String
}

private struct LegacyV2: Codable {
    var enabled: Bool
    var iosVersion: String
    var deviceModel: String
    var build: String
    var hardwarePlatform: String?
    var style: StoreUserAgentStyle?
}

extension StoreDeviceSpoof: Codable {
    enum CodingKeys: String, CodingKey {
        case enabled, iosVersion, deviceModel, build, hardwarePlatform, style, autoSelectCompatibleVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        iosVersion = try c.decodeIfPresent(String.self, forKey: .iosVersion) ?? UIDevice.current.systemVersion
        deviceModel = try c.decodeIfPresent(String.self, forKey: .deviceModel) ?? Self.realModelIdentifier()
        build = try c.decodeIfPresent(String.self, forKey: .build) ?? ""
        hardwarePlatform = try c.decodeIfPresent(String.self, forKey: .hardwarePlatform) ?? ""
        style = try c.decodeIfPresent(StoreUserAgentStyle.self, forKey: .style) ?? .configuratorIOS
        autoSelectCompatibleVersion = try c.decodeIfPresent(Bool.self, forKey: .autoSelectCompatibleVersion) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(iosVersion, forKey: .iosVersion)
        try c.encode(deviceModel, forKey: .deviceModel)
        try c.encode(build, forKey: .build)
        try c.encode(hardwarePlatform, forKey: .hardwarePlatform)
        try c.encode(style, forKey: .style)
        try c.encode(autoSelectCompatibleVersion, forKey: .autoSelectCompatibleVersion)
    }
}
