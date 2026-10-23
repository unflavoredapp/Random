import SwiftUI

/// Educational, non-mutating preview of the possible behavior change and its trade-offs.
/// This view does not edit bytes, apply patches, or claim the inferred outcome is verified.
struct PatchImpactPreviewSheet: View {
    let finding: ProtectionFinding
    let ipaURL: URL
    @State private var instructionWindow: [DecodedInsn] = []
    @State private var instructionStatus = "Loading instruction evidence…"
    @State private var isLoadingInstructions = true
    @State private var storeKitTrace: StoreKitGateTrace?
    @State private var isLoadingStoreKitTrace = false

    private var isPremiumFinding: Bool {
        let category = finding.category.lowercased()
        let title = finding.title.lowercased()
        return category.contains("purchase") || category.contains("storekit") || category.contains("premium") || title.contains("entitlement") || title.contains("storekit")
    }

    private var conditionalBranches: [DecodedInsn] {
        instructionWindow.filter {
            let mnemonic = $0.mnem.uppercased()
            return mnemonic.hasPrefix("B.") || mnemonic == "CBZ" || mnemonic == "CBNZ" || mnemonic == "TBZ" || mnemonic == "TBNZ"
        }
    }
    @Environment(\.dismiss) private var dismiss

    private struct Scenario {
        let beforeTitle: String
        let beforeDetail: String
        let hypotheticalTitle: String
        let hypotheticalDetail: String
        let repercussions: [String]
        let verification: [String]
    }

