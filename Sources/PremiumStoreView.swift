import SwiftUI

/// Two-step premium checkout. Step 1: pick a length of premium. Step 2: review and pay in Litecoin inside the app.
struct PremiumStoreView: View {
    @ObservedObject private var shop = PremiumShop.shared
    @ObservedObject private var certs = CertificateRequestClient.shared
    @State private var selectedID: String?
    @State private var showConfirm = false
    @State private var showHistory = false
    @Environment(\.scenePhase) private var scenePhase

    private var selected: PremiumPlan? {
        shop.plans.first { $0.id == selectedID } ?? shop.plans.first
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule().fill(.gray.opacity(0.5)).frame(width: 36, height: 5).padding(.top, 8)

            ScrollView {
                VStack(spacing: 14) {
                    header

                    if shop.plans.isEmpty {
                        if shop.plansState == .loading || shop.plansState == .idle {
                            ProgressView().padding(.vertical, 30)
                        } else {
                            StateBanner(state: shop.plansState) { Task { await shop.loadPlans() } }
                                .padding(.vertical, 20)
                        }
                    } else if case .failed = shop.plansState {
                        // Old prices stay on screen, but say they may be out of date.
                        StateBanner(state: shop.plansState) { Task { await shop.loadPlans() } }
                    }

                    ForEach(shop.plans) { plan in
                        Button { selectedID = plan.id } label: {
                            PlanRow(plan: plan, selected: plan.id == selected?.id)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        PerkRow(icon: "crown.fill", text: "Premium status on your account")
                        ForEach(shop.perks) { perk in PerkRow(icon: perk.icon, text: perk.text) }
                        PerkRow(icon: "plus.circle.fill", text: "Days stack if you buy more")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.top, 6)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Total").font(.caption).foregroundStyle(.secondary)
                    Text(selected?.priceText ?? "\u{2013}").font(.title2.bold())
                }
                Spacer()
                Button { showConfirm = true } label: {
                    HStack { Text("Buy Now"); Image(systemName: "cart") }
                        .font(.headline)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(selected == nil || !shop.cryptoEnabled || shop.plansState.isWorking && shop.plans.isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Color(white: 0.12))
        }
        .background(Color(white: 0.09).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task {
            await shop.loadPlans()
            await shop.reconcilePending()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { Task { await shop.reconcilePending(); await certs.refreshStatus() } }
        }
        .sheet(isPresented: $showConfirm, onDismiss: { Task { await certs.refreshStatus() } }) {
            if let plan = selected { PremiumConfirmView(plan: plan) }
        }
        .sheet(isPresented: $showHistory) { PurchaseHistoryView() }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Premium").font(.title.bold())
            if certs.server?.premiumActive == true {
                let d = certs.server?.premiumDaysLeft ?? 0
                Text("\(d) day\(d == 1 ? "" : "s") left").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("One-time payment in Litecoin, no subscription").font(.subheadline).foregroundStyle(.secondary)
                if !shop.cryptoEnabled { Text("Litecoin payments aren't available yet.").font(.footnote).foregroundStyle(.orange) }
            }
            Button { showHistory = true } label: {
                Label("Purchase history", systemImage: "clock.arrow.circlepath").font(.footnote)
            }
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }
}

private struct PlanRow: View {
    let plan: PremiumPlan
    let selected: Bool

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [.yellow, .orange, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 52, height: 52)
                .overlay(Image(systemName: "crown.fill").font(.title3).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(plan.days) days").font(.headline)
                Text("one-time, paid in LTC").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(plan.priceText)
                .font(.caption.weight(.bold)).foregroundStyle(.black)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.yellow, in: Capsule())
        }
        .padding(14)
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(selected
                              ? AnyShapeStyle(LinearGradient(colors: [.yellow, .orange, .purple], startPoint: .leading, endPoint: .trailing))
                              : AnyShapeStyle(Color.gray.opacity(0.25)),
                              lineWidth: selected ? 2 : 1)
        )
        .shadow(color: selected ? .orange.opacity(0.3) : .clear, radius: 12)
    }
}

private struct PerkRow: View {
    let icon: String
    let text: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundStyle(.green).frame(width: 28)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Step 2

struct PremiumConfirmView: View {
    let plan: PremiumPlan

    @ObservedObject private var shop = PremiumShop.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showInfo = false
    @State private var closeTask: Task<Void, Never>?

