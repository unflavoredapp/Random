import SwiftUI
import UniformTypeIdentifiers

/// A deliberately manual patch-definition workbench. It never writes to or modifies the analyzed binary.
/// Patch candidates are authored and reviewed by the user; no protection bypass is inferred automatically.
struct ManualPatchWorkbench: View {
    let findings: [ProtectionFinding]
    let ipaURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFindingID: String = ""
    @State private var patchName = "Manual instruction change"
    @State private var targetVA = ""
    @State private var originalBytes = ""
    @State private var proposedBytes = ""
    @State private var rationale = ""
    @State private var authorized = false
    @State private var showManifest = false
    @State private var isVerifying = false
    @State private var verificationMessage = "Not verified against the selected binary."
    @State private var verifiedFileOffset: UInt64?
    @State private var verifiedBinaryIdentity = ""
    @State private var verifiedOriginalBytes = ""

    private var premiumFindings: [ProtectionFinding] {
        findings.filter {
            let value = ($0.category + " " + $0.title + " " + $0.note).lowercased()
            return value.contains("storekit") || value.contains("premium") || value.contains("entitlement") || value.contains("purchase") || value.contains("subscription")
        }
    }
    private var selectedFinding: ProtectionFinding? {
        findings.first { String(describing: $0.id) == selectedFindingID }
    }
    private var normalizedOriginal: String { originalBytes.replacingOccurrences(of: "0x", with: "").filter { $0.isHexDigit } }
    private var normalizedProposed: String { proposedBytes.replacingOccurrences(of: "0x", with: "").filter { $0.isHexDigit } }
    private func containsOnlyHexAndSeparators(_ value: String) -> Bool {
        let stripped = value.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        return stripped.allSatisfy { $0.isHexDigit || $0.isWhitespace || $0 == "," || $0 == ":" || $0 == "-" }
    }
    private var validBytes: Bool {
        containsOnlyHexAndSeparators(originalBytes) && containsOnlyHexAndSeparators(proposedBytes) &&
        !normalizedOriginal.isEmpty && normalizedOriginal.count % 2 == 0 &&
        normalizedProposed.count == normalizedOriginal.count && normalizedProposed.count % 2 == 0
    }
    private var validAddress: Bool {
        let raw = targetVA.lowercased().hasPrefix("0x") ? String(targetVA.dropFirst(2)) : targetVA
        guard let value = UInt64(raw, radix: 16) else { return false }
        return value % 4 == 0
    }
    private var verified: Bool {
        guard let offset = verifiedFileOffset else { return false }
        return verifiedBinaryIdentity == ipaURL.standardizedFileURL.path &&
            verifiedOriginalBytes == normalizedOriginal.uppercased() && validBytes && validAddress && offset >= 0
    }

    private func invalidateVerification() {
        verifiedFileOffset = nil
        verifiedBinaryIdentity = ""
        verifiedOriginalBytes = ""
        verificationMessage = "Inputs changed. Verify the address and bytes again."
    }

    /// Resolves the entered VA through the selected main ARM64 Mach-O's segment map,
    /// then compares the bytes at that exact thin-slice file offset against the supplied original.
    private func verifyAgainstSelectedBinary() async {
        isVerifying = true
        defer { isVerifying = false }
        invalidateVerification()
        guard validAddress, validBytes else {
            verificationMessage = "Invalid address or byte sequence."
            return
        }
        guard let context = await LocalBinaryScanner.binaryContext(ipaURL: ipaURL, localPath: nil) else {
            verificationMessage = "Could not load the main executable from the selected IPA."
            return
        }
        let rawAddress = targetVA.lowercased().hasPrefix("0x") ? String(targetVA.dropFirst(2)) : targetVA
        guard let va = UInt64(rawAddress, radix: 16) else {
            verificationMessage = "Invalid virtual address."
            return
        }
        let expected = stride(from: 0, to: normalizedOriginal.count, by: 2).compactMap { i -> UInt8? in
            let start = normalizedOriginal.index(normalizedOriginal.startIndex, offsetBy: i)
            let end = normalizedOriginal.index(start, offsetBy: 2)
            return UInt8(normalizedOriginal[start..<end], radix: 16)
        }
        guard expected.count == normalizedOriginal.count / 2 else {
            verificationMessage = "Original bytes contain invalid hexadecimal."
            return
        }
        let matching = context.segments.filter { segment in
            guard va >= segment.vmaddr else { return false }
            let delta = va - segment.vmaddr
            guard delta < segment.filesize, UInt64(expected.count) <= segment.filesize - delta else { return false }
            return true
        }
        guard matching.count == 1, let segment = matching.first else {
            verificationMessage = matching.isEmpty
                ? "Address is not backed by file bytes in the selected Mach-O. It may be unmapped or in zero-fill memory."
                : "Address maps to multiple segments; refusing ambiguous mapping."
            return
        }
        let delta = va - segment.vmaddr
        let offset = segment.fileoff + delta
        guard offset <= UInt64(Int.max), Int(offset) <= context.thin.count,
              expected.count <= context.thin.count - Int(offset) else {
            verificationMessage = "Mapped file offset falls outside the selected thin Mach-O slice."
            return
        }
        let actual = Array(context.thin[Int(offset)..<Int(offset) + expected.count])
        guard actual == expected else {
            verificationMessage = "MISMATCH: the bytes at VA 0x\(String(va, radix: 16)) are \(actual.map { String(format: "%02X", $0) }.joined(separator: " ")). Supplied original bytes do not match; definition generation is blocked."
            return
        }
        verifiedFileOffset = offset
        verifiedBinaryIdentity = ipaURL.standardizedFileURL.path
        verifiedOriginalBytes = normalizedOriginal.uppercased()
        verificationMessage = "VERIFIED: VA 0x\(String(va, radix: 16)) maps through segment \(segment.name) to thin-slice file offset 0x\(String(offset, radix: 16)); original bytes match exactly."
    }

