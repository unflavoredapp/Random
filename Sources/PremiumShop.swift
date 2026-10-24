import SwiftUI
import SafariServices

struct PremiumPlan: Identifiable, Decodable, Equatable {
    let id: String
    let name: String
    let days: Int
    let amount: Int      // minor units (cents)
    let currency: String

    var priceText: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency.uppercased()
        return f.string(from: NSNumber(value: Double(amount) / 100)) ?? "\(amount)"
    }
}

struct CheckoutPage: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Talks to the AirShare backend (/app/v1/shop, /app/v1/checkout). Card details are entered on Stripe's own
/// page in Safari, so the app never sees them and needs no payment SDK. The server grants the days after Stripe
/// confirms payment; the app only refreshes the account afterwards.
@MainActor
final class PremiumShop: ObservableObject {
    static let shared = PremiumShop()

    @Published var plans: [PremiumPlan] = []
    @Published var busy = false
    @Published var error: String?
    @Published var page: CheckoutPage?

    private init() {}

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let base = URL(string: ZefvAccount.apiBase) else { throw ZefvAccount.Err.badURL }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.timeoutInterval = 20
        if let token = ZefvAccount.shared.sessionToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code >= 400 { throw ZefvAccount.Err.server((object["error"] as? String) ?? "Server error (\(code))") }
        return object
    }

    private static func text(_ error: Error) -> String {
        (error as? ZefvAccount.Err)?.message ?? error.localizedDescription
    }

    func loadPlans() async {
        do {
            let object = try await request("GET", "shop")
            let raw = try JSONSerialization.data(withJSONObject: object["plans"] ?? [])
            plans = try JSONDecoder().decode([PremiumPlan].self, from: raw)
        } catch {
            self.error = Self.text(error)
        }
    }

    func startCheckout(_ plan: PremiumPlan) async {
        guard ZefvAccount.shared.sessionToken != nil else {
            error = "Sign in to buy Premium."
            return
        }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let object = try await request("POST", "checkout", body: ["plan": plan.id])
            guard let s = object["url"] as? String, let url = URL(string: s), url.scheme == "https" else {
                error = "Couldn't start checkout. Please try again."
                return
            }
            page = CheckoutPage(url: url)
        } catch {
            self.error = Self.text(error)
        }
    }

    /// The webhook can land a few seconds after the buyer returns, so check a few times.
    func refreshAfterPurchase() async {
        let before = CertificateRequestClient.shared.server?.premiumDaysLeft ?? 0
        for _ in 0..<6 {
            await CertificateRequestClient.shared.refreshStatus()
            if (CertificateRequestClient.shared.server?.premiumDaysLeft ?? 0) > before { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
