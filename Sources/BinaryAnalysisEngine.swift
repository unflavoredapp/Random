import Foundation

/// Local, evidence-first analysis model. Every displayed count comes from bytes
/// actually extracted from the selected Mach-O; unavailable metadata is nil.
nonisolated struct BinaryAnalysisReport: Sendable {
    struct SectionInfo: Identifiable, Sendable {
        let id: String
        let segment: String
        let name: String
        let address: UInt64
        let offset: UInt64
        let size: UInt64
        var endAddress: UInt64 { address &+ size }
    }

    struct MetadataEvidence: Sendable {
        let available: Bool
        let source: String
        let count: Int
        let values: [String]
        let note: String?
        let truncated: Bool
    }

    let binarySize: Int
    let architecture: String
    let sections: [SectionInfo]
    let strings: [String]
    let objcClasses: MetadataEvidence
    let objcSelectors: MetadataEvidence
    let swiftMetadata: MetadataEvidence
    let executableRange: Range<UInt64>?
    let textRange: Range<UInt64>?
}

enum BinaryAnalysisEngine {
    static func analyze(ipaURL: URL) async -> BinaryAnalysisReport? {
        guard let raw = await LocalBinaryScanner.rawMainBinary(ipaURL: ipaURL), !raw.isEmpty else { return nil }
        let thin = MachOTools.thinArm64(raw)
        let sections = MachOTools.sections(in: thin)
        let segments = MachOTools.segments(in: thin)
        guard !thin.isEmpty else { return nil }

        let infos = sections.map {
            BinaryAnalysisReport.SectionInfo(
                id: "\($0.segment).\($0.name)", segment: $0.segment, name: $0.name,
                address: $0.addr, offset: $0.offset, size: $0.size)
        }

        let cstrings = extractCStringTable(named: "__cstring", sections: sections, data: thin)
        let objcClassNames = extractCStringTable(named: "__objc_classname", sections: sections, data: thin)
        let objcSelectors = extractCStringTable(named: "__objc_methname", sections: sections, data: thin)
        let swiftRefl = extractCStringTable(named: "__swift5_reflstr", sections: sections, data: thin)
        let swiftSections = sections.filter { $0.segment == "__TEXT" && $0.name.hasPrefix("__swift5_") }

        let executable = segments.filter { $0.name == "__TEXT" && $0.filesize > 0 }
            .map { $0.vmaddr ..< ($0.vmaddr &+ $0.filesize) }
            .first
        let text = sections.first(where: { $0.segment == "__TEXT" && $0.name == "__text" })
            .map { $0.addr ..< ($0.addr &+ $0.size) }

        let classListEntries = sections.first(where: { ($0.segment == "__DATA" || $0.segment == "__DATA_CONST") && $0.name == "__objc_classlist" })
            .map { countPointerEntries(section: $0, data: thin) } ?? 0
        let objcClassEvidence: BinaryAnalysisReport.MetadataEvidence
        if classListEntries > 0 {
            let names = objcClassNames.values
            let note: String? = names.count < classListEntries
                ? "Recovered \(names.count) class-name strings for \(classListEntries) class-list entries."
                : nil
            objcClassEvidence = .init(available: true, source: "__objc_classlist", count: classListEntries, values: names, note: note, truncated: objcClassNames.truncated)
        } else if sections.contains(where: { ($0.segment == "__DATA" || $0.segment == "__DATA_CONST") && $0.name == "__objc_classlist" }) {
            objcClassEvidence = .init(available: false, source: "__objc_classlist", count: 0, values: [], note: "Objective-C class-list section exists but contains no recoverable class pointers.", truncated: false)
        } else {
            objcClassEvidence = .init(available: false, source: "__objc_classlist", count: 0, values: [], note: "Objective-C class metadata section is not present in this binary.", truncated: false)
        }

        let objcSelectorEvidence = BinaryAnalysisReport.MetadataEvidence(
            available: sections.contains(where: { $0.name == "__objc_methname" }) && objcSelectors.count > 0,
            source: "__objc_methname", count: objcSelectors.count, values: objcSelectors.values,
            note: objcSelectors.count == 0 ? "No Objective-C selector strings were recoverable." : nil,
            truncated: objcSelectors.truncated)

        let swiftEvidence = BinaryAnalysisReport.MetadataEvidence(
            available: !swiftSections.isEmpty,
            source: swiftSections.map { $0.name }.joined(separator: ", "),
            count: swiftRefl.count,
            values: swiftRefl.values,
            note: swiftSections.isEmpty ? "No __swift5_* metadata sections were found." : (swiftRefl.count == 0 ? "Swift metadata sections exist, but reflection strings were not recoverable." : nil),
            truncated: swiftRefl.truncated)

        return BinaryAnalysisReport(
            binarySize: thin.count,
            architecture: architectureName(thin),
            sections: infos,
            strings: cstrings.values,
            objcClasses: objcClassEvidence,
            objcSelectors: objcSelectorEvidence,
            swiftMetadata: swiftEvidence,
            executableRange: executable,
            textRange: text)
    }

