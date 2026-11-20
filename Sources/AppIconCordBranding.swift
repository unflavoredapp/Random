//
//  AppIconCordBranding.swift
//  Brand: Tetherless · https://tetherless.dev
//
//  Stamps the Mach-O cord watermark onto app icons inside decrypted Payload
//  bundles (lower-left, ~33% of icon height — same scale as the Alpha/Orbit mockups).
//

import Foundation
import UIKit

nonisolated enum AppIconCordBranding {
    /// Cord height as a fraction of the icon’s short side (340 / 1024).
    static let cordHeightFraction: CGFloat = 340.0 / 1024.0
    static let marginFraction: CGFloat = 0.028
    static let cordOpacity: CGFloat = 0.94
    static let assetName = "MachOCordWatermark"

    /// Brand every loose app-icon PNG in `app` and write standard AppIcon names
    /// so SpringBoard picks up the mark even when the original lived in Assets.car.
    @discardableResult
    static func brandAppBundle(at app: URL) -> Int {
        guard let watermark = loadWatermark() else { return 0 }
        guard let source = loadBestIcon(in: app) else { return 0 }

        var written = 0
        let fm = FileManager.default

        // Overwrite existing icon-ish PNGs at their native pixel size.
        let pngs = (try? fm.contentsOfDirectory(at: app, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "png" } ?? []
        let iconPNGs = pngs.filter { nameLooksLikeIcon($0.lastPathComponent) }
        for url in iconPNGs {
            guard let img = UIImage(contentsOfFile: url.path) else { continue }
            let side = max(img.size.width * img.scale, img.size.height * img.scale)
            let branded = brand(icon: img, watermark: watermark, pixelSide: side)
            if let data = branded.pngData() {
                try? data.write(to: url, options: .atomic)
                written += 1
            }
        }

        // Always emit flat AppIcon files SpringBoard / IPAMeta recognize.
        let masterSide: CGFloat = 1024
        let master = brand(icon: source, watermark: watermark, pixelSide: masterSide)
        guard let masterPNG = master.pngData() else { return written }

        let flatNames = [
            "AppIcon.png",
            "AppIcon60x60@2x.png",
            "AppIcon60x60@3x.png",
            "AppIcon76x76@2x~ipad.png",
            "iTunesArtwork@2x",
            "iTunesArtwork",
        ]
        for name in flatNames {
            let url = app.appendingPathComponent(name)
            let side: CGFloat
            if name.contains("60x60@3x") { side = 180 }
            else if name.contains("60x60@2x") { side = 120 }
            else if name.contains("76x76") { side = 152 }
            else if name == "iTunesArtwork" { side = 512 }
            else { side = 1024 }
            let scaled = brand(icon: source, watermark: watermark, pixelSide: side)
            if let data = scaled.pngData() {
                try? data.write(to: url, options: .atomic)
                written += 1
            } else if name.hasPrefix("AppIcon") {
                try? masterPNG.write(to: url, options: .atomic)
                written += 1
            }
        }

        pointInfoPlistAtFlatIcons(app: app)
        return written
    }

    /// Brand every `.app` under a Payload directory.
    @discardableResult
    static func brandPayload(at payload: URL) -> Int {
        let fm = FileManager.default
        let apps = (try? fm.contentsOfDirectory(at: payload, includingPropertiesForKeys: [.isDirectoryKey]))?
            .filter { $0.pathExtension == "app" } ?? []
        return apps.reduce(0) { $0 + brandAppBundle(at: $1) }
    }

    // MARK: - Composite

    static func brand(icon: UIImage, watermark: UIImage, pixelSide: CGFloat) -> UIImage {
        let side = max(32, pixelSide)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { _ in
            icon.draw(in: CGRect(x: 0, y: 0, width: side, height: side))

            let cordH = side * cordHeightFraction
            let aspect = watermark.size.width / max(watermark.size.height, 1)
            let cordW = cordH * aspect
            let margin = side * marginFraction
            let cordRect = CGRect(
                x: margin,
                y: side - cordH - margin,
                width: cordW,
                height: cordH
            )

            // Soft shadow under the cord for contrast on dark icons.
            if let shadow = watermark.cgImage {
                let ctx = UIGraphicsGetCurrentContext()
                ctx?.saveGState()
                ctx?.setShadow(offset: CGSize(width: side * 0.004, height: side * 0.006),
                               blur: side * 0.008,
                               color: UIColor.black.withAlphaComponent(0.35).cgColor)
                UIImage(cgImage: shadow).draw(in: cordRect.offsetBy(dx: 1, dy: 2), blendMode: .normal, alpha: 0.35)
                ctx?.restoreGState()
            }

            watermark.draw(in: cordRect, blendMode: .normal, alpha: cordOpacity)
        }
    }

    // MARK: - Loaders

    static func loadWatermark() -> UIImage? {
        if let named = UIImage(named: assetName) { return named }
        if let url = Bundle.main.url(forResource: assetName, withExtension: "png"),
           let img = UIImage(contentsOfFile: url.path) {
            return img
        }
        // Imageset file may be registered without the catalog name on thin builds.
        if let url = Bundle.main.url(forResource: "MachOCordWatermark", withExtension: "png",
                                     subdirectory: "MachOCordWatermark.imageset"),
           let img = UIImage(contentsOfFile: url.path) {
            return img
        }
        return nil
    }

    private static func loadBestIcon(in app: URL) -> UIImage? {
        let fm = FileManager.default
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))
        var bases: [String] = []
        if let icons = info?["CFBundleIcons"] as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            bases.append(contentsOf: files.reversed())
        }
        bases.append(contentsOf: [
            "AppIcon60x60@3x", "AppIcon60x60@2x", "AppIcon76x76@2x~ipad",
            "AppIcon", "iTunesArtwork@2x", "iTunesArtwork",
            "Icon-60@3x", "Icon-60@2x", "Icon@2x", "Icon",
        ])

        let pngs = (try? fm.contentsOfDirectory(at: app, includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension.lowercased() == "png" || $0.pathExtension.isEmpty } ?? []

        for base in bases {
            if let hit = pngs.first(where: {
                let n = $0.deletingPathExtension().lastPathComponent
                return n == base || n.hasPrefix(base) || $0.lastPathComponent.hasPrefix(base)
            }), let img = UIImage(contentsOfFile: hit.path) {
                return img
            }
        }

        let iconish = pngs.filter { nameLooksLikeIcon($0.lastPathComponent) }
        let pool = iconish.isEmpty ? pngs : iconish
        let largest = pool.max { a, b in
            let sa = (try? a.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let sb = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return sa < sb
        }
        return largest.flatMap { UIImage(contentsOfFile: $0.path) }
    }

    private static func nameLooksLikeIcon(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("appicon")
            || lower.hasPrefix("icon")
            || lower.contains("itunesartwork")
            || lower.contains("60x60")
            || lower.contains("76x76")
            || lower.contains("83.5x83.5")
    }

    private static func pointInfoPlistAtFlatIcons(app: URL) {
        let infoURL = app.appendingPathComponent("Info.plist")
        guard let dict = NSMutableDictionary(contentsOf: infoURL) else { return }
        dict["CFBundleIconFile"] = "AppIcon"
        dict["CFBundleIcons"] = [
            "CFBundlePrimaryIcon": [
                "CFBundleIconFiles": ["AppIcon60x60"],
                "CFBundleIconName": "AppIcon",
            ]
        ]
        dict.write(to: infoURL, atomically: true)
    }
}
