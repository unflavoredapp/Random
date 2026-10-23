import Foundation

/// Read-only, static control-flow tracing for StoreKit/entitlement findings.
/// This deliberately reports evidence and uncertainty; it never emits modified bytes.
nonisolated struct StoreKitGateTrace {
    struct Branch: Identifiable, Sendable {
        let address: UInt64
        let mnemonic: String
        let operands: String
        let target: UInt64?
        let fallthroughAddress: UInt64
        let distanceFromFinding: UInt64
        let nearbyInstructions: [String]
        let registerHints: [String]
        var id: UInt64 { address }
    }
    let functionName: String
    let functionStart: UInt64
    let functionEnd: UInt64
    let callSite: UInt64
    let instructions: [DecodedInsn]
    let branches: [Branch]
    struct BasicBlock: Identifiable, Sendable {
        let start: UInt64
        let end: UInt64
        let instructionCount: Int
        let successors: [UInt64]
        let predecessorCount: Int
        let exitKind: String
        var id: UInt64 { start }
    }
    struct CallEdge: Identifiable, Sendable {
        let address: UInt64
        let target: UInt64
        let symbol: String
        let kind: String
        var id: UInt64 { address }
    }
    struct RegisterFlow: Identifiable, Sendable {
        let branchAddress: UInt64
        let register: String
        let definitionAddress: UInt64?
        let definition: String
        let interveningInstructions: Int
        var id: String { "\(branchAddress)-\(register)" }
    }
    let basicBlocks: [BasicBlock]
    let callEdges: [CallEdge]
    let registerFlows: [RegisterFlow]
    let confidence: String
    let summary: String
    let limitations: [String]
}

