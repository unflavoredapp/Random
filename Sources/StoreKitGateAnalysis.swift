import Foundation

/// Groups StoreKit and entitlement evidence separately from generic branch candidates.
nonisolated enum StoreKitGateAnalysis {
    static let profile = ProtectionProfile(
        category: "In-app purchase gates",
        title: "StoreKit purchase / entitlement indicators",
        importTerms: ["skpaymentqueue", "skproduct", "skpayment", "sktransaction", "apptransaction", "currententitlements", "verificationresult", "transaction.updates", "finishtransaction"],
        stringTerms: ["currententitlements", "verificationresult", "transaction.updates", "haspremium", "ispremium", "entitlement", "premium", "purchase", "subscription", "productid", "revocationdate", "expirationdate"],
        note: "Use call-site and CFG evidence to understand entitlement decisions. These indicators do not establish a valid purchase and this module never fabricates transactions or unlocks paid features. Test with StoreKit Configuration files or sandbox purchases for apps you control."
    )
}
