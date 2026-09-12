import XCTest
@testable import SigneurCore

@MainActor
final class SignerReliabilityTests: XCTestCase {
    func testRenamePreservesExistingIdentityMetadata() async throws {
        let defaults = makeEphemeralDefaults()
        let legacy = Identity(id: "legacy-key", displayName: "Existing key", npub: TestVectors.npub)
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "signstr.identities")
        defaults.set(legacy.id, forKey: "signstr.active.identity")
        let store = IdentityStore(defaults: defaults)
        let identities = await store.list()
        let active = await store.activeIdentityID()
        XCTAssertEqual(identities.map(\.id), [legacy.id])
        XCTAssertEqual(active, legacy.id)
    }

    func testRenamePreservesConnectionsPermissionsAndActivity() async throws {
        let defaults = makeEphemeralDefaults()
        let connection = AppConnection(appPubkey: TestVectors.pubkeyHex, appName: "Existing app", relays: ["wss://relay.one"], identityID: "legacy-key", isApproved: true)
        let rule = PermissionRule(appPubkey: TestVectors.pubkeyHex, method: "sign_event", kind: 1)
        let entry = AuditEntry(appName: "Existing app", method: "sign_event", outcome: .signed)
        defaults.set(try JSONEncoder().encode([connection]), forKey: "signstr.connections")
        defaults.set(try JSONEncoder().encode([rule]), forKey: "signstr.permission.rules")
        defaults.set([TestVectors.pubkeyHex: "Existing app"], forKey: "signstr.permission.appnames")
        defaults.set(try JSONEncoder().encode([entry]), forKey: "signstr.audit.entries")

        let connections = await ConnectionStore(defaults: defaults).approved()
        let permissions = PermissionRuleStore(defaults: defaults)
        let apps = await permissions.listConnectedApps()
        let remembered = await permissions.shouldAutoApprove(request: makeTestRequest())
        let entries = try await AuditLogStore(defaults: defaults).list()
        XCTAssertEqual(connections, [connection])
        XCTAssertEqual(apps.first?.appName, "Existing app")
        XCTAssertTrue(remembered)
        XCTAssertEqual(entries, [entry])
    }

    func testBoundIdentityCannotBeOverriddenByManualApproval() async {
        let executor = RecordingExecutor()
        let manager = NIP46SessionManager(validator: NIP46Validator(), executor: executor, transport: RecordingTransport(), authorizationGuard: AuthorizationGuard())
        await manager.onRequestArrived(makeTestRequest(identityID: "paired-key"))
        let state = await manager.handleApprove(requestID: "req-1", identityID: "different-key")
        let used = await executor.identities()
        XCTAssertEqual(state, .completedSuccess)
        XCTAssertEqual(used, ["paired-key"])
    }

    func testInvalidBoundIdentityCannotFallBackToActiveKey() async {
        let executor = RecordingExecutor()
        let manager = NIP46SessionManager(validator: NIP46Validator(), executor: executor, transport: RecordingTransport(), authorizationGuard: AuthorizationGuard())
        await manager.onRequestArrived(makeTestRequest(identityID: "bad\nidentity"))
        let state = await manager.handleApprove(requestID: "req-1", identityID: "valid-key")
        let count = await executor.signCount()
        XCTAssertEqual(state, .completedError(.unauthorizedSigningAttempt))
        XCTAssertEqual(count, 0)
    }

    func testDeletedBoundKeyCannotFallBackToAnotherStoredKey() async {
        let executor = NIP46MethodExecutor(nsecStore: InMemoryNsecStore(keys: ["other-key": TestVectors.otherNsec]))
        let transport = RecordingTransport()
        let manager = NIP46SessionManager(validator: NIP46Validator(), executor: executor, transport: transport, authorizationGuard: AuthorizationGuard())
        await manager.onRequestArrived(makeTestRequest(identityID: "deleted-key"))
        let state = await manager.handleApprove(requestID: "req-1", identityID: "other-key")
        let responses = await transport.sentResponses()
        XCTAssertEqual(state, .completedError(.identityKeyUnavailable))
        XCTAssertNil(responses.first?.result)
    }

    func testRequestIdentitySurvivesEncodingAndOlderRequestsStillDecode() throws {
        let bound = makeTestRequest(identityID: "paired-key")
        let decoded = try JSONDecoder().decode(NIP46Request.self, from: JSONEncoder().encode(bound))
        XCTAssertEqual(decoded, bound)
        let olderRequest = makeTestRequest()
        let olderData = try JSONEncoder().encode(olderRequest)
        XCTAssertFalse(String(decoding: olderData, as: UTF8.self).contains("identityID"))
        XCTAssertNil(try JSONDecoder().decode(NIP46Request.self, from: olderData).identityID)
    }

    func testRememberedRequestUsesTheIdentityBoundToItsConnection() async throws {
        let identities = IdentityStore(defaults: makeEphemeralDefaults(), seed: [
            Identity(id: "paired-key", displayName: "Paired key", npub: TestVectors.npub),
            Identity(id: "other-key", displayName: "Other key", npub: TestVectors.otherNpub)
        ])
        await identities.setActive(identityID: "other-key")
        let keys = InMemoryNsecStore(keys: ["paired-key": TestVectors.nsec, "other-key": TestVectors.otherNsec])
        let connections = ConnectionStore(defaults: makeEphemeralDefaults())
        let appPubkey = try NostrKeyDeriver.derivePublicKeyHex(fromNsec: TestVectors.otherNsec)
        await connections.upsert(AppConnection(appPubkey: appPubkey, relays: ["wss://relay.one"], identityID: "paired-key", isApproved: true))
        let transport = RecordingTransport()
        let permissions = PermissionRuleStore(defaults: makeEphemeralDefaults())
        await permissions.saveRememberRule(for: makeTestRequest(id: "earlier-approval", appPubkey: appPubkey))
        let manager = NIP46SessionManager(validator: NIP46Validator(), executor: NIP46MethodExecutor(nsecStore: keys), transport: transport, authorizationGuard: AuthorizationGuard(), permissionEvaluator: permissions)
        let listener = NIP46RelayListener(pool: NostrRelayPool(socketFactory: { _ in FakeRelaySocket() }), connections: connections, nsecStore: keys, identities: identities, coordinator: RequestRoutingCoordinator(sessionManager: manager))
        let unsigned = "{\"kind\":1,\"content\":\"review probe\",\"tags\":[],\"created_at\":\(Int(Date().timeIntervalSince1970))}"
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["id": "bound-key-probe", "method": "sign_event", "params": [unsigned]]), as: UTF8.self)
        let event = try makeNIP46Event(body: body, senderNsec: TestVectors.otherNsec, recipientPubkeyHex: TestVectors.pubkeyHex, createdAt: Int(Date().timeIntervalSince1970))
        await listener.handle(event)
        let vm = SessionViewModel(sessionManager: manager, identityStore: identities)
        await vm.refresh()
        let responses = await transport.sentResponses()
        let result = try XCTUnwrap(responses.first?.result)
        let signed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(signed["pubkey"] as? String, TestVectors.pubkeyHex)
    }

    func testFastRelayAcknowledgementIsNotLost() async throws {
        let socket = FastAcknowledgementSocket()
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket, publishTimeout: 0.05)
        try await connection.start { _ in }
        let event = try NostrEventFactory.sign(UnsignedNostrEvent(createdAt: Int(Date().timeIntervalSince1970), kind: 24133, tags: [], content: "probe"), privateKey: NostrKeyDeriver.secretKeyBytes(fromNsec: TestVectors.nsec))
        do {
            try await connection.publish(event)
        } catch {
            XCTFail("An acknowledged event must succeed, got \(error)")
        }
        await connection.stop()
    }

    func testReceiveFailureRestoresListeningWithoutAnotherPublish() async throws {
        let socket = FakeRelaySocket()
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket, reconnectDelay: 0.01)
        try await connection.start { _ in }
        try await connection.subscribe(subscriptionID: "review", recipientPubkey: TestVectors.pubkeyHex)
        try await Task.sleep(for: .milliseconds(20))
        await socket.close()
        try await Task.sleep(for: .milliseconds(200))
        let count = await socket.connectionsMade()
        XCTAssertGreaterThan(count, 1, "Receive failure leaves no reader or reconnect task")
        await connection.stop()
    }
}

private actor FastAcknowledgementSocket: RelaySocketing {
    let wrapped = FakeRelaySocket()
    func connect() async throws { try await wrapped.connect() }
    func receive() async throws -> String { try await wrapped.receive() }
    func close() async { await wrapped.close() }
    func send(_ text: String) async throws {
        try await wrapped.send(text)
        // A receive callback can run before an asynchronous send call returns.
        try await Task.sleep(for: .milliseconds(20))
    }
}
