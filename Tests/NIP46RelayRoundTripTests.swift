import XCTest
@testable import SignstrCore

final class ConnectionStoreTests: XCTestCase {
    private func makeConnection(pubkey: String = "app-pub", approved: Bool = false) -> AppConnection {
        AppConnection(
            appPubkey: pubkey,
            appName: "Amethyst",
            relays: ["wss://relay.one"],
            identityID: "id-1",
            secret: "s3cret",
            isApproved: approved
        )
    }

    func testStoredConnectionsSurviveANewStoreInstance() async {
        let defaults = makeEphemeralDefaults()
        await ConnectionStore(defaults: defaults).upsert(makeConnection(approved: true))

        let reloaded = await ConnectionStore(defaults: defaults).all()

        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.appName, "Amethyst")
        XCTAssertEqual(reloaded.first?.relays, ["wss://relay.one"])
    }

    func testOnlyApprovedConnectionsAreListenedTo() async {
        let store = ConnectionStore(defaults: makeEphemeralDefaults())
        await store.upsert(makeConnection(pubkey: "pending-app"))
        await store.upsert(makeConnection(pubkey: "approved-app", approved: true))

        let approved = await store.approved()

        XCTAssertEqual(approved.map(\.appPubkey), ["approved-app"])
    }

    func testApprovingAPendingPairingKeepsItsDetails() async {
        let store = ConnectionStore(defaults: makeEphemeralDefaults())
        await store.upsert(makeConnection())

        await store.approve(appPubkey: "app-pub")

        let connection = await store.connection(forAppPubkey: "app-pub")
        XCTAssertEqual(connection?.isApproved, true)
        XCTAssertEqual(connection?.relays, ["wss://relay.one"])
        XCTAssertNotNil(connection?.lastUsedAt)
    }

    func testRescanningAnApprovedAppDoesNotDowngradeIt() async {
        let store = ConnectionStore(defaults: makeEphemeralDefaults())
        await store.upsert(makeConnection(approved: true))
        let usedAt = Date(timeIntervalSince1970: 1_700_000_000)
        await store.markUsed(appPubkey: "app-pub", at: usedAt)

        await store.upsert(makeConnection(approved: false))

        let connection = await store.connection(forAppPubkey: "app-pub")
        XCTAssertEqual(connection?.isApproved, true, "an existing approval must not be lost")
        XCTAssertEqual(connection?.lastUsedAt, usedAt, "rescanning must not erase activity metadata")
    }

    func testLegacyEncryptionIsRememberedOnceSeen() async {
        let store = ConnectionStore(defaults: makeEphemeralDefaults())
        await store.upsert(makeConnection(approved: true))

        await store.markUsed(appPubkey: "app-pub", legacyEncryption: true)

        let connection = await store.connection(forAppPubkey: "app-pub")
        XCTAssertEqual(connection?.usesLegacyEncryption, true)
    }

    func testRemovingAConnectionForgetsIt() async {
        let store = ConnectionStore(defaults: makeEphemeralDefaults())
        await store.upsert(makeConnection(approved: true))

        await store.remove(appPubkey: "app-pub")

        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testRelayURLsSkipUnparseableEntries() {
        let connection = AppConnection(
            appPubkey: "app",
            relays: ["wss://relay.one", ""],
            identityID: "id-1",
            secret: "s"
        )

        XCTAssertEqual(connection.relayURLs.map(\.absoluteString), ["wss://relay.one"])
    }
}

final class NIP46RelayTransportTests: XCTestCase {
    /// The app's own key, used here to read what Signstr sends back.
    private let appNsec = TestVectors.otherNsec

    private func makeSetup(legacy: Bool = false) async throws -> (
        transport: NIP46RelayTransport,
        sockets: SocketRegistry,
        pool: NostrRelayPool,
        appPubkey: String
    ) {
        let appPubkey = try NostrKeyDeriver.derivePublicKeyHex(fromNsec: appNsec)
        let sockets = SocketRegistry()
        let pool = NostrRelayPool(socketFactory: { url in sockets.socket(for: url) })
        let connections = ConnectionStore(defaults: makeEphemeralDefaults())
        await connections.upsert(
            AppConnection(
                appPubkey: appPubkey,
                appName: "Amethyst",
                relays: ["wss://relay.one"],
                identityID: "id-1",
                secret: "s3cret",
                isApproved: true,
                usesLegacyEncryption: legacy
            )
        )
        let transport = NIP46RelayTransport(
            pool: pool,
            connections: connections,
            nsecStore: InMemoryNsecStore(keys: ["id-1": TestVectors.nsec]),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        return (transport, sockets, pool, appPubkey)
    }

    func testResponseIsPublishedAsASignedKind24133EventTheAppCanDecrypt() async throws {
        let setup = try await makeSetup()

        try await setup.transport.sendResponse(
            NIP46Response(id: "req-1", result: "pong", error: nil),
            to: setup.appPubkey
        )

        let frames = await setup.sockets.socket(for: URL(string: "wss://relay.one")!).frames()
        let event = try XCTUnwrap(Self.publishedEvent(in: frames))
        XCTAssertEqual(event.kind, 24133)
        XCTAssertEqual(event.pubkey, TestVectors.pubkeyHex, "signed by our identity")
        XCTAssertEqual(event.tags, [["p", setup.appPubkey]], "addressed to the app so the relay routes it")
        XCTAssertEqual(event.createdAt, 1_700_000_000)

        let body = try NIP44.decrypt(
            payload: event.content,
            privateKey: try NostrKeyDeriver.secretKeyBytes(fromNsec: appNsec),
            publicKeyXOnly: try NostrEventFactory.hexBytes(TestVectors.pubkeyHex)
        )
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["id"] as? String, "req-1")
        XCTAssertEqual(decoded["result"] as? String, "pong")
        await setup.pool.stop()
    }

