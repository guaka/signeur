import Foundation

public struct NIP46SessionStateMachine: Sendable {
    public private(set) var state: SessionState = .idle

    public init() {}

    @discardableResult
    public mutating func transition(on event: SessionEvent) -> SessionState {
        state = nextState(from: state, event: event)
        return state
    }

    private func nextState(from current: SessionState, event: SessionEvent) -> SessionState {
        switch (current, event) {
        case (.idle, .onRequestArrived):
            return .requestReceived
        case (.requestReceived, .onApprove):
            return .awaitingUserDecision
        case (.requestReceived, .onReject):
            return .completedError(.userRejected)
        case (.awaitingUserDecision, .onApprove):
            return .signing
        case (.awaitingUserDecision, .onReject):
            return .cancelled
        case (.signing, .onSignComplete(.success)):
            return .sendingResponse
        case (.signing, .onSignComplete(.failure)):
            return .completedError(.signingFailed)
        case (.sendingResponse, .onSendComplete(.success)):
            return .completedSuccess
        case (.sendingResponse, .onSendComplete(.failure)):
            return .completedError(.transportFailure)
        case (_, .onTimeout):
            return .expired
        case (_, .onCancel):
            return .cancelled
        default:
            return current
        }
    }
}
