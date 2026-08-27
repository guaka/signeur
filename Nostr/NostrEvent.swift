import CryptoKit
import Foundation

public enum NostrEventError: Error, Equatable {
    case malformedJSON
    case invalidPrivateKey
    case signingFailed
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
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kind = object["kind"] as? Int
        else {
            throw NostrEventError.malformedJSON
        }

        let tags = (object["tags"] as? [[Any]])?.map { tag in
            tag.compactMap { $0 as? String }
        } ?? []

        return UnsignedNostrEvent(
            createdAt: object["created_at"] as? Int,
            kind: kind,
            tags: tags,
            content: object["content"] as? String ?? ""
        )
    }
}
