import Foundation

/// A remote app Signstr answers for: which key it uses, and where to reply.
public struct AppConnection: Codable, Equatable, Sendable, Identifiable {
    public var id: String { appPubkey }

    public let appPubkey: String
    public var appName: String?
    public var appURL: String?
    public var relays: [String]
    /// Capabilities advertised in the pairing URL. These describe what the app
    /// expects to ask for; remembered automatic approvals are stored separately.
    public var requestedPermissions: [String]?
    public var identityID: String
    public var secret: String
    public var isApproved: Bool
    /// Some older clients only speak NIP-04; set once we see what they send us.
    public var usesLegacyEncryption: Bool
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(
        appPubkey: String,
        appName: String? = nil,
        appURL: String? = nil,
        relays: [String],
        requestedPermissions: [String] = [],
        identityID: String,
        secret: String,
        isApproved: Bool = false,
        usesLegacyEncryption: Bool = false,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.appPubkey = appPubkey
        self.appName = appName
        self.appURL = appURL
        self.relays = relays
        self.requestedPermissions = requestedPermissions
        self.identityID = identityID
        self.secret = secret
        self.isApproved = isApproved
        self.usesLegacyEncryption = usesLegacyEncryption
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    public var relayURLs: [URL] {
        relays.compactMap(URL.init(string:))
    }
}
