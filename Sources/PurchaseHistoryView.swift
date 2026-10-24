import SwiftUI

/// Past premium purchases, plus a Restore button for "I paid but Premium isn't showing".
struct PurchaseHistoryView: View {
    @ObservedObject private var shop = PremiumShop.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await shop.restore() }
                    } label: {
                        HStack {
                            Label("Restore purchase", systemImage: "arrow.clockwise")
                            Spacer()
                            if shop.restoring { ProgressView() }
                        }
                    }
                    .disabled(shop.restoring)
                    if let m = shop.restoreMessage {
                        Text(m).font(.footnote).foregroundStyle(shop.restoreIsError ? .red : .secondary)
                    }
                } footer: {
                    Text("Paid but Premium isn't showing yet? Tap Restore and we'll check the Litecoin network for it.")
                }

                Section("Purchases") {
                    StateBanner(state: shop.purchasesState) { Task { await shop.loadPurchases() } }
                    if shop.purchases.isEmpty && shop.purchasesState == .loaded {
                        Text("No purchases yet.").foregroundStyle(.secondary)
                    }
                    ForEach(shop.purchases) { p in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name).font(.body.weight(.semibold))
                                if let d = p.date {
                                    Text(d.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(p.priceText).font(.body)
                                if let l = p.ltcText { Text(l).font(.caption2).foregroundStyle(.secondary) }
                                Text(p.statusText)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(color(for: p.status))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Purchase history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                shop.clearRestoreMessage()
                await shop.loadPurchases()
            }
            .refreshable { await shop.loadPurchases() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await shop.reconcilePending() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func color(for status: String) -> Color {
        switch status {
        case "paid": return .green
        case "pending", "seen": return .yellow
        case "refunded", "partially_refunded", "expired": return .gray
        default: return .orange
        }
    }
}
