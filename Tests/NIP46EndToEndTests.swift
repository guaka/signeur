import P256K
import XCTest
@testable import SigneurCore

/// Plays the part of a remote app: pairs, sends an encrypted request over a relay,
/// and reads the reply back off that relay.
final class NIP46EndToEndTests: XCTestCase {
    private let relay = URL(string: "wss://relay.one")!
    private let appNsec = TestVectors.otherNsec

    private struct Harness {
        let manager: NIP46SessionManager
        let coordinator: RequestRoutingCoordinator
        let listener: NIP46RelayListener
        let identities: IdentityStore
        let connections: ConnectionStore
        let activator: ConnectionActivator
        let pool: NostrRelayPool
        let sockets: SocketRegistry
        let appPubkey: String
        let signerPubkey: String
    }

    private actor RequestReceipt {
        private var count = 0

        func record() { count += 1 }
        func recordedCount() -> Int { count }
    }

    private func makeHarness(
        onRequestReceived: @escaping @Sendable () async -> Void = {}
    ) async throws -> Harness {
        let appPubkey = try NostrKeyDeriver.derivePublicKeyHex(fromNsec: appNsec)
        let sockets = SocketRegistry()
        let pool = NostrRelayPool(socketFactory: { url in sockets.socket(for: url) })
        let connections = ConnectionStore(defaults: makeEphemeralDefaults())
        let nsecStore = InMemoryNsecStore(keys: ["id-1": TestVectors.nsec])
        let identities = IdentityStore(
            defaults: makeEphemeralDefaults(),
            seed: [Identity(id: "id-1", displayName: "Main", npub: TestVectors.npub)]
        )

        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: NIP46MethodExecutor(nsecStore: nsecStore, now: { Date(timeIntervalSince1970: 1_700_000_000) }),
            transport: NIP46RelayTransport(
                pool: pool,
                connections: connections,
                nsecStore: nsecStore,
                logger: RedactedLogger(emit: { _ in }),
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            authorizationGuard: AuthorizationGuard()
        )
        let activator = ConnectionActivator(connections: connections)
        let coordinator = RequestRoutingCoordinator(
            sessionManager: manager,
            connectionRegistry: activator,
            activeIdentityID: { "id-1" }
        )
        let listener = NIP46RelayListener(
            pool: pool,
            connections: connections,
            nsecStore: nsecStore,
            identities: identities,
            coordinator: coordinator,
            logger: RedactedLogger(emit: { _ in }),
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            onRequestReceived: onRequestReceived
        )

        return Harness(
            manager: manager,
            coordinator: coordinator,
            listener: listener,
            identities: identities,
            connections: connections,
            activator: activator,
            pool: pool,
            sockets: sockets,
            appPubkey: appPubkey,
            signerPubkey: TestVectors.pubkeyHex
        )
    }

    private func pairingLink(for appPubkey: String) -> String {
        "nostrconnect://\(appPubkey)?relay=wss://relay.one&secret=s3cret&name=Amethyst"
    }

    func testPairingApprovalSendsTheSecretBackToTheAppOverTheRelay() async throws {
        let harness = try await makeHarness()
        _ = try await harness.coordinator.routeScannedPayload(pairingLink(for: harness.appPubkey))
        let activated = await harness.manager.activateNextPendingIfNeeded()
        let session = try XCTUnwrap(activated)

        let state = await harness.manager.handleApprove(requestID: session.request.id, identityID: "id-1")

        XCTAssertEqual(state, .completedSuccess)
        let replyBody = try await lastReply(from: harness)
        let reply = try XCTUnwrap(replyBody)
        XCTAssertEqual(reply["result"] as? String, "s3cret", "the app checks this against the secret in its code")
        XCTAssertEqual(reply["id"] as? String, session.request.id)
        await harness.pool.stop()
    }

    @MainActor
    func testPairingThroughTheApprovalScreenUsesTheActiveIdentityForItsReply() async throws {
        let harness = try await makeHarness()
        _ = try await harness.coordinator.routeScannedPayload(pairingLink(for: harness.appPubkey))
        let viewModel = SessionViewModel(
            sessionManager: harness.manager,
            identityStore: harness.identities,
            connectionRegistry: harness.activator
        )

        await viewModel.refresh()
        XCTAssertEqual(viewModel.selectedIdentityID, "id-1")
        let approved = await viewModel.approve()
        XCTAssertTrue(approved)

        let connection = await harness.connections.connection(forAppPubkey: harness.appPubkey)
        XCTAssertEqual(connection?.identityID, "id-1")
        XCTAssertEqual(connection?.isApproved, true)
        let replyBody = try await lastReply(from: harness)
        let reply = try XCTUnwrap(replyBody)
        XCTAssertEqual(reply["result"] as? String, "s3cret")
        await harness.pool.stop()
    }

