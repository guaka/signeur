import Foundation

public struct PermissionRule: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let appPubkey: String
    public let method: String
    public let kind: Int?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        appPubkey: String,
        method: String,
        kind: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.appPubkey = appPubkey
        self.method = method
        self.kind = kind
        self.createdAt = createdAt
    }
}
