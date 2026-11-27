//
// Brand: Tetherless · https://tetherless.dev
//  DecryptCompanionConsole.swift
//  FairPlayed-style companion decrypt UI — shown only by the installed
//  “FastDecryptBot” companion IPA (`DecryptCompanionRoot`), not as a
//  host fullScreenCover.
//

import Combine
import UIKit
#if !DECRYPT_HELPER
import SwiftUI
#endif

/// Compact markdown-ish companion log helpers (headers, bullets, dedupe).
enum DecryptCompanionLog {
    static func normalize(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\t", with: " ")
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Key used to detect semantic duplicates across bootstrap ↔ decrypt.
    static func dedupeKey(_ line: String) -> String {
        var s = normalize(line).lowercased()
        if s.hasPrefix("## ") { s = String(s.dropFirst(3)) }
        if s.hasPrefix("- ") { s = String(s.dropFirst(2)) }
        // Collapse common label aliases that used to double-print.
        let aliases: [(String, String)] = [
            ("target bid ·", "bid:"),
            ("bid ·", "bid:"),
            ("preflight live ·", "live:"),
            ("stamped live install path (hint):", "live:"),
            ("stamped live install path:", "live:"),
            ("host-stamped live path (hint):", "live:"),
            ("fairplay read root · embeddedpayload:", "source: embeddedpayload"),
            ("fairplay read root · live install:", "source: live"),
            ("found embedded app:", "target:"),
            ("fastdecryptbot ·", "target:"),
        ]
        for (from, to) in aliases {
            if s.hasPrefix(from) {
                s = to + s.dropFirst(from.count)
                break
            }
        }
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        if s.hasSuffix(".") { s = String(s.dropLast()) }
        return s
    }

    static func isDuplicate(_ a: String, _ b: String) -> Bool {
        dedupeKey(a) == dedupeKey(b)
    }

    static func isRecentDuplicate(_ line: String, in lines: [String], window: Int = 24) -> Bool {
        let key = dedupeKey(line)
        guard !key.isEmpty else { return false }
        // Always allow progress / per-file / mem heartbeats through.
        if line.hasPrefix("[") || line.hasPrefix("Decrypting ") || line.contains(" · free ") {
            return false
        }
        if line.hasPrefix("## ") { return false }
        for prev in lines.suffix(window) where dedupeKey(prev) == key {
            return true
        }
        return false
    }

    /// Plain display text (strip light markdown markers for status / UIKit fallback).
    static func plain(_ line: String) -> String {
        var s = line
        if s.hasPrefix("## ") { s = String(s.dropFirst(3)) }
        s = s.replacingOccurrences(of: "**", with: "")
        // Italic markers used for soft notes: _(none)_
        // Copy the inner Substring before mutating `s` (exclusive access).
        while let open = s.range(of: "_("),
              let close = s.range(of: ")_", range: open.upperBound..<s.endIndex) {
            let inner = String(s[open.upperBound..<close.lowerBound])
            s.replaceSubrange(open.lowerBound..<close.upperBound, with: "(\(inner))")
        }
        return s
    }
}

@MainActor
final class DecryptCompanionController: ObservableObject {
    static let shared = DecryptCompanionController()

    @Published var isPresented = false
    @Published var displayName = ""
    @Published var version = ""
    @Published var iconURL: URL?
    @Published var iconImage: UIImage?
    @Published var logLines: [String] = []
    @Published var busy = false
    @Published var done = false
    @Published var finishedURL: URL?
    @Published var statusTitle = "Ready"
    /// Last FairPlay verify_ipa summary (e.g. "12 cryptid=0 · 0 encrypted · 3 no LC_ENCRYPTION").
    @Published var verifySummary = ""
    /// True when the clear IPA was copied into the App Group for the host to import.
    @Published var exportSentToHost = false

    private init() {}

    func present(
        name: String,
        version: String = "",
        icon: URL? = nil,
        iconImage: UIImage? = nil,
        clearLog: Bool = true
    ) {
        displayName = name
        self.version = version
        iconURL = icon
        self.iconImage = iconImage
        if clearLog { logLines = [] }
        busy = true
        done = false
        finishedURL = nil
        verifySummary = ""
        exportSentToHost = false
        statusTitle = "Decrypting…"
        isPresented = true
    }

