import Foundation
import P256K

public enum NostrKeyAgreementError: Error, Equatable {
    case invalidPrivateKey
    case invalidPublicKey
}

public enum NostrKeyAgreement {
    /// The x-coordinate of the ECDH shared point, which is what both NIP-04 and NIP-44 use
    /// as key material. Nostr public keys are x-only, so the even-Y point is assumed.
    public static func sharedX(privateKey: [UInt8], publicKeyXOnly: [UInt8]) throws -> [UInt8] {
        guard privateKey.count == 32 else { throw NostrKeyAgreementError.invalidPrivateKey }
        guard publicKeyXOnly.count == 32 else { throw NostrKeyAgreementError.invalidPublicKey }

        let secret: P256K.KeyAgreement.PrivateKey
        do {
            secret = try P256K.KeyAgreement.PrivateKey(dataRepresentation: Data(privateKey))
        } catch {
            throw NostrKeyAgreementError.invalidPrivateKey
        }

        let peer: P256K.KeyAgreement.PublicKey
        do {
            peer = try P256K.KeyAgreement.PublicKey(dataRepresentation: Data([0x02] + publicKeyXOnly), format: .compressed)
        } catch {
            throw NostrKeyAgreementError.invalidPublicKey
        }

        let shared = secret.sharedSecretFromKeyAgreement(with: peer, format: .compressed)
        let bytes = shared.withUnsafeBytes { Array($0) }
        // Compressed form is a 1-byte parity prefix followed by the 32-byte x coordinate.
        return Array(bytes.dropFirst())
    }
}
