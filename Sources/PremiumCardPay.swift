//
//  PremiumCardPay.swift
//  Pay for Premium by card with Stripe's PaymentSheet, inside the app (no Safari).
//
//  Flow: POST stripe/intent (server creates the PaymentIntent at the plan's fixed USD price) → PaymentSheet collects the card →
//  POST stripe/verify (the server asks Stripe directly and adds the days exactly once; the Stripe webhook does the same if the app
//  is closed first). The app never sees a secret key and never decides whether a payment counts.
//

import SwiftUI
import StripePaymentSheet

@MainActor
final class CardCheckout: ObservableObject {
    static let shared = CardCheckout()

    @Published private(set) var working = false
    @Published private(set) var message: String?
    @Published private(set) var isError = false
    @Published private(set) var confirmed = false

    private var orderID: Int?
    private init() {}

    func reset() { message = nil; isError = false; confirmed = false; working = false; orderID = nil }

    /// Asks the server for a PaymentIntent and opens the sheet.
    func start(plan: PremiumPlan) async {
        guard !working else { return }
        guard AirShareAPI.ownerTag != nil else { fail("Sign in to buy Premium."); return }
        working = true; message = nil; isError = false; confirmed = false
        defer { working = false }
        do {
            let o = try await AirShareAPI.request("POST", "stripe/intent", body: ["plan": plan.id])
            guard let secret = o["client_secret"] as? String, let key = o["publishable_key"] as? String,
                  let id = (o["order_id"] as? Int) ?? (o["order_id"] as? Double).map(Int.init) else {
                fail("The server's answer was incomplete. Please try again."); return
            }
            orderID = id
            STPAPIClient.shared.publishableKey = key
            var cfg = PaymentSheet.Configuration()
            cfg.merchantDisplayName = "Decrypt.Team"
            cfg.allowsDelayedPaymentMethods = false        // days are added when the payment is final, so no slow bank debits
            cfg.returnURL = nil
            let sheet = PaymentSheet(paymentIntentClientSecret: secret, configuration: cfg)
            guard let top = Self.topViewController() else { fail("Couldn't open the payment sheet. Please try again."); return }
            sheet.present(from: top) { [weak self] result in
                Task { @MainActor in self?.finished(result) }
            }
        } catch {
            switch AirShareAPI.classify(error) {
            case .cancelled: break
            case .signedOut: fail("Your session ended. Sign in again to buy Premium.")
            case let .message(m): fail(m)
            }
        }
    }

    private func finished(_ result: PaymentSheetResult) {
        switch result {
        case .completed:
            message = "Payment received. Confirming…"; isError = false
            Task { await confirm() }
        case .canceled:
            break
        case let .failed(error):
            fail(error.localizedDescription)
        }
    }

    /// Asks the server to check with Stripe until it reports paid (usually the first try).
    func confirm() async {
        guard let id = orderID else { return }
        for attempt in 0..<12 {
            do {
                let o = try await AirShareAPI.request("POST", "stripe/verify", body: ["order_id": id])
                switch (o["status"] as? String) ?? "" {
                case "paid":
                    confirmed = true; isError = false; message = "Payment confirmed. Premium is active."
                    await CertificateRequestClient.shared.refreshStatus()
                    await PremiumShop.shared.loadPurchases()
                    return
                case "failed", "canceled":
                    fail("The payment didn't go through. You weren't charged."); return
                default: break
                }
            } catch {
                if case .cancelled = AirShareAPI.classify(error) { return }
            }
            try? await Task.sleep(nanoseconds: UInt64(min(attempt + 1, 4)) * 1_000_000_000)
        }
        // Paid but not confirmed yet: it is safe, the webhook will add the days.
        isError = false
        message = "Your payment went through. Premium is added as soon as Stripe confirms it, usually within a minute."
        await PremiumShop.shared.loadPurchases()
    }

    /// The view controller to present Stripe's sheet from (the top-most one, so it appears over the Premium sheets).
    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    private func fail(_ m: String) { message = m; isError = true }
}
