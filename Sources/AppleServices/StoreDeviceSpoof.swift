//
//  StoreDeviceSpoof.swift
//  Optional App Store request identity (iOS version / device model) used by
//  AppStoreClient User-Agent so Apple can serve a compatible build variant.
//

import Foundation
import UIKit

/// Spoofed device profile for MZFinance / App Store download requests.
struct StoreDeviceSpoof: Codable, Equatable, Sendable {
    var enabled: Bool
    /// e.g. "18.2" — claimed iOS version in the store User-Agent.
    var iosVersion: String
    /// Hardware identifier, e.g. "iPhone16,2".
    var deviceModel: String
    /// Optional build string, e.g. "22C152".
    var build: String

    static let defaultsKey = "tetherless.storeDeviceSpoof"

    static var `default`: StoreDeviceSpoof {
        StoreDeviceSpoof(
            enabled: false,
            iosVersion: UIDevice.current.systemVersion,
            deviceModel: Self.realModelIdentifier(),
            build: ""
        )
    }

    static var current: StoreDeviceSpoof {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let decoded = try? JSONDecoder().decode(StoreDeviceSpoof.self, from: data) else {
                return .default
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
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

    /// App Store–style UA so Apple picks an iPhoneOS package (Configurator/macOS UA is a poor fit).
    func storeUserAgent(fallbackConfigurator: String) -> String {
        _ = fallbackConfigurator
        let ios = effectiveIOSVersion
        let model = effectiveModel
        let buildPart = build.trimmingCharacters(in: .whitespacesAndNewlines)
        if buildPart.isEmpty {
            return "AppStore/3.0 iOS/\(ios) model/\(model) (6; dt:1) AMS/1"
        }
        return "AppStore/3.0 iOS/\(ios) model/\(model) build/\(buildPart) (6; dt:1) AMS/1"
    }

    static let modelPresets: [(label: String, model: String)] = [
        ("This iPhone", realModelIdentifier()),
        ("iPhone 16 Pro", "iPhone17,1"),
        ("iPhone 15", "iPhone15,4"),
        ("iPhone 14", "iPhone14,7"),
        ("iPhone 13", "iPhone14,5"),
        ("iPhone 12", "iPhone13,2"),
        ("iPhone 11", "iPhone12,1"),
        ("iPhone XS", "iPhone11,2"),
        ("iPhone X", "iPhone10,3"),
        ("iPhone 8", "iPhone10,1"),
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
}
