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
    case connectionNotRegistered
    case identityKeyUnavailable
    case responseEncryptionFailed
    case relayUnavailable
    case keyAuthenticationFailed
    case keyAuthenticationCanceled
    case keychainInteractionNotAllowed
    case keychainPermissionMissing
    case keychainProtectionUnavailable
    case keychainUnavailable
    case storedKeyInvalid
    case keychainUnexpectedError
    case unauthorizedSigningAttempt

    public var userMessage: String {
        switch self {
        case .userRejected:
            return "The request was declined. (N46-1001)"
        case .invalidProtocol:
            return "The request was not valid NIP-46. (N46-1002)"
        case .timeout:
            return "The request expired before it was completed. (N46-1003)"
        case .signingFailed:
            return "The selected key could not complete this request. (N46-2001)"
        case .transportFailure:
            return "The response could not be delivered. (N46-2099)"
        case .connectionNotRegistered:
            return "The app connection was not registered for a reply. (N46-2101)"
        case .identityKeyUnavailable:
            return "The approved connection could not find its signing key. (N46-2102)"
        case .responseEncryptionFailed:
            return "The response could not be encrypted for the requesting app. (N46-2103)"
        case .relayUnavailable:
            return "None of the requested Nostr relays accepted the response. (N46-2104)"
        case .keyAuthenticationFailed:
            return "Face ID or device authentication did not succeed. Try again. (N46-2201)"
        case .keyAuthenticationCanceled:
            return "Key authentication was canceled. (N46-2202)"
        case .keychainInteractionNotAllowed:
            return "iOS did not allow Signstr to show key authentication. Keep Signstr open and try again. (N46-2203)"
        case .keychainPermissionMissing:
            return "This Signstr build does not have permission to read its Keychain. (N46-2204)"
        case .keychainProtectionUnavailable:
            return "Biometric Keychain protection is unavailable on this device. (N46-2205)"
        case .keychainUnavailable:
            return "The iPhone Keychain is currently unavailable. Unlock the phone and try again. (N46-2206)"
        case .storedKeyInvalid:
            return "The stored private key is damaged or invalid. Re-import it before retrying. (N46-2207)"
        case .keychainUnexpectedError:
            return "The iPhone Keychain returned an unexpected error. (N46-2299)"
        case .unauthorizedSigningAttempt:
            return "The selected key is not authorized for this request. (N46-2002)"
        }
    }
}
