import Foundation

public enum SessionState: Equatable, Sendable {
    case idle
    case requestReceived
    case awaitingUserDecision
    case signing
    case sendingResponse
    case completedSuccess
    case completedError(SessionFailureReason)
    case expired
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completedSuccess, .completedError, .expired, .cancelled:
            return true
        default:
            return false
        }
    }
}

public enum SessionFailureReason: String, Error, Equatable, Sendable {
    case userRejected
    case invalidProtocol
    case timeout
    case signingFailed
    case transportFailure
    case unauthorizedSigningAttempt
}
