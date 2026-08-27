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
        isApproved: Bool = false,
        usesLegacyEncryption: Bool = false,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.appPubkey = appPubkey
        self.appName = appName.flatMap { SecurityPolicy.validateMetadataText($0) ? $0 : nil }
        self.appURL = appURL.flatMap { try? SecurityPolicy.canonicalMetadataURL($0) }
        self.relays = SecurityPolicy.validRelays(from: relays)
        self.requestedPermissions = Array(requestedPermissions.prefix(32)).filter(SecurityPolicy.validateMetadataText)
        self.identityID = identityID
        self.isApproved = isApproved
        self.usesLegacyEncryption = usesLegacyEncryption
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    public var relayURLs: [URL] {
        SecurityPolicy.validRelays(from: relays).compactMap(URL.init(string:))
    }

    public var needsSecureRelay: Bool { relayURLs.isEmpty }
}