    func testApprovedPairingIsRememberedSoTheAppIsHeardAfterRelaunch() async throws {
        let harness = try await makeHarness()
        _ = try await harness.coordinator.routeScannedPayload(pairingLink(for: harness.appPubkey))
        let activated = await harness.manager.activateNextPendingIfNeeded()
        let session = try XCTUnwrap(activated)
        _ = await harness.manager.handleApprove(requestID: session.request.id, identityID: "id-1")

        await harness.activator.activate(appPubkey: harness.appPubkey)

        let approved = await harness.connections.approved()
        XCTAssertEqual(approved.map(\.appPubkey), [harness.appPubkey])
        XCTAssertEqual(approved.first?.relays, ["wss://relay.one"])
        XCTAssertEqual(approved.first?.identityID, "id-1")
        await harness.pool.stop()
    }

    func testSignEventRequestOverTheRelayComesBackAsAVerifiableSignedEvent() async throws {
        let harness = try await makeHarness()
        try await connect(harness)

        let event = try makeNIP46Event(
            body: #"{"id":"req-sign","method":"sign_event","params":["{\"kind\":1,\"content\":\"gm nostr\",\"created_at\":1700000000}"]}"#,
            senderNsec: appNsec,
            recipientPubkeyHex: harness.signerPubkey
        )
        await harness.listener.handle(event)

        let activated = await harness.manager.activateNextPendingIfNeeded()
        let session = try XCTUnwrap(activated)
        XCTAssertEqual(session.request.method, .signEvent)
        let state = await harness.manager.handleApprove(requestID: "req-sign", identityID: "id-1")
        XCTAssertEqual(state, .completedSuccess)

        let replyBody = try await lastReply(from: harness)
        let reply = try XCTUnwrap(replyBody)
        let signedJSON = try XCTUnwrap(reply["result"] as? String)
        let signed = try JSONDecoder().decode(NostrEvent.self, from: Data(signedJSON.utf8))
        XCTAssertEqual(signed.content, "gm nostr")
        XCTAssertEqual(signed.pubkey, harness.signerPubkey)
        XCTAssertTrue(try verify(signed), "the app would discard an event it cannot verify")
        await harness.pool.stop()
    }

    func testRejectedRequestComesBackAsAnError() async throws {
        let harness = try await makeHarness()
        try await connect(harness)

        let event = try makeNIP46Event(
            body: #"{"id":"req-no","method":"sign_event","params":["{\"kind\":1,\"content\":\"nope\"}"]}"#,
            senderNsec: appNsec,
            recipientPubkeyHex: harness.signerPubkey
        )
        await harness.listener.handle(event)
        _ = await harness.manager.activateNextPendingIfNeeded()

        _ = await harness.manager.handleReject(requestID: "req-no")

        let replyBody = try await lastReply(from: harness)
        let reply = try XCTUnwrap(replyBody)
        XCTAssertEqual(reply["error"] as? String, "userRejected")
        await harness.pool.stop()
    }

    func testPingOverTheRelayIsAnsweredWithPong() async throws {
        let harness = try await makeHarness()
        try await connect(harness)

        let event = try makeNIP46Event(
            body: #"{"id":"req-ping","method":"ping","params":[]}"#,
            senderNsec: appNsec,
            recipientPubkeyHex: harness.signerPubkey
        )
        await harness.listener.handle(event)
        _ = await harness.manager.activateNextPendingIfNeeded()

        _ = await harness.manager.handleApprove(requestID: "req-ping", identityID: "id-1")

        let replyBody = try await lastReply(from: harness)
        let reply = try XCTUnwrap(replyBody)
        XCTAssertEqual(reply["result"] as? String, "pong")
        await harness.pool.stop()
    }

    func testGetPublicKeyOverTheRelayReturnsTheIdentityKey() async throws {
        let receipt = RequestReceipt()
        let harness = try await makeHarness(onRequestReceived: { await receipt.record() })
        try await connect(harness)

        let event = try makeNIP46Event(
            body: #"{"id":"req-pk","method":"get_public_key","params":[]}"#,
            senderNsec: appNsec,
            recipientPubkeyHex: harness.signerPubkey
        )
        await harness.listener.handle(event)
        _ = await harness.manager.activateNextPendingIfNeeded()

        _ = await harness.manager.handleApprove(requestID: "req-pk", identityID: "id-1")

        let replyBody = try await lastReply(from: harness)
        let reply = try XCTUnwrap(replyBody)
        XCTAssertEqual(reply["result"] as? String, harness.signerPubkey)
        let receivedCount = await receipt.recordedCount()
        XCTAssertEqual(receivedCount, 1, "the app shell must be told to show each relay request")
        await harness.pool.stop()
    }

