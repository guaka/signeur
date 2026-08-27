import Foundation

public struct AuditEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let appName: String
    public let method: String
    public let outcome: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        appName: String,
        method: String,
        outcome: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.appName = appName
        self.method = method
        self.outcome = outcome
    }
}
