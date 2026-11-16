//
// Brand: Tetherless · https://tetherless.dev
//  IPadnPriceViews.swift
//  English multi-region price comparison — mengangs/ipadn PriceViews (GPL-2.0).
//

import SwiftUI

struct IPadnRegionPrice: Identifiable, Hashable {
    var country: String
    var price: Double?
    var currency: String
    var formatted: String
    var id: String { country }
}

enum IPadnExchangeRates {
    static func load(base: String) async -> [String: Double] {
        // Frankfurter free API — same approach as many clients.
        let url = URL(string: "https://api.frankfurter.app/latest?from=\(base)")!
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rates = json["rates"] as? [String: Double] else {
            return [base: 1]
        }
        var out = rates
        out[base] = 1
        return out
    }

    static func convert(_ amount: Double, from: String, to: String, rates: [String: Double]) -> Double? {
        guard rates[to] != nil, let fromRate = rates[from], fromRate > 0 else { return nil }
        // rates are relative to `to` base when loaded with from=base... Frankfurter returns rates for converting FROM base TO others.
        // If base is `to`, amount in `from` = amount / rates[from] when rates keyed as base→currency... 
        // We load with from=base(=to), so 1 base = rates[currency] of that currency.
        // amount_in_base = amount_in_from / rates[from] if from!=base; if from==base, amount.
        if from == to { return amount }
        if let r = rates[from], r > 0 {
            // rates[from] means 1 base = r from-currency, so amount from → base = amount/r
            let inBase = amount / r
            return inBase
        }
        return nil
    }
}

struct IPadnRegionPriceView: View {
    let app: IPadnStoreApp
    @AppStorage("tetherless.priceBaseCurrency") private var baseCurrency = "USD"
    @AppStorage("tetherless.priceRegions") private var regionsRaw = "US,NG,TR,PH,KR,JP,HK"
    @State private var prices: [IPadnRegionPrice] = []
    @State private var rates: [String: Double] = [:]
    @State private var loading = true
    @State private var editingRegions = false

    private var regions: [String] {
        regionsRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { !$0.isEmpty }
    }

    private var sorted: [IPadnRegionPrice] {
        prices.sorted { a, b in
            let ca = converted(a) ?? .infinity
            let cb = converted(b) ?? .infinity
            return ca < cb
        }
    }

    private var cheapest: String? {
        sorted.first(where: { converted($0) != nil })?.country
    }

    var body: some View {
        List {
            Section {
                if loading && prices.isEmpty {
                    ProgressView("Loading prices…")
                } else if prices.isEmpty {
                    Text("Couldn’t read prices. Pull to refresh.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sorted) { item in
                    HStack(spacing: 12) {
                        Text(flag(item.country))
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(regionName(item.country))
                                    .font(.body.weight(.medium))
                                if item.country == cheapest {
                                    Text("Lowest")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.green, in: Capsule())
                                }
                            }
                            Text(item.formatted.isEmpty ? "—" : item.formatted)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let c = converted(item) {
                            Text("≈ \(format(c, currency: baseCurrency))")
                                .font(.body.weight(.semibold))
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("App price")
            } footer: {
                Text("Prices are sorted low to high after conversion to \(baseCurrency).")
            }
        }
        .navigationTitle("Multi-region Prices")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Convert to", selection: $baseCurrency) {
                        ForEach(["USD", "CNY", "HKD", "EUR", "GBP", "JPY", "KRW", "TRY", "AUD", "CAD"], id: \.self) {
                            Text($0).tag($0)
                        }
                    }
                    Button("Choose regions", systemImage: "globe") { editingRegions = true }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
            }
        }
        .task(id: "\(baseCurrency)|\(regionsRaw)") { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $editingRegions) {
            NavigationStack {
                List {
                    ForEach(["US", "GB", "DE", "FR", "JP", "KR", "CN", "HK", "TW", "TR", "NG", "PH", "IN", "BR", "AU", "CA"], id: \.self) { code in
                        Button {
                            toggle(code)
                        } label: {
                            HStack {
                                Text("\(flag(code))  \(regionName(code))")
                                Spacer()
                                if regions.contains(code) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(TetherlessPalette.accent)
                                }
                            }
                        }
                    }
                }
                .navigationTitle("Regions to compare")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { editingRegions = false }
                    }
                }
            }
        }
    }

    private func converted(_ item: IPadnRegionPrice) -> Double? {
        guard let price = item.price, price > 0 else { return nil }
        return IPadnExchangeRates.convert(price, from: item.currency, to: baseCurrency, rates: rates)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        rates = await IPadnExchangeRates.load(base: baseCurrency)
        // Capture off MainActor before nonisolated TaskGroup work (Swift 6).
        let currencyBase = baseCurrency
        var out: [IPadnRegionPrice] = []
        await withTaskGroup(of: IPadnRegionPrice?.self) { group in
            for code in regions {
                group.addTask {
                    guard let listing = try? await IPadnStoreClient.lookupPublic(id: app.id, country: code) else {
                        return IPadnRegionPrice(country: code, price: nil, currency: "", formatted: "Unavailable")
                    }
                    return IPadnRegionPrice(
                        country: code,
                        price: listing.priceValue,
                        currency: listing.currency ?? currencyBase,
                        formatted: listing.isFree ? "Free" : (listing.price.isEmpty ? "—" : listing.price)
                    )
                }
            }
            for await item in group {
                if let item { out.append(item) }
            }
        }
        prices = out
    }

    private func toggle(_ code: String) {
        var set = Set(regions)
        if set.contains(code) { set.remove(code) } else { set.insert(code) }
        regionsRaw = set.sorted().joined(separator: ",")
    }

    private func format(_ value: Double, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    private func regionName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    private func flag(_ code: String) -> String {
        let base: UInt32 = 127397
        var s = ""
        for v in code.uppercased().unicodeScalars {
            if let scalar = UnicodeScalar(base + v.value) { s.unicodeScalars.append(scalar) }
        }
        return s
    }
}
