import CryptoKit
import Foundation
import P256K

public enum NostrEventError: Error, Equatable {
    case malformedJSON
    case invalidPrivateKey
    case signingFailed
    case invalidEventID
    case invalidSignature
    case invalidPublicKey
    case invalidTimestamp
    case invalidPayload
}

public struct NostrEvent: Codable, Equatable, Sendable {
    public let id: String
    public let pubkey: String
    public let createdAt: Int
    public let kind: Int
    public let tags: [[String]]
    public let content: String
    public let sig: String

    enum CodingKeys: String, CodingKey {
        case id
        case pubkey
        case createdAt = "created_at"
        case kind
        case tags
        case content
        case sig
    }

    public init(
        id: String,
        pubkey: String,
        createdAt: Int,
        kind: Int,
        tags: [[String]],
        content: String,
        sig: String
    ) {
        self.id = id
        self.pubkey = pubkey
        self.createdAt = createdAt
        self.kind = kind
        self.tags = tags
        self.content = content
        self.sig = sig
    }

    /// The canonical serialisation an event ID is the SHA-256 of, per NIP-01:
    /// `[0, pubkey, created_at, kind, tags, content]`.
    public static func serializeForID(
        pubkey: String,
        createdAt: Int,
        kind: Int,
        tags: [[String]],
        content: String
    ) -> String {
        let elements = [
            "0",
            "\"\(pubkey)\"",
            String(createdAt),
            String(kind),
            serializeTags(tags),
            escape(content)
        ]
        return "[" + elements.joined(separator: ",") + "]"
    }

    public static func computeID(
        pubkey: String,
        createdAt: Int,
        kind: Int,
        tags: [[String]],
        content: String
    ) -> String {
        let serialized = serializeForID(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
        return SHA256.hash(data: Data(serialized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func validate(
        now: Date = Date(),
        maxAge: TimeInterval = 10 * 60,
        maxFutureSkew: TimeInterval = 2 * 60
    ) throws {
        guard SecurityPolicy.isCanonicalPublicKey(pubkey) else {
            throw NostrEventError.invalidPublicKey
        }
        guard id.utf8.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              sig.utf8.count == 128, sig.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else {
            throw NostrEventError.invalidSignature
        }
        guard tags.count <= SecurityPolicy.maxEventTags,
              tags.allSatisfy({ $0.count <= SecurityPolicy.maxTagValues && $0.allSatisfy(SecurityPolicy.validateMetadataText) }),
              content.utf8.count <= SecurityPolicy.maxRequestPayloadBytes * 2
        else {
            throw NostrEventError.invalidPayload
        }
        let expectedID = Self.computeID(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
        guard id == expectedID else { throw NostrEventError.invalidEventID }

        let eventDate = Date(timeIntervalSince1970: TimeInterval(createdAt))
        guard eventDate >= now.addingTimeInterval(-maxAge),
              eventDate <= now.addingTimeInterval(maxFutureSkew)
        else {
            throw NostrEventError.invalidTimestamp
        }

        let publicKey = P256K.Schnorr.XonlyKey(dataRepresentation: try NostrEventFactory.hexBytes(pubkey))
        let signature = try P256K.Schnorr.SchnorrSignature(
            dataRepresentation: Data(try NostrEventFactory.hexBytes(sig))
        )
        var digest = try NostrEventFactory.hexBytes(id)
        guard publicKey.isValid(signature, for: &digest) else {
            throw NostrEventError.invalidSignature
        }
    }

    private static func serializeTags(_ tags: [[String]]) -> String {
        let inner = tags.map { tag in
            "[" + tag.map(escape).joined(separator: ",") + "]"
        }
        return "[" + inner.joined(separator: ",") + "]"
    }

    /// JSON string escaping restricted to what NIP-01 mandates, so IDs match other clients byte for byte.
    private static func escape(_ value: String) -> String {
        var escaped = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\u{08}": escaped += "\\b"
            case "\u{0C}": escaped += "\\f"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return escaped + "\""
    }
}

/// An event as a requesting app sends it: no id, pubkey, or signature yet.
public struct UnsignedNostrEvent: Equatable, Sendable {
    public let createdAt: Int?
    public let kind: Int
    public let tags: [[String]]
    public let content: String

    public init(createdAt: Int?, kind: Int, tags: [[String]], content: String) {
        self.createdAt = createdAt
        self.kind = kind
        self.tags = tags
        self.content = content
    }

    public static func decode(json: String) throws -> UnsignedNostrEvent {
        guard
            let data = json.data(using: .utf8),
            data.count <= SecurityPolicy.maxRequestPayloadBytes,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kind = object["kind"] as? Int,
            (0...65_535).contains(kind),
            object["id"] == nil,
            object["sig"] == nil,
            object["pubkey"] == nil
        else {
            throw NostrEventError.malformedJSON
        }

        let tags: [[String]]
        if let rawTags = object["tags"] {
            guard let parsed = rawTags as? [[String]],
                  parsed.count <= SecurityPolicy.maxEventTags,
                  parsed.allSatisfy({ tag in
                      tag.count <= SecurityPolicy.maxTagValues
                          && tag.allSatisfy(SecurityPolicy.validateMetadataText)
                  })
            else {
                throw NostrEventError.malformedJSON
            }
            tags = parsed
        } else {
            tags = []
        }
        let content: String
        if let rawContent = object["content"] {
            guard let value = rawContent as? String else {
                throw NostrEventError.malformedJSON
            }
            content = value
        } else {
            content = ""
        }
        let createdAt: Int?
        if let rawCreatedAt = object["created_at"] {
            guard let value = rawCreatedAt as? Int, value >= 0 else {
                throw NostrEventError.malformedJSON
            }
            createdAt = value
        } else {
            createdAt = nil
        }

        return UnsignedNostrEvent(
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content
        )
    }
}
