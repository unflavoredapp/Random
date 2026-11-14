//
//  CSRBuilder.swift
//  RSA-2048 PKCS#10 CSR + private key PEM via Security framework (no CodeSignKit).
//

import Foundation
import Security

enum CSRBuilder {

    struct Result: Sendable {
        var csrPEM: String
        var privateKeyPEM: String
        var commonName: String
    }

    struct Subject: Sendable {
        var country: String
        var state: String
        var locality: String
        var organization: String
        var commonName: String

        static func machine(_ name: String) -> Subject {
            Subject(
                country: "US",
                state: "CA",
                locality: "Cupertino",
                organization: "TetherLess",
                commonName: name
            )
        }
    }

    static func generate(machineName: String) throws -> Result {
        try generate(subject: .machine(machineName))
    }

    static func generate(commonName: String) throws -> Result {
        try generate(subject: .machine(commonName))
    }

    static func generate(subject: Subject) throws -> Result {
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: false
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw AppleAuthError.csrFailed(error?.takeRetainedValue().localizedDescription ?? "SecKeyCreateRandomKey failed")
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw AppleAuthError.csrFailed("Missing public key")
        }
        guard let publicDER = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw AppleAuthError.csrFailed(error?.takeRetainedValue().localizedDescription ?? "Export public key failed")
        }

        let writer = DERWriter()
        let info = writer.certificationRequestInfo(subject: subject, publicKeyDER: publicDER)
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            info as CFData,
            &error
        ) as Data? else {
            throw AppleAuthError.csrFailed(error?.takeRetainedValue().localizedDescription ?? "CSR sign failed")
        }

        let request = writer.sequence([
            info,
            writer.sequence([writer.oid(.sha256WithRSAEncryption), writer.null]),
            writer.bitString(signature)
        ])

        guard let pkcs1 = SecKeyCopyExternalRepresentation(privateKey, &error) as Data? else {
            throw AppleAuthError.csrFailed(error?.takeRetainedValue().localizedDescription ?? "Export private key failed")
        }
        // Wrap PKCS#1 RSAPrivateKey in PKCS#8 PrivateKeyInfo for a portable PEM.
        let pkcs8 = writer.sequence([
            writer.integer(Data([0x00])),
            writer.sequence([writer.oid(.rsaEncryption), writer.null]),
            writer.octetString(pkcs1)
        ])

        return Result(
            csrPEM: pem(request, label: "CERTIFICATE REQUEST"),
            privateKeyPEM: pem(pkcs8, label: "PRIVATE KEY"),
            commonName: subject.commonName
        )
    }

    private static func pem(_ der: Data, label: String) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(b64)\n-----END \(label)-----\n"
    }
}

// MARK: - Minimal DER writer

private final class DERWriter {
    func certificationRequestInfo(subject: CSRBuilder.Subject, publicKeyDER: Data) -> Data {
        let name = writerName(subject)
        let spki = sequence([
            sequence([oid(.rsaEncryption), null]),
            bitString(publicKeyDER)
        ])
        // version, subject, subjectPKInfo, empty attributes [0]
        return sequence([
            integer(Data([0x00])),
            name,
            spki,
            Data([0xA0, 0x00])
        ])
    }

    private func writerName(_ subject: CSRBuilder.Subject) -> Data {
        func rdn(_ oidv: OID, _ value: String, utf8: Bool = true) -> Data {
            let v = utf8 ? self.utf8(value) : printable(value)
            return set([sequence([oid(oidv), v])])
        }
        var parts: [Data] = []
        if !subject.country.isEmpty { parts.append(rdn(.countryName, subject.country, utf8: false)) }
        if !subject.state.isEmpty { parts.append(rdn(.state, subject.state)) }
        if !subject.locality.isEmpty { parts.append(rdn(.locality, subject.locality)) }
        if !subject.organization.isEmpty { parts.append(rdn(.organization, subject.organization)) }
        parts.append(rdn(.commonName, subject.commonName))
        return sequence(parts)
    }

    func integer(_ value: Data) -> Data {
        var content = Data(value)
        while content.count > 1, content.first == 0x00, (content.dropFirst().first ?? 0) < 0x80 {
            content.removeFirst()
        }
        if content.isEmpty { content = Data([0x00]) }
        if let first = content.first, first >= 0x80 {
            content.insert(0x00, at: 0)
        }
        return tagged(0x02, content)
    }

    func oid(_ oid: OID) -> Data {
        let first = UInt8(oid.first * 40 + oid.second)
        var encoded = Data([first])
        for value in oid.rest { encoded.append(contentsOf: base128(value)) }
        return tagged(0x06, encoded)
    }

    var null: Data { Data([0x05, 0x00]) }

    func utf8(_ string: String) -> Data { tagged(0x0C, Data(string.utf8)) }
    func printable(_ string: String) -> Data { tagged(0x13, Data(string.utf8)) }

    func sequence(_ parts: [Data]) -> Data { tagged(0x30, concat(parts)) }
    func set(_ parts: [Data]) -> Data { tagged(0x31, concat(parts)) }

    func bitString(_ content: Data) -> Data {
        var wrapped = Data([0x00])
        wrapped.append(content)
        return tagged(0x03, wrapped)
    }

    func octetString(_ content: Data) -> Data { tagged(0x04, content) }

    private func tagged(_ tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        out.append(length(content.count))
        out.append(content)
        return out
    }

    private func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private func base128(_ value: Int) -> [UInt8] {
        var stack: [UInt8] = [UInt8(value & 0x7F)]
        var remaining = value >> 7
        while remaining > 0 {
            stack.insert(UInt8(remaining & 0x7F) | 0x80, at: 0)
            remaining >>= 7
        }
        return stack
    }

    private func concat(_ parts: [Data]) -> Data {
        parts.reduce(into: Data()) { $0.append($1) }
    }

    struct OID {
        let first: Int
        let second: Int
        let rest: [Int]

        static let commonName = OID(first: 2, second: 5, rest: [4, 3])
        static let countryName = OID(first: 2, second: 5, rest: [4, 6])
        static let locality = OID(first: 2, second: 5, rest: [4, 7])
        static let state = OID(first: 2, second: 5, rest: [4, 8])
        static let organization = OID(first: 2, second: 5, rest: [4, 10])
        static let rsaEncryption = OID(first: 1, second: 2, rest: [840, 113549, 1, 1, 1])
        static let sha256WithRSAEncryption = OID(first: 1, second: 2, rest: [840, 113549, 1, 1, 11])
    }
}
