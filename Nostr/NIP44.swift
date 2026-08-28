import CryptoKit
import Foundation
import Security

public enum NIP44Error: Error, Equatable {
    case messageEmpty
    case messageTooLong
    case unsupportedVersion(UInt8)
    case malformedPayload
    case invalidMAC
    case invalidPadding
    case randomGenerationFailed(OSStatus)
}

/// NIP-44 v2 payload encryption: HKDF-derived keys, ChaCha20, HMAC-SHA256 over the nonce.
public enum NIP44 {
    public static let version: UInt8 = 2
    private static let salt = Data("nip44-v2".utf8)
    private static let nonceByteCount = 32
    private static let macByteCount = 32
    private static let maxPlaintextByteCount = 65_535

    public static func conversationKey(privateKey: [UInt8], publicKeyXOnly: [UInt8]) throws -> [UInt8] {
        let sharedX = try NostrKeyAgreement.sharedX(privateKey: privateKey, publicKeyXOnly: publicKeyXOnly)
        return Array(HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: sharedX), salt: salt))
    }

    public static func encrypt(
        plaintext: String,
        privateKey: [UInt8],
        publicKeyXOnly: [UInt8],
        nonce: [UInt8]? = nil
    ) throws -> String {
        try encrypt(
            plaintext: plaintext,
            conversationKey: try conversationKey(privateKey: privateKey, publicKeyXOnly: publicKeyXOnly),
            nonce: nonce
        )
    }

    public static func decrypt(
        payload: String,
        privateKey: [UInt8],
        publicKeyXOnly: [UInt8]
    ) throws -> String {
        try decrypt(
            payload: payload,
            conversationKey: try conversationKey(privateKey: privateKey, publicKeyXOnly: publicKeyXOnly)
        )
    }

    public static func encrypt(plaintext: String, conversationKey: [UInt8], nonce: [UInt8]? = nil) throws -> String {
        let padded = try pad(plaintext)
        let nonce = try nonce ?? randomBytes(nonceByteCount)
        let keys = messageKeys(conversationKey: conversationKey, nonce: nonce)

        let ciphertext = ChaCha20.apply(key: keys.chachaKey, nonce: keys.chachaNonce, to: padded)
        let mac = hmac(key: keys.hmacKey, aad: nonce, message: ciphertext)

        return Data([version] + nonce + ciphertext + mac).base64EncodedString()
    }

    public static func decrypt(payload: String, conversationKey: [UInt8]) throws -> String {
        guard !payload.hasPrefix("#") else { throw NIP44Error.unsupportedVersion(0) }
        guard
            let raw = Data(base64Encoded: payload).map(Array.init),
            raw.count >= 1 + nonceByteCount + macByteCount + 1
        else {
            throw NIP44Error.malformedPayload
        }
        guard raw[0] == version else { throw NIP44Error.unsupportedVersion(raw[0]) }

        let nonce = Array(raw[1..<(1 + nonceByteCount)])
        let ciphertext = Array(raw[(1 + nonceByteCount)..<(raw.count - macByteCount)])
        let mac = Array(raw.suffix(macByteCount))

        let keys = messageKeys(conversationKey: conversationKey, nonce: nonce)
        guard isValidMAC(mac, key: keys.hmacKey, aad: nonce, message: ciphertext) else {
            throw NIP44Error.invalidMAC
        }

        let padded = ChaCha20.apply(key: keys.chachaKey, nonce: keys.chachaNonce, to: ciphertext)
        return try unpad(padded)
    }

    /// Rounds a plaintext length up so payload sizes leak as little as possible.
    static func paddedLength(for unpaddedLength: Int) -> Int {
        guard unpaddedLength > 32 else { return 32 }
        let nextPower = 1 << (Int(log2(Double(unpaddedLength - 1))) + 1)
        let chunk = nextPower <= 256 ? 32 : nextPower / 8
        return chunk * (((unpaddedLength - 1) / chunk) + 1)
    }

    static func messageKeys(
        conversationKey: [UInt8],
        nonce: [UInt8]
    ) -> (chachaKey: [UInt8], chachaNonce: [UInt8], hmacKey: [UInt8]) {
        let expanded = HKDF<SHA256>.expand(
            pseudoRandomKey: SymmetricKey(data: conversationKey),
            info: Data(nonce),
            outputByteCount: 76
        ).withUnsafeBytes { Array($0) }

        return (
            chachaKey: Array(expanded[0..<32]),
            chachaNonce: Array(expanded[32..<44]),
            hmacKey: Array(expanded[44..<76])
        )
    }

    private static func pad(_ plaintext: String) throws -> [UInt8] {
        let bytes = Array(plaintext.utf8)
        guard !bytes.isEmpty else { throw NIP44Error.messageEmpty }
        guard bytes.count <= maxPlaintextByteCount else { throw NIP44Error.messageTooLong }

        let target = paddedLength(for: bytes.count)
        let prefix = [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xff)]
        return prefix + bytes + [UInt8](repeating: 0, count: target - bytes.count)
    }

    static func unpad(_ padded: [UInt8]) throws -> String {
        guard padded.count >= 2 else { throw NIP44Error.invalidPadding }
        let declaredLength = Int(padded[0]) << 8 | Int(padded[1])
        let content = Array(padded.dropFirst(2))

        guard
            declaredLength > 0,
            content.count >= declaredLength,
            content.count == paddedLength(for: declaredLength)
        else {
            throw NIP44Error.invalidPadding
        }
        guard let text = String(bytes: content[0..<declaredLength], encoding: .utf8) else {
            throw NIP44Error.invalidPadding
        }
        return text
    }

    private static func hmac(key: [UInt8], aad: [UInt8], message: [UInt8]) -> [UInt8] {
        var authenticated = Data(aad)
        authenticated.append(contentsOf: message)
        return Array(HMAC<SHA256>.authenticationCode(for: authenticated, using: SymmetricKey(data: key)))
    }

    private static func isValidMAC(_ mac: [UInt8], key: [UInt8], aad: [UInt8], message: [UInt8]) -> Bool {
        var authenticated = Data(aad)
        authenticated.append(contentsOf: message)
        return HMAC<SHA256>.isValidAuthenticationCode(
            mac,
            authenticating: authenticated,
            using: SymmetricKey(data: key)
        )
    }

    static func randomBytes(
        _ count: Int,
        using fill: (Int, UnsafeMutableRawPointer) -> OSStatus = { count, buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer)
        }
    ) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return fill(count, baseAddress)
        }
        guard status == errSecSuccess else { throw NIP44Error.randomGenerationFailed(status) }
        return bytes
    }
}
