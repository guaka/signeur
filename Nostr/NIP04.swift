import CommonCrypto
import Foundation

public enum NIP04Error: Error, Equatable {
    case malformedPayload
    case encryptionFailed
    case decryptionFailed
}

/// Legacy NIP-04 encryption: AES-256-CBC over the ECDH shared x-coordinate,
/// serialised as `<base64 ciphertext>?iv=<base64 iv>`.
public enum NIP04 {
    public static func encrypt(
        plaintext: String,
        privateKey: [UInt8],
        publicKeyXOnly: [UInt8],
        iv: [UInt8]? = nil
    ) throws -> String {
        let key = try NostrKeyAgreement.sharedX(privateKey: privateKey, publicKeyXOnly: publicKeyXOnly)
        let iv = try iv ?? NIP44.randomBytes(kCCBlockSizeAES128)
        let ciphertext = try crypt(operation: CCOperation(kCCEncrypt), data: Array(plaintext.utf8), key: key, iv: iv)
        return "\(Data(ciphertext).base64EncodedString())?iv=\(Data(iv).base64EncodedString())"
    }

    public static func decrypt(payload: String, privateKey: [UInt8], publicKeyXOnly: [UInt8]) throws -> String {
        let parts = payload.components(separatedBy: "?iv=")
        guard
            parts.count == 2,
            let ciphertext = Data(base64Encoded: parts[0]).map(Array.init),
            let iv = Data(base64Encoded: parts[1]).map(Array.init),
            iv.count == kCCBlockSizeAES128,
            !ciphertext.isEmpty
        else {
            throw NIP04Error.malformedPayload
        }

        let key = try NostrKeyAgreement.sharedX(privateKey: privateKey, publicKeyXOnly: publicKeyXOnly)
        let plaintext = try crypt(operation: CCOperation(kCCDecrypt), data: ciphertext, key: key, iv: iv)
        guard let text = String(bytes: plaintext, encoding: .utf8) else {
            throw NIP04Error.decryptionFailed
        }
        return text
    }

    static func crypt(operation: CCOperation, data: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var movedBytes = 0

        let status = CCCrypt(
            operation,
            CCAlgorithm(kCCAlgorithmAES),
            CCOptions(kCCOptionPKCS7Padding),
            key,
            key.count,
            iv,
            data,
            data.count,
            &output,
            output.count,
            &movedBytes
        )

        guard status == CCCryptorStatus(kCCSuccess) else {
            throw operation == CCOperation(kCCEncrypt) ? NIP04Error.encryptionFailed : NIP04Error.decryptionFailed
        }
        return Array(output.prefix(movedBytes))
    }
}
