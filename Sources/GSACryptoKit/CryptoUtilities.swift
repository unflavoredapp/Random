//
//  CryptoUtilities.swift
//  GSACryptoKit (vendored) — CommonCrypto CBC so we don't need CryptoExtras.
//

import Foundation
import Crypto
import CommonCrypto

public enum CryptoUtilities {

    public typealias SRP = SRPClient

    public static func hmacSHA256(key: Data, strings: [String]) -> Data? {
        var concatenated = Data()
        for s in strings { concatenated.append(Data(s.utf8)) }
        let symmetricKey = SymmetricKey(data: key)
        return Data(HMAC<SHA256>.authenticationCode(for: concatenated, using: symmetricKey))
    }

    public static func sha256(_ data: Data) -> Data? {
        Data(SHA256.hash(data: data))
    }

    public static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        rounds: Int,
        outputLength: Int
    ) -> Data? {
        guard rounds > 0, outputLength > 0 else { return nil }
        var out = Data(count: outputLength)
        let status: CCStatus = out.withUnsafeMutableBytes { outBuf in
            password.withUnsafeBytes { passBuf in
                salt.withUnsafeBytes { saltBuf in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passBuf.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltBuf.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(rounds),
                        outBuf.bindMemory(to: UInt8.self).baseAddress,
                        outputLength
                    )
                }
            }
        }
        return status == kCCSuccess ? out : nil
    }

    public static func aesCBCDecrypt(key: Data, iv: Data, ciphertext: Data) -> Data? {
        guard iv.count >= 16 else { return nil }
        guard key.count == 16 || key.count == 24 || key.count == 32 else { return nil }
        guard !ciphertext.isEmpty, ciphertext.count % 16 == 0 else { return nil }
        var out = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var moved = 0
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outBuf in
            ciphertext.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.prefix(16).withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            inBuf.baseAddress, ciphertext.count,
                            outBuf.baseAddress, out.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.count = moved
        return out
    }

    public static func aesGCMDecrypt(
        key: Data,
        nonce: Data,
        aad: Data,
        ciphertext: Data,
        tag: Data
    ) -> Data? {
        guard key.count == 16 || key.count == 24 || key.count == 32 else { return nil }
        guard let gcmNonce = try? AES.GCM.Nonce(data: nonce) else { return nil }
        guard tag.count == 16 else { return nil }
        do {
            let sealedBox = try AES.GCM.SealedBox(nonce: gcmNonce, ciphertext: ciphertext, tag: tag)
            let symmetricKey = SymmetricKey(data: key)
            if aad.isEmpty {
                return try AES.GCM.open(sealedBox, using: symmetricKey)
            } else {
                return try AES.GCM.open(sealedBox, using: symmetricKey, authenticating: aad)
            }
        } catch {
            return nil
        }
    }
}
