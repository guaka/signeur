import Foundation

public enum NIP55CallbackError: Error, Equatable {
    case noWayToReturnResult
    case callbackRefused
}

/// Answers apps that opened Signstr through `nostrsigner:`, by returning to their callback URL.
///
/// When a caller supplies no callback there is no way back on iOS, so the result is put on
/// the clipboard for the user to paste.
public actor NIP55CallbackTransport: NIP46RespondingTransport {
    private struct Pending {
        let callbackURL: URL?
        let returnType: SignerURLRequest.ReturnType
    }

    private let openURL: @Sendable (URL) async -> Bool
    private let copyToClipboard: @Sendable (String) -> Void
    private var pending: [String: Pending] = [:]

    public init(
        openURL: @escaping @Sendable (URL) async -> Bool,
        copyToClipboard: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.openURL = openURL
        self.copyToClipboard = copyToClipboard
    }

    public func register(requestID: String, callbackURL: URL?, returnType: SignerURLRequest.ReturnType) {
        pending[requestID] = Pending(callbackURL: callbackURL, returnType: returnType)
    }

    public func handles(requestID: String) -> Bool {
        pending[requestID] != nil
    }

    public func sendResponse(_ response: NIP46Response, to appPubkey: String) async throws {
        guard let entry = pending.removeValue(forKey: response.id) else {
            throw NIP55CallbackError.noWayToReturnResult
        }

        // A refusal is reported by returning nothing, which is all NIP-55 offers.
        guard let result = response.result, response.error == nil else {
            return
        }

        let payload = Self.payload(for: result, returnType: entry.returnType)
        guard let callbackURL = entry.callbackURL else {
            copyToClipboard(payload)
            throw NIP55CallbackError.noWayToReturnResult
        }

        let encoded = payload.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? payload
        guard let target = URL(string: callbackURL.absoluteString + encoded) else {
            throw NIP55CallbackError.callbackRefused
        }
        guard await openURL(target) else {
            copyToClipboard(payload)
            throw NIP55CallbackError.callbackRefused
        }
    }

    /// Apps asking for `returnType=signature` want the signature alone, not the event.
    static func payload(for result: String, returnType: SignerURLRequest.ReturnType) -> String {
        guard returnType == .signature else { return result }
        guard
            let data = result.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let signature = object["sig"] as? String
        else {
            return result
        }
        return signature
    }
}

/// Sends each response the way its request arrived: back to a `nostrsigner:` caller, or over relays.
public struct RoutingTransport: NIP46RespondingTransport {
    private let callbackTransport: NIP55CallbackTransport
    private let relayTransport: NIP46RespondingTransport

    public init(callbackTransport: NIP55CallbackTransport, relayTransport: NIP46RespondingTransport) {
        self.callbackTransport = callbackTransport
        self.relayTransport = relayTransport
    }

    public func sendResponse(_ response: NIP46Response, to appPubkey: String) async throws {
        if await callbackTransport.handles(requestID: response.id) {
            try await callbackTransport.sendResponse(response, to: appPubkey)
            return
        }
        try await relayTransport.sendResponse(response, to: appPubkey)
    }
}
