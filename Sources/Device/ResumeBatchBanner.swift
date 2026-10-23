//
//  ResumeBatchBanner.swift
//  If iOS killed AirShare in the middle of a batch install or uninstall, offer to carry on where it stopped.
//

import SwiftUI

struct ResumeBatchBanner: View {
    @ObservedObject private var installs = NativeBatchInstaller.shared
    @ObservedObject private var removals = NativeBatchUninstaller.shared
    @State private var installPending: [SignedEntry] = []
    @State private var removePending: [DeviceApp] = []

    private var idle: Bool { !installs.isRunning && !removals.isRunning && !NativeInstaller.shared.isActive }

    var body: some View {
        VStack(spacing: 8) {
            if idle, !installPending.isEmpty {
                card(title: "Finish installing \(installPending.count) app\(installPending.count == 1 ? "" : "s")?",
                     detail: installPending.prefix(3).map(\.name).joined(separator: ", "),
                     resume: { installs.resumePending(); refresh() },
                     discard: { NativeBatchInstaller.discardPending(); refresh() })
            }
            if idle, !removePending.isEmpty {
                card(title: "Finish uninstalling \(removePending.count) app\(removePending.count == 1 ? "" : "s")?",
                     detail: removePending.prefix(3).map(\.name).joined(separator: ", "),
                     resume: { removals.resumePending(); refresh() },
                     discard: { NativeBatchUninstaller.discardPending(); refresh() })
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: installs.isRunning) { _ in refresh() }
        .onChange(of: removals.isRunning) { _ in refresh() }
    }

    private func refresh() {
        installPending = NativeBatchInstaller.pendingEntries
        removePending = NativeBatchUninstaller.pendingApps
    }

    private func card(title: String, detail: String, resume: @escaping () -> Void, discard: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.text).lineLimit(1)
                Text("AirShare was closed mid-batch · \(detail)").font(.system(size: 11)).foregroundStyle(Theme.subtle).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("Resume", action: resume).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.accent)
            Button(action: discard) { Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.subtle) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.accent.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 16)
    }
}
