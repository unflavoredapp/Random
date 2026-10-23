import SwiftUI
import Foundation

/// A concrete, address-backed observation from the analyzed Mach-O.
/// `confidence` describes evidence strength, not whether the app is vulnerable.
nonisolated struct ProtectionFinding: Identifiable, Sendable {
    let id: String
    let category: String
    let title: String
    let confidence: String
    let location: String
    let evidence: [String]
    let note: String
    /// Numeric address used for stable ordering (VA of the call site or string).
    var sortAddress: UInt64 = 0
}

nonisolated enum ProtectionAnalysis {
    private typealias Profile = ProtectionProfile

    private struct StringHit {
        let value: String
        let section: String
        let va: UInt64
        let fileOffset: Int
    }

    private struct CallHit {
        let api: String
        let callVA: UInt64
        let functionName: String
        let functionVA: UInt64
    }

    private static let profiles: [Profile] = ProtectionProfiles.all
    private static let perProfileCap = 80

    static func scan(ipaURL: URL) async -> [ProtectionFinding] {
        guard let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil) else { return [] }
        let thin = ctx.thin
        let symbols = MachOTools.symbolMap(in: thin)
        let imports = MachOTools.importStubMap(in: thin)
        let strings = collectStrings(thin: thin, sections: ctx.sections)
        let calls = collectImportedCalls(thin: thin, sections: ctx.sections, imports: imports,
                                         starts: MachOTools.functionStarts(in: thin), symbols: symbols)

        // Lowercase once, not once per profile.
        let loweredCalls = calls.map { $0.api.lowercased() }
        let loweredStrings = strings.map { $0.value.lowercased() }

        var output: [ProtectionFinding] = []
        var seen = Set<String>()

        for profile in profiles {
            if Task.isCancelled { return [] }
            let importTerms = profile.importTerms.map { $0.lowercased() }
            let stringTerms = profile.stringTerms.map { $0.lowercased() }

            var callCount = 0
            for (idx, call) in calls.enumerated() where callCount < perProfileCap {
                let name = loweredCalls[idx]
                guard importTerms.contains(where: { name.contains($0) }) else { continue }
                let key = "\(profile.category)|call|\(call.callVA)|\(call.api)"
                guard seen.insert(key).inserted else { continue }
                callCount += 1
                output.append(ProtectionFinding(
                    id: key, category: profile.category, title: profile.title,
                    confidence: "Resolved imported call",
                    location: String(format: "call 0x%llx \u{00B7} %@ 0x%llx", call.callVA, call.functionName, call.functionVA),
                    evidence: ["API: \(call.api)",
                               String(format: "Call-site VA: 0x%llx", call.callVA),
                               String(format: "Containing function: %@ (0x%llx)", call.functionName, call.functionVA)],
                    note: profile.note,
                    sortAddress: call.callVA))
            }

            var strCount = 0
            for (idx, hit) in strings.enumerated() where strCount < perProfileCap {
                let value = loweredStrings[idx]
                guard stringTerms.contains(where: { value.contains($0) }) else { continue }
                let key = "\(profile.category)|str|\(hit.fileOffset)|\(hit.value)"
                guard seen.insert(key).inserted else { continue }
                strCount += 1
                output.append(ProtectionFinding(
                    id: key, category: profile.category, title: profile.title,
                    confidence: "Address-backed string indicator",
                    location: String(format: "%@ VA 0x%llx \u{00B7} file offset 0x%x", hit.section, hit.va, hit.fileOffset),
                    evidence: [hit.value, "Section: \(hit.section)",
                               String(format: "String VA: 0x%llx", hit.va),
                               String(format: "Thin-slice file offset: 0x%x", hit.fileOffset)],
                    note: profile.note,
                    sortAddress: hit.va))
            }
        }

        return output.sorted {
            if $0.category != $1.category { return $0.category < $1.category }
            if $0.sortAddress != $1.sortAddress { return $0.sortAddress < $1.sortAddress }
            return $0.id < $1.id
        }
    }

    private static func collectStrings(thin: Data, sections: [MachOTools.Section]) -> [StringHit] {
        let wanted: Set<String> = ["__cstring", "__objc_methname", "__objc_classname", "__objc_methtype"]
        var hits: [StringHit] = []
        let base = thin.startIndex
        for section in sections where wanted.contains(section.name) {
            guard section.offset <= UInt64(thin.count) else { continue }
            let start = Int(section.offset)
            guard section.size > 0, section.size <= UInt64(thin.count - start) else { continue }
            let end = start + Int(section.size)
            var cursor = start
            while cursor < end {
                let stringStart = cursor
                while cursor < end, thin[base + cursor] != 0 { cursor += 1 }
                let length = cursor - stringStart
                if length >= 4, length <= 4096,
                   let value = String(data: thin.subdata(in: (base + stringStart)..<(base + cursor)), encoding: .utf8) {
                    let hasControl = value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
                    if !hasControl {
                        hits.append(StringHit(value: value, section: section.name,
                                              va: section.addr + UInt64(stringStart - start),
                                              fileOffset: stringStart))
                    }
                }
                cursor += 1
            }
        }
        return hits
    }

    /// Last function start <= address (binary search over sorted starts).
    private static func containingFunction(_ sortedStarts: [UInt64], _ address: UInt64) -> UInt64? {
        var lo = 0, hi = sortedStarts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sortedStarts[mid] <= address { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : sortedStarts[lo - 1]
    }

    /// Finds actual ARM64 BL instructions whose computed target equals a real
    /// imported stub address. No target is inferred from an API-name string.
    private static func collectImportedCalls(thin: Data, sections: [MachOTools.Section],
                                             imports: [UInt64: String], starts: [UInt64],
                                             symbols: [UInt64: String]) -> [CallHit] {
        guard !imports.isEmpty, let text = MachOTools.textSection(sections, in: thin) else { return [] }
        let orderedStarts = starts.sorted()
        let textData = text.data
        var result: [CallHit] = []
        textData.withUnsafeBytes { raw in
            let count = raw.count / 4
            for i in 0..<count {
                let word = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                guard (word & 0xFC00_0000) == 0x9400_0000 else { continue } // BL imm26
                // Sign-extend imm26: shift bit 25 up to the sign bit, arithmetic shift back.
                let imm = Int64(Int32(bitPattern: word << 6) >> 6) * 4
                let site = text.vmaddr + UInt64(i * 4)
                let targetSigned = Int64(bitPattern: site) &+ imm
                guard targetSigned >= 0, let api = imports[UInt64(targetSigned)] else { continue }
                let fn = containingFunction(orderedStarts, site)
                let name = fn.flatMap { symbols[$0] }.map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }
                    ?? fn.map { String(format: "sub_%llx", $0) } ?? "unknown function"
                result.append(CallHit(api: api, callVA: site, functionName: name, functionVA: fn ?? site))
            }
        }
        return result
    }
}

