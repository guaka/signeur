import Foundation

public struct NIP46Session: Identifiable, Sendable {
    public let id: String
    public let request: NIP46Request
    public var stateMachine: NIP46SessionStateMachine
    public let createdAt: Date
    public let expiresAt: Date
    public var identityID: String?

    public init(
        id: String = UUID().uuidString,
        request: NIP46Request,
        stateMachine: NIP46SessionStateMachine = .init(),
        createdAt: Date = Date(),
        expiresAt: Date,
        identityID: String? = nil
    ) {
        self.id = id
        self.request = request
        self.stateMachine = stateMachine
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.identityID = identityID
    }
}