    func testTheAppCanAskUsToDecryptAMessageAddressedToIt() async throws {
        let harness = try await makeHarness()
        try await connect(harness)
        // A third party encrypted this to our identity key.
        let payload = try NIP44.encrypt(
            plaintext: "hello from a friend",
            privateKey: try NostrKeyDeriver.secretKeyBytes(fromNsec: appNsec),
            publicKeyXOnly: try NostrEventFactory.hexBytes(harness.signerPubkey)
        )
        let body = try JSONSerialization.data(withJSONObject: [
            "id": "req-dec",
            "method": "nip44_decrypt",
            "params": [harness.appPubkey, payload]
        ])

        await harness.listener.handle(
            try makeNIP46Event(
                body: String(decoding: body, as: UTF8.self),
                senderNsec: appNsec,
                recipientPubkeyHex: harness.signerPubkey
            )
        )
        _ = await harness.manager.activateNextPendingIfNeeded()
        _ = await harness.manager.handleApprove(requestID: "req-dec", identityID: "id-1")

        let replyBody = try await lastReply(from: harness)
        let reply = try XCTUnwrap(replyBody)
        XCTAssertEqual(reply["result"] as? String, "hello from a friend")
        await harness.pool.stop()
    }

    func testTwoRequestsAreQueuedAndAnsweredOneAtATime() async throws {
        let harness = try await makeHarness()
        try await connect(harness)

        for id in ["req-1", "req-2"] {
            await harness.listener.handle(
                try makeNIP46Event(
                    body: #"{"id":"\#(id)","method":"ping","params":[]}"#,
                    senderNsec: appNsec,
                    recipientPubkeyHex: harness.signerPubkey,
                    createdAt: id == "req-1" ? 1_700_000_000 : 1_700_000_001
                )
            )
        }

        let pending = await harness.manager.pendingSessions()
        XCTAssertEqual(pending.map(\.request.id), ["req-1", "req-2"])

        _ = await harness.manager.activateNextPendingIfNeeded()
        _ = await harness.manager.handleApprove(requestID: "req-1", identityID: "id-1")
        let next = await harness.manager.activateNextPendingIfNeeded()
        XCTAssertEqual(next?.request.id, "req-2", "the second prompt only appears after the first is answered")
        await harness.pool.stop()
    }

    /// Walks a pairing all the way to an approved, listening connection.
    private func connect(_ harness: Harness) async throws {
        _ = try await harness.coordinator.routeScannedPayload(pairingLink(for: harness.appPubkey))
        let activated = await harness.manager.activateNextPendingIfNeeded()
        let session = try XCTUnwrap(activated)
        _ = await harness.manager.handleApprove(requestID: session.request.id, identityID: "id-1")
        await harness.activator.activate(appPubkey: harness.appPubkey)
        await clearFrames(harness)
    }

    private func clearFrames(_ harness: Harness) async {
        await harness.sockets.socket(for: relay).resetFrames()
    }

    /// Decrypts the newest event Signeur published, the way the app would.
    private func lastReply(from harness: Harness) async throws -> [String: Any]? {
        let frames = await harness.sockets.socket(for: relay).frames()
        guard
            let frame = frames.last(where: { $0.hasPrefix("[\"EVENT\"") }),
            let data = frame.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
            let object = array.last as? [String: Any],
            let eventData = try? JSONSerialization.data(withJSONObject: object),
            let event = try? JSONDecoder().decode(NostrEvent.self, from: eventData)
        else {
            return nil
        }

        let body = try NIP44.decrypt(
            payload: event.content,
            privateKey: try NostrKeyDeriver.secretKeyBytes(fromNsec: appNsec),
            publicKeyXOnly: try NostrEventFactory.hexBytes(harness.signerPubkey)
        )
        return try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
    }

    private func verify(_ event: NostrEvent) throws -> Bool {
        let signature = try P256K.Schnorr.SchnorrSignature(
            dataRepresentation: Data(try NostrEventFactory.hexBytes(event.sig))
        )
        var message = try NostrEventFactory.hexBytes(event.id)
        let xonly = P256K.Schnorr.XonlyKey(dataRepresentation: try NostrEventFactory.hexBytes(event.pubkey))
        return xonly.isValid(signature, for: &message)
    }
}