    private var scenario: Scenario {
        let c = finding.category.lowercased()
        if c.contains("ssl") || c.contains("certificate") || c.contains("pinning") {
            return Scenario(
                beforeTitle: "Connection may be rejected",
                beforeDetail: "A trust or pin comparison may reject a certificate that differs from the app's expected identity.",
                hypotheticalTitle: "Connection may proceed under altered trust logic",
                hypotheticalDetail: "If an authorized test build changes the validation decision, a proxy may see traffic that was previously rejected. This finding alone does not prove pinning is active.",
                repercussions: ["TLS interception can expose credentials, tokens, and personal data in the test session.", "A mistaken trust change can weaken protection for every connection, not just the test host.", "The app may still reject the connection through another validation layer or backend check."],
                verification: ["Use a staging account and test endpoint.", "Confirm the exact trust-evaluation path in the CFG.", "Compare certificate failures and successful requests in an authorized proxy session."])
        }
        if c.contains("receipt") || c.contains("attestation") || c.contains("devicecheck") {
            return Scenario(
                beforeTitle: "Validation may fail",
                beforeDetail: "Receipt or device-attestation evidence may be missing, stale, or rejected by local or server-side validation.",
                hypotheticalTitle: "The local app may advance without valid evidence",
                hypotheticalDetail: "Changing a local decision can make the next screen appear accessible, but it does not create a valid receipt or attestation assertion.",
                repercussions: ["Server APIs can still deny access because they independently validate purchase or device evidence.", "Receipt refresh, restore-purchase, or account state can become inconsistent.", "Security telemetry and fraud controls may flag contradictory client/server state."],
                verification: ["Use StoreKit sandbox and a test backend you control.", "Trace local validation separately from server-side validation.", "Test missing, expired, invalid, and valid evidence cases."])
        }
        if c.contains("in-app purchase") || c.contains("storekit") || c.contains("premium") || c.contains("gate") {
            return Scenario(
                beforeTitle: "Premium feature remains gated",
                beforeDetail: "A purchase or entitlement decision may keep a feature unavailable when no valid entitlement is present.",
                hypotheticalTitle: "The UI may display the premium state",
                hypotheticalDetail: "A changed local branch can alter presentation in an app you own, but it does not establish a genuine transaction or entitlement with StoreKit or your server.",
                repercussions: ["Purchase and UI state may disagree, confusing restore and subscription flows.", "Server-authorized features can remain unavailable.", "A broad branch change may unlock unrelated states or break expiry, revocation, and family-sharing behavior."],
                verification: ["Use a StoreKit Configuration file or sandbox account.", "Test purchased, expired, revoked, pending, and restored states.", "Check server entitlement responses as well as the UI."])
        }
        if c.contains("tweak") || c.contains("loaded library") || c.contains("instrumentation") {
            return Scenario(
                beforeTitle: "App may terminate or restrict features",
                beforeDetail: "A loaded-image scan may identify a library and feed a detection result into a later decision.",
                hypotheticalTitle: "The app may continue past that local decision",
                hypotheticalDetail: "This is only a behavior hypothesis until the detection result is traced to a reachable response path.",
                repercussions: ["Other integrity checks may still detect instrumentation.", "Instrumentation can alter timing, memory layout, and app stability.", "A broad change can hide a real diagnostic signal and complicate crash analysis."],
                verification: ["Identify the enumerator, comparison, and consuming branch in the CFG.", "Compare clean and instrumented test runs on a lab device.", "Record crashes and alternate integrity-check results."])
        }
        if c.contains("screen capture") || c.contains("screenshot") || c.contains("recording") {
            return Scenario(
                beforeTitle: "Sensitive UI may be hidden or session restricted",
                beforeDetail: "A notification observer or capture-state handler may react to screenshots or recording.",
                hypotheticalTitle: "Content may remain visible during capture",
                hypotheticalDetail: "Changing a response path in an authorized test app can affect privacy controls, not just the visual result.",
                repercussions: ["Sensitive information may be captured or retained outside the app.", "Session logout and incident-reporting behavior may no longer run.", "A handler can have multiple side effects beyond blanking the screen."],
                verification: ["Trace observer registration to the actual selector or closure.", "Inspect all handler side effects and call sites.", "Test with synthetic data and verify capture notifications and session state."])
        }
        return Scenario(
            beforeTitle: "Original behavior is unknown",
            beforeDetail: "The static finding is a lead; its runtime effect has not been established.",
            hypotheticalTitle: "A changed decision could alter downstream behavior",
            hypotheticalDetail: "Use the CFG and runtime evidence to establish what the branch controls before predicting an unlock.",
            repercussions: ["The finding may be unused or a false positive.", "Changing one condition can affect several callers or states.", "Indirect calls and server-side decisions may change the outcome."],
            verification: ["Resolve the containing function and its callers.", "Trace both branch successors and their side effects.", "Reproduce the behavior in a controlled test build."])
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Finding") {
                    Text(finding.title).font(.headline)
                    Text(finding.category).font(.subheadline).foregroundStyle(.secondary)
                    Text(finding.location).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("Evidence strength: \(finding.confidence)").font(.caption).foregroundStyle(.orange)
                }
                Section("Real binary evidence") {
                    if isLoadingInstructions {
                        HStack(spacing: 8) { ProgressView(); Text(instructionStatus).font(.caption).foregroundStyle(.secondary) }
                    } else if instructionWindow.isEmpty {
                        Text(instructionStatus).font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        Text("Decoded from the analyzed ARM64 Mach-O at the reported call-site address. These are original instructions, not a proposed modification.")
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(Array(instructionWindow.enumerated()), id: \.offset) { index, insn in
                            HStack(alignment: .top, spacing: 8) {
                                Text(String(format: "0x%llx", insn.va))
                                    .frame(width: 104, alignment: .leading)
                                    .foregroundStyle(.secondary)
                                Text(insn.byteString)
                                    .frame(width: 92, alignment: .leading)
                                    .foregroundStyle(.tertiary)
                                Text("\(insn.mnem) \(insn.ops)".trimmingCharacters(in: .whitespaces))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(size: 11, weight: index == 4 ? .semibold : .regular, design: .monospaced))
                            .padding(.vertical, 3)
                            .background(index == 4 ? Color.orange.opacity(0.14) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .textSelection(.disabled)
                        }
                        Text("Highlighted row is the reported call site. Nearby instructions provide context only; static disassembly does not prove the call executes at runtime.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if isPremiumFinding {
                    Section("Premium-gate function trace") {
                        if isLoadingStoreKitTrace {
                            HStack { ProgressView(); Text("Tracing containing function and branch candidates…").font(.caption).foregroundStyle(.secondary) }
                        } else if let trace = storeKitTrace {
                            Text(trace.summary).font(.footnote).foregroundStyle(.secondary)
                            LabeledContent("Trace confidence", value: trace.confidence)
                            Text("Function: \(trace.functionName)").font(.system(.caption, design: .monospaced))
                            Text(String(format: "Range: 0x%llx–0x%llx", trace.functionStart, trace.functionEnd)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            Text(String(format: "Resolved call site: 0x%llx", trace.callSite)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            if trace.branches.isEmpty {
                                Text("No conditional branch was established in this function range.").font(.subheadline)
                            } else {
                                ForEach(trace.branches.prefix(24)) { branch in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(String(format: "0x%llx  %@ %@", branch.address, branch.mnemonic, branch.operands)).font(.system(.subheadline, design: .monospaced).weight(.semibold))
                                        Text("Taken: \(branch.target.map { String(format: "0x%llx", $0) } ?? "unresolved") · Fall-through: \(String(format: "0x%llx", branch.fallthroughAddress))").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                        Text("Distance from call: \(branch.distanceFromFinding) bytes").font(.caption).foregroundStyle(.secondary)
                                        ForEach(branch.registerHints, id: \.self) { hint in Text(hint).font(.caption).foregroundStyle(.secondary) }
                                        DisclosureGroup("Nearby instructions") {
                                            ForEach(branch.nearbyInstructions, id: \.self) { line in Text(line).font(.system(.caption2, design: .monospaced)).textSelection(.enabled) }
                                        }
                                    }.padding(.vertical, 4)
                                }
                            }
                            if !trace.registerFlows.isEmpty {
                                DisclosureGroup("Register / condition value flow (heuristic)") {
                                    ForEach(trace.registerFlows) { flow in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Branch 0x\(String(flow.branchAddress, radix: 16)) · \(flow.register)")
                                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                            if let va = flow.definitionAddress {
                                                Text(String(format: "Nearest definition: 0x%llx", va)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                                            }
                                            Text(flow.definition).font(.system(.caption, design: .monospaced))
                                            Text("\(flow.interveningInstructions) intervening instruction(s); bounded textual heuristic, not proven data flow.").font(.caption2).foregroundStyle(.secondary)
                                        }.padding(.vertical, 4)
                                    }
                                }
                            }
                            DisclosureGroup("Reconstructed basic blocks (CFG)") {
                                Text("Blocks are inferred from decoded branch targets and fall-through edges. Indirect edges may be missing.").font(.caption).foregroundStyle(.secondary)
                                ForEach(trace.basicBlocks) { block in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(String(format: "0x%llx–0x%llx", block.start, block.end))
                                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                                        Text("\(block.instructionCount) instructions · \(block.exitKind) · \(block.predecessorCount) predecessor(s)").font(.caption).foregroundStyle(.secondary)
                                        Text(block.successors.isEmpty ? "Successors: unresolved / none" : "Successors: " + block.successors.map { String(format: "0x%llx", $0) }.joined(separator: ", "))
                                            .font(.system(.caption2, design: .monospaced))
                                    }.padding(.vertical, 4)
                                }
                            }
                            DisclosureGroup("Direct call edges") {
                                Text("Shows direct BL targets only. This is a call map, not recursive interprocedural execution.").font(.caption).foregroundStyle(.secondary)
                                if trace.callEdges.isEmpty { Text("No direct BL calls were decoded in this function.").font(.caption) }
                                ForEach(trace.callEdges) { edge in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(String(format: "0x%llx → 0x%llx", edge.address, edge.target)).font(.system(.caption, design: .monospaced).weight(.semibold))
                                        Text(edge.symbol).font(.system(.caption, design: .monospaced))
                                        Text(edge.kind).font(.caption2).foregroundStyle(.secondary)
                                    }.padding(.vertical, 3)
                                }
                            }
                            DisclosureGroup("Trace limitations") {
                                ForEach(trace.limitations, id: \.self) { item in Text("• \(item)").font(.caption).foregroundStyle(.secondary) }
                            }
                        } else {
                            Text("A full function trace could not be established. This can happen for a string-only finding, an unresolved call site, or incomplete function metadata.").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Label("Read-only: no patch is generated or applied to the analyzed binary.", systemImage: "lock.shield").font(.caption.weight(.medium))
                    }
                }
                Section("Lab lesson — a real ARM64 branch patch") {
                    Text("This fixed example is a teaching fixture, separate from the analyzed app. It demonstrates a valid instruction-level change without generating a patch for the selected binary.")
                        .font(.footnote).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Original: branch when equal", systemImage: "arrow.turn.down.right")
                            .font(.subheadline.weight(.semibold))
                        instructionLine(address: "LAB+0x00", bytes: "40 00 00 54", assembly: "B.EQ 0x8")
                        Label("Lab alternative: branch when not equal", systemImage: "arrow.triangle.swap")
                            .font(.subheadline.weight(.semibold))
                        instructionLine(address: "LAB+0x00", bytes: "41 00 00 54", assembly: "B.NE 0x8")
                        Text("The condition field changes from EQ to NE; the branch displacement stays the same. If the compared values are equal, the original takes the branch and the alternative falls through; if they differ, the opposite happens. The destination blocks and surrounding program determine the actual consequence.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                    Text("Lab fixture only — not a recommendation to alter the selected app. No bytes are written, and this screen has no save, copy, export, or apply action.")
                        .font(.footnote.weight(.medium))
                }
                Section("Before — observed or suspected") {
                    Label(scenario.beforeTitle, systemImage: "lock.shield")
                        .font(.headline)
                    Text(scenario.beforeDetail).font(.subheadline).foregroundStyle(.secondary)
                }
                Section("After — hypothetical change") {
                    Label(scenario.hypotheticalTitle, systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.headline)
                    Text(scenario.hypotheticalDetail).font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Possible repercussions") {
                    ForEach(scenario.repercussions, id: \.self) { item in
                        Label(item, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                    }
                }
                Section("How to verify") {
                    ForEach(scenario.verification, id: \.self) { item in
                        Label(item, systemImage: "checkmark.circle")
                            .font(.subheadline)
                    }
                }
                Section {
                    Text("This is an educational impact preview, not a simulation of the actual binary. No bytes are changed. Confirm the branch, side effects, and runtime outcome before treating an unlock as real.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Change Impact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await loadInstructionEvidence()
                if isPremiumFinding {
                    isLoadingStoreKitTrace = true
                    storeKitTrace = await StoreKitGateTracer.trace(ipaURL: ipaURL, finding: finding)
                    isLoadingStoreKitTrace = false
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func branchMeaning(_ instruction: DecodedInsn) -> String {
        let mnemonic = instruction.mnem.uppercased()
        switch mnemonic {
        case "B.EQ": return "Branches when the previous comparison indicated equality (Z = 1)."
        case "B.NE": return "Branches when the previous comparison indicated inequality (Z = 0)."
        case "B.HI": return "Branches when unsigned comparison indicates higher."
        case "B.LS": return "Branches when unsigned comparison indicates lower or same."
        case "B.GT": return "Branches when signed comparison indicates greater than."
        case "B.LE": return "Branches when signed comparison indicates less than or equal."
        case "B.GE": return "Branches when signed comparison indicates greater than or equal."
        case "B.LT": return "Branches when signed comparison indicates less than."
        case "CBZ": return "Branches if the tested register is zero."
        case "CBNZ": return "Branches if the tested register is nonzero."
        case "TBZ": return "Branches if the tested bit is zero."
        case "TBNZ": return "Branches if the tested bit is nonzero."
        default: return "Conditional control-flow instruction. Confirm the condition and both successor blocks in the CFG."
        }
    }

    @ViewBuilder
    private func instructionLine(address: String, bytes: String, assembly: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(address).frame(width: 76, alignment: .leading).foregroundStyle(.secondary)
            Text(bytes).frame(width: 92, alignment: .leading).foregroundStyle(.tertiary)
            Text(assembly).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .padding(8)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .textSelection(.disabled)
    }

    @MainActor
    private func loadInstructionEvidence() async {
        defer { isLoadingInstructions = false }
        guard finding.confidence == "Resolved imported call" else {
            instructionStatus = "No code address is established for this finding. The result is a string indicator, so treating its VA as executable instructions would be misleading."
            return
        }
        guard let match = finding.location.range(of: #"call 0x[0-9a-fA-F]+"#, options: .regularExpression),
              let addressRange = finding.location[match].range(of: #"0x[0-9a-fA-F]+"#, options: .regularExpression),
              let address = UInt64(finding.location[match][addressRange].dropFirst(2), radix: 16) else {
            instructionStatus = "The finding does not contain a parseable call-site VA."
            return
        }
        guard let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil) else {
            instructionStatus = "AirCore could not reopen the local Mach-O for instruction inspection."
            return
        }
        let start = address >= 16 ? address - 16 : address
        let decoded = AVXDisassembler.disassemble(atVA: start, count: 9, thin: ctx.thin, segments: ctx.segments)
        guard decoded.contains(where: { $0.va == address }) else {
            instructionStatus = "The reported call-site VA could not be decoded in the current ARM64 slice."
            return
        }
        instructionWindow = decoded
        instructionStatus = "Loaded original instructions from the selected binary."
    }
}
