import SwiftUI

struct PremiumPlan: Identifiable, Decodable, Equatable {
    let id: String
    let name: String
    let days: Int
    let amount: Int      // US cents; the Litecoin amount is quoted when you start paying
    let currency: String

    var priceText: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency.uppercased()
        return f.string(from: NSNumber(value: Double(amount) / 100)) ?? "\(amount)"
    }
}

/// One line of the perk list. The server builds these from its real settings, so the sheet never promises more than exists.
struct PremiumPerk: Decodable, Identifiable {
    let icon: String   // SF Symbol name
    let text: String
    var id: String { text }
}

/// A Litecoin payment request: send `amountLTC` to `address` before `expiresAt`.
struct LTCOrder: Decodable, Equatable, Identifiable {
    let orderID: Int
    let plan: String
    let name: String
    let days: Int
    let status: String
    let address: String
    let amountLTC: String
    let usdCents: Int
    let expiresAt: String
    let uri: String
    let confirmations: Int
    let requiredConfirmations: Int
    let receivedLTC: String

    var id: Int { orderID }

    enum CodingKeys: String, CodingKey {
        case orderID = "order_id", plan, name, days, status, address, amountLTC = "amount_ltc", usdCents = "usd_cents",
             expiresAt = "expires_at", uri, confirmations, requiredConfirmations = "required_confirmations", receivedLTC = "received_ltc"
    }

    var expiry: Date { AirShareAPI.date(expiresAt) ?? .distantPast }
    var isOpen: Bool { status == "pending" || status == "seen" }
}

struct PurchaseRecord: Identifiable, Decodable {
    let sessionID: String
    let name: String
    let amount: Int?          // US cents
    let currency: String?
    let amountLTC: String?
    let status: String
    let createdAt: String

    var id: String { sessionID }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", name, amount, currency, amountLTC = "amount_ltc", status, createdAt = "created_at"
    }

    var priceText: String {
        guard let amount else { return "" }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = (currency ?? "usd").uppercased()
        return f.string(from: NSNumber(value: Double(amount) / 100)) ?? "\(amount)"
    }

    var ltcText: String? { amountLTC.map { "\($0) LTC" } }
    var date: Date? { AirShareAPI.date(createdAt) }

    /// Plain-language status for the history list.
    var statusText: String {
        switch status {
        case "paid": return "Paid"
        case "pending": return "Waiting for payment"
        case "seen": return "Payment seen, confirming"
        case "refunded": return "Refunded"
        case "expired": return "Expired"
        case "late": return "Late payment, under review"
        case "underpaid": return "Underpaid, under review"
        case "user_missing": return "Needs review"
        default: return status.capitalized
        }
    }
}

/// Where the buy flow stands. The pay screen closes only on `.confirmed`; every other state says plainly what is known.
enum CheckoutPhase: Equatable {
    case idle
    case creating                 // asking our server for an address and amount
    case awaiting                 // an order is open: waiting for the coins and their confirmations
    case confirmed                // enough confirmations; Premium is on the account
    case expired                  // the quote ran out before a payment was seen
    case needsReview              // a payment arrived but needs a person to look at it (late or short)
    case failed(String)           // couldn't set up the order

    var isBusy: Bool { self == .creating }
}

/// Talks to the AirShare backend (/app/v1/shop, /app/v1/checkout). Payment is in Litecoin: the server gives each order its own
/// address and amount, watches the blockchain, and adds the days after enough confirmations. No browser, no account with any
/// payment company; the app only shows the request and asks the server how it is going.
@MainActor
final class PremiumShop: ObservableObject {
    static let shared = PremiumShop()

    @Published private(set) var plans: [PremiumPlan] = []
    @Published private(set) var perks: [PremiumPerk] = []
    @Published private(set) var plansState: LoadState = .idle
    @Published private(set) var cryptoEnabled = true
    @Published private(set) var purchases: [PurchaseRecord] = []
    @Published private(set) var purchasesState: LoadState = .idle
    @Published private(set) var phase: CheckoutPhase = .idle
    @Published private(set) var order: LTCOrder?
    @Published private(set) var watchNote: String?       // e.g. "Can't reach AirShare right now. Still watching."
    @Published private(set) var restoring = false
    @Published private(set) var restoreMessage: String?
    @Published private(set) var restoreIsError = false

