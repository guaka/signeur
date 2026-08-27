import Foundation

public enum SessionEvent: Sendable {
    case onRequestArrived
    case onApprove
    case onReject
    case onSignComplete(Result<Data, Error>)
    case onSendComplete(Result<Void, Error>)
    case onTimeout
    case onCancel
}
