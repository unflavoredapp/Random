import SwiftUI
import CoreImage.CIFilterBuiltins

/// Everything the buyer needs to pay one Litecoin order without leaving the app: QR code, exact amount, address,
/// a live countdown and the confirmation progress.
struct LTCPayPanel: View {
    let order: LTCOrder
    let note: String?
    let checkNow: () -> Void

    @State private var copied: String?

    var body: some View {
        VStack(spacing: 14) {
            if let image = LTCQRCode.image(for: order.uri) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 190, height: 190)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityLabel("QR code for the Litecoin payment")
            }

            field(title: "Send exactly", value: "\(order.amountLTC) LTC", copyValue: order.amountLTC, big: true)
            field(title: "To this Litecoin address", value: order.address, copyValue: order.address, big: false)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(order.expiry.timeIntervalSince(context.date)))
                HStack {
                    Image(systemName: "timer")
                    Text(left > 0 ? "This quote is valid for \(left / 60):\(String(format: "%02d", left % 60))" : "This quote has expired")
                        .monospacedDigit()
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(left > 0 ? Color.yellow : Color.red)
            }

            statusLine

            if let note {
                Label(note, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.orange)
            }

            Button(action: checkNow) { Label("Check now", systemImage: "arrow.clockwise").font(.subheadline.weight(.semibold)) }

            if let url = URL(string: order.uri) {
                Link(destination: url) { Label("Open in a wallet app", systemImage: "arrow.up.forward.app").font(.footnote) }
            }

            Text("Send the full amount so that at least this much arrives. Exchange withdrawals often take their fee out of the amount, so add it on top. You can close this screen: Premium is added automatically once the payment has \(order.requiredConfirmations) confirmations.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .payCard()
    }

    @ViewBuilder
    private var statusLine: some View {
        if order.status == "seen" {
            VStack(spacing: 4) {
                Label("Payment seen on the network", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(order.confirmations) of \(order.requiredConfirmations) confirmations. About 2.5 minutes each.")
                    .font(.footnote).foregroundStyle(.secondary)
                ProgressView(value: Double(min(order.confirmations, order.requiredConfirmations)), total: Double(max(1, order.requiredConfirmations)))
                    .tint(.green)
            }
            .font(.subheadline.weight(.semibold))
        } else {
            HStack(spacing: 8) { ProgressView(); Text("Waiting for your payment\u{2026}").font(.subheadline).foregroundStyle(.secondary) }
        }
    }

    private func field(title: String, value: String, copyValue: String, big: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(value)
                    .font(big ? .title3.weight(.bold).monospacedDigit() : .system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(copied == copyValue ? "Copied" : "Copy") {
                    UIPasteboard.general.string = copyValue
                    copied = copyValue
                    Task { try? await Task.sleep(nanoseconds: 1_500_000_000); if copied == copyValue { copied = nil } }
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum LTCQRCode {
    private static let context = CIContext()

    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension View {
    func payCard(stroke: Color? = nil) -> some View {
        self.padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                if let stroke { RoundedRectangle(cornerRadius: 18).strokeBorder(stroke, lineWidth: 1) }
            }
    }
}