    private var watchTask: Task<Void, Never>?
    private var plansGeneration = 0
    private var purchasesGeneration = 0
    private var purchasesOwner: String?
    private var orderOwner: String?

    private init() {}

    // MARK: Loading

    func loadPlans() async {
        plansGeneration += 1
        let mine = plansGeneration
        plansState = plans.isEmpty ? .loading : .refreshing
        do {
            // The shop list is public, so a signed-out buyer still sees prices (and is told to sign in when buying).
            let o = try await AirShareAPI.request("GET", "shop", requiresAuth: false)
            guard mine == plansGeneration else { return }
            let decoded = try AirShareAPI.decodeList(PremiumPlan.self, o["plans"])
            plans = decoded
            if let list = o["perks"] { perks = (try? AirShareAPI.decodeList(PremiumPerk.self, list)) ?? perks }
            if let crypto = o["crypto"] as? [String: Any] { cryptoEnabled = (crypto["enabled"] as? Bool) ?? true }
            plansState = decoded.isEmpty ? .failed("No plans are available right now.") : .loaded
        } catch {
            guard mine == plansGeneration else { return }
            switch AirShareAPI.classify(error) {
            case .cancelled: plansState = plans.isEmpty ? .idle : .loaded
            case .signedOut: plansState = .signedOut
            case let .message(m): plansState = .failed(m)
            }
        }
    }

    func loadPurchases() async {
        if purchasesOwner != nil, purchasesOwner != AirShareAPI.ownerTag {
            purchases = []          // never show one account's purchases to the next
            purchasesOwner = nil
        }
        purchasesGeneration += 1
        let mine = purchasesGeneration
        purchasesState = purchases.isEmpty ? .loading : .refreshing
        do {
            let o = try await AirShareAPI.request("GET", "purchases")
            guard mine == purchasesGeneration else { return }
            purchases = try AirShareAPI.decodeList(PurchaseRecord.self, o["purchases"])
            purchasesOwner = AirShareAPI.ownerTag
            purchasesState = .loaded
        } catch {
            guard mine == purchasesGeneration else { return }
            switch AirShareAPI.classify(error) {
            case .cancelled: purchasesState = purchases.isEmpty ? .idle : .loaded
            case .signedOut: purchases = []; purchasesOwner = nil; purchasesState = .signedOut
            case let .message(m): purchasesState = .failed(m)
            }
        }
    }

    // MARK: Paying

    /// Call when the pay screen opens. Clears an old failure or a finished order, and picks the open order back up
    /// (and its polling) if the same account already has one on screen.
    func beginVisit(planID: String) {
        if orderOwner != nil, orderOwner != AirShareAPI.ownerTag { resetOrder() }
        if let o = order, o.plan != planID { resetOrder() }           // a different plan was picked: don't show the old order
        switch phase {
        case .awaiting: startWatching()
        case .creating: break
        default: resetOrder()
        }
    }

    /// Call when the pay screen goes away. The server keeps watching the chain either way, so Premium still arrives.
    func endVisit() { stopWatching() }

    private func resetOrder() {
        stopWatching()
        order = nil
        orderOwner = nil
        watchNote = nil
        phase = .idle
    }

    func startCheckout(_ plan: PremiumPlan) async {
        guard !phase.isBusy else { return }                                    // double tap
        guard AirShareAPI.ownerTag != nil else { phase = .failed("Sign in to buy Premium."); return }
        stopWatching()
        phase = .creating
        watchNote = nil
        do {
            let o = try await AirShareAPI.request("POST", "checkout", body: ["plan": plan.id])
            let data = try JSONSerialization.data(withJSONObject: o)
            let created = try JSONDecoder().decode(LTCOrder.self, from: data)
            order = created
            orderOwner = AirShareAPI.ownerTag
            apply(created)
            if phase == .awaiting { startWatching() }
        } catch {
            switch AirShareAPI.classify(error) {
            case .cancelled: phase = .idle
            case .signedOut: phase = .failed("Your session ended. Sign in again to buy Premium.")
            case let .message(m): phase = .failed(m)
            }
        }
    }

