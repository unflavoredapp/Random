import Foundation

/// Finds certificate/trust-validation implementation clues for authorized review.
/// It does not disable trust evaluation or alter network traffic.
nonisolated enum SSLPinningAnalysis {
    static let profile = ProtectionProfile(
        category: "SSL / certificate validation",
        title: "Trust evaluation / certificate-pinning indicators",
        importTerms: ["sectrustevaluate", "sectrustevaluatewitherror", "secpolicycreate", "seccertificatecopy", "seckeycopy", "sec_trust_evaluate"],
        stringTerms: ["servertrust", "didreceivechallenge", "publickey", "certificatepinning", "pinnedcertificate", "trustkit", "alamofire", "sha256", "spki", "certificatehash", "evaluateServerTrust"],
        note: "Review the trust-evaluation result, certificate/key comparison, and failure branch in the CFG. A symbol or hash-like string alone does not prove pinning is enforced. For proxy testing, use a test build or an explicitly authorized trust configuration."
    )
}
