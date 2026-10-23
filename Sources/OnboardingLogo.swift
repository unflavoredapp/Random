import SwiftUI
import UIKit

/// Shared AirShare branding used by onboarding and account flows.
/// The logo is stored in Sources/Resources rather than Assets.xcassets,
/// so load it explicitly from the application bundle.
struct OnboardingLogo: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let image = Self.logoImage() {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(Color.green.opacity(0.14))
                    Image(systemName: "signature")
                        .font(.system(size: size * 0.48, weight: .bold))
                        .foregroundStyle(Color.green)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(Color.green.opacity(0.30), lineWidth: 1)
        }
        .shadow(color: Color.green.opacity(0.22), radius: size * 0.22, y: size * 0.08)
        .accessibilityLabel("AirShare")
    }

    private static func logoImage() -> UIImage? {
        guard let url = Bundle.main.url(forResource: "AirShareLogo", withExtension: "png"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return UIImage(data: data)
    }
}

/// A plain, transparent-background AirShare mark used to brand full-screen
/// loading/progress states (string search, gate checks, class scans, etc.)
/// that would otherwise just be empty black space above a progress bar.
/// Unlike `OnboardingLogo`, this has no card, fill, or border — just the
/// logo itself, sitting directly on whatever background it's placed over.
///
/// Uses the existing "airshare_mark" entry already in Assets.xcassets
/// (a genuine transparent-PNG asset), the same mark already shipping in
/// the app, rather than a separate bundled file.
struct AirShareWatermark: View {
    var size: CGFloat = 96
    var opacity: Double = 0.92

    var body: some View {
        Image("airshare_mark")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .opacity(opacity)
            .accessibilityHidden(true)
    }
}