    /// Moves the screen to whatever the server says about the order.
    private func apply(_ o: LTCOrder) {
        order = o
        switch o.status {
        case "paid": phase = .confirmed
        case "expired": phase = .expired
        case "late", "underpaid", "user_missing": phase = .needsReview
        case "refunded": phase = .failed("This order was refunded.")
        default: phase = .awaiting
        }
    }

    private func startWatching() {
        guard watchTask == nil, let id = order?.orderID else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce(orderID: id)
                if self.phase != .awaiting { break }
                try? await Task.sleep(nanoseconds: 6_000_000_000)
            }
            self?.watchTask = nil
        }
    }

    private func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    /// Ask the server (which asks the blockchain) how the order is doing. Network problems never change the order's state.
    func pollOnce(orderID: Int) async {
        do {
            let o = try await AirShareAPI.request("POST", "checkout/verify", body: ["order_id": orderID])
            let data = try JSONSerialization.data(withJSONObject: o)
            let fresh = try JSONDecoder().decode(LTCOrder.self, from: data)
            guard order?.orderID == fresh.orderID else { return }          // the buyer started a different order meanwhile
            watchNote = nil
            apply(fresh)
            if fresh.status == "paid" {
                await CertificateRequestClient.shared.refreshStatus()
                await loadPurchases()
            }
        } catch {
            switch AirShareAPI.classify(error) {
            case .cancelled: break
            case .signedOut:
                phase = .failed("Your session ended. Sign in again; your payment will still be credited.")
                stopWatching()
            case .message:
                if case let AirShareAPI.Failure.http(code, _) = error, code == 404 { watchNote = "This order was not found." }
                else { watchNote = "Can't reach AirShare right now. Still trying; your payment is safe." }
            }
        }
    }

    /// "Check now" button.
    func checkNow() { if let id = order?.orderID { Task { await pollOnce(orderID: id) } } }

    /// App came back to the foreground while an order is open: look right away instead of waiting for the next tick.
    func foregrounded() {
        if phase == .awaiting { checkNow() }
    }

    // MARK: Restore and quiet reconciliation

    /// "Restore": re-check the latest unfinished order and say exactly what happened.
    func restore() async {
        guard !restoring else { return }
        restoring = true
        restoreMessage = nil
        restoreIsError = false
        defer { restoring = false }
        do {
            let o = try await AirShareAPI.request("POST", "checkout/verify", body: [:])
            let fresh = try JSONDecoder().decode(LTCOrder.self, from: JSONSerialization.data(withJSONObject: o))
            await CertificateRequestClient.shared.refreshStatus()
            await loadPurchases()
            switch fresh.status {
            case "paid": restoreMessage = "Your purchase is confirmed and Premium is active."
            case "seen": restoreMessage = "Your payment is on the network: \(fresh.confirmations) of \(fresh.requiredConfirmations) confirmations. Premium is added automatically."
            case "pending": restoreMessage = "No payment seen yet for your open order."
            default: restoreMessage = "Nothing to restore. Your purchases are listed below."
            }
        } catch {
            switch AirShareAPI.classify(error) {
            case .cancelled: break
            case .signedOut: restoreIsError = true; restoreMessage = "Your session ended. Sign in again, then tap Restore."
            case let .message(m):
                if case let AirShareAPI.Failure.http(code, _) = error, code == 404 {
                    restoreMessage = "No unfinished purchase found."      // not an error: there is simply nothing to restore
                } else {
                    restoreIsError = true
                    restoreMessage = m
                }
            }
        }
    }

    /// Runs when the store opens or the app returns to the foreground. If a payment confirmed while the app was away,
    /// this picks it up without showing any error.
    func reconcilePending() async {
        guard !phase.isBusy, AirShareAPI.ownerTag != nil else { return }
        guard (try? await AirShareAPI.request("POST", "checkout/verify", body: [:])) != nil else { return }   // 404/offline: stay quiet
        await CertificateRequestClient.shared.refreshStatus()
        await loadPurchases()
    }

    func clearRestoreMessage() { restoreMessage = nil; restoreIsError = false }
}