nonisolated enum StoreKitGateTracer {
    private static let maxFunctionBytes = 64 * 1024
    private static let branchMnemonics: Set<String> = [
        "B.EQ", "B.NE", "B.HI", "B.LS", "B.GE", "B.LT", "B.GT", "B.LE", "B.CS", "B.CC", "B.MI", "B.PL", "B.VS", "B.VC", "CBZ", "CBNZ", "TBZ", "TBNZ"
    ]

    static func trace(ipaURL: URL, finding: ProtectionFinding) async -> StoreKitGateTrace? {
        guard isStoreKitFinding(finding),
              let callSite = parseCallSite(finding.location),
              let ctx = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil),
              let text = MachOTools.textSection(ctx.sections, in: ctx.thin) else { return nil }

        let starts = MachOTools.functionStarts(in: ctx.thin).sorted()
        var functionStart = starts.last(where: { $0 <= callSite })
        if functionStart == nil {
            functionStart = AVXDisassembler.inferFunctionEntry(textVA: text.vmaddr, textData: text.data, xrefVA: callSite)
        }
        guard let start = functionStart, callSite >= start,
              let offset = MachOTools.fileOffset(forVA: start, segments: ctx.segments), offset < ctx.thin.count else { return nil }

        let nextStart = starts.first(where: { $0 > start })
        let availableBytes: Int
        if let nextStart, nextStart > start {
            availableBytes = Int(min(UInt64(maxFunctionBytes), nextStart - start))
        } else {
            availableBytes = maxFunctionBytes
        }
        let endOffset = min(ctx.thin.count, offset + max(0, availableBytes))
        guard endOffset > offset + 4 else { return nil }
        let bytes = ctx.thin.subdata(in: offset..<endOffset)
        var instructions: [DecodedInsn] = []
        bytes.withUnsafeBytes { raw in
            let count = raw.count / 4
            instructions.reserveCapacity(count)
            for i in 0..<count {
                let p = i * 4
                let word = raw.loadUnaligned(fromByteOffset: p, as: UInt32.self)
                let insn = AVXDisassembler.decode(va: start + UInt64(p), insn: word)
                instructions.append(insn)
                // A function boundary is known from LC_FUNCTION_STARTS; stop at a terminal return only
                // when no reliable next start exists, to avoid decoding unrelated data as code.
                if nextStart == nil && i > 0 && insn.mnem.uppercased() == "RET" { break }
            }
        }
        guard instructions.contains(where: { $0.va == callSite }) else { return nil }

        let symbols = MachOTools.symbolMap(in: ctx.thin)
        let functionName = symbols[start].map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }
            ?? String(format: "sub_%llx", start)
        let candidateBranches = instructions.enumerated().compactMap { index, insn -> StoreKitGateTrace.Branch? in
            let mnemonic = insn.mnem.uppercased()
            guard branchMnemonics.contains(mnemonic) else { return nil }
            let dist = insn.va >= callSite ? insn.va - callSite : callSite - insn.va
            let lower = max(0, index - 3), upper = min(instructions.count, index + 4)
            let nearby = instructions[lower..<upper].map {
                String(format: "0x%llx  %@ %@", $0.va, $0.mnem, $0.ops).trimmingCharacters(in: .whitespaces)
            }
            let hints = registerHints(around: instructions, branchIndex: index)
            return StoreKitGateTrace.Branch(address: insn.va, mnemonic: insn.mnem, operands: insn.ops,
                target: insn.branchTgt, fallthroughAddress: insn.va + 4, distanceFromFinding: dist,
                nearbyInstructions: nearby, registerHints: hints)
        }.sorted {
            if $0.distanceFromFinding != $1.distanceFromFinding { return $0.distanceFromFinding < $1.distanceFromFinding }
            return $0.address < $1.address
        }

        let basicBlocks = buildBasicBlocks(instructions)
        let importStubs = MachOTools.importStubMap(in: ctx.thin)
        let directCalls: [StoreKitGateTrace.CallEdge] = instructions.compactMap { insn in
            guard insn.mnem.uppercased() == "BL", let target = insn.branchTgt else { return nil }
            let rawName = importStubs[target] ?? symbols[target]
            let name = rawName.map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 }
                ?? String(format: "sub_%llx", target)
            return StoreKitGateTrace.CallEdge(address: insn.va, target: target, symbol: name,
                kind: importStubs[target] != nil ? "Imported API stub" : (symbols[target] != nil ? "Named internal/external symbol" : "Direct call target"))
        }
        let registerFlows = candidateBranches.compactMap { branch in
            traceRegisterDefinition(branch: branch, instructions: instructions)
        }
        let closeBranches = candidateBranches.filter { $0.distanceFromFinding <= 96 }
        let summary: String
        let confidence: String
        if !closeBranches.isEmpty {
            summary = "A conditional branch exists within 96 bytes of the resolved call site in the same function. This is a candidate decision point, not proof that it controls the entitlement result."
            confidence = "Candidate branch found"
        } else if !candidateBranches.isEmpty {
            summary = "Conditional branches exist in the containing function, but none is close to the call site. Inspect data flow and successor blocks before linking any branch to premium state."
            confidence = "Function-level evidence only"
        } else {
            summary = "No supported conditional branch was decoded in the available function range. The entitlement decision may be in a callee, use indirect control flow, or be enforced by a server."
            confidence = "No local branch established"
        }
        return StoreKitGateTrace(functionName: functionName, functionStart: start,
            functionEnd: start + UInt64(instructions.count * 4), callSite: callSite,
            instructions: instructions, branches: candidateBranches, basicBlocks: basicBlocks,
            callEdges: directCalls, registerFlows: registerFlows, confidence: confidence,
            summary: summary, limitations: [
                "Register definition tracing is a bounded textual def-use heuristic, not full ARM64 SSA or symbolic execution.",
                "Basic blocks are reconstructed from decoded direct branch targets; indirect jumps, exception edges, and some tail calls are not recovered.",
                "Direct call edges are listed, but callees are not recursively decompiled and interprocedural values are not propagated.",
                "Objective-C message dispatch, Swift async state machines, and cross-function value flow may hide the decision.",
                "A local entitlement branch does not establish server authorization or a valid StoreKit transaction.",
                "Function boundaries can be incomplete in stripped or unusual Mach-O binaries."
            ])
    }

    private static func buildBasicBlocks(_ instructions: [DecodedInsn]) -> [StoreKitGateTrace.BasicBlock] {
        guard !instructions.isEmpty else { return [] }
        let addresses = Set(instructions.map(\.va))
        var leaders: Set<UInt64> = [instructions[0].va]
        for (i, insn) in instructions.enumerated() {
            let m = insn.mnem.uppercased()
            if let target = insn.branchTgt, addresses.contains(target),
               m == "B" || m.hasPrefix("B.") || m == "CBZ" || m == "CBNZ" || m == "TBZ" || m == "TBNZ" {
                leaders.insert(target)
            }
            if (m == "B" || m.hasPrefix("B.") || m == "CBZ" || m == "CBNZ" || m == "TBZ" || m == "TBNZ" || m == "RET" || m == "BR"), i + 1 < instructions.count {
                leaders.insert(instructions[i + 1].va)
            }
        }
        let ordered = instructions.filter { leaders.contains($0.va) }.map(\.va).sorted()
        var blocks: [StoreKitGateTrace.BasicBlock] = []
        for (idx, start) in ordered.enumerated() {
            guard let begin = instructions.firstIndex(where: { $0.va == start }) else { continue }
            let endIndex = idx + 1 < ordered.count ? (instructions.firstIndex(where: { $0.va == ordered[idx + 1] }) ?? instructions.count) : instructions.count
            guard endIndex > begin else { continue }
            let slice = Array(instructions[begin..<endIndex])
            guard let last = slice.last else { continue }
            let m = last.mnem.uppercased()
            var successors: [UInt64] = []
            if m == "B" {
                if let target = last.branchTgt, addresses.contains(target) { successors.append(target) }
            } else if m == "RET" || m == "BR" {
                // Indirect branch/return: successor cannot be established statically.
            } else {
                if m.hasPrefix("B.") || m == "CBZ" || m == "CBNZ" || m == "TBZ" || m == "TBNZ" {
                    if let target = last.branchTgt, addresses.contains(target) { successors.append(target) }
                }
                if endIndex < instructions.count { successors.append(instructions[endIndex].va) }
            }
            let exit = m == "RET" ? "return" : (m == "BR" ? "indirect branch" : (m == "B" ? "unconditional branch" : ((m.hasPrefix("B.") || m == "CBZ" || m == "CBNZ" || m == "TBZ" || m == "TBNZ") ? "conditional branch" : "fall-through")))
            blocks.append(.init(start: start, end: last.va + 4, instructionCount: slice.count, successors: Array(Set(successors)).sorted(), predecessorCount: 0, exitKind: exit))
        }
        let predecessorCounts = blocks.reduce(into: [UInt64: Int]()) { result, block in
            for successor in block.successors { result[successor, default: 0] += 1 }
        }
        return blocks.map { .init(start: $0.start, end: $0.end, instructionCount: $0.instructionCount,
                                  successors: $0.successors, predecessorCount: predecessorCounts[$0.start, default: 0], exitKind: $0.exitKind) }
    }

    private static func traceRegisterDefinition(branch: StoreKitGateTrace.Branch, instructions: [DecodedInsn]) -> StoreKitGateTrace.RegisterFlow? {
        guard let index = instructions.firstIndex(where: { $0.va == branch.address }) else { return nil }
        let m = branch.mnemonic.uppercased()
        let register: String? = {
            let first = branch.operands.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
            if ["CBZ", "CBNZ", "TBZ", "TBNZ"].contains(m) { return first }
            return nil
        }()
        guard let reg = register else {
            // B.cond consumes NZCV, so find the nearest flag-setting instruction.
            let begin = max(0, index - 12)
            if begin < index, let def = instructions[begin..<index].last(where: { ["CMP", "CMN", "TST", "SUBS", "ADDS", "ANDS", "CCMP", "CCMN"].contains($0.mnem.uppercased()) }) {
                // Compute safely without UInt64 underflow or Int overflow.
                let diff: UInt64 = branch.address >= def.va ? branch.address - def.va : 0
                let rawCount = diff / 4
                let count = rawCount > UInt64(Int.max) ? Int.max : Int(rawCount)
                let interveningCount = max(0, count - 1)
                return .init(branchAddress: branch.address, register: "NZCV", definitionAddress: def.va,
                             definition: "\(def.mnem) \(def.ops)", interveningInstructions: interveningCount)
            }
            return nil
        }
        let begin = max(0, index - 16)
        guard begin < index else { return .init(branchAddress: branch.address, register: reg, definitionAddress: nil, definition: "No definition found in bounded window", interveningInstructions: 0) }
        for i in stride(from: index - 1, through: begin, by: -1) {
            let insn = instructions[i]
            let first = insn.ops.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init)?.trimmingCharacters(in: .whitespaces)
            if first == reg {
                return .init(branchAddress: branch.address, register: reg, definitionAddress: insn.va,
                             definition: "\\(insn.mnem) \\(insn.ops)", interveningInstructions: index - i - 1)
            }
        }
        return .init(branchAddress: branch.address, register: reg, definitionAddress: nil, definition: "No definition found in previous 16 instructions", interveningInstructions: 0)
    }

    static func isStoreKitFinding(_ finding: ProtectionFinding) -> Bool {
        let c = finding.category.lowercased(), t = finding.title.lowercased()
        return c.contains("purchase") || c.contains("storekit") || c.contains("premium") || c.contains("entitlement") || t.contains("storekit") || t.contains("entitlement")
    }

    private static func parseCallSite(_ location: String) -> UInt64? {
        guard let r = location.range(of: #"call 0x[0-9a-fA-F]+"#, options: .regularExpression),
              let a = location[r].range(of: #"0x[0-9a-fA-F]+"#, options: .regularExpression) else { return nil }
        return UInt64(location[r][a].dropFirst(2), radix: 16)
    }

    private static func registerHints(around instructions: [DecodedInsn], branchIndex: Int) -> [String] {
        let begin = max(0, branchIndex - 8)
        let window = instructions[begin...branchIndex]
        let joined = window.map { "\($0.mnem) \($0.ops)" }.joined(separator: "\n")
        var hints: [String] = []
        let lower = joined.lowercased()
        if lower.contains("cmp") || lower.contains("subs") || lower.contains("ccmp") { hints.append("A compare/flags-setting instruction appears in the preceding window.") }
        if lower.contains("tst") || lower.contains("ands") { hints.append("A bit-test/ANDs instruction appears in the preceding window.") }
        if lower.contains("currententitlements") || lower.contains("verificationresult") || lower.contains("haspremium") || lower.contains("entitlement") { hints.append("Entitlement-related text appears in the local instruction window.") }
        if hints.isEmpty { hints.append("No simple compare/test pattern was recognized in the preceding eight instructions.") }
        return hints
    }
}
