import Foundation

/// Surfaces App Store receipt and device/app-attestation code for inspection.
nonisolated enum ReceiptAttestationAnalysis {
    static let profile = ProtectionProfile(
        category: "Receipt / device attestation",
        title: "Receipt validation / attestation indicators",
        importTerms: ["skreceiptrefreshrequest", "apptransaction", "dcdevice", "dcappattestservice", "generateassertion", "attestkey", "receiptrefresh", "verifyreceipt"],
        stringTerms: ["receiptvalidation", "appattest", "devicecheck", "validatereceipt", "verifyreceipt", "appstore.receipt", "apptransaction", "productionreceipt", "sandboxreceipt", "bundleid", "originalapplicationversion"],
        note: "Trace the validation result and its callers to learn why a build is rejected. This module does not forge receipts, assertions, or App Store identity. For owned apps, prefer a documented development/test validation mode."
    )
}
