import SwiftUI

struct BinaryAnalysisView: View {
    let ipaURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var report: BinaryAnalysisReport?
    @State private var thin: Data?
    @State private var segments: [MachOTools.Segment] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selectedVA: UInt64?
    @State private var disassembly: [DecodedInsn] = []
    @State private var query = ""
    @State private var tab = 0

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    VStack(spacing: 12) { ProgressView(); Text("Parsing Mach-O locally…").foregroundStyle(Theme.subtle) }
                } else if let error {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(.orange)
                        Text("Analysis unavailable").font(.headline).foregroundStyle(Theme.text)
                        Text(error).font(.caption).foregroundStyle(Theme.subtle).multilineTextAlignment(.center)
                    }.padding(24)
                } else if let report {
                    VStack(spacing: 0) {
                        tabPicker
                        if tab == 0 { dashboard(report) }
                        else if tab == 1 { codeView(report) }
                        else if tab == 2 { metadataView(report) }
                        else { sectionsView(report) }
                    }
                }
            }
            .navigationTitle("Binary Analysis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await load() }
        .searchable(text: $query, prompt: "Search metadata")
    }

    private var tabPicker: some View {
        Picker("Analysis", selection: $tab) {
            Text("Dashboard").tag(0); Text("Code + Hex").tag(1); Text("Metadata").tag(2); Text("Sections").tag(3)
        }
        .pickerStyle(.segmented).padding(12).background(Color.black)
    }

    private func dashboard(_ r: BinaryAnalysisReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                evidenceCard(title: "Binary", icon: "doc.binary.fill") {
                    stat("Architecture", r.architecture, true)
                    stat("Size", ByteCountFormatter.string(fromByteCount: Int64(r.binarySize), countStyle: .file), false)
                    stat("Sections", "\(r.sections.count)", false)
                    stat("__text", r.textRange.map { hex($0.lowerBound) + " – " + hex($0.upperBound) } ?? "Unavailable", true)
                }
                evidenceCard(title: "Objective-C runtime metadata", icon: "shippingbox.fill") {
                    evidenceRow("Classes", r.objcClasses)
                    evidenceRow("Selectors", r.objcSelectors)
                }
                evidenceCard(title: "Swift metadata", icon: "swift") {
                    evidenceRow("Reflection strings", r.swiftMetadata)
                    stat("Metadata source", r.swiftMetadata.source, true)
                }
                evidenceCard(title: "Evidence policy", icon: "checkmark.shield.fill") {
                    Text("Counts and names above come from sections in this binary. Missing metadata is shown as Unavailable; AirShare does not invent classes, methods, symbols, or types.")
                        .font(.caption).foregroundStyle(Theme.subtle)
                }
            }.padding(12)
        }.background(Color.black)
    }

    private func codeView(_ r: BinaryAnalysisReport) -> some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Virtual address, e.g. 0x100004000", text: Binding(get: { selectedVA.map(hex) ?? "" }, set: { value in
                    selectedVA = UInt64(value.replacingOccurrences(of: "0x", with: ""), radix: 16)
                    decodeSelected(r)
                }))
                .font(.system(size: 12, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Go") { decodeSelected(r) }.buttonStyle(.borderedProminent)
            }.padding(10)
            Divider().overlay(Theme.stroke)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if disassembly.isEmpty {
                        Text("Enter an address inside __text to inspect the real instruction bytes.")
                            .font(.caption).foregroundStyle(Theme.subtle).padding(16)
                    } else {
                        ForEach(disassembly, id: \.va) { insn in
                            Button {
                                selectedVA = insn.va
                            } label: {
                                HStack(spacing: 8) {
                                    Text(hex(insn.va)).frame(width: 112, alignment: .leading)
                                    Text(insn.byteString).frame(width: 105, alignment: .leading)
                                    Text("\(insn.mnem) \(insn.ops)").frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(selectedVA == insn.va ? Color.black : Theme.text)
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(selectedVA == insn.va ? Theme.accent : Color.clear)
                            }.buttonStyle(.plain)
                        }
                        if let selectedVA, let insn = disassembly.first(where: { $0.va == selectedVA }) {
                            hexInspector(insn)
                        }
                    }
                }
            }
        }.background(Color.black)
    }

    private func hexInspector(_ insn: DecodedInsn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SELECTED BYTES").font(.caption.bold()).foregroundStyle(Theme.accent)
            Text("VA \(hex(insn.va))  ·  \(insn.byteString)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
            Text("Disassembly: \(insn.mnem) \(insn.ops)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.subtle)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.card)
    }

    private func metadataView(_ r: BinaryAnalysisReport) -> some View {
        List {
            metadataSection("Objective-C classes", r.objcClasses)
            metadataSection("Objective-C selectors", r.objcSelectors)
            metadataSection("Swift reflection", r.swiftMetadata)
        }.scrollContentBackground(.hidden).background(Color.black)
    }

    private func metadataSection(_ title: String, _ evidence: BinaryAnalysisReport.MetadataEvidence) -> some View {
        Section(title) {
            if !evidence.available {
                Text("Unavailable — \(evidence.note ?? "not present in the binary")").foregroundStyle(.orange)
            } else {
                let values = query.isEmpty ? evidence.values : evidence.values.filter { $0.localizedCaseInsensitiveContains(query) }
                let shown = min(values.count, 500)
                Text("Source: \(evidence.source) · \(evidence.count) recovered · showing \(shown)").font(.caption).foregroundStyle(Theme.subtle)
                if let note = evidence.note { Text(note).font(.caption2).foregroundStyle(.orange) }
                ForEach(Array(values.prefix(500)), id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text) }
                if values.count > 500 { Text("Display limited to 500 results; the recovered evidence above is larger.").font(.caption2).foregroundStyle(Theme.subtle) }
            }
        }.listRowBackground(Theme.card)
    }

    private func sectionsView(_ r: BinaryAnalysisReport) -> some View {
        List {
            ForEach(r.sections) { s in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(s.segment),\(s.name)").font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.text)
                    Text("VA \(hex(s.address))  ·  file 0x\(String(s.offset, radix: 16))  ·  \(s.size) bytes")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.subtle)
                }.padding(.vertical, 3)
            }.listRowBackground(Theme.card)
        }.scrollContentBackground(.hidden).background(Color.black)
    }

    private func evidenceCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(Theme.text)
            VStack(alignment: .leading, spacing: 7) { content() }.padding(10).background(Theme.card).clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func evidenceRow(_ title: String, _ evidence: BinaryAnalysisReport.MetadataEvidence) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(Theme.subtle)
            Spacer()
            if evidence.available { Text(evidence.truncated ? "\(evidence.count)+" : "\(evidence.count)").foregroundStyle(.green).fontWeight(.semibold) }
            else { Text("Unavailable").foregroundStyle(.orange) }
        }.font(.subheadline)
    }

    private func stat(_ title: String, _ value: String, _ mono: Bool) -> some View {
        HStack { Text(title).foregroundStyle(Theme.subtle); Spacer(); Text(value).foregroundStyle(Theme.text).font(mono ? .system(size: 12, design: .monospaced) : .subheadline) }
    }

    private func hex(_ value: UInt64) -> String { String(format: "0x%llx", value) }

    private func load() async {
        loading = true
        report = await BinaryAnalysisEngine.analyze(ipaURL: ipaURL)
        if let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil) {
            thin = ctx.thin
            segments = ctx.segments
        }
        loading = false
        if report == nil { error = "AirShare could not extract a readable Mach-O from this IPA." }
        if let report, let text = report.textRange { selectedVA = text.lowerBound; decodeSelected(report) }
    }

    private func decodeSelected(_ r: BinaryAnalysisReport) {
        guard let selectedVA, let thin else { return }
        disassembly = AVXDisassembler.disassemble(atVA: selectedVA, count: 96, thin: thin, segments: segments)
    }
}
