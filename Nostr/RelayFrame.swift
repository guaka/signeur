import Foundation

/// The relay-to-client messages of NIP-01 that matter to a signer.
public enum RelayFrame: Equatable, Sendable {
    case event(subscriptionID: String, event: NostrEvent)
    case ok(eventID: String, accepted: Bool, message: String)
    case endOfStoredEvents(subscriptionID: String)
    case closed(subscriptionID: String, message: String)
    case notice(String)
    case authChallenge(String)

    public static func decode(_ text: String) -> RelayFrame? {
        guard
            let data = text.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
            let kind = array.first as? String
        else {
            return nil
        }

        switch kind {
        case "EVENT":
            guard
                array.count >= 3,
                let subscriptionID = array[1] as? String,
                let object = array[2] as? [String: Any],
                let eventData = try? JSONSerialization.data(withJSONObject: object),
                let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData)
            else {
                return nil
            }
            return .event(subscriptionID: subscriptionID, event: event)

        case "OK":
            guard array.count >= 3, let eventID = array[1] as? String, let accepted = array[2] as? Bool else {
                return nil
            }
            return .ok(eventID: eventID, accepted: accepted, message: array.count > 3 ? (array[3] as? String ?? "") : "")

        case "EOSE":
            guard let subscriptionID = array.dropFirst().first as? String else { return nil }
            return .endOfStoredEvents(subscriptionID: subscriptionID)

        case "CLOSED":
            guard let subscriptionID = array.dropFirst().first as? String else { return nil }
            return .closed(subscriptionID: subscriptionID, message: array.count > 2 ? (array[2] as? String ?? "") : "")

        case "NOTICE":
            guard let message = array.dropFirst().first as? String else { return nil }
            return .notice(message)

        case "AUTH":
            guard let challenge = array.dropFirst().first as? String else { return nil }
            return .authChallenge(challenge)

        default:
            return nil
        }
    }
}

/// The client-to-relay messages this app sends.
public enum RelayRequest {
    public static func event(_ event: NostrEvent) throws -> String {
        "[\"EVENT\"," + (try NostrEventFactory.json(for: event)) + "]"
    }

    /// A NIP-46 subscription: events of kind 24133 addressed to us.
    public static func subscribeToNIP46(
        subscriptionID: String,
        recipientPubkey: String,
        since: Int?
    ) throws -> String {
        var filter: [String: Any] = ["kinds": [24133], "#p": [recipientPubkey]]
        if let since {
            filter["since"] = since
        }
        let payload: [Any] = ["REQ", subscriptionID, filter]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw NostrEventError.malformedJSON
        }
        return text
    }

    /// Requests the latest replaceable profile event for one author.
    public static func subscribeToProfile(subscriptionID: String, authorPubkey: String) throws -> String {
        guard SecurityPolicy.isCanonicalPublicKey(authorPubkey) else {
            throw NostrEventError.invalidPublicKey
        }
        let payload: [Any] = [
            "REQ",
            subscriptionID,
            ["authors": [authorPubkey], "kinds": [0], "limit": 1]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw NostrEventError.malformedJSON
        }
        return text
    }

    public static func close(subscriptionID: String) -> String {
        "[\"CLOSE\",\"\(subscriptionID)\"]"
    }
}
