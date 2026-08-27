import Foundation
import P256K

public enum NostrKeyDeriveError: Error, Equatable {
    case invalidNsec
    case invalidPrivateKey
}

public enum NostrKeyDeriver {
    public static func generateNsec() throws -> String {
        let privateKey = try P256K.Signing.PrivateKey()
        return try Bech32.encode(hrp: "nsec", bytes: Array(privateKey.dataRepresentation))
    }

    public static func secretKeyBytes(fromNsec nsec: String) throws -> [UInt8] {
        let normalized = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = try Bech32.decode(normalized, expectedHRP: "nsec")
        guard raw.count == 32 else { throw NostrKeyDeriveError.invalidNsec }
        return raw
    }

    public static func xonlyPublicKeyBytes(fromNsec nsec: String) throws -> [UInt8] {
        try xonlyPublicKeyBytes(fromSecretKey: try secretKeyBytes(fromNsec: nsec))
    }

    public static func xonlyPublicKeyBytes(fromSecretKey secret: [UInt8]) throws -> [UInt8] {
        do {
            return try P256K.Signing.PrivateKey(dataRepresentation: Data(secret)).publicKey.xonly.bytes
        } catch {
            throw NostrKeyDeriveError.invalidPrivateKey
        }
    }

    public static func deriveNpub(fromNsec nsec: String) throws -> String {
        try Bech32.encode(hrp: "npub", bytes: xonlyPublicKeyBytes(fromNsec: nsec))
    }

    public static func derivePublicKeyHex(fromNsec nsec: String) throws -> String {
        try xonlyPublicKeyBytes(fromNsec: nsec)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