    private var manifest: String {
        let object: [String: Any] = [
            "format": "AirCore.ManualPatchDefinition.v1",
            "name": patchName,
            "targetVirtualAddress": targetVA,
            "verifiedThinSliceFileOffset": (verifiedFileOffset.map { String(format: "0x%llx", $0) } as Any?) ?? NSNull(),
            "binaryPath": ipaURL.lastPathComponent,
            "originalBytesVerifiedAgainstSelectedBinary": verified,
            "architecture": "arm64",
            "originalBytes": normalizedOriginal.uppercased().enumerated().map { index, char in index % 2 == 0 ? String(char) : String(char) }.joined(),
            "proposedBytes": normalizedProposed.uppercased(),
            "findingTitle": selectedFinding?.title ?? "Manual finding",
            "findingCategory": selectedFinding?.category ?? "Unspecified",
            "rationale": rationale,
            "authorizationConfirmed": authorized,
            "mode": "definition-only; does not modify a binary"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "Unable to construct definition." }
        return text
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Premium gate findings") {
                    if premiumFindings.isEmpty {
                        Text("No premium / StoreKit findings were supplied. You can still create a generic manual definition below.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Picker("Finding", selection: $selectedFindingID) {
                            Text("Choose a finding").tag("")
                            ForEach(premiumFindings, id: \.id) { finding in
                                Text("\(finding.title) · \(finding.confidence)").tag(String(describing: finding.id))
                            }
                        }
                        if let finding = selectedFinding {
                            Text(finding.category).font(.caption).foregroundStyle(.secondary)
                            Text(finding.location).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            ForEach(finding.evidence, id: \.self) { evidence in
                                Text(evidence).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                            }
                            Text("A detected indicator is evidence to review, not proof that this location controls premium access.").font(.footnote).foregroundStyle(.orange)
                        }
                    }
                }
                Section("Manually define a candidate") {
                    TextField("Patch definition name", text: $patchName)
                    TextField("Target virtual address (hex, e.g. 0x100012340)", text: $targetVA)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Original bytes (hex)", text: $originalBytes)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    TextField("Proposed bytes (hex)", text: $proposedBytes)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Text("For ARM64, address must be 4-byte aligned. Original and proposed byte sequences must have equal, nonzero lengths. Separate bytes with spaces if preferred.")
                        .font(.footnote).foregroundStyle(.secondary)
                    TextField("Reasoning and expected behavior", text: $rationale, axis: .vertical).lineLimit(3...6)
                    Toggle("I own this binary or am authorized to modify it", isOn: $authorized)
                }
                Section("Selected binary verification") {
                    Button {
                        Task { await verifyAgainstSelectedBinary() }
                    } label: {
                        if isVerifying { ProgressView("Verifying selected binary…") }
                        else { Label("Verify address and original bytes", systemImage: "checkmark.shield") }
                    }
                    .disabled(isVerifying || !validAddress || !validBytes)
                    Text(verificationMessage)
                        .font(.footnote.monospaced())
                        .foregroundStyle(verified ? .green : (verificationMessage.hasPrefix("MISMATCH") ? .red : .secondary))
                    if verified, let offset = verifiedFileOffset {
                        Text("Selected IPA: \(ipaURL.lastPathComponent) · thin-slice offset 0x\(String(offset, radix: 16))")
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
                Section("Review") {
                    Label(validAddress ? "Address alignment: valid" : "Enter a valid, 4-byte-aligned hexadecimal address", systemImage: validAddress ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(validAddress ? .green : .secondary)
                    Label(validBytes ? "Byte lengths match" : "Original and proposed bytes must be valid equal-length hex sequences", systemImage: validBytes ? "checkmark.circle" : "exclamationmark.circle")
                        .foregroundStyle(validBytes ? .green : .secondary)
                    Label(verified ? "Original bytes match selected binary" : "Selected-binary verification required", systemImage: verified ? "checkmark.seal.fill" : "exclamationmark.triangle")
                        .foregroundStyle(verified ? .green : .orange)
                    Label(authorized ? "Authorization confirmed" : "Authorization confirmation required", systemImage: authorized ? "checkmark.shield" : "lock.shield")
                        .foregroundStyle(authorized ? .green : .secondary)
                    Text("This workbench is intentionally manual: it does not infer a premium-unlock instruction, alter the IPA, or apply a candidate. It creates a reviewable definition only.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { showManifest = true } label: {
                        Label("Generate patch definition", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(!validAddress || !validBytes || !verified || !authorized || patchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Manual Patch Generator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } } }
            .sheet(isPresented: $showManifest) {
                NavigationStack {
                    ScrollView { Text(manifest).font(.system(.footnote, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                        .navigationTitle("Patch Definition")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) { Button("Done") { showManifest = false } }
                        }
                }
            }
        }
        .onChange(of: targetVA) { _ in invalidateVerification() }
        .onChange(of: originalBytes) { _ in invalidateVerification() }
        .onChange(of: proposedBytes) { _ in invalidateVerification() }
        .onChange(of: ipaURL) { _ in invalidateVerification() }
        .preferredColorScheme(.dark)
    }
}
