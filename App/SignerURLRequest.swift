import Foundation

public enum SignerURLParseError: Error, Equatable {
    case invalidScheme
    case unsupportedType(String)
    case missingPayload
    case missingPeerPubkey
    case unsupportedCompression(String)
}

/// What a NIP-55 `nostrsigner:` URL is asking for, and how to answer the app that sent it.
public struct SignerURLRequest: Equatable, Sendable {
    public enum ReturnType: String, Equatable, Sendable {
        /// Just the 64-byte signature, which is all some apps want back.
        case signature
        /// The whole signed event as JSON.
        case event
    }

    public let method: NIP46Method
    public let params: [String]
    public let appName: String?
    public let callbackURL: URL?
    public let returnType: ReturnType
    public let requestedPermissions: [String]
    /// A stand-in for the app's key, since a `nostrsigner:` caller has none.
    public let appIdentifier: String

    public static func parse(_ url: URL) throws -> SignerURLRequest {
        try parse(url.absoluteString)
    }

    public static func parse(_ text: String) throws -> SignerURLRequest {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("nostrsigner:") else {
            throw SignerURLParseError.invalidScheme
        }

        let body = String(trimmed.dropFirst("nostrsigner:".count))
        let separatorIndex = body.firstIndex(of: "?")
        let encodedPayload = separatorIndex.map { String(body[body.startIndex..<$0]) } ?? body
        let query = separatorIndex.map { String(body[body.index(after: $0)...]) } ?? ""
        let items = queryItems(query)

        if let compression = items["compressionType"], compression != "none" {
            // gzip payloads are legal in NIP-55 but nothing here can inflate them yet.
            throw SignerURLParseError.unsupportedCompression(compression)
        }

        let payload = encodedPayload.removingPercentEncoding ?? encodedPayload
        let typeName = items["type"] ?? (payload.isEmpty ? "get_public_key" : "sign_event")
        let method = try method(for: typeName)

        return SignerURLRequest(
            method: method,
            params: try params(for: method, payload: payload, items: items),
            appName: items["appName"],
            callbackURL: items["callbackUrl"].flatMap(URL.init(string:)),
            returnType: ReturnType(rawValue: items["returnType"] ?? "") ?? .event,
            requestedPermissions: permissions(from: items["permissions"]),
            appIdentifier: appIdentifier(name: items["appName"], callback: items["callbackUrl"])
        )
    }

    private static func method(for typeName: String) throws -> NIP46Method {
        switch typeName {
        case "sign_event": return .signEvent
        case "get_public_key": return .getPublicKey
        case "nip04_encrypt": return .nip04Encrypt
        case "nip04_decrypt": return .nip04Decrypt
        case "nip44_encrypt": return .nip44Encrypt
        case "nip44_decrypt": return .nip44Decrypt
        case "ping": return .ping
        default: throw SignerURLParseError.unsupportedType(typeName)
        }
    }

    private static func params(for method: NIP46Method, payload: String, items: [String: String]) throws -> [String] {
        switch method {
        case .getPublicKey, .ping:
            return []
        case .signEvent:
            guard !payload.isEmpty else { throw SignerURLParseError.missingPayload }
            return [payload]
        case .nip04Encrypt, .nip04Decrypt, .nip44Encrypt, .nip44Decrypt:
            guard !payload.isEmpty else { throw SignerURLParseError.missingPayload }
            guard let peer = items["pubkey"], !peer.isEmpty else { throw SignerURLParseError.missingPeerPubkey }
            return [peer, payload]
        case .connect, .switchRelays, .logout:
            throw SignerURLParseError.unsupportedType(method.rawValue)
        }
    }

    private static func permissions(from json: String?) -> [String] {
        guard
            let json,
            let data = json.data(using: .utf8),
            let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return []
        }
        return entries.compactMap { entry in
            guard let type = entry["type"] as? String else { return nil }
            if let kind = entry["kind"] {
                return "\(type):\(kind)"
            }
            return type
        }
    }

    /// Groups requests from the same caller so remembered permissions apply to it.
    private static func appIdentifier(name: String?, callback: String?) -> String {
        if let callback, let scheme = URL(string: callback)?.scheme, !scheme.isEmpty {
            return "nostrsigner:\(scheme)"
        }
        return "nostrsigner:\(name ?? "unknown")"
    }

    private static func queryItems(_ query: String) -> [String: String] {
        var components = URLComponents()
        components.percentEncodedQuery = query
        return (components.queryItems ?? []).reduce(into: [:]) { result, item in
            if let value = item.value, result[item.name] == nil {
                result[item.name] = value
            }
        }
    }

    public func makeNIP46Request(id: String = UUID().uuidString, requestedAt: Date = Date()) -> NIP46Request {
        NIP46Request(
            id: id,
            method: method,
            params: params,
            appName: appName,
            appURL: callbackURL?.absoluteString,
            appPubkey: appIdentifier,
            requestedPermissions: requestedPermissions,
            requestedAt: requestedAt,
            correlationID: id,
            rawPayloadPreview: preview
        )
    }

    private var preview: String {
        switch method {
        case .signEvent:
            return params.first ?? ""
        case .nip04Encrypt, .nip04Decrypt, .nip44Encrypt, .nip44Decrypt:
            return "peer: \(params.first ?? "unknown")"
        default:
            return method.rawValue
        }
    }
}
