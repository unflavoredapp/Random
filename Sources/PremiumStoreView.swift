import SwiftUI

/// Two-step premium checkout. Step 1: pick a length of premium. Step 2: review and pay on Stripe's page.
struct PremiumStoreView: View {
    @ObservedObject private var shop = PremiumShop.shared
    @ObservedObject private var certs = CertificateRequestClient.shared
    @State private var selectedID: String?
    @State private var showConfirm = false

    // Flip to true once the premium badge actually shows next to usernames, so the sheet only promises what exists.
    private let showsBadgePerk = false

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
                        if let e = shop.error {
                            Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
                        } else {
                            ProgressView().padding(.vertical, 30)
                        }
                    }

                    ForEach(shop.plans) { plan in
                        Button { selectedID = plan.id } label: {
                            PlanRow(plan: plan, selected: plan.id == selected?.id)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        PerkRow(icon: "crown.fill", text: "Premium status on your account")
                        if showsBadgePerk { PerkRow(icon: "checkmark.seal.fill", text: "Premium badge") }
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
                .disabled(selected == nil)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Color(white: 0.12))
        }
        .background(Color(white: 0.09).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await shop.loadPlans() }
        .sheet(isPresented: $showConfirm) {
            if let plan = selected { PremiumConfirmView(plan: plan) }
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            Text("Premium").font(.title.bold())
            if certs.server?.premiumActive == true {
                let d = certs.server?.premiumDaysLeft ?? 0
                Text("\(d) day\(d == 1 ? "" : "s") left").font(.subheadline).foregroundStyle(.secondary)
            } else {
                Text("One-time payment, no subscription").font(.subheadline).foregroundStyle(.secondary)
            }
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
                Text("one-time payment").font(.caption).foregroundStyle(.secondary)
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
            Text(text)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Step 2

struct PremiumConfirmView: View {
    let plan: PremiumPlan

    @ObservedObject private var shop = PremiumShop.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showInfo = false

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
                .card()

                Button { withAnimation { showInfo.toggle() } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "questionmark.diamond").font(.title2).foregroundStyle(.yellow)
                        Text("What do you need to know before paying").multilineTextAlignment(.leading)
                        Spacer()
                        Image(systemName: showInfo ? "chevron.down" : "chevron.right").foregroundStyle(.secondary)
                    }
                    .foregroundStyle(.white)
                    .card(stroke: .gray.opacity(0.4))
                }
                if showInfo {
                    // Edit this to match your real refund and support policy.
                    Text("Premium days are added to your account right after payment and stack on top of any days you already have. Payment is a one-time charge, not a subscription. Contact support if something looks wrong.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card()
                }

                HStack(spacing: 10) {
                    Image(systemName: "largecircle.fill.circle").foregroundStyle(.white)
                    Badge(text: "Apple Pay", fg: .black, bg: .white)
                    Badge(text: "Mastercard", fg: .white, bg: Color(red: 0.8, green: 0.2, blue: 0.2))
                    Badge(text: "VISA", fg: .white, bg: Color(red: 0.1, green: 0.2, blue: 0.6))
                    Badge(text: "AMEX", fg: .white, bg: Color(red: 0.2, green: 0.45, blue: 0.75))
                    Spacer(minLength: 0)
                }
                .card()

                HStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill").font(.title2).foregroundStyle(.green)
                    Text("You'll pay on a secure Stripe page. Your card details never pass through AirShare.")
                        .font(.footnote)
                    Spacer(minLength: 0)
                }
                .card()

                Button { Task { await shop.startCheckout(plan) } } label: {
                    HStack {
                        if shop.busy { ProgressView().tint(.black) } else { Image(systemName: "arrow.right.circle.fill") }
                        Text("Purchase")
                    }
                    .font(.headline).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(.white, in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(shop.busy)

                if let e = shop.error {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.footnote)
                }

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
        .fullScreenCover(item: $shop.page, onDismiss: {
            Task {
                await shop.refreshAfterPurchase()
                dismiss()
            }
        }) { page in
            SafariView(url: page.url).ignoresSafeArea()
        }
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

private extension View {
    func card(stroke: Color? = nil) -> some View {
        self.padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                if let stroke { RoundedRectangle(cornerRadius: 18).strokeBorder(stroke, lineWidth: 1) }
            }
    }
}
