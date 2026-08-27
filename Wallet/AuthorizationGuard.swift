import Foundation

public struct AuthorizationGuard: RequestAuthorization {
    public init() {}

    public func canExecute(session: NIP46Session) -> Bool {
        session.stateMachine.state == .signing
            && session.identityID.map(SecurityPolicy.validateIdentifier) == true
    }
}
