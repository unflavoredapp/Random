//
//  DecryptCompanionRuntime.swift
//  When this process is the installed “Tetherless Decrypt” companion (cloned
//  binary + EmbeddedPayload), run FairPlayed-style export and write the clear IPA
//  into the shared Documents/Decrypted folder for the host app to pick up.
//

import Foundation
import SwiftUI
import UIKit
import ZIPFoundation

@MainActor
enum DecryptCompanionRuntime {
    /// True when Info.plist says we're the companion role, or EmbeddedPayload exists.
    static var isCompanionProcess: Bool {
        if Bundle.main.object(forInfoDictionaryKey: "TLCompanionRole") as? Bool == true {
            return true
        }
        if Bundle.main.bundleIdentifier?.hasSuffix(".decrypt") == true {
            return true
        }
        let embed = Bundle.main.bundleURL.appendingPathComponent("EmbeddedPayload", isDirectory: true)
        return FileManager.default.fileExists(atPath: embed.path)
    }

    static var embeddedPayloadRoot: URL {
        Bundle.main.bundleURL.appendingPathComponent("EmbeddedPayload", isDirectory: true)
    }

    static func embeddedAppName() -> String? {
        let root = embeddedPayloadRoot
        let man = root.appendingPathComponent("manifest.plist")
        if let plist = NSDictionary(contentsOf: man) as? [String: Any],
           let name = plist["name"] as? String, !name.isEmpty {
            return name
        }
        let kids = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return kids.first(where: {
            ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
                && $0.lastPathComponent != "Watch"
        })?.lastPathComponent
    }

    /// FairPlayed `embeddedExport`: decrypt Mach-Os from EmbeddedPayload into a Payload copy, zip IPA.
    static func runEmbeddedDecrypt(progress: ((String) -> Void)? = nil) async throws -> URL {
        let fm = FileManager.default
        guard let name = embeddedAppName() else {
            throw DecryptError("No EmbeddedPayload in Tetherless Decrypt — reinstall the companion from TetherLess.")
        }
        let src = embeddedPayloadRoot.appendingPathComponent(name, isDirectory: true)
        guard fm.fileExists(atPath: src.path) else {
            throw DecryptError("EmbeddedPayload/\(name) missing.")
        }

        progress?("Found embedded app: \(name)")
        DecryptCompanionController.shared.present(name: name, clearLog: true)
        DecryptCompanionController.shared.appendLog("Found embedded app: \(name)")

        let work = fm.temporaryDirectory.appendingPathComponent("tl-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        let payload = work.appendingPathComponent("Payload", isDirectory: true)
        let destApp = payload.appendingPathComponent("\(name).app", isDirectory: true)
        try fm.createDirectory(at: destApp, withIntermediateDirectories: true)

        progress?("Copying app bundle…")
        DecryptCompanionController.shared.appendLog("Copying app bundle…")
        // Copy whatever was embedded (already slim) as the writable Payload tree.
        if let en = fm.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let item as URL in en {
                let vals = try? item.resourceValues(forKeys: [.isDirectoryKey])
                let rel: String = {
                    let prefix = src.path.hasSuffix("/") ? src.path : src.path + "/"
                    return item.path.hasPrefix(prefix) ? String(item.path.dropFirst(prefix.count)) : item.lastPathComponent
                }()
                let out = destApp.appendingPathComponent(rel)
                if vals?.isDirectory == true {
                    try? fm.createDirectory(at: out, withIntermediateDirectories: true)
                } else {
                    try? fm.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? fm.removeItem(at: out)
                    try? fm.copyItem(at: item, to: out)
                }
            }
        }

        // Decrypt FROM embedded (live bundle path — fairplayd can read SC_Info here)
        // INTO the writable Payload copy — FairPlayed embeddedExport contract.
        let report = try FairPlayDecrypt.decryptMachOs(
            readingFrom: src,
            writingTo: destApp
        ) { msg in
            progress?(msg)
            Task { @MainActor in DecryptCompanionController.shared.appendLog(msg) }
        }
        let decN = report.decrypted.count
        let plainN = report.plain.count
        let summary = "Done: \(decN) decrypted, \(plainN) already plain."
        progress?(summary)
        DecryptCompanionController.shared.appendLog(summary)

        progress?("Packaging \(name)-decrypted.ipa…")
        DecryptCompanionController.shared.appendLog("Packaging \(name)-decrypted.ipa…")

        // Harden (strip SC_Info from clear IPA) then zip into Documents/Decrypted.
        var mutable = report
        // Use FairPlayDecrypt's public IPA path via a temp zip of payload.
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let outDir = docs.appendingPathComponent("Decrypted", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        let outIPA = outDir.appendingPathComponent("\(name)-decrypted.ipa")
        try? fm.removeItem(at: outIPA)

        // Strip SC_Info from dest before zip (clear IPA shouldn't carry licenses).
        try? fm.removeItem(at: destApp.appendingPathComponent("SC_Info"))
        if let en = fm.enumerator(at: destApp, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let item as URL in en where item.lastPathComponent == "SC_Info" {
                try? fm.removeItem(at: item)
            }
        }
        _ = mutable

        let tmpZip = outIPA.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmpZip)
        try fm.zipItem(at: payload, to: tmpZip, shouldKeepParent: true, compressionMethod: .deflate)
        try fm.moveItem(at: tmpZip, to: outIPA)

        DecryptCompanionController.shared.markFinished(url: outIPA, name: name)
        progress?("Wrote \(outIPA.lastPathComponent).")
        DecryptCompanionController.shared.appendLog(
            "IPA is in this companion’s Documents/Decrypted (separate sandbox from TetherLess). Use Share to save or AirDrop."
        )
        return outIPA
    }
}

/// Root scene when the cloned binary is running as the companion app.
struct DecryptCompanionRoot: View {
    @ObservedObject private var companion = DecryptCompanionController.shared
    @State private var errorText: String?
    @State private var shareURL: URL?

    var body: some View {
        DecryptCompanionConsole(showsDismiss: false, shareURL: $shareURL)
            .task {
                companion.present(name: DecryptCompanionRuntime.embeddedAppName() ?? "App", clearLog: true)
                do {
                    let url = try await DecryptCompanionRuntime.runEmbeddedDecrypt()
                    shareURL = url
                } catch {
                    errorText = error.localizedDescription
                    companion.markFailed(error.localizedDescription)
                }
            }
            .sheet(item: Binding(
                get: { shareURL.map { ShareItem(url: $0) } },
                set: { shareURL = $0?.url }
            )) { item in
                ShareSheet(items: [item.url])
            }
            .alert("Decrypt failed", isPresented: Binding(
                get: { errorText != nil },
                set: { if !$0 { errorText = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorText ?? "")
            }
    }
}

private struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.path }
}