struct ProtectionAnalysisSheet: View {
    let ipaURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var findings: [ProtectionFinding] = []
    @State private var isLoading = true
    @State private var selectedCategory = "All"
    @State private var query = ""
    @State private var impactFinding: ProtectionFinding?
    @State private var showManualPatchWorkbench = false
    @State private var showTestOnlyTrustConfiguration = false

    private var categories: [String] { ["All"] + Array(Set(findings.map(\.category))).sorted() }

    private var filtered: [ProtectionFinding] {
        findings.filter { finding in
            let matchesCategory = selectedCategory == "All" || finding.category == selectedCategory
            guard matchesCategory else { return false }
            if query.isEmpty { return true }
            let combinedText = finding.title + " " + finding.location + " " + finding.evidence.joined(separator: " ")
            return combinedText.localizedCaseInsensitiveContains(query)
        }
    }

    private var grouped: [(category: String, items: [ProtectionFinding])] {
        Dictionary(grouping: filtered, by: \.category)
            .map { (category: $0.key, items: $0.value) }
            .sorted { $0.category < $1.category }
    }

    private var headerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Address-backed static-analysis leads. Imported calls are matched to real ARM64 BL targets; strings include section addresses and file offsets. These findings do not prove runtime behavior.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Picker("Category", selection: $selectedCategory) {
                ForEach(categories, id: \.self) { category in
                    Text(category).tag(category)
                }
            }
            .pickerStyle(.menu)
            TextField("Search findings", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button {
                showManualPatchWorkbench = true
            } label: {
                Label("Open Manual Patch Generator", systemImage: "wrench.and.screwdriver")
                    .font(.subheadline.weight(.semibold))
            }
            #if DEBUG
            Button {
                showTestOnlyTrustConfiguration = true
            } label: {
                Label("Test-Only TLS Trust Configuration", systemImage: "checkmark.shield")
                    .font(.subheadline.weight(.semibold))
            }
            #endif
        }
        .padding(.vertical, 8)
    }

    private func findingView(_ finding: ProtectionFinding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(finding.title).font(.headline)
                Spacer(minLength: 8)
                Text(finding.confidence)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
            }
            Text(finding.location)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            // Index-based IDs: duplicate evidence strings no longer collide.
            ForEach(Array(finding.evidence.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(finding.note)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                impactFinding = finding
            } label: {
                Label("Preview change & repercussions", systemImage: "arrow.left.arrow.right.circle")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Analyzing Mach-O evidence\u{2026}")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Controls always stay visible, so an empty result can still be re-filtered.
                    List {
                        Section {
                            headerControls
                        }
                        if filtered.isEmpty {
                            Section {
                                VStack(spacing: 8) {
                                    Image(systemName: "checkmark.shield")
                                        .font(.system(size: 40))
                                        .foregroundStyle(.secondary)
                                    Text("No matching indicators")
                                        .font(.headline)
                                    Text("No imported calls or strings match the current filters. Indirect calls, stripped metadata, and embedded frameworks may require separate analysis.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                            }
                        } else {
                            ForEach(grouped, id: \.category) { group in
                                Section {
                                    ForEach(group.items) { finding in
                                        findingView(finding)
                                    }
                                } header: {
                                    Text(group.category)
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Color.black)
            .navigationTitle("Protection Analysis")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(trailing: SwiftUI.Button("Close") { dismiss() })
            .sheet(item: $impactFinding) { finding in
                PatchImpactPreviewSheet(finding: finding, ipaURL: ipaURL)
            }
            .sheet(isPresented: $showManualPatchWorkbench) {
                ManualPatchWorkbench(findings: findings, ipaURL: ipaURL)
            }
            #if DEBUG
            .sheet(isPresented: $showTestOnlyTrustConfiguration) {
                TestOnlyTrustConfigurationView()
            }
            #endif
            .task {
                // Detached so the heavy scan never runs on the main actor.
                let url = ipaURL
                let result = await Task.detached(priority: .userInitiated) {
                    await ProtectionAnalysis.scan(ipaURL: url)
                }.value
                findings = result
                isLoading = false
            }
        }
        .preferredColorScheme(.dark)
    }
}
