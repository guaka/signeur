import Foundation

public enum NIP46RequestOrigin: String, Codable, Equatable, Sendable {
    case pairing
    case relay
    case localSigner

    public var hasCryptographicAppIdentity: Bool {
        self == .pairing || self == .relay
    }
}

public struct NIP46Request: Codable, Equatable, Sendable {
    public let id: String
    public let method: NIP46Method
    public let params: [String]
    public let appName: String?
    public let appURL: String?
    public let appPubkey: String
    public let requestedPermissions: [String]
    public let relays: [String]
    public let requestedAt: Date
    public let correlationID: String
    public let rawPayloadPreview: String
    public let origin: NIP46RequestOrigin

    public init(
        id: String,
        method: NIP46Method,
        params: [String],
        appName: String?,
        appURL: String?,
        appPubkey: String,
        requestedPermissions: [String] = [],
        relays: [String] = [],
        requestedAt: Date = Date(),
        correlationID: String,
        rawPayloadPreview: String,
        origin: NIP46RequestOrigin = .relay
    ) {
        self.id = id
        self.method = method
        self.params = params
        self.appName = appName
        self.appURL = appURL
        self.appPubkey = appPubkey
        self.requestedPermissions = requestedPermissions
        self.relays = relays
        self.requestedAt = requestedAt
        self.correlationID = correlationID
        self.rawPayloadPreview = rawPayloadPreview
        self.origin = origin
    }
}