    func testLegacyAppsAreAnsweredWithNIP04() async throws {
        let setup = try await makeSetup(legacy: true)

        try await setup.transport.sendResponse(
            NIP46Response(id: "req-1", result: "pong", error: nil),
            to: setup.appPubkey
        )

        let frames = await setup.sockets.socket(for: URL(string: "wss://relay.one")!).frames()
        let event = try XCTUnwrap(Self.publishedEvent(in: frames))
        XCTAssertTrue(event.content.contains("?iv="), "NIP-04 payloads carry their IV")
        let body = try NIP04.decrypt(
            payload: event.content,
            privateKey: try NostrKeyDeriver.secretKeyBytes(fromNsec: appNsec),
            publicKeyXOnly: try NostrEventFactory.hexBytes(TestVectors.pubkeyHex)
        )
        XCTAssertTrue(body.contains("pong"))
        await setup.pool.stop()
    }

    func testRejectionTravelsAsAnErrorField() async throws {
        let setup = try await makeSetup()

        try await setup.transport.sendResponse(
            NIP46Response(id: "req-1", result: nil, error: NIP46ResponseError(code: 4_001, message: "userRejected")),
            to: setup.appPubkey
        )

        let frames = await setup.sockets.socket(for: URL(string: "wss://relay.one")!).frames()
        let event = try XCTUnwrap(Self.publishedEvent(in: frames))
        let body = try NIP44.decrypt(
            payload: event.content,
            privateKey: try NostrKeyDeriver.secretKeyBytes(fromNsec: appNsec),
            publicKeyXOnly: try NostrEventFactory.hexBytes(TestVectors.pubkeyHex)
        )
        let decoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(decoded["error"] as? String, "userRejected")
        await setup.pool.stop()
    }

    func testAnUnknownAppCannotBeAnswered() async throws {
        let setup = try await makeSetup()

        do {
            try await setup.transport.sendResponse(
                NIP46Response(id: "req-1", result: "pong", error: nil),
                to: "0000000000000000000000000000000000000000000000000000000000000000"
            )
            XCTFail("there are no relays to answer on")
        } catch {
            XCTAssertEqual(error as? NIP46RelayTransportError, .unknownApp)
        }
        await setup.pool.stop()
    }

    func testAMissingKeyIsReported() async throws {
        let appPubkey = try NostrKeyDeriver.derivePublicKeyHex(fromNsec: appNsec)
        let connections = ConnectionStore(defaults: makeEphemeralDefaults())
        await connections.upsert(
            AppConnection(appPubkey: appPubkey, relays: ["wss://relay.one"], identityID: "id-gone", secret: "s", isApproved: true)
        )
        let transport = NIP46RelayTransport(
            pool: NostrRelayPool(socketFactory: { _ in FakeRelaySocket() }),
            connections: connections,
            nsecStore: InMemoryNsecStore()
        )

        do {
            try await transport.sendResponse(NIP46Response(id: "r", result: "x", error: nil), to: appPubkey)
            XCTFail("without a key nothing can be signed")
        } catch {
            XCTAssertEqual(error as? NIP46RelayTransportError, .noKeyForIdentity)
        }
    }

    func testJSONRPCBodyUsesTheFieldsClientsLookFor() throws {
        let body = try NIP46RelayTransport.jsonRPCBody(
            for: NIP46Response(id: "req-1", result: "pong", error: nil)
        )

        XCTAssertEqual(body, #"{"id":"req-1","result":"pong"}"#)
    }

    private static func publishedEvent(in frames: [String]) -> NostrEvent? {
        for frame in frames where frame.hasPrefix("[\"EVENT\"") {
            guard
                let data = frame.data(using: .utf8),
                let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
                let object = array.last as? [String: Any],
                let eventData = try? JSONSerialization.data(withJSONObject: object)
            else {
                continue
            }
            return try? JSONDecoder().decode(NostrEvent.self, from: eventData)
        }
        return nil
    }
}

final class NIP46RelayListenerTests: XCTestCase {
    private let appNsec = TestVectors.otherNsec

