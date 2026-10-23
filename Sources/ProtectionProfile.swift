import Foundation

/// A static-analysis profile. Matches are investigative leads, not a vulnerability verdict.
nonisolated struct ProtectionProfile: Sendable {
    let category: String
    let title: String
    let importTerms: [String]
    let stringTerms: [String]
    let note: String
}

nonisolated enum ProtectionProfiles {
    static let all: [ProtectionProfile] = [
        .init(category: "Jailbreak detection", title: "Filesystem / URL-scheme indicators",
              importTerms: ["access", "stat", "lstat", "fopen", "opendir", "fileexistsatpath", "filemanager"],
              stringTerms: ["/applications/cydia.app", "/library/mobilesubstrate", "/usr/sbin/sshd", "cydia://", "sileo://", "checkra1n", "jailbreak", "isjailbroken", "canopenurl", "ellekit", "libhooker"],
              note: "The call site and matching string are evidence of a relevant probe, not proof that its result blocks execution."),
        .init(category: "Anti-debugging", title: "Debugger / tracing API call",
              importTerms: ["ptrace", "sysctl", "task_get_exception_ports", "mach_port_kobject"],
              stringTerms: ["pt_deny_attach", "p_traced", "debugserver", "beingdebugged", "anti-debug"],
              note: "Inspect arguments and result handling before concluding this call restricts debugging."),
        SSLPinningAnalysis.profile,
        ReceiptAttestationAnalysis.profile,
        StoreKitGateAnalysis.profile,
        LoadedTweakAnalysis.profile,
        ScreenCaptureAnalysis.profile
    ]
}