    func appendLog(_ line: String) {
        let trimmed = DecryptCompanionLog.normalize(line)
        guard !trimmed.isEmpty else { return }
        // Drop exact / near-duplicate consecutive lines (bootstrap ↔ decrypt overlap).
        if let last = logLines.last, DecryptCompanionLog.isDuplicate(last, trimmed) {
            return
        }
        // Also skip if the same bullet already appears in the recent window.
        if DecryptCompanionLog.isRecentDuplicate(trimmed, in: logLines) {
            return
        }
        logLines.append(trimmed)
        // Keep memory bounded on huge framework trees.
        if logLines.count > 400 {
            logLines.removeFirst(logLines.count - 400)
        }
        // Don't clobber a finished status with mid-run log chatter.
        if done { return }
        if trimmed.hasPrefix("[DECRYPTED]") || trimmed.hasPrefix("[plain]") || trimmed.hasPrefix("[FAILED]") {
            statusTitle = "Decrypting…"
        } else if trimmed.localizedCaseInsensitiveContains("DRM audit")
                    || trimmed.hasPrefix("[BEFORE")
                    || trimmed.hasPrefix("[AFTER")
                    || trimmed.hasPrefix("[IPA") {
            statusTitle = "Verifying DRM…"
        } else if trimmed.localizedCaseInsensitiveContains("packaging")
                    || trimmed.hasPrefix("## Package") {
            statusTitle = "Packaging…"
        } else if trimmed.hasPrefix("VERIFY OK") {
            statusTitle = "Verified clear"
        } else if trimmed.localizedCaseInsensitiveContains("wrote") || trimmed.hasPrefix("Done:") {
            statusTitle = "Done"
        } else if trimmed.hasPrefix("## ") {
            let title = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { statusTitle = title }
        } else if trimmed.count < 80, !trimmed.hasPrefix("- ") {
            statusTitle = trimmed
        }
    }

    func markFinished(url: URL?, name: String) {
        busy = false
        done = true
        finishedURL = url
        if !name.isEmpty { displayName = name }
        if !verifySummary.isEmpty {
            statusTitle = "Verified · \(verifySummary)"
        } else {
            statusTitle = url == nil ? "Failed" : "Done"
        }
        // Runtime already logs the IPA name — don't append a second "Wrote …" line.
    }

    func markFailed(_ message: String) {
        busy = false
        done = false
        statusTitle = "Failed"
        appendLog("**ERROR:** \(message)")
    }

    func dismiss() {
        isPresented = false
    }
}

#if !DECRYPT_HELPER
/// Full-screen companion console for FastDecryptBot (host / fat-shell path).
/// DecryptHelper uses UIKit `DecryptCompanionConsoleViewController` instead.
struct DecryptCompanionConsole: View {
    @ObservedObject private var companion = DecryptCompanionController.shared
    @ObservedObject private var client = DecryptClient.shared
    /// Host sheet can dismiss; the installed companion app should not.
    var showsDismiss: Bool = true
    @Binding var shareURL: URL?

    init(showsDismiss: Bool = true, shareURL: Binding<URL?> = .constant(nil)) {
        self.showsDismiss = showsDismiss
        self._shareURL = shareURL
    }

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

