//
//  CertificateImport.swift
//  Helpers for the Certificates screen: sorting picked files (or a .zip) into certificate / profile /
//  password, exporting a certificate as a re-importable .zip, and the certificate badge picture.
//

import SwiftUI
import UIKit
import ZIPFoundation

/// Sorts picked files into a certificate, a profile and an optional password. Works on loose files picked
/// together, or on a single .zip that contains them (a .txt next to them holds the password).
struct CertImportBundle {
    struct File { var name: String; var data: Data }

    var p12: File?
    var profile: File?
    var password: String?
    var problems: [String] = []

    private static let maxEntryBytes: Int64 = 8 * 1024 * 1024

    static func read(_ urls: [URL]) -> CertImportBundle {
        var p12s: [File] = []
        var profiles: [File] = []
        var passwords: [String] = []
        var problems: [String] = []

        func take(_ name: String, _ data: Data) {
            switch (name as NSString).pathExtension.lowercased() {
            case "p12", "pfx": p12s.append(File(name: name, data: data))
            case "mobileprovision": profiles.append(File(name: name, data: data))
            case "txt": if let text = passwordText(from: data) { passwords.append(text) }
            default: break
            }
        }

        for url in urls {
            if url.pathExtension.lowercased() == "zip" {
                do {
                    let archive = try Archive(url: url, accessMode: .read)
                    for entry in archive where entry.type == .file {
                        let name = (entry.path as NSString).lastPathComponent
                        guard !name.hasPrefix("."), !entry.path.hasPrefix("__MACOSX") else { continue }
                        guard Int64(entry.uncompressedSize) <= maxEntryBytes else { continue }
                        var data = Data()
                        guard (try? archive.extract(entry, consumer: { data.append($0) })) != nil else { continue }
                        take(name, data)
                    }
                } catch {
                    problems.append("Couldn't open \(url.lastPathComponent).")
                }
            } else if let data = try? Data(contentsOf: url) {
                take(url.lastPathComponent, data)
            }
        }

        var bundle = CertImportBundle()
        if p12s.count > 1 { problems.append("Found \(p12s.count) .p12 files. Choose just one.") } else { bundle.p12 = p12s.first }
        if profiles.count > 1 { problems.append("Found \(profiles.count) .mobileprovision files. Choose just one.") } else { bundle.profile = profiles.first }
        if passwords.count > 1 { problems.append("Found more than one password .txt. Choose just one.") } else { bundle.password = passwords.first }
        if p12s.isEmpty && profiles.isEmpty && problems.isEmpty {
            problems.append("No .p12 or .mobileprovision found in what you chose.")
        }
        bundle.problems = problems
        return bundle
    }

    /// First line of the text file, with an optional leading "password:" label removed.
    static func passwordText(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard var line = text.split(whereSeparator: \.isNewline).first.map(String.init) else { return nil }
        let lower = line.lowercased()
        for label in ["password:", "password ="] where lower.hasPrefix(label) {
            line = String(line.dropFirst(label.count))
            break
        }
        line = line.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? nil : line
    }
}

/// Packs a certificate into a .zip that the importer above reads back: .p12, .mobileprovision and, when the
/// certificate has one, password.txt.
enum CertificateExporter {
    static func zipURL(for cert: Certificate) throws -> URL {
        let cleaned = String(cert.name.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        let safe = cleaned.isEmpty ? "Certificate" : cleaned
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cert-export-\(cert.id)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipURL = dir.appendingPathComponent("\(safe).zip")

        var files: [(String, Data)] = [
            ("\(safe).p12", try Data(contentsOf: cert.p12URL)),
            ("\(safe).mobileprovision", try Data(contentsOf: cert.provisionURL)),
        ]
        if let password = Keychain.get("cert-" + cert.id), !password.isEmpty {
            files.append(("password.txt", Data(password.utf8)))
        }

        let archive = try Archive(url: zipURL, accessMode: .create)
        for (path, data) in files {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position) ..< Int(position) + size)
            }
        }
        return zipURL
    }
}

@MainActor
enum CertificateShare {
    /// Presents the share sheet above whatever is on screen, including full-screen covers.
    static func present(_ url: URL) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        top.present(UIActivityViewController(activityItems: [url], applicationActivities: nil), animated: true)
    }
}

/// The certificate picture. Uses the artwork in the asset catalog; if it's missing, draws a similar
/// certificate (white paper, gold seal, even blue border) so the screen never shows a blank.
struct CertificateBadge: View {
    enum Style { case seal, crown }
    var size: CGFloat = 60
    var style: Style = .seal

    private var assetName: String { style == .crown ? "CertCrown" : "CertSeal" }

    var body: some View {
        Group {
            if UIImage(named: assetName) != nil {
                Image(assetName).resizable().scaledToFit()
            } else {
                drawn
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var drawn: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.38, green: 0.64, blue: 0.98), Color(red: 0.15, green: 0.37, blue: 0.86)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.17, style: .continuous)
                .fill(LinearGradient(colors: [.white, Color(white: 0.91)], startPoint: .top, endPoint: .bottom))
                .padding(size * 0.08)
            VStack(spacing: size * 0.04) {
                Text("Certificate")
                    .font(.custom("SnellRoundhand", size: size * 0.24))
                    .foregroundStyle(Color(white: 0.22))
                    .lineLimit(1).minimumScaleFactor(0.5)
                Image(systemName: style == .crown ? "crown.fill" : "rosette")
                    .font(.system(size: size * 0.3, weight: .semibold))
                    .foregroundStyle(Color(red: 0.98, green: 0.76, blue: 0.16))
            }
            .padding(size * 0.16)
        }
    }
}

/// Artwork from the asset catalog, with an SF Symbol tile if the image isn't there.
struct AssetIcon: View {
    let name: String
    var size: CGFloat = 60
    var fallback: String = "seal.fill"

    var body: some View {
        Group {
            if UIImage(named: name) != nil {
                Image(name).resizable().scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Theme.accent.opacity(0.2))
                    Image(systemName: fallback).font(.system(size: size * 0.45)).foregroundStyle(Theme.accent)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
