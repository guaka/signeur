import Foundation

public enum DeepLinkParseError: Error, Equatable {
    case invalidScheme
    case missingClientPubkey
    case missingRelay
    case missingSecret
    case invalidClientPubkey
    case invalidRelay
    case invalidSecret
    case invalidMetadata
}

public struct DeepLinkRequest: Equatable, Sendable {
    public let clientPubkey: String
    public let relays: [String]
    public let secret: String
    public let requestedPerms: [String]
    public let appName: String?
    public let appURL: String?
}

public struct DeepLinkHandler: Sendable {
    public init() {}

    public func parse(_ url: URL) throws -> DeepLinkRequest {
        guard url.scheme?.lowercased() == "nostrconnect" else {
            throw DeepLinkParseError.invalidScheme
        }
        guard !url.host(percentEncoded: false).orEmpty.isEmpty else {
            throw DeepLinkParseError.missingClientPubkey
        }
        guard let clientPubkey = url.host(percentEncoded: false), SecurityPolicy.isCanonicalPublicKey(clientPubkey) else {
            throw DeepLinkParseError.invalidClientPubkey
        }
        // A URL that has already supplied a scheme and host is representable as URLComponents.
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!

        let relayValues = components.queryItems?.filter { $0.name == "relay" }.compactMap { $0.value } ?? []
        guard !relayValues.isEmpty else {
            throw DeepLinkParseError.missingRelay
        }
        guard let relays = try? SecurityPolicy.sanitizeRelays(relayValues) else {
            throw DeepLinkParseError.invalidRelay
        }
        guard let secret = components.queryItems?.first(where: { $0.name == "secret" })?.value, !secret.isEmpty else {
            throw DeepLinkParseError.missingSecret
        }
        guard SecurityPolicy.validateSecret(secret) else {
            throw DeepLinkParseError.invalidSecret
        }
        let perms = components.queryItems?.first(where: { $0.name == "perms" })?.value?
            .split(separator: ",")
            .map(String.init) ?? []
        let appName = components.queryItems?.first(where: { $0.name == "name" })?.value
        let rawAppURL = components.queryItems?.first(where: { $0.name == "url" })?.value
        guard perms.count <= 32,
              perms.allSatisfy(SecurityPolicy.validateMetadataText),
              appName.map(SecurityPolicy.validateMetadataText) ?? true
        else {
            throw DeepLinkParseError.invalidMetadata
        }
        let appURL: String?
        if let rawAppURL {
            guard let canonical = try? SecurityPolicy.canonicalMetadataURL(rawAppURL) else {
                throw DeepLinkParseError.invalidMetadata
            }
            appURL = canonical
        } else {
            appURL = nil
        }

        return DeepLinkRequest(
            clientPubkey: clientPubkey,
            relays: relays,
            secret: secret,
            requestedPerms: perms,
            appName: appName,
            appURL: appURL
        )
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}