            VStack(spacing: 0) {
                header
                appCard
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                statusPill
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                if companion.done, companion.finishedURL != nil {
                    exportActions
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
                console
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .onChange(of: client.message) { msg in
            // Mirror DecryptClient progress into the companion log when presented.
            guard companion.isPresented, !msg.isEmpty else { return }
            if companion.logLines.last != msg {
                companion.appendLog(msg)
            }
        }
    }

    private var header: some View {
        ZStack {
            // Center: always FastDecryptBot brand (target name/icon live in the app card).
            HStack(spacing: 8) {
                Group {
                    if let brand = Self.companionBrandIcon() {
                        Image(uiImage: brand)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "bolt.shield.fill")
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(Color(red: 0.95, green: 0.2, blue: 0.22))
                            .padding(4)
                    }
                }
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text(DecryptCompanionIdentity.companionDisplayName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                if showsDismiss {
                    Button {
                        companion.dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)

                if companion.done, companion.finishedURL != nil {
                    Button {
                        shareURL = companion.finishedURL
                    } label: {
                        Image(systemName: "square.and.arrow.up.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                } else {
                    // Keep layout balanced when share isn’t shown.
                    Color.clear.frame(width: 22, height: 22)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 56)
        .padding(.bottom, 8)
    }

    private var appCard: some View {
        HStack(spacing: 14) {
            targetAppIcon
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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

    @ViewBuilder
    private var targetAppIcon: some View {
        if let img = companion.iconImage {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else if let icon = companion.iconURL {
            AsyncImage(url: icon) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    placeholderIcon
                }
            }
        } else {
            placeholderIcon
        }
    }

    private var placeholderIcon: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.08))
            .overlay {
                Image(systemName: "app.fill")
                    .font(.title2)
                    .foregroundStyle(.white.opacity(0.45))
            }
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

    private var exportActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if companion.exportSentToHost {
                Text("Clear IPA sent to AppAssassin. Switch back for Sign → Install.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    DecryptCompanionHandoff.openHostForClearIPAImport()
                } label: {
                    Text("Open AppAssassin")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
            } else {
                Text("App Group isn’t available on this certificate — Share the IPA and choose Open in AppAssassin.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                shareURL = companion.finishedURL
            } label: {
                Text(companion.exportSentToHost ? "Share copy…" : "Share IPA with AppAssassin")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(TetherlessPalette.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var console: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(companion.logLines.enumerated()), id: \.offset) { i, line in
                        logRow(line)
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

    @ViewBuilder
    private func logRow(_ line: String) -> some View {
        if line.hasPrefix("## ") {
            Text(DecryptCompanionLog.plain(line))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.cyan.opacity(0.95))
                .padding(.top, 4)
        } else if line.hasPrefix("- ") {
            Text(DecryptCompanionLog.plain(line))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.72))
        } else if line.hasPrefix("**ERROR:**") || line.hasPrefix("ERROR:") {
            Text(DecryptCompanionLog.plain(line))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.orange)
        } else {
            Text(DecryptCompanionLog.plain(line))
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(color(for: line))
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("[DECRYPTED]") || line.hasPrefix("[AFTER CLEAR]") || line.hasPrefix("[IPA CLEAR]") {
            return Color.green.opacity(0.95)
        }
        if line.hasPrefix("[BEFORE DRM]") || line.hasPrefix("[DRM]") {
            return Color.orange.opacity(0.95)
        }
        if line.hasPrefix("VERIFY OK") { return Color.green }
        if line.hasPrefix("[plain]") { return Color.white.opacity(0.55) }
        if line.hasPrefix("[FAILED]") || line.hasPrefix("ERROR:") || line.hasPrefix("**ERROR:**") {
            return Color.orange
        }
        if line.hasPrefix("Done:") || line.hasPrefix("Wrote ") || line.hasPrefix("[BEFORE]")
            || line.hasPrefix("[AFTER]") || line.hasPrefix("[IPA]") {
            return Color.cyan.opacity(0.9)
        }
        return Color.white.opacity(0.78)
    }

    /// Companion ships flat PNGs (no Assets.car) — `Image(named:)` misses them.
    private static func companionBrandIcon() -> UIImage? {
        if let named = UIImage(named: DecryptCompanionIdentity.companionIconAsset) { return named }
        let bundle = Bundle.main.bundleURL
        let candidates = [
            "AppIcon60x60@3x.png",
            "AppIcon60x60@2x.png",
            "AppIcon76x76@2x~ipad.png",
            "iTunesArtwork@2x",
            "iTunesArtwork",
        ]
        for name in candidates {
            let url = bundle.appendingPathComponent(name)
            if let img = UIImage(contentsOfFile: url.path) { return img }
        }
        return TetherlessBrand.appIconImage()
    }
}
#endif
