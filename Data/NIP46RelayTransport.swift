import Foundation

public enum NIP46RelayTransportError: Error, Equatable {
    case unknownApp
    case noKeyForIdentity
    case encryptionFailed
}

/// Sends NIP-46 replies the way clients expect them: a JSON-RPC body, encrypted to the
/// app's key, wrapped in a kind 24133 event we sign, published to that app's relays.
public struct NIP46RelayTransport: NIP46RespondingTransport {
    public static let nip46Kind = 24133

    private let pool: NostrRelayPool
    private let connections: ConnectionStore
    private let nsecStore: NsecStoring
    private let logger: RedactedLogger
    private let now: @Sendable () -> Date

    public init(
        pool: NostrRelayPool,
        connections: ConnectionStore,
        nsecStore: NsecStoring,
        logger: RedactedLogger = RedactedLogger(),
        now: @escaping @Sendable () -> Date = { Date() } // coverage:ignore Compiler-generated default-argument thunk.
    ) {
        self.pool = pool
        self.connections = connections
        self.nsecStore = nsecStore
        self.logger = logger
        self.now = now
    }

    public func sendResponse(_ response: NIP46Response, to appPubkey: String) async throws {
        guard let connection = await connections.connection(forAppPubkey: appPubkey) else {
            throw NIP46RelayTransportError.unknownApp
        }
        guard let nsec = try await nsecStore.loadNsec(for: connection.identityID) else {
            throw NIP46RelayTransportError.noKeyForIdentity
        }

        let secret = try NostrKeyDeriver.secretKeyBytes(fromNsec: nsec)
        let peer = try NostrEventFactory.hexBytes(appPubkey)
        let body = try Self.jsonRPCBody(for: response)

        let ciphertext: String
        do {
            ciphertext = connection.usesLegacyEncryption
                ? try NIP04.encrypt(plaintext: body, privateKey: secret, publicKeyXOnly: peer)
                : try NIP44.encrypt(plaintext: body, privateKey: secret, publicKeyXOnly: peer)
        } catch { // coverage:ignore-region Inputs are validated before transport; only a cryptographic library failure reaches this boundary.
            throw NIP46RelayTransportError.encryptionFailed
        }

        let event = try NostrEventFactory.sign(
            UnsignedNostrEvent(
                createdAt: Int(now().timeIntervalSince1970),
                kind: Self.nip46Kind,
                tags: [["p", appPubkey]],
                content: ciphertext
            ),
            privateKey: secret
        )

        logger.log(
            event: "nip46.response.publish",
            metadata: ["requestID": response.id, "app": appPubkey, "relays": "\(connection.relays.count)"]
        )
        try await pool.publish(event, to: connection.relayURLs)
        await connections.markUsed(appPubkey: appPubkey, at: now())
    }

    static func jsonRPCBody(for response: NIP46Response) throws -> String {
        var object: [String: Any] = ["id": response.id]
        object["result"] = response.result ?? ""
        if let error = response.error {
            object["error"] = error.message
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
