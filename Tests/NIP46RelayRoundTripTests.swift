import XCTest
@testable import SignstrCore

final class ConnectionStoreTests: XCTestCase {
    private func makeConnection(pubkey: String = TestVectors.otherPubkeyHex, approved: Bool = false) -> AppConnection {
        AppConnection(
            appPubkey: pubkey,
            appName: "Amethyst",
            relays: ["wss://relay.one"],
            identityID: "id-1",
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
        await store.upsert(makeConnection(pubkey: TestVectors.pubkeyHex))
        await store.upsert(makeConnection(pubkey: TestVectors.otherPubkeyHex, approved: true))

        let approved = await store.approved()

        XCTAssertEqual(approved.map(\.appPubkey), [TestVectors.otherPubkeyHex])
    }

    func testApprovingAPendingPairingKeepsItsDetails() async {
        let store = ConnectionStore(defaults: makeEphemeralDefaults())
        await store.upsert(makeConnection())

        await store.approve(appPubkey: TestVectors.otherPubkeyHex)

        let connection = await store.connection(forAppPubkey: TestVectors.otherPubkeyHex)
        XCTAssertEqual(connection?.isApproved, true)
        XCTAssertEqual(connection?.relays, ["wss://relay.one"])
        XCTAssertNotNil(connection?.lastUsedAt)
    }

    func testRescanningAnApprovedAppDoesNotDowngradeIt() async {
        let store = ConnectionStore(defaults: makeEphemeralDefaults())
        await store.upsert(makeConnection(approved: true))
        let usedAt = Date(timeIntervalSince1970: 1_700_000_000)
        await store.markUsed(appPubkey: TestVectors.otherPubkeyHex, at: usedAt)

        await store.upsert(makeConnection(approved: false))

        let connection = await store.connection(forAppPubkey: TestVectors.otherPubkeyHex)
        XCTAssertEqual(connection?.isApproved, true, "an existing approval must not be lost")
        XCTAssertEqual(connection?.lastUsedAt, usedAt, "rescanning must not erase activity metadata")
    }

    func testLegacyEncryptionIsRememberedOnceSeen() async {
        let store = ConnectionStore(defaults: makeEphemeralDefaults())
        await store.upsert(makeConnection(approved: true))

        await store.markUsed(appPubkey: TestVectors.otherPubkeyHex, legacyEncryption: true)

        let connection = await store.connection(forAppPubkey: TestVectors.otherPubkeyHex)
        XCTAssertEqual(connection?.usesLegacyEncryption, true)
    }

    func testRemovingAConnectionForgetsIt() async {
        let store = ConnectionStore(defaults: makeEphemeralDefaults())
        await store.upsert(makeConnection(approved: true))

        await store.remove(appPubkey: TestVectors.otherPubkeyHex)

        let all = await store.all()
        XCTAssertTrue(all.isEmpty)
    }

    func testRelayURLsSkipUnparseableEntries() {
        let connection = AppConnection(
            appPubkey: "app",
            relays: ["wss://relay.one", ""],
            identityID: "id-1"
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
            AppConnection(appPubkey: appPubkey, relays: ["wss://relay.one"], identityID: "id-gone", isApproved: true)
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
        registerApp: Bool = true,
        approved: Bool = true,
        connectionIdentityID: String = "id-1",
        socketFactory: @escaping (URL) -> RelaySocketing = { _ in FakeRelaySocket() },
        identitySeed: [Identity]? = nil,
        nsecStoreKeys: [String: String] = ["id-1": TestVectors.nsec]
    ) async throws -> (listener: NIP46RelayListener, manager: NIP46SessionManager, appPubkey: String) {
        let appPubkey = try NostrKeyDeriver.derivePublicKeyHex(fromNsec: appNsec)
        let connections = ConnectionStore(defaults: makeEphemeralDefaults())
        if registerApp {
            await connections.upsert(
                AppConnection(
                    appPubkey: appPubkey,
                    appName: "Amethyst",
                    relays: ["wss://relay.one"],
                    identityID: connectionIdentityID,
                    isApproved: approved,
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
        let identities = IdentityStore(
            defaults: makeEphemeralDefaults(),
            seed: identitySeed ?? [Identity(id: connectionIdentityID, displayName: "Main", npub: TestVectors.npub)]
        )
        let listener = NIP46RelayListener(
            pool: NostrRelayPool(socketFactory: socketFactory),
            connections: connections,
            nsecStore: InMemoryNsecStore(keys: nsecStoreKeys),
            identities: identities,
            coordinator: RequestRoutingCoordinator(sessionManager: manager),
            logger: RedactedLogger(emit: { _ in }),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
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

    func testPendingConnectionCannotSendRequests() async throws {
        let setup = try await makeListener(approved: false)
        let event = try makeNIP46Event(
            body: #"{"id":"pending","method":"ping","params":[]}"#,
            senderNsec: appNsec,
            recipientPubkeyHex: TestVectors.pubkeyHex
        )

        await setup.listener.handle(event)

        let pending = await setup.manager.pendingSessions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testForgedEventIsRejectedBeforeDecryption() async throws {
        let setup = try await makeListener()
        let signed = try makeNIP46Event(
            body: #"{"id":"forged","method":"ping","params":[]}"#,
            senderNsec: appNsec,
            recipientPubkeyHex: TestVectors.pubkeyHex
        )
        let forged = NostrEvent(
            id: signed.id,
            pubkey: signed.pubkey,
            createdAt: signed.createdAt,
            kind: signed.kind,
            tags: signed.tags,
            content: signed.content + "x",
            sig: signed.sig
        )

        await setup.listener.handle(forged)

        let pending = await setup.manager.pendingSessions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testStaleAndFutureDatedEventsAreRejected() async throws {
        let setup = try await makeListener()
        for timestamp in [1_699_999_399, 1_700_000_121] {
            let event = try makeNIP46Event(
                body: #"{"id":"time-\#(timestamp)","method":"ping","params":[]}"#,
                senderNsec: appNsec,
                recipientPubkeyHex: TestVectors.pubkeyHex,
                createdAt: timestamp
            )
            await setup.listener.handle(event)
        }

        let pending = await setup.manager.pendingSessions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testCryptographicallyValidEventForAnotherSignerIsRejected() async throws {
        let setup = try await makeListener()
        let secret = try NostrKeyDeriver.secretKeyBytes(fromNsec: appNsec)
        let signerPeer = try NostrEventFactory.hexBytes(TestVectors.pubkeyHex)
        let content = try NIP44.encrypt(
            plaintext: #"{"id":"wrong-signer","method":"ping","params":[]}"#,
            privateKey: secret,
            publicKeyXOnly: signerPeer
        )
        let event = try NostrEventFactory.sign(
            UnsignedNostrEvent(
                createdAt: 1_700_000_000,
                kind: NIP46RelayTransport.nip46Kind,
                tags: [["p", TestVectors.otherPubkeyHex]],
                content: content
            ),
            privateKey: secret
        )

        await setup.listener.handle(event)

        let pending = await setup.manager.pendingSessions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testReplayedRelayEventCreatesOnlyOneApproval() async throws {
        let setup = try await makeListener()
        let event = try makeNIP46Event(
            body: #"{"id":"replay","method":"ping","params":[]}"#,
            senderNsec: appNsec,
            recipientPubkeyHex: TestVectors.pubkeyHex
        )

        await setup.listener.handle(event)
        await setup.listener.handle(event)

        let pending = await setup.manager.pendingSessions()
        XCTAssertEqual(pending.count, 1)
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
        let connection = AppConnection(appPubkey: TestVectors.otherNpub, relays: [], identityID: "id-1")
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
        let connection = AppConnection(appPubkey: TestVectors.otherNpub, relays: [], identityID: "id-1")
        let event = NostrEvent(id: "e1", pubkey: "app", createdAt: 1, kind: 24133, tags: [], content: "", sig: "")

        XCTAssertNil(
            NIP46RelayListener.request(fromJSONRPC: #"{"method":"ping"}"#, event: event, connection: connection)
        )
    }

    func testRequestWithTooManyParametersIsRejected() {
        let params = Array(0...32)
        let payload = try! JSONSerialization.data(
            withJSONObject: ["id": "r", "method": "ping", "params": params],
            options: .sortedKeys
        )
        let connection = AppConnection(appPubkey: TestVectors.otherNpub, relays: [], identityID: "id-1")
        let event = NostrEvent(
            id: "e1",
            pubkey: "app",
            createdAt: 1_700_000_000,
            kind: 24133,
            tags: [["p", "requester"]],
            content: "",
            sig: ""
        )
        let request = String(decoding: payload, as: UTF8.self)

        XCTAssertNil(NIP46RelayListener.request(fromJSONRPC: request, event: event, connection: connection))
    }

    func testRequestWithOversizedPayloadIsRejected() {
        let huge = String(repeating: "x", count: SecurityPolicy.maxRequestPayloadBytes + 1)
        let payload = try! JSONSerialization.data(
            withJSONObject: ["id": "r", "method": "ping", "params": [huge]],
            options: .sortedKeys
        )
        let connection = AppConnection(appPubkey: TestVectors.otherNpub, relays: [], identityID: "id-1")
        let event = NostrEvent(
            id: "e1",
            pubkey: "app",
            createdAt: 1_700_000_000,
            kind: 24133,
            tags: [["p", "requester"]],
            content: "",
            sig: ""
        )
        let request = String(decoding: payload, as: UTF8.self)

        XCTAssertNil(NIP46RelayListener.request(fromJSONRPC: request, event: event, connection: connection))
    }

    func testStartSubscribesToApprovedConnections() async throws {
        let relay = URL(string: "wss://relay.one")!
        let sockets = SocketRegistry()
        let setup = try await makeListener(socketFactory: { sockets.socket(for: $0) })

        await setup.listener.start()

        let frames = await sockets.socket(for: relay).frames()
        let prefix = String(setup.appPubkey.prefix(8))
        let hasSubscription = frames.contains { frame in
            frame.hasPrefix("[\"REQ\",") && frame.contains("nip46-\(prefix)")
        }
        XCTAssertTrue(hasSubscription)
    }

    func testResubscribeSkipsConnectionsWithoutSignerIdentity() async throws {
        let relay = URL(string: "wss://relay.one")!
        let sockets = SocketRegistry()
        let setup = try await makeListener(
            connectionIdentityID: "missing-id",
            identitySeed: [],
            socketFactory: { sockets.socket(for: $0) }
        )

        await setup.listener.resubscribe()

        let frames = await sockets.socket(for: relay).frames()
        XCTAssertTrue(frames.isEmpty)
    }

    func testListenSubscribesToConnectionRelay() async throws {
        let relay = URL(string: "wss://relay.one")!
        let sockets = SocketRegistry()
        let setup = try await makeListener(socketFactory: { sockets.socket(for: $0) })
        let connection = AppConnection(
            appPubkey: setup.appPubkey,
            appName: "Amethyst",
            relays: ["wss://relay.one"],
            identityID: "id-1",
            isApproved: true
        )

        await setup.listener.listen(to: connection)

        let frames = await sockets.socket(for: relay).frames()
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames.first?.hasPrefix("[\"REQ\",") == true)
    }

    func testListenIsNoopWhenSignerIdentityIsUnknown() async throws {
        let relay = URL(string: "wss://relay.one")!
        let sockets = SocketRegistry()
        let setup = try await makeListener(
            identitySeed: [],
            socketFactory: { sockets.socket(for: $0) }
        )
        let connection = AppConnection(
            appPubkey: setup.appPubkey,
            appName: "Amethyst",
            relays: ["wss://relay.one"],
            identityID: "missing-id",
            isApproved: true
        )

        await setup.listener.listen(to: connection)

        let frames = await sockets.socket(for: relay).frames()
        XCTAssertTrue(frames.isEmpty)
    }

    func testMissingNsecInStoreSkipsPendingSessionCreation() async throws {
        let setup = try await makeListener(
            nsecStoreKeys: [:],
            identitySeed: [Identity(id: "id-1", displayName: "Main", npub: TestVectors.npub)]
        )
        let event = try makeNIP46Event(
            body: #"{"id":"r","method":"ping","params":[]}"#,
            senderNsec: appNsec,
            recipientPubkeyHex: TestVectors.pubkeyHex
        )

        await setup.listener.handle(event)

        let pending = await setup.manager.pendingSessions()
        XCTAssertTrue(pending.isEmpty)
    }
}
