//
//  BetaBuildManager.swift
//  Lets a beta-group member pick which detected beta builds actually get pinned/badged in Browse —
//  without this, every third-party app whose name or bundle happens to contain "beta" floods the top
//  of the grid for every member. Server-flagged builds (the ones actually distributed as closed beta)
//  are marked so they're never confused with heuristic matches from unrelated repos.
//

import SwiftUI

struct BetaBuildManager: View {
    let groups: [AppGroup]
    @State var hidden: Set<String>
    let setHidden: (Set<String>) -> Void
    @Environment(\.dismiss) private var dismiss

    init(groups: [AppGroup], hidden: Set<String>, setHidden: @escaping (Set<String>) -> Void) {
        self.groups = groups
        self._hidden = State(initialValue: hidden)
        self.setHidden = setHidden
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text("Every build detected as beta (flagged by the repo, or by name/bundle) is listed here. Turn one off to stop it from being pinned to the top and badged BETA in Browse — it stays in the catalog as a normal app.")
                        .font(.system(size: 13)).foregroundStyle(Theme.subtle)
                        .listRowBackground(Color.clear)
                }
                Section {
                    ForEach(groups) { g in
                        let app = g.latest
                        HStack(spacing: 12) {
                            SourceIcon(url: app.iconURL, side: 36, fallback: app.name)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(app.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                                    if app.beta {
                                        Text("CLOSED BETA").font(.system(size: 9, weight: .heavy, design: .monospaced))
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(Theme.accent.opacity(0.18)).foregroundStyle(Theme.accent).clipShape(Capsule())
                                    }
                                }
                                Text(g.bundle).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.subtle).lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { !hidden.contains(g.bundle) },
                                set: { shown in
                                    if shown { hidden.remove(g.bundle) } else { hidden.insert(g.bundle) }
                                    setHidden(hidden)
                                }
                            )).labelsHidden()
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(Color.black)
                    }
                } header: {
                    Text("\(groups.count) beta build\(groups.count == 1 ? "" : "s") detected")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Manage Beta Builds")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
