import Foundation

/// Finds dynamic-image enumeration and instrumentation-name indicators.
nonisolated enum LoadedTweakAnalysis {
    static let profile = ProtectionProfile(
        category: "Loaded-tweak detection",
        title: "Loaded-image / instrumentation indicators",
        importTerms: ["_dyld_image_count", "_dyld_get_image_name", "_dyld_get_image_header", "dladdr", "dlsym", "dlopen"],
        stringTerms: ["mobilesubstrate", "libhooker", "frida", "cycript", "ellekit", "substitute", "substrate", "frida-gadget", "gadget.dylib", "fishhook"],
        note: "Inspect the image-enumeration loop, string comparisons, and downstream branch/termination behavior. Image enumeration or a library name alone is not proof that a detection check is active."
    )
}
