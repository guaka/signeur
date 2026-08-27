import Foundation

/// Reads a pairing link out of whatever the user gives us: a scanned QR code, pasted
/// text that may carry extra words, or a URL another app opened us with.
public struct PairingPayloadParser: Sendable {
    private static let pairingScheme = "nostrconnect://"
    private static let wrapperScheme = "signstr://"

    private let deepLinkHandler: DeepLinkHandler

    public init(deepLinkHandler: DeepLinkHandler = .init()) {
        self.deepLinkHandler = deepLinkHandler
    }

    public func parse(_ payload: String) throws -> DeepLinkRequest {
        guard let url = Self.pairingURL(in: payload) else {
            throw DeepLinkParseError.invalidScheme
        }
        return try deepLinkHandler.parse(url)
    }

    public func parse(_ url: URL) throws -> DeepLinkRequest {
        try parse(url.absoluteString)
    }

    private static func pairingURL(in payload: String) -> URL? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix(wrapperScheme) {
            return unwrap(text).flatMap(URL.init(string:))
        }
        guard let range = text.range(of: pairingScheme, options: [.caseInsensitive]) else {
            return nil
        }
        // Tolerates a link pasted alongside surrounding prose.
        let link = text[range.lowerBound...].prefix { !$0.isWhitespace }
        return URL(string: String(link))
    }

    /// Unpacks `signstr://pair?uri=<encoded nostrconnect link>`, which lets an app hand us
    /// a pairing request through our own scheme.
    private static func unwrap(_ text: String) -> String? {
        guard
            let components = URLComponents(string: text),
            let wrapped = components.queryItems?.first(where: { $0.name == "uri" || $0.name == "url" })?.value
        else {
            return nil
        }
        return wrapped
    }
}
