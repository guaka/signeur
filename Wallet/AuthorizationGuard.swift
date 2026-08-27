import Foundation

public struct AuthorizationGuard: RequestAuthorization {
    public init() {}

    public func canSign(session: NIP46Session) -> Bool {
        guard session.request.method == .signEvent else {
            return true
        }

        switch session.stateMachine.state {
        case .signing, .awaitingUserDecision:
            return true
        default:
            return false
        }
    }
}