    private func makeListener(
        legacy: Bool = false,
        registerApp: Bool = true
    ) async throws -> (listener: NIP46RelayListener, manager: NIP46SessionManager, appPubkey: String) {
        let appPubkey = try NostrKeyDeriver.derivePublicKeyHex(fromNsec: appNsec)
        let connections = ConnectionStore(defaults: makeEphemeralDefaults())
        if registerApp {
            await connections.upsert(
                AppConnection(
                    appPubkey: appPubkey,
                    appName: "Amethyst",
                    relays: ["wss://relay.one"],
                    identityID: "id-1",
                    secret: "s3cret",
                    isApproved: true,
                    usesLegacyEncryption: legacy
                )
            )
        }
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        let listener = NIP46RelayListener(
            pool: NostrRelayPool(socketFactory: { _ in FakeRelaySocket() }),
            connections: connections,
            nsecStore: InMemoryNsecStore(keys: ["id-1": TestVectors.nsec]),
            coordinator: RequestRoutingCoordinator(sessionManager: manager),
            logger: RedactedLogger(emit: { _ in })
        )
        return (listener, manager, appPubkey)
    }

    func testAnEncryptedSignEventRequestBecomesAPendingApproval() async throws {
        let setup = try await makeListener()
        let event = try makeNIP46Event(
            body: #"{"id":"req-9","method":"sign_event","params":["{\"kind\":1,\"content\":\"gm\"}"]}"#,
            senderNsec: appNsec,
            recipientPubkeyHex: TestVectors.pubkeyHex
        )

        await setup.listener.handle(event)

        let pending = await setup.manager.pendingSessions()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.request.method, .signEvent)
        XCTAssertEqual(pending.first?.request.id, "req-9")
        XCTAssertEqual(pending.first?.request.appName, "Amethyst", "the approval screen names the app")
        XCTAssertEqual(pending.first?.request.params.first, #"{"kind":1,"content":"gm"}"#)
    }

    func testALegacyNIP04RequestIsAlsoUnderstood() async throws {
        let setup = try await makeListener(legacy: true)
        let event = try makeNIP46Event(
            body: #"{"id":"req-4","method":"get_public_key","params":[]}"#,
            senderNsec: appNsec,
            recipientPubkeyHex: TestVectors.pubkeyHex,
            legacy: true
        )

        await setup.listener.handle(event)

        let pending = await setup.manager.pendingSessions()
        XCTAssertEqual(pending.first?.request.method, .getPublicKey)
    }

    func testAnEventFromAnUnknownAppIsIgnored() async throws {
        let setup = try await makeListener(registerApp: false)
        let event = try makeNIP46Event(
            body: #"{"id":"req-9","method":"ping","params":[]}"#,
            senderNsec: appNsec,
            recipientPubkeyHex: TestVectors.pubkeyHex
        )

        await setup.listener.handle(event)

        let pending = await setup.manager.pendingSessions()
        XCTAssertTrue(pending.isEmpty, "only apps the user paired with can ask for anything")
    }

    func testAnUndecryptableEventIsIgnored() async throws {
        let setup = try await makeListener()
        let event = try NostrEventFactory.sign(
            UnsignedNostrEvent(createdAt: 1_700_000_000, kind: 24133, tags: [], content: "not encrypted"),
            privateKey: try NostrKeyDeriver.secretKeyBytes(fromNsec: appNsec)
        )

        await setup.listener.handle(event)

        let pending = await setup.manager.pendingSessions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testAnEventOfAnotherKindIsIgnored() async throws {
        let setup = try await makeListener()
        let event = try NostrEventFactory.sign(
            UnsignedNostrEvent(createdAt: 1_700_000_000, kind: 1, tags: [], content: "just a note"),
            privateKey: try NostrKeyDeriver.secretKeyBytes(fromNsec: appNsec)
        )

        await setup.listener.handle(event)

        let pending = await setup.manager.pendingSessions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testAnUnknownMethodIsIgnored() async throws {
        let setup = try await makeListener()
        let event = try makeNIP46Event(
            body: #"{"id":"req-9","method":"do_something_else","params":[]}"#,
            senderNsec: appNsec,
            recipientPubkeyHex: TestVectors.pubkeyHex
        )

        await setup.listener.handle(event)

        let pending = await setup.manager.pendingSessions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testNonStringParametersAreCarriedThroughAsJSON() {
        let connection = AppConnection(appPubkey: "app", relays: [], identityID: "id-1", secret: "s")
        let event = NostrEvent(id: "e1", pubkey: "app", createdAt: 1, kind: 24133, tags: [], content: "", sig: "")

        let request = NIP46RelayListener.request(
            fromJSONRPC: #"{"id":"r","method":"sign_event","params":[{"kind":1,"content":"gm"}]}"#,
            event: event,
            connection: connection
        )

        XCTAssertEqual(request?.params.count, 1)
        XCTAssertTrue(request?.params.first?.contains("\"kind\":1") == true, request?.params.first ?? "nil")
    }

    func testRequestWithoutAnIDIsRejected() {
        let connection = AppConnection(appPubkey: "app", relays: [], identityID: "id-1", secret: "s")
        let event = NostrEvent(id: "e1", pubkey: "app", createdAt: 1, kind: 24133, tags: [], content: "", sig: "")

        XCTAssertNil(
            NIP46RelayListener.request(fromJSONRPC: #"{"method":"ping"}"#, event: event, connection: connection)
        )
    }
}
