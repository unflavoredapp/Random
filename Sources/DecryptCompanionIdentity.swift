//
// Brand: AppAssassin · https://fastdecrypt.ai
//  DecryptCompanionIdentity.swift
//  Display name / URL scheme / icon constants shared by host packager and
//  lean DecryptHelper console (so the helper never compiles Packager).
//

import Foundation

enum DecryptCompanionIdentity {
    static let companionBundleIDFallback = "bot.fastdecrypt.ai.decrypt"
    static let companionDisplayName = "FastDecryptBot"
    /// Primary URL scheme for opening the companion. Legacy schemes still accepted by the host.
    static let companionURLScheme = "fastdecryptbot"
    static let companionIconAsset = "FastDecryptBotAppIcon"
    /// Embedded lean helper product name (Resources/DecryptHelper.app).
    static let helperProductName = "DecryptHelper"
    /// Target app icon dropped at companion `.app` root (not SpringBoard brand icons).
    static let targetIconFileName = "TargetIcon.png"
    /// Info.plist: lean DecryptHelper vs fat host-clone fallback.
    static let helperModeKey = "TLDecryptHelperMode"
    static let helperModeLean = "lean"
    static let helperModeHostFallback = "host-fallback"
}
