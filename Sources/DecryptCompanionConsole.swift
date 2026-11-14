//
//  DecryptCompanionConsole.swift
//  FairPlayed-style companion decrypt UI (competition handoff).
//  Live console with [DECRYPTED] / [plain] lines; opened from Decrypt or
//  via tetherless-decrypt:// URL after download/install prep.
//

import SwiftUI

@MainActor
final class DecryptCompanionController: ObservableObject {
    static let shared = DecryptCompanionController()

    @Published var isPresented = false
    @Published var displayName = ""
    @Published var version = ""
    @Published var iconURL: URL?
    @Published var logLines: [String] = []
    @Published var busy = false
    @Published var done = false
    @Published var finishedURL: URL?
    @Published var statusTitle = "Ready"

    private init() {}

    func present(
        name: String,
        version: String = "",
        icon: URL? = nil,
        clearLog: Bool = true
    ) {
        displayName = name
        self.version = version
        iconURL = icon
        if clearLog { logLines = [] }
        busy = true
        done = false
        finishedURL = nil
        statusTitle = "Decrypting…"
        isPresented = true
    }

    func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logLines.append(trimmed)
        // Keep memory bounded on huge framework trees.
        if logLines.count > 400 {
            logLines.removeFirst(logLines.count - 400)
        }
        if trimmed.hasPrefix("[DECRYPTED]") || trimmed.hasPrefix("[plain]") || trimmed.hasPrefix("[FAILED]") {
            statusTitle = "Decrypting…"
        } else if trimmed.localizedCaseInsensitiveContains("packaging") {
            statusTitle = "Packaging…"
        } else if trimmed.localizedCaseInsensitiveContains("wrote") || trimmed.hasPrefix("Done:") {
            statusTitle = "Done"
        } else if trimmed.count < 80 {
            statusTitle = trimmed
        }
    }

    func markFinished(url: URL?, name: String) {
        busy = false
        done = true
        finishedURL = url
        if !name.isEmpty { displayName = name }
        statusTitle = url == nil ? "Failed" : "Done — saving automatically…"
        if let url {
            appendLog("Wrote \(url.lastPathComponent).")
        }
    }

    func markFailed(_ message: String) {
        busy = false
        done = false
        statusTitle = "Failed"
        appendLog("ERROR: \(message)")
    }

    func dismiss() {
        isPresented = false
    }
}

/// Full-screen companion console matching FairPlayed / competition “Tetherless Decrypt”.
struct DecryptCompanionConsole: View {
    @ObservedObject private var companion = DecryptCompanionController.shared
    @ObservedObject private var client = DecryptClient.shared

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.07, green: 0.09, blue: 0.14),
                    Color(red: 0.05, green: 0.07, blue: 0.12),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                appCard
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                statusPill
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                console
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: client.message) { msg in
            // Mirror DecryptClient progress into the companion log when presented.
            guard companion.isPresented, !msg.isEmpty else { return }
            if companion.logLines.last != msg {
                companion.appendLog(msg)
            }
        }
    }

    private var header: some View {
        HStack {
            Button {
                companion.dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            Spacer()
            Text("Tetherless Decrypt")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            // Balance the close button.
            Image(systemName: "xmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.clear)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var appCard: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(width: 56, height: 56)
                .overlay {
                    if let icon = companion.iconURL {
                        AsyncImage(url: icon) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            default:
                                Image(systemName: "app.fill")
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        Image(systemName: "app.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(companion.displayName.isEmpty ? "App" : companion.displayName)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !companion.version.isEmpty {
                    Text("Version \(companion.version)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var statusPill: some View {
        HStack(spacing: 10) {
            if companion.busy {
                ProgressView()
                    .tint(TetherlessPalette.accent)
            } else if companion.done, companion.finishedURL != nil {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "lock.open.fill")
                    .foregroundStyle(TetherlessPalette.accent)
            }
            Text(companion.statusTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            companion.done && companion.finishedURL != nil
                ? Color.green.opacity(0.22)
                : Color.white.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(companion.logLines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(color(for: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(12)
            }
            .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onChange(of: companion.logLines.count) { _ in
                if let last = companion.logLines.indices.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("[DECRYPTED]") { return Color.green.opacity(0.95) }
        if line.hasPrefix("[plain]") { return Color.white.opacity(0.55) }
        if line.hasPrefix("[FAILED]") || line.hasPrefix("ERROR:") { return Color.orange }
        if line.hasPrefix("Done:") || line.hasPrefix("Wrote ") { return Color.cyan.opacity(0.9) }
        return Color.white.opacity(0.78)
    }
}
