//
//  NewsIPA.swift
//  Download / Sign for an IPA attached to a news card. It uses the same shared download as the app pages,
//  so a Sign tapped while the file is still coming down waits for it and then starts by itself.
//

import SwiftUI

extension SourceNews {
    /// The attached IPA, expressed as an app so the normal download and signing code can handle it.
    var ipaApp: SourceApp? {
        guard let ipaURL else { return nil }
        let ver = ipaVersion.isEmpty ? "1.0" : ipaVersion
        let mb = ipaSize > 0 ? String(format: "%.1f MB", Double(ipaSize) / 1_048_576) : "—"
        return SourceApp(id: "news-ipa-\(id)-\(ver)", name: title, bundle: appID ?? "news.\(id)", subtitle: "", version: ver,
                         sizeMB: mb, updated: date, downloads: "", description: caption, iconURL: imageURL,
                         downloadURL: ipaURL, screenshots: [])
    }
}

enum IPAExport {
    /// A copy named "AppName-version.ipa" so the saved file says what it is.
    static func namedCopy(of app: SourceApp) throws -> URL {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        func clean(_ t: String) -> String {
            t.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) }.map(String.init).joined()
                .trimmingCharacters(in: CharacterSet(charactersIn: " ._"))
        }
        let name = clean(app.name).isEmpty ? "App" : clean(app.name)
        let ver = clean(app.version)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ipa-export", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name + (ver.isEmpty ? "" : "-\(ver)") + ".ipa")
        let src = IPAInbox.url(for: app)
        do { try FileManager.default.linkItem(at: src, to: dest) } catch { try FileManager.default.copyItem(at: src, to: dest) }
        return dest
    }
}

/// Download + Sign pair shown under a news card that carries an IPA.
struct NewsIPAButtons: View {
    let app: SourceApp
    var onSign: () -> Void
    @ObservedObject private var d: PendingIPADownload
    @State private var message: String?

    init(app: SourceApp, onSign: @escaping () -> Void) {
        self.app = app; self.onSign = onSign
        _d = ObservedObject(wrappedValue: PendingIPADownload.current(for: app))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(action: downloadTapped) {
                    HStack(spacing: 8) {
                        if d.ready { Image(systemName: "square.and.arrow.up") }
                        else if d.progress > 0 && d.failure == nil { ProgressView(value: d.progress).tint(.white).frame(width: 40) }
                        else { Image(systemName: "arrow.down.circle.fill") }
                        Text(d.ready ? "Save IPA" : (d.progress > 0 && d.failure == nil ? "\(Int(d.progress * 100))%" : "Download"))
                            .monospacedDigit()
                    }
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 13).background(Theme.accent).clipShape(Capsule())
                }
                Button(action: signTapped) {
                    HStack(spacing: 8) { Image(systemName: "signature"); Text("Sign") }
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .overlay(Capsule().stroke(Theme.accent, lineWidth: 1.5))
                }
            }
            if let f = d.failure ?? message { Text(f).font(.caption).foregroundStyle(.orange) }
            Text("\(app.name) \(app.version) · \(app.sizeMB)").font(.system(size: 12)).foregroundStyle(Theme.subtle)
        }
    }

    private func downloadTapped() {
        if d.ready {
            do { CertificateShare.present(try IPAExport.namedCopy(of: app)) }
            catch { message = "Couldn't prepare the IPA: \(error.localizedDescription)" }
        } else { message = nil; d.start() }
    }

    private func signTapped() {
        if d.ready { onSign(); SignQueue.shared.enqueue(d.url) }
        else { d.start(); onSign(); SignQueue.shared.enqueueDownloading(d) }
    }
}
