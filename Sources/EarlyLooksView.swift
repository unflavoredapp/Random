import SwiftUI

/// Posts about what's coming. Premium members see them before they go public.
struct EarlyLooksView: View {
    @ObservedObject private var early = EarlyClient.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPremium = false

    var body: some View {
        NavigationStack {
            List {
                if early.locked > 0 && !early.isPremium {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("\(early.locked) early look\(early.locked == 1 ? "" : "s") waiting", systemImage: "sparkles")
                                .font(.headline)
                            Text("Premium members see new features before they go public.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("Get Premium") { showPremium = true }.buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    StateBanner(state: early.state) { Task { await early.load() } }
                    if early.state == .loaded && early.posts.isEmpty {
                        Text("Nothing here yet.").foregroundStyle(.secondary)
                    }
                    ForEach(early.posts) { p in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(p.title).font(.headline)
                                if p.early {
                                    Text("EARLY").font(.caption2.weight(.heavy)).foregroundStyle(.black)
                                        .padding(.horizontal, 6).padding(.vertical, 2).background(.yellow, in: Capsule())
                                }
                            }
                            if p.early, let d = AirShareAPI.date(p.publicAt) {
                                Text("Public on \(d.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text(p.body).font(.subheadline)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    if early.state == .refreshing { ProgressView().controlSize(.mini) }
                }
            }
            .navigationTitle("Early looks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await early.load() }
            .refreshable { await early.load() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await early.refreshIfStale() } }
            }
            // Buying (or backing out of) Premium changes what the server sends, so always reload afterwards.
            .sheet(isPresented: $showPremium, onDismiss: { Task { await early.load() } }) { PremiumStoreView() }
        }
        .preferredColorScheme(.dark)
    }
}