    private struct CStringEvidence {
        let values: [String]
        let count: Int
        let truncated: Bool
    }

    private static func extractCStringTable(named name: String, sections: [MachOTools.Section], data: Data, limit: Int = 20_000) -> CStringEvidence {
        guard let s = sections.first(where: { $0.name == name }), s.offset < UInt64(data.count) else { return .init(values: [], count: 0, truncated: false) }
        let start = Int(s.offset)
        let end = min(data.count, start + Int(s.size))
        guard start < end else { return .init(values: [], count: 0, truncated: false) }
        let bytes = data[start..<end]
        var result: [String] = []
        result.reserveCapacity(min(limit, 1024))
        var current: [UInt8] = []
        current.reserveCapacity(64)
        var total = 0
        for b in bytes {
            if b == 0 {
                if let value = String(bytes: current, encoding: .utf8), !value.isEmpty {
                    total += 1
                    if result.count < limit { result.append(value) }
                }
                current.removeAll(keepingCapacity: true)
            } else if b >= 0x20 && b < 0x7F {
                current.append(b)
            } else {
                current.removeAll(keepingCapacity: true)
            }
        }
        return .init(values: result, count: total, truncated: total > result.count)
    }

    private static func readLittleEndianUInt64(from data: Data, at offset: Int) -> UInt64 {
        let b0 = UInt64(data[offset])
        let b1 = UInt64(data[offset + 1])
        let b2 = UInt64(data[offset + 2])
        let b3 = UInt64(data[offset + 3])
        let b4 = UInt64(data[offset + 4])
        let b5 = UInt64(data[offset + 5])
        let b6 = UInt64(data[offset + 6])
        let b7 = UInt64(data[offset + 7])

        return b0
            | (b1 << 8)
            | (b2 << 16)
            | (b3 << 24)
            | (b4 << 32)
            | (b5 << 40)
            | (b6 << 48)
            | (b7 << 56)
    }

    private static func countPointerEntries(section: MachOTools.Section, data: Data) -> Int {
        guard section.offset < UInt64(data.count) else { return 0 }

        let start = Int(section.offset)
        let available = min(Int(section.size), data.count - start)
        guard available >= 8 else { return 0 }

        var count = 0
        var cursor = start
        let end = start + available - (available % 8)

        while cursor < end {
            let value = readLittleEndianUInt64(from: data, at: cursor)

            if value != 0 {
                count += 1
            }

            cursor += 8
        }

        return count
    }

    private static func architectureName(_ thin: Data) -> String {
        guard thin.count >= 12 else { return "Unavailable" }
        let cpu = UInt32(thin[4]) | (UInt32(thin[5]) << 8) | (UInt32(thin[6]) << 16) | (UInt32(thin[7]) << 24)
        let sub = UInt32(thin[8]) | (UInt32(thin[9]) << 8) | (UInt32(thin[10]) << 16) | (UInt32(thin[11]) << 24)
        switch cpu {
        case 0x0100000C:
            return sub == 2 ? "arm64e" : "arm64"
        case 7: return "x86"
        case 0x01000007: return "x86_64"
        default: return String(format: "CPU 0x%08x", cpu)
        }
    }
}
