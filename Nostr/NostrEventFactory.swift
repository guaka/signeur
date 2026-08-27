import Foundation
import P256K

/// Builds fully signed Nostr events from key material.
public enum NostrEventFactory {
    public static func sign(
        _ unsigned: UnsignedNostrEvent,
        privateKey: [UInt8],
        now: Date = Date()
    ) throws -> NostrEvent {
        let signingKey: P256K.Schnorr.PrivateKey
        do {
            signingKey = try P256K.Schnorr.PrivateKey(dataRepresentation: Data(privateKey))
        } catch {
            throw NostrEventError.invalidPrivateKey
        }

        let pubkey = signingKey.publicKey.xonly.bytes.map { String(format: "%02x", $0) }.joined()
        let createdAt = unsigned.createdAt ?? Int(now.timeIntervalSince1970)
        let id = NostrEvent.computeID(
            pubkey: pubkey,
            createdAt: createdAt,
            kind: unsigned.kind,
            tags: unsigned.tags,
            content: unsigned.content
        )

        var digest = try hexBytes(id)
        let signature: P256K.Schnorr.SchnorrSignature
        do {
            signature = try signingKey.signature(message: &digest, auxiliaryRand: nil, strict: true)
        } catch {
            throw NostrEventError.signingFailed
        }

        return NostrEvent(
            id: id,
            pubkey: pubkey,
            createdAt: createdAt,
            kind: unsigned.kind,
            tags: unsigned.tags,
            content: unsigned.content,
            sig: signature.dataRepresentation.map { String(format: "%02x", $0) }.joined()
        )
    }

    public static func json(for event: NostrEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let json = String(data: try encoder.encode(event), encoding: .utf8) else {
            throw NostrEventError.malformedJSON
        }
        return json
    }

    static func hexBytes(_ hex: String) throws -> [UInt8] {
        guard hex.count % 2 == 0 else { throw NostrEventError.malformedJSON }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw NostrEventError.malformedJSON
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
