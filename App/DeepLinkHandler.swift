import Foundation

public enum DeepLinkParseError: Error, Equatable {
    case invalidScheme
    case missingClientPubkey
    case missingRelay
    case missingSecret
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
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw DeepLinkParseError.invalidScheme
        }

        let relayValues = components.queryItems?.filter { $0.name == "relay" }.compactMap { $0.value } ?? []
        guard !relayValues.isEmpty else {
            throw DeepLinkParseError.missingRelay
        }
        guard let secret = components.queryItems?.first(where: { $0.name == "secret" })?.value, !secret.isEmpty else {
            throw DeepLinkParseError.missingSecret
        }
        let perms = components.queryItems?.first(where: { $0.name == "perms" })?.value?
            .split(separator: ",")
            .map(String.init) ?? []
        let appName = components.queryItems?.first(where: { $0.name == "name" })?.value
        let appURL = components.queryItems?.first(where: { $0.name == "url" })?.value

        return DeepLinkRequest(
            clientPubkey: url.host(percentEncoded: false) ?? "",
            relays: relayValues,
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
