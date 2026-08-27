import Foundation

/// Decodes an incoming NIP-46 request event and hands it to the approval flow.
public actor NIP46RelayListener {
    public struct DecodedRequest: Equatable, Sendable {
        public let request: NIP46Request
        public let usedLegacyEncryption: Bool
    }

    private let pool: NostrRelayPool
    private let connections: ConnectionStore
    private let nsecStore: NsecStoring
    private let coordinator: RequestRoutingCoordinator
    private let logger: RedactedLogger

    public init(
        pool: NostrRelayPool,
        connections: ConnectionStore,
        nsecStore: NsecStoring,
        coordinator: RequestRoutingCoordinator,
        logger: RedactedLogger = RedactedLogger()
    ) {
        self.pool = pool
        self.connections = connections
        self.nsecStore = nsecStore
        self.coordinator = coordinator
        self.logger = logger
    }

    /// Subscribes on every relay of every approved connection.
    public func start() async {
        await pool.setEventHandler { [weak self] event in
            await self?.handle(event)
        }
        await resubscribe()
    }

    public func resubscribe() async {
        for connection in await connections.approved() {
            guard
                let nsec = try? await nsecStore.loadNsec(for: connection.identityID),
                let pubkey = try? NostrKeyDeriver.derivePublicKeyHex(fromNsec: nsec)
            else {
                continue
            }
            await pool.subscribe(
                subscriptionID: "nip46-\(connection.appPubkey.prefix(8))",
                recipientPubkey: pubkey,
                on: connection.relayURLs
            )
        }
    }

    /// Also used when a pairing is approved, so the app is heard immediately.
    public func listen(to connection: AppConnection) async {
        guard
            let nsec = try? await nsecStore.loadNsec(for: connection.identityID),
            let pubkey = try? NostrKeyDeriver.derivePublicKeyHex(fromNsec: nsec)
        else {
            return
        }
        await pool.subscribe(
            subscriptionID: "nip46-\(connection.appPubkey.prefix(8))",
            recipientPubkey: pubkey,
            on: connection.relayURLs
        )
    }

    func handle(_ event: NostrEvent) async {
        guard event.kind == NIP46RelayTransport.nip46Kind else { return }
        guard let connection = await connections.connection(forAppPubkey: event.pubkey) else {
            logger.log(event: "nip46.request.unknownApp", metadata: ["app": event.pubkey])
            return
        }

        guard let decoded = await decode(event: event, for: connection) else { return }

        await connections.markUsed(appPubkey: event.pubkey, legacyEncryption: decoded.usedLegacyEncryption)
        logger.log(
            event: "nip46.request.received",
            metadata: ["method": decoded.request.method.rawValue, "app": event.pubkey]
        )
        await coordinator.routeIncomingRequest(decoded.request)
    }

    func decode(event: NostrEvent, for connection: AppConnection) async -> DecodedRequest? {
        guard
            let nsec = try? await nsecStore.loadNsec(for: connection.identityID),
            let secret = try? NostrKeyDeriver.secretKeyBytes(fromNsec: nsec),
            let peer = try? NostrEventFactory.hexBytes(event.pubkey)
        else {
            return nil
        }

        var usedLegacy = false
        var plaintext = try? NIP44.decrypt(payload: event.content, privateKey: secret, publicKeyXOnly: peer)
        if plaintext == nil {
            plaintext = try? NIP04.decrypt(payload: event.content, privateKey: secret, publicKeyXOnly: peer)
            usedLegacy = plaintext != nil
        }
        guard let plaintext else {
            logger.log(event: "nip46.request.undecryptable", metadata: ["app": event.pubkey])
            return nil
        }

        guard let request = Self.request(fromJSONRPC: plaintext, event: event, connection: connection) else {
            logger.log(event: "nip46.request.malformed", metadata: ["app": event.pubkey])
            return nil
        }
        return DecodedRequest(request: request, usedLegacyEncryption: usedLegacy)
    }

    static func request(fromJSONRPC json: String, event: NostrEvent, connection: AppConnection) -> NIP46Request? {
        guard
            let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = object["id"] as? String,
            let methodName = object["method"] as? String,
            let method = NIP46Method(rawValue: methodName)
        else {
            return nil
        }

        let params = (object["params"] as? [Any])?.map { value -> String in
            if let text = value as? String { return text }
            if let nested = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
                return String(decoding: nested, as: UTF8.self)
            }
            return ""
        } ?? []

        return NIP46Request(
            id: id,
            method: method,
            params: params,
            appName: connection.appName,
            appURL: connection.appURL,
            appPubkey: event.pubkey,
            requestedAt: Date(timeIntervalSince1970: TimeInterval(event.createdAt)),
            correlationID: event.id,
            rawPayloadPreview: Self.preview(method: method, params: params)
        )
    }

    /// What the user sees on the approval screen.
    private static func preview(method: NIP46Method, params: [String]) -> String {
        switch method {
        case .signEvent:
            return params.first ?? ""
        case .nip04Encrypt, .nip44Encrypt, .nip04Decrypt, .nip44Decrypt:
            return "peer: \(params.first ?? "unknown")"
        default:
            return method.rawValue
        }
    }
}
