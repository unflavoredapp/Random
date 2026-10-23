import Foundation

/// Rules used by AirShare's analysis UI.
///
/// Production analysis values must originate from bytes/metadata recovered from the
/// currently loaded binary. A display limit is never a discovered count, and a
/// bounded decode window is never presented as a function size.
enum AnalysisEvidenceState: String, Codable, Sendable {
    case detected
    case partial
    case unavailable
    case notSupported
    case invalid
}

struct AnalysisEvidence: Sendable {
    let state: AnalysisEvidenceState
    let source: String
    let detail: String

    static func detected(source: String, detail: String) -> Self {
        Self(state: .detected, source: source, detail: detail)
    }

    static func partial(source: String, detail: String) -> Self {
        Self(state: .partial, source: source, detail: detail)
    }

    static func unavailable(source: String, detail: String) -> Self {
        Self(state: .unavailable, source: source, detail: detail)
    }

    static func notSupported(source: String, detail: String) -> Self {
        Self(state: .notSupported, source: source, detail: detail)
    }

    static func invalid(source: String, detail: String) -> Self {
        Self(state: .invalid, source: source, detail: detail)
    }
}

enum AnalysisDisplayRule {
    /// A display/pagination cap is not the total number of records.
    static func shownLabel(_ noun: String, shown: Int, hasMore: Bool) -> String {
        hasMore ? "\(shown) \(noun) shown • more available" : "\(shown) \(noun)"
    }

    /// Bounded decoding must never be described as the discovered function size.
    static func boundedDecodeDetail(maxBytes: Int) -> String {
        "Decoded within a \(maxBytes)-byte analysis window; function size is determined separately."
    }
}
