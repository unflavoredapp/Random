//
// Brand: decrypt.software XPC · public site https://fastdecrypt.bot
//  DecryptSoftwareXPCClient.swift
//  Swift façade for the hand-rolled XPC product (software.decrypt.xpc).
//  The C service lives under DecryptSoftwareXPC/ and builds on macOS via Make.
//  On iPhone the installed companion remains the FairPlay worker; this type
//  exposes brand identity + availability for Settings / Mac routing.
//

import Foundation

/// Brand + service identity for the decrypt.software XPC product.
enum DecryptSoftwareXPC {
    static let brand = "decrypt.software"
    /// Public Decrypt site / API edge (not the XPC product name).
    static let site = "https://fastdecrypt.bot"
    static let siteURL = URL(string: site)!
    static let serviceName = "software.decrypt.xpc"
    static let version = "1.0.0"
    static let stamp = "Brand: decrypt.software · XPC software.decrypt.xpc"
}

enum DecryptSoftwareXPCError: LocalizedError {
    case unsupportedPlatform
    case notLinked
    case connect(String)
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "\(DecryptSoftwareXPC.brand) XPC (\(DecryptSoftwareXPC.serviceName)) is the Mac helper. On iPhone use FastDecryptBot / EmbeddedPayload."
        case .notLinked:
            return "\(DecryptSoftwareXPC.brand) XPC client isn’t linked in this build. Build DecryptSoftwareXPC on macOS (`make`) and embed \(DecryptSoftwareXPC.serviceName)."
        case .connect(let detail):
            return "Couldn't connect to \(DecryptSoftwareXPC.serviceName): \(detail)"
        case .remote(let detail):
            return "\(DecryptSoftwareXPC.brand) XPC error: \(detail)"
        }
    }
}

/// Availability + brand helpers. Wire the C client on macOS host targets separately.
enum DecryptSoftwareXPCClient {
    /// True only on macOS host builds that embed/link the XPC service.
    static var isAvailable: Bool {
        #if os(macOS)
        return FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL
                .appendingPathComponent("Contents/XPCServices/\(DecryptSoftwareXPC.serviceName).xpc")
                .path
        )
        #else
        return false
        #endif
    }

    static func ping() throws {
        #if os(macOS)
        guard isAvailable else { throw DecryptSoftwareXPCError.notLinked }
        throw DecryptSoftwareXPCError.notLinked
        #else
        throw DecryptSoftwareXPCError.unsupportedPlatform
        #endif
    }

    static func decrypt(from inPath: String, to outPath: String) throws {
        _ = inPath
        _ = outPath
        #if os(macOS)
        guard isAvailable else { throw DecryptSoftwareXPCError.notLinked }
        throw DecryptSoftwareXPCError.notLinked
        #else
        throw DecryptSoftwareXPCError.unsupportedPlatform
        #endif
    }
}
