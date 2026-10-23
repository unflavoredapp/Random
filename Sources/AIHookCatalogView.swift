import SwiftUI
import UniformTypeIdentifiers

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Local-only report scanner and hook-catalog matcher.
/// The on-device Foundation Models API is used only when available; a deterministic
/// catalog matcher remains available on older OS versions and unsupported devices.
struct AIHookCatalogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var reportText = ""
    @State private var reportName = ""
    @State private var resultText = ""
    @State private var isScanning = false
    @State private var showImporter = false
    @State private var modelStatus = "Checking on-device model availability…"
    @State private var scanError: String?

    private struct CatalogEntry: Identifiable, Codable {
        let id: String
        let title: String
        let triggers: [String]
        let template: String
        let notes: String
    }

    private var catalog: [CatalogEntry] {
        if let url = Bundle.main.url(forResource: "HookCatalog", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([CatalogEntry].self, from: data), !decoded.isEmpty {
            return decoded
        }
        return Self.fallbackCatalog
    }

    private static let fallbackCatalog: [CatalogEntry] = [
        .init(id: "objc-runtime", title: "Objective-C runtime inspection", triggers: ["objc_getclass", "class_getinstancemethod", "method_gettypeencoding", "selector", "__objc_classlist"], template: "Objective-C class/selector inventory and method-encoding diagnostics", notes: "Use verified class and selector metadata; do not infer argument types from selector spelling."),
        .init(id: "storekit-diagnostics", title: "StoreKit / entitlement diagnostics", triggers: ["storekit", "skpayment", "transaction", "entitlement", "subscription", "premium", "purchase"], template: "Purchase lifecycle and entitlement-state logging scaffold", notes: "Observe and report state transitions without changing entitlement results or granting access."),
        .init(id: "trust-diagnostics", title: "TLS / certificate-pinning diagnostics", triggers: ["sectrustevaluatewitherror", "sectrustevaluate", "sectrustcopykey", "sectrustsetanchorcertificates", "nsurlauthenticationmethodservertrust", "urlsession:didreceivechallenge:", "servertrust", "certificatepinning", "pinnedcertificate", "publickeyhashes", "trustkit", "alamofire", "spki", "tls"], template: "Evidence-backed TLS trust-flow report and diagnostic logging scaffold", notes: "Trace the actual trust callback, certificate/public-key comparison, and failure branch. Keep validation behavior unchanged; use a test build or explicit test-only trust configuration for authorized proxy testing."),
        .init(id: "loaded-images", title: "Loaded-image diagnostics", triggers: ["_dyld_image_count", "dyld", "loaded image", "dlsym", "dlopen"], template: "Loaded-image enumeration and logging scaffold", notes: "Read-only runtime inventory for debugging and compatibility checks."),
        .init(id: "capture-diagnostics", title: "Screen-capture diagnostics", triggers: ["capturedidchangenotification", "screenshot", "uiscreen", "screen capture", "recording"], template: "Screen-capture state and notification logging scaffold", notes: "Observe capture state and notification delivery without suppressing application behavior."),
        .init(id: "objc-swizzle-forward", title: "Objective-C forwarding instrumentation", triggers: ["-[", "+[", "method_list_t", "method_setimplementation", "method_setimplementation"], template: "Log-and-forward swizzle scaffold for a verified Objective-C method", notes: "Requires a real method encoding and ABI-compatible signature. Preserve and call the original implementation."),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    introCard
                    HStack(spacing: 10) {
                        Button { showImporter = true } label: {
                            Label("Scan .txt / .md", systemImage: "doc.text.magnifyingglass")
                                .frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent)
                        Button { Task { await scanReport() } } label: {
                            Label(isScanning ? "Analyzing…" : "Match catalog", systemImage: "brain.head.profile")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isScanning || reportText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if !reportName.isEmpty {
                        Label(reportName, systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
                    }
                    if let scanError {
                        Text(scanError).font(.footnote).foregroundStyle(.red)
                    }
                    if !resultText.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("MATCH RESULTS").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                                Spacer()
                                ShareLink(item: resultText) { Label("Share report", systemImage: "square.and.arrow.up").font(.caption) }
                            }
                            Text(resultText).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12).background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Text("LOCAL CATALOG").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    ForEach(catalog) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.title).font(.subheadline.weight(.semibold))
                            Text(item.template).font(.footnote).foregroundStyle(.primary)
                            Text(item.notes).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(16)
            }
            .navigationTitle("AI Hook Catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.plainText, UTType(filenameExtension: "md") ?? .plainText], allowsMultipleSelection: false) { outcome in
                do {
                    guard let url = try outcome.get().first else { return }
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    reportText = try String(contentsOf: url, encoding: .utf8)
                    reportName = url.lastPathComponent
                    scanError = nil
                    resultText = ""
                } catch { scanError = "Could not read report: \(error.localizedDescription)" }
            }
            .task { await updateModelStatus() }
        }
    }

    private var introCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("On-device matching", systemImage: "iphone.gen3.radiowaves.left.and.right")
                .font(.headline)
            Text("Import a text or Markdown analysis report. AirCore matches its evidence against a bundled local catalog and, when Apple Foundation Models is available, asks the on-device model to rank candidates and identify missing evidence.")
                .font(.footnote).foregroundStyle(.secondary)
            Text(modelStatus).font(.caption).foregroundStyle(.secondary)
            Text("Generated entries are instrumentation and diagnostics templates. Unverified classes, selectors, and signatures are never presented as confirmed facts.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13).background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private func updateModelStatus() async {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                modelStatus = "Apple Foundation Models: available on this device"
            case .unavailable(let reason):
                modelStatus = "On-device model unavailable (\(String(describing: reason))); deterministic matching remains available"
            }
        } else {
            modelStatus = "iOS 26+ required for Foundation Models; deterministic local matching remains available"
        }
        #else
        modelStatus = "FoundationModels unavailable in this build environment; deterministic local matching remains available"
        #endif
    }

    private func isModelAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    private func scanReport() async {
        isScanning = true
        defer { isScanning = false }
        let lower = reportText.lowercased()
        let matches = catalog.filter { item in item.triggers.contains { lower.contains($0.lowercased()) } }
        let deterministic = matches.isEmpty
            ? "No catalog match. Keep the report as an unresolved finding and add stronger evidence (real class/selector, type encoding, symbol, or CFG address)."
            : matches.map { "• \($0.title)\n  Candidate: \($0.template)\n  Evidence triggers: \($0.triggers.filter { lower.contains($0.lowercased()) }.joined(separator: ", "))\n  Notes: \($0.notes)" }.joined(separator: "\n\n")
        let prompt = """
        You are AirCore's local reverse-engineering report triage assistant. Use only evidence present in the report and the catalog below. Do not invent class names, selectors, method signatures, addresses, or type encodings. Distinguish direct evidence from inference. Recommend only diagnostic, logging, and original-behavior-preserving instrumentation templates; never suggest changing purchase/entitlement outcomes or disabling security checks. Output concise Markdown with sections: Confirmed evidence, Best catalog matches, Missing verification, and Safe next step.\n\nCATALOG MATCHES:\n\(deterministic)\n\nREPORT:\n\(String(reportText.prefix(26000)))
        """
        #if canImport(FoundationModels)
        if isModelAvailable() {
            do {
                let session = LanguageModelSession(instructions: "You analyze local iOS binary reports for AirCore. You cannot access network or files. Never fabricate evidence.")
                let response = try await session.respond(to: prompt)
                resultText = response.content
                modelStatus = "Matched locally with Apple Foundation Models; no report uploaded."
            } catch {
                resultText = "DETERMINISTIC MATCHING\n\n\(deterministic)\n\nAI analysis failed: \(error.localizedDescription)"
                modelStatus = "Foundation Models failed; deterministic local matching used."
            }
        } else {
            resultText = "DETERMINISTIC MATCHING\n\n\(deterministic)"
            modelStatus = "Used local catalog matching; on-device Foundation Models unavailable."
        }
        #else
        resultText = "DETERMINISTIC MATCHING\n\n\(deterministic)"
        modelStatus = "FoundationModels unavailable in this build environment; deterministic local matching used."
        #endif
    }
}
