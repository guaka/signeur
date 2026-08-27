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
        let method: NIP46Method
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

    public func register(
        requestID: String,
        callbackURL: URL?,
        returnType: SignerURLRequest.ReturnType,
        method: NIP46Method = .signEvent
    ) {
        pending[requestID] = Pending(callbackURL: callbackURL, returnType: returnType, method: method)
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

        guard let target = Self.callbackTarget(callbackURL, payload: payload) else {
            throw NIP55CallbackError.callbackRefused
        }
        guard await openURL(target) else {
            copyToClipboard(payload)
            throw NIP55CallbackError.callbackRefused
        }
    }

    static func callbackTarget(_ callbackURL: URL, payload: String) -> URL? {
        guard var components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = components.queryItems ?? []
        if let index = items.lastIndex(where: { ($0.value ?? "").isEmpty }) {
            items[index].value = payload
        } else {
            items.append(URLQueryItem(name: "result", value: payload))
        }
        components.queryItems = items
        return components.url
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