    // Replace with your real terms page.
    private let termsURL = URL(string: "https://airshare.lol/terms")!

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Capsule().fill(.gray.opacity(0.5)).frame(width: 36, height: 5).padding(.top, 4)

                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 52, height: 52)
                        .overlay(Image(systemName: "crown.fill").foregroundStyle(.white))
                    Text("Premium \u{00B7} \(plan.days) days").font(.headline)
                    Spacer()
                    Text(plan.priceText)
                        .font(.caption.weight(.bold)).foregroundStyle(.black)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.yellow, in: Capsule())
                }
                .payCard()

                Button { withAnimation { showInfo.toggle() } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "questionmark.diamond").font(.title2).foregroundStyle(.yellow)
                        Text("What do you need to know before paying").multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: showInfo ? "chevron.down" : "chevron.right").foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)
                    .payCard(stroke: .gray.opacity(0.4))
                }
                if showInfo {
                    // Edit this to match your real refund and support policy.
                    Text("Premium days are added to your account once your payment has enough confirmations (a few minutes) and stack on top of any days you already have. Payment is a one-time Litecoin transfer, not a subscription, and it can't be reversed once confirmed. Contact support if something looks wrong.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .payCard()
                }

                HStack(spacing: 10) {
                    Badge(text: "Litecoin \u{00B7} LTC", fg: .white, bg: Color(red: 0.2, green: 0.36, blue: 0.62))
                    Text("Paid on the Litecoin network").font(.footnote).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .payCard()

                HStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(.green)
                    Text("You pay from your own wallet, right here in the app. No card, no account with a payment company. The price is fixed in US dollars and quoted in LTC when you start.")
                        .font(.footnote)
                    Spacer(minLength: 0)
                }
                .payCard()

                actionArea

                VStack(spacing: 4) {
                    Text("By paying, you confirm that you accept the")
                    Link("Terms of service", destination: termsURL).bold()
                }
                .font(.footnote).padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Color(white: 0.09).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear { shop.beginVisit(planID: plan.id) }
        .onChange(of: shop.phase) { phase in
            // Close only once the server has confirmed payment. Anything else keeps this sheet up with an honest message.
            if phase == .confirmed {
                closeTask?.cancel()
                closeTask = Task {
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                    if !Task.isCancelled { dismiss() }
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { shop.foregrounded() }
        }
        .onDisappear { closeTask?.cancel(); shop.endVisit() }
    }

    @ViewBuilder
    private var actionArea: some View {
        switch shop.phase {
        case .awaiting:
            if let order = shop.order { LTCPayPanel(order: order, note: shop.watchNote) { shop.checkNow() } }

        case .confirmed:
            Label("Payment confirmed. Premium is active.", systemImage: "checkmark.seal.fill")
                .font(.headline).foregroundStyle(.green)
                .frame(maxWidth: .infinity).padding(.vertical, 12)

        case .expired:
            VStack(spacing: 10) {
                Label("This quote expired before a payment was seen.", systemImage: "clock.badge.exclamationmark.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.yellow)
                Text("If you already sent the coins, tap Check now. A payment that arrives late is reviewed by our team. Otherwise get a fresh quote.")
                    .font(.footnote).foregroundStyle(.secondary)
                actionButton("Check now", icon: "arrow.clockwise") { shop.checkNow() }
                Button("Get a new quote") { Task { await shop.startCheckout(plan) } }.font(.footnote)
            }

        case .needsReview:
            VStack(spacing: 10) {
                Label("We received a payment that needs a quick manual check.", systemImage: "person.fill.questionmark")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Text("It arrived after the quote expired or was less than the price. Contact support and mention order #\(shop.order?.orderID ?? 0); nothing is lost.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

        case let .failed(message):
            VStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
                actionButton("Try again", icon: "arrow.right.circle.fill") { Task { await shop.startCheckout(plan) } }
            }

        case .idle, .creating:
            actionButton("Pay with Litecoin", icon: "arrow.right.circle.fill", working: shop.phase == .creating) {
                Task { await shop.startCheckout(plan) }
            }
        }
    }

    private func actionButton(_ title: String, icon: String, working: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if working { ProgressView().tint(.black) } else { Image(systemName: icon) }
                Text(title)
            }
            .font(.headline).foregroundStyle(.black)
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
        }
        .disabled(working)
    }
}

private struct Badge: View {
    let text: String
    let fg: Color
    let bg: Color
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold)).foregroundStyle(fg)
            .padding(.horizontal, 8).padding(.vertical, 8)
            .background(bg, in: RoundedRectangle(cornerRadius: 6))
            .lineLimit(1).minimumScaleFactor(0.6)
    }
}
