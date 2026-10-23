import Foundation
import UIKit

extension OTAInstaller {
    nonisolated static func otaIconPNG(_ data: Data?, side: CGFloat) -> Data {
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { _ in
            UIColor(red: 0.06, green: 0.06, blue: 0.06, alpha: 1).setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: size)).fill()

            if let data, let image = UIImage(data: data) {
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }.pngData() ?? Data()
    }
}
