import Foundation
import Security
import XCTest
@testable import SignstrCore

@MainActor
final class ViewModelCoverageGapTests: XCTestCase {
    func testConnectedAppFormattingCoversAllDateAndPermissionFallbacks() {
        let now = Date()
        let asking = ConnectedAppRow(app: ConnectedAppItem(
            appName: "Ask",
            appPubkey: TestVectors.pubkeyHex,
            methods: ["asks you every time"],
            requestedPermissions: []
        ))
        let remembered = ConnectedAppRow(app: ConnectedAppItem(
            appName: "Remembered",
            appPubkey: TestVectors.otherPubkeyHex,
            methods: ["sign_event", "logout"],
            requestedPermissions: []
        ))

        XCTAssertEqual(asking.permissionSummary, "Asks before every action")
        XCTAssertEqual(remembered.permissionSummary, "Sign events, Disconnect signer")
        XCTAssertTrue(asking.activityLabel(for: now).hasPrefix("Today,"))
        XCTAssertTrue(asking.activityLabel(for: now.addingTimeInterval(-86_400)).hasPrefix("Yesterday,"))
        XCTAssertFalse(asking.activityLabel(for: now.addingTimeInterval(-7 * 86_400)).isEmpty)
    }

    func testIncomingPermissionHelpersCoverEveryMapping() async {
        let manager = makeManager()
        let store = IdentityStore(defaults: makeEphemeralDefaults())
        let view = IncomingRequestView(viewModel: SessionViewModel(sessionManager: manager, identityStore: store))

        XCTAssertEqual(view.permissionLabel("get_public_key"), "Read your public key")
        XCTAssertEqual(view.permissionLabel("nip04_encrypt"), "Encrypt NIP-04 messages")
        XCTAssertEqual(view.permissionLabel("nip44_decrypt"), "Decrypt NIP-44 messages")
        XCTAssertEqual(view.permissionLabel("switch_relays"), "Change relay settings")
        XCTAssertEqual(view.permissionLabel("ping"), "Check signer availability")
        XCTAssertEqual(view.permissionIcon("get_public_key"), "person.text.rectangle")
        XCTAssertEqual(view.permissionIcon("switch_relays"), "network")
    }

    func testPairingErrorCopyCoversEveryParserFailure() {
        XCTAssertTrue(PairingViewModel.message(for: SignerURLParseError.invalidScheme).contains("not a signing request"))
        XCTAssertTrue(PairingViewModel.message(for: SignerURLParseError.unsupportedType("zap")).contains("zap"))
        XCTAssertTrue(PairingViewModel.message(for: SignerURLParseError.missingPeerPubkey).contains("whose key"))
        XCTAssertTrue(PairingViewModel.message(for: SignerURLParseError.unsupportedCompression("gzip")).contains("gzip"))
        XCTAssertTrue(PairingViewModel.message(for: SignerURLParseError.payloadTooLarge).contains("too large"))
        XCTAssertTrue(PairingViewModel.message(for: DeepLinkParseError.invalidClientPubkey).contains("invalid app public key"))
        XCTAssertTrue(PairingViewModel.message(for: DeepLinkParseError.invalidRelay).contains("insecure"))
        XCTAssertTrue(PairingViewModel.message(for: DeepLinkParseError.invalidSecret).contains("pairing secret"))
        XCTAssertTrue(PairingViewModel.message(for: DeepLinkParseError.invalidMetadata).contains("metadata"))
        XCTAssertEqual(PairingViewModel.message(for: PlainCoverageError()), "This link could not be read.")
    }

    func testPairingReportsWhenTheSessionManagerRejectsConnectRequests() async {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(supportedMethods: [.ping]),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        let viewModel = PairingViewModel(coordinator: RequestRoutingCoordinator(sessionManager: manager))
        let url = URL(string: "nostrconnect://\(TestVectors.otherPubkeyHex)?relay=wss://relay.one&secret=coverage")!

        let accepted = await viewModel.handleDeepLink(url)
        XCTAssertFalse(accepted)
        XCTAssertTrue(viewModel.errorMessage?.contains("not accepted") == true)
    }

    func testSessionViewModelPublishesManualAndAutomaticAuthorizationFailures() async {
        let identity = Identity(id: "coverage-id", displayName: "Coverage", npub: TestVectors.npub)
        let identities = IdentityStore(defaults: makeEphemeralDefaults(), seed: [identity])
        await identities.setActive(identityID: identity.id)
        let manualManager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: DenyingAuthorization()
        )
        let manualViewModel = SessionViewModel(sessionManager: manualManager, identityStore: identities)

        _ = await manualManager.onRequestArrived(makeTestRequest(id: "manual-denied"))
        await manualViewModel.refresh()
        _ = await manualViewModel.approve()
        XCTAssertEqual(manualViewModel.errorMessage, SessionFailureReason.unauthorizedSigningAttempt.userMessage)

        let automaticManager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: DenyingAuthorization(),
            permissionEvaluator: AlwaysApprovingPermission()
        )
        let automaticViewModel = SessionViewModel(sessionManager: automaticManager, identityStore: identities)
        _ = await automaticManager.onRequestArrived(makeTestRequest(id: "automatic-denied"))
        await automaticViewModel.refresh()
        XCTAssertEqual(automaticViewModel.errorMessage, SessionFailureReason.unauthorizedSigningAttempt.userMessage)
        XCTAssertNil(automaticViewModel.currentSession)
    }

    func testKeysViewModelCoversRelayFallbackRefreshAndMissingKey() async {
        let identity = Identity(id: "coverage-key", displayName: "Coverage", npub: TestVectors.npub)
        let defaults = makeEphemeralDefaults()
        let identities = IdentityStore(defaults: defaults, seed: [identity])
        let keys = InMemoryNsecStore(keys: [identity.id: TestVectors.nsec])
        let lookup = StubProfileLookup(
            metadata: nil,
            relayURLs: [URL(string: "relative-relay")!, URL(string: "wss://relay.example")!]
        )
        let viewModel = KeysViewModel(identityStore: identities, nsecStore: keys, profileLookup: lookup)
        await viewModel.refresh()

        XCTAssertEqual(viewModel.syncRelayDescriptions, ["relay.example (kind 0)"])
        await viewModel.toggleReveal(identity)
        await identities.delete(identityID: identity.id)
        await viewModel.refresh()
        XCTAssertTrue(viewModel.revealedNsecs.isEmpty)

        let missing = Identity(id: "missing", displayName: "Missing", npub: TestVectors.otherNpub)
        await viewModel.toggleReveal(missing)
        XCTAssertEqual(viewModel.errorMessage, "No key is stored for Missing.")

        viewModel.nsec = "   "
        await viewModel.addKey()
        XCTAssertEqual(viewModel.errorMessage, "Paste an nsec to continue.")
    }

    func testKeysViewModelUsesNonLocalizedStorageErrorAndSetActive() async {
        let first = Identity(id: "first", displayName: "First", npub: TestVectors.npub)
        let second = Identity(id: "second", displayName: "Second", npub: TestVectors.otherNpub)
        let identities = IdentityStore(defaults: makeEphemeralDefaults(), seed: [first, second])
        let viewModel = KeysViewModel(identityStore: identities, nsecStore: PlainFailingNsecStore())
        await viewModel.refresh()
        await viewModel.setActive(second)
        XCTAssertEqual(viewModel.activeIdentityID, second.id)

        viewModel.nsec = TestVectors.nsec
        await viewModel.addKey()
        XCTAssertFalse(viewModel.errorMessage?.isEmpty ?? true)
    }

    private func makeManager() -> NIP46SessionManager {
        NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard()
        )
    }
}

final class ProtocolCoverageGapTests: XCTestCase {
    func testNostrEventValidationAndEscapingFailureBranches() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let secret = try NostrKeyDeriver.secretKeyBytes(fromNsec: TestVectors.nsec)
        let signed = try NostrEventFactory.sign(
            UnsignedNostrEvent(createdAt: Int(now.timeIntervalSince1970), kind: 1, tags: [], content: "ok"),
            privateKey: secret,
            now: now
        )

        XCTAssertThrowsError(try NostrEvent(id: signed.id, pubkey: "bad", createdAt: signed.createdAt, kind: 1, tags: [], content: "ok", sig: signed.sig).validate(now: now))
        XCTAssertThrowsError(try NostrEvent(id: "bad", pubkey: signed.pubkey, createdAt: signed.createdAt, kind: 1, tags: [], content: "ok", sig: signed.sig).validate(now: now))
        XCTAssertThrowsError(try NostrEvent(id: signed.id, pubkey: signed.pubkey, createdAt: signed.createdAt, kind: 1, tags: Array(repeating: [], count: SecurityPolicy.maxEventTags + 1), content: "ok", sig: signed.sig).validate(now: now))
        let changedSignature = String(repeating: "0", count: 128)
        XCTAssertThrowsError(try NostrEvent(id: signed.id, pubkey: signed.pubkey, createdAt: signed.createdAt, kind: 1, tags: [], content: "ok", sig: changedSignature).validate(now: now))

        let escaped = NostrEvent.serializeForID(
            pubkey: signed.pubkey,
            createdAt: signed.createdAt,
            kind: 1,
            tags: [["\r", "\t", "\u{08}", "\u{0C}", "\u{01}"]],
            content: "\r\t\u{08}\u{0C}\u{01}"
        )
        XCTAssertTrue(escaped.contains("\\r"))
        XCTAssertTrue(escaped.contains("\\t"))
        XCTAssertTrue(escaped.contains("\\b"))
        XCTAssertTrue(escaped.contains("\\f"))
        XCTAssertTrue(escaped.contains("\\u0001"))
    }

    func testUnsignedEventRejectsOversizedContentAndNegativeTimestamp() {
        let oversized = String(repeating: "x", count: SecurityPolicy.maxRequestPayloadBytes + 1)
        XCTAssertThrowsError(try UnsignedNostrEvent.decode(json: #"{"kind":1,"content":""# + oversized + #""}"#))
        XCTAssertThrowsError(try UnsignedNostrEvent.decode(json: #"{"kind":1,"created_at":-1}"#))
        XCTAssertThrowsError(try UnsignedNostrEvent.decode(json: #"{"kind":1,"content":5}"#))
    }

    func testEventFactoryRejectsInvalidKeysAndHex() {
        XCTAssertThrowsError(try NostrEventFactory.sign(UnsignedNostrEvent(createdAt: nil, kind: 1, tags: [], content: ""), privateKey: []))
        XCTAssertThrowsError(try NostrEventFactory.hexBytes("0"))
        XCTAssertThrowsError(try NostrEventFactory.hexBytes("zz"))
    }

    func testRelayFrameFallbacksAndInvalidProfileRequests() throws {
        XCTAssertEqual(RelayFrame.decode(#"["OK","id",true]"#), .ok(eventID: "id", accepted: true, message: ""))
        XCTAssertEqual(RelayFrame.decode(#"["OK","id",false,7]"#), .ok(eventID: "id", accepted: false, message: ""))
        XCTAssertNil(RelayFrame.decode(#"["EOSE",7]"#))
        XCTAssertEqual(RelayFrame.decode(#"["CLOSED","sub"]"#), .closed(subscriptionID: "sub", message: ""))
        XCTAssertEqual(RelayFrame.decode(#"["CLOSED","sub",7]"#), .closed(subscriptionID: "sub", message: ""))
        XCTAssertNil(RelayFrame.decode(#"["NOTICE",7]"#))
        XCTAssertNil(RelayFrame.decode(#"["AUTH",7]"#))
        XCTAssertThrowsError(try RelayRequest.subscribeToProfile(subscriptionID: "s", authorPubkey: "bad"))
        XCTAssertThrowsError(try RelayRequest.subscribeToProfile(subscriptionID: "s", authorPubkey: TestVectors.pubkeyHex, kinds: []))
    }

    func testDefaultRelaySocketAdaptersCanBeConstructedWithoutNetworking() async {
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        let factory = DefaultRelayWebSocketTaskFactory(session: session)
        let task = factory.makeTask(for: URL(string: "wss://relay.example")!)
        task.cancel(with: .goingAway, reason: nil)

        let socket = URLSessionRelaySocket(url: URL(string: "wss://relay.example")!, session: session)
        await socket.close()
    }

    func testSignerURLCoversEverySupportedMethodAndPreview() throws {
        for type in ["nip04_encrypt", "nip04_decrypt", "nip44_encrypt", "nip44_decrypt"] {
            let request = try SignerURLRequest.parse("nostrsigner:hello?type=\(type)&pubkey=\(TestVectors.otherPubkeyHex)")
            XCTAssertEqual(request.params.count, 2)
            XCTAssertTrue(request.makeNIP46Request().rawPayloadPreview.hasPrefix("peer:"))
        }
        XCTAssertEqual(try SignerURLRequest.parse("nostrsigner:?type=ping").method, .ping)
        XCTAssertThrowsError(try SignerURLRequest.parse("nostrsigner:?type=nip44_encrypt&pubkey=\(TestVectors.otherPubkeyHex)"))
        let encoded = try SignerURLRequest.parse("nostrsigner:hello%20world?type=sign_event")
        XCTAssertEqual(encoded.params, ["hello world"])
        let permissions = "%5B%7B%22kind%22%3A1%7D%2C%7B%22type%22%3A%22sign_event%22%2C%22kind%22%3A1%7D%5D"
        XCTAssertEqual(try SignerURLRequest.parse("nostrsigner:x?permissions=\(permissions)").requestedPermissions, ["sign_event:1"])
        XCTAssertThrowsError(try SignerURLRequest.parse("nostrsigner:?type=connect")) {
            XCTAssertEqual($0 as? SignerURLParseError, .unsupportedType("connect"))
        }
    }

    func testCallbackTransportUnknownClipboardAndQueryFallbacks() async throws {
        let transport = NIP55CallbackTransport(openURL: { _ in false })
        do {
            try await transport.sendResponse(NIP46Response(id: "unknown", result: "x", error: nil), to: "app")
            XCTFail("Expected an unregistered response to fail")
        } catch {
            XCTAssertEqual(error as? NIP55CallbackError, .noWayToReturnResult)
        }

        await transport.register(requestID: "clipboard", callbackURL: nil, returnType: .event)
        do {
            try await transport.sendResponse(NIP46Response(id: "clipboard", result: "x", error: nil), to: "app")
            XCTFail("Expected a missing callback to fail")
        } catch {
            XCTAssertEqual(error as? NIP55CallbackError, .noWayToReturnResult)
        }

        let appended = NIP55CallbackTransport.callbackTarget(URL(string: "damus:callback")!, payload: "signed")
        XCTAssertEqual(URLComponents(url: appended, resolvingAgainstBaseURL: false)?.queryItems?.last?.name, "result")
        let replaced = NIP55CallbackTransport.callbackTarget(URL(string: "damus:callback?result=")!, payload: "signed")
        XCTAssertEqual(URLComponents(url: replaced, resolvingAgainstBaseURL: false)?.queryItems?.last?.value, "signed")
    }

    func testKeychainErrorDescriptionsAndPresenceMappings() {
        XCTAssertTrue(NsecStoreError.unexpectedStatus(errSecParam).errorDescription?.contains("Keychain error") == true)
        XCTAssertTrue(NsecKeychainStore.indicatesPresence(errSecInteractionNotAllowed))
        XCTAssertTrue(NsecKeychainStore.indicatesPresence(errSecAuthFailed))
        XCTAssertFalse(NsecKeychainStore.indicatesPresence(errSecParam))
    }

    func testDefaultKeychainBackendOperationsUseScopedQueries() {
        let backend = DefaultNsecKeychainBackend()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "signstr.coverage.\(UUID().uuidString)",
            kSecAttrAccount as String: "coverage"
        ]
        var result: CFTypeRef?

        _ = backend.delete(query: query)
        let addStatus = backend.add(query: query)
        let copyStatus = backend.copyMatching(query: query, result: &result)
        _ = backend.delete(query: query)
        XCTAssertEqual(addStatus, errSecSuccess)
        XCTAssertEqual(copyStatus, errSecSuccess)
    }

    func testKeychainStoreReportsBackendWriteFailures() async {
        let store = NsecKeychainStore(unlockDuration: 1, keychain: FailingAddKeychainBackend())
        do {
            try await store.saveNsec(TestVectors.nsec, for: "coverage-id")
            XCTFail("Expected the backend failure to be reported")
        } catch {
            XCTAssertEqual(error as? NsecStoreError, .unexpectedStatus(errSecParam))
        }
    }

    func testKeychainStoreReportsUnavailableProtection() async {
        let store = NsecKeychainStore(unlockDuration: 1, keychain: MissingProtectionKeychainBackend())
        do {
            try await store.saveNsec(TestVectors.nsec, for: "coverage-id")
            XCTFail("Expected unavailable access control to be reported")
        } catch {
            XCTAssertEqual(error as? NsecStoreError, .protectionUnavailable)
        }
    }

    func testValidatorCoversInvalidIdentifiersAndConnectSecret() {
        let invalidID = NIP46Request(
            id: "bad\nid",
            method: .ping,
            params: [],
            appName: nil,
            appURL: nil,
            appPubkey: TestVectors.pubkeyHex,
            correlationID: "valid",
            rawPayloadPreview: ""
        )
        let invalidCorrelation = NIP46Request(
            id: "valid",
            method: .ping,
            params: [],
            appName: nil,
            appURL: nil,
            appPubkey: TestVectors.pubkeyHex,
            correlationID: "bad\ncorrelation",
            rawPayloadPreview: ""
        )
        let invalidConnect = NIP46Request(
            id: "connect",
            method: .connect,
            params: [""],
            appName: nil,
            appURL: nil,
            appPubkey: TestVectors.pubkeyHex,
            correlationID: "connect",
            rawPayloadPreview: ""
        )

        XCTAssertEqual(validationError(invalidID), .invalidField("id"))
        XCTAssertEqual(validationError(invalidCorrelation), .invalidField("correlationID"))
        XCTAssertEqual(validationError(invalidConnect), .invalidParamShape("connect expects one bounded secret"))
    }

    func testDeepLinkRejectsAnOversizedSecret() {
        let secret = String(repeating: "x", count: SecurityPolicy.maxSecretBytes + 1)
        let url = URL(string: "nostrconnect://\(TestVectors.otherPubkeyHex)?relay=wss://relay.one&secret=\(secret)")!
        XCTAssertThrowsError(try DeepLinkHandler().parse(url)) { error in
            XCTAssertEqual(error as? DeepLinkParseError, .invalidSecret)
        }
    }

    func testMethodExecutorCoversDefaultClockMissingEventAndEncryptionFailure() async throws {
        let executor = NIP46MethodExecutor(nsecStore: InMemoryNsecStore(keys: ["key": TestVectors.nsec]))
        let signed = try await executor.execute(
            makeTestRequest(method: .signEvent, params: [#"{"kind":1,"content":"clock"}"#]),
            identityID: "key"
        )
        XCTAssertTrue(signed.contains("created_at"))

        do {
            _ = try await executor.execute(makeTestRequest(method: .signEvent, params: []), identityID: "key")
            XCTFail("Expected a missing event")
        } catch {
            XCTAssertEqual(error as? NIP46ExecutionError, .missingParameter("event"))
        }

        let oversized = String(repeating: "x", count: 70_000)
        do {
            _ = try await executor.execute(
                makeTestRequest(method: .nip44Encrypt, params: [TestVectors.otherPubkeyHex, oversized]),
                identityID: "key"
            )
            XCTFail("Expected oversized encryption to fail")
        } catch {
            XCTAssertEqual(error as? NIP46ExecutionError, .encryptionFailed)
        }
    }

    func testSessionManagerRejectsApprovalWhenAuthorizationGuardDeniesIt() async {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: DenyingAuthorization()
        )
        _ = await manager.onRequestArrived(makeTestRequest(id: "denied"))
        _ = await manager.activateNextPendingIfNeeded()

        let state = await manager.handleApprove(requestID: "denied", identityID: "key")
        XCTAssertEqual(state, .completedError(.unauthorizedSigningAttempt))
    }

    func testRelayConnectionCoversUnsubscribeClosedFramesAndPendingStop() async throws {
        let socket = FakeRelaySocket(autoAcknowledge: false)
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket)
        try await connection.start { _ in }
        try await connection.subscribe(subscriptionID: "coverage-sub", recipientPubkey: TestVectors.pubkeyHex)
        await connection.unsubscribe(subscriptionID: "coverage-sub")
        await socket.deliver(#"["CLOSED","coverage-sub","done"]"#)
        await socket.deliver(#"["NOTICE","slow down"]"#)

        let event = try NostrEventFactory.sign(
            UnsignedNostrEvent(createdAt: 1_700_000_000, kind: 1, tags: [], content: "pending"),
            privateKey: try NostrKeyDeriver.secretKeyBytes(fromNsec: TestVectors.nsec)
        )
        let publish = Task { try await connection.publish(event) }
        try await Task.sleep(for: .milliseconds(30))
        await connection.stop()
        do {
            try await publish.value
            XCTFail("Expected stop to fail the pending publish")
        } catch {
            XCTAssertEqual(error as? RelaySocketError, .closed)
        }
    }

    func testProfileDefaultsClosedRelayAndConnectionFailure() async throws {
        XCTAssertTrue(NoopNostrProfileLookup().relayURLs.isEmpty)
        XCTAssertEqual(NostrProfileMetadata(nip05: "_@trustroots.org").suggestedName, "trustroots.org")

        let closedSocket = FakeRelaySocket()
        let fetcher = WebSocketNostrProfileEventFetcher(socketFactory: { _ in closedSocket }, timeout: 1)
        let task = Task {
            await fetcher.fetchProfileEvents(pubkey: TestVectors.pubkeyHex, relays: [URL(string: "wss://relay.one")!])
        }
        try await Task.sleep(for: .milliseconds(30))
        let frames = await closedSocket.frames()
        let subscribe = try XCTUnwrap(frames.first { $0.hasPrefix("[\"REQ\",") })
        let array = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(subscribe.utf8)) as? [Any])
        let subscriptionID = try XCTUnwrap(array[1] as? String)
        await closedSocket.deliver("[\"CLOSED\",\"\(subscriptionID)\",\"done\"]")
        let closedEvents = await task.value
        XCTAssertTrue(closedEvents.isEmpty)

        let failing = WebSocketNostrProfileEventFetcher(
            socketFactory: { _ in FakeRelaySocket(failOnConnect: true) },
            timeout: 1
        )
        let failed = await failing.fetchProfileEvents(
            pubkey: TestVectors.pubkeyHex,
            relays: [URL(string: "wss://relay.two")!]
        )
        XCTAssertTrue(failed.isEmpty)
    }

    func testDefaultRelayFactoriesAndRedirectDelegate() async {
        _ = NostrRelayPool()
        _ = WebSocketNostrProfileEventFetcher()

        let completion = expectation(description: "redirect refused")
        let delegate = NoRedirectURLSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: URL(string: "https://example.com")!)
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        )!
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://example.org")!)
        ) { request in
            XCTAssertNil(request)
            completion.fulfill()
        }
        await fulfillment(of: [completion], timeout: 1)
    }

    func testAppConnectionIdentifierIsItsPublicKey() {
        let connection = AppConnection(appPubkey: TestVectors.pubkeyHex, relays: [], identityID: "key")
        XCTAssertEqual(connection.id, TestVectors.pubkeyHex)
    }

    private func validationError(_ request: NIP46Request) -> NIP46ValidationError? {
        guard case let .failure(error) = NIP46Validator().validate(request) else { return nil }
        return error
    }
}

private struct PlainCoverageError: Error, CustomStringConvertible {
    var description: String { "plain coverage error" }
}

private actor PlainFailingNsecStore: NsecStoring {
    func saveNsec(_ nsec: String, for identityID: String) async throws { throw PlainCoverageError() }
    func loadNsec(for identityID: String) async throws -> String? { throw PlainCoverageError() }
    func hasNsec(for identityID: String) async -> Bool { false }
    func deleteNsec(for identityID: String) async {}
}

private struct DenyingAuthorization: RequestAuthorization {
    func canExecute(session: NIP46Session) -> Bool { false }
}

private actor AlwaysApprovingPermission: PermissionRuleEvaluating {
    func shouldAutoApprove(request: NIP46Request) async -> Bool { true }
    func saveRememberRule(for request: NIP46Request) async {}
}

private struct FailingAddKeychainBackend: NsecKeychainBackend {
    func delete(query: [String: Any]) -> OSStatus { errSecSuccess }
    func add(query: [String: Any]) -> OSStatus { errSecParam }
    func copyMatching(query: [String: Any], result: inout CFTypeRef?) -> OSStatus { errSecItemNotFound }
}

private struct MissingProtectionKeychainBackend: NsecKeychainBackend {
    func delete(query: [String: Any]) -> OSStatus { errSecSuccess }
    func add(query: [String: Any]) -> OSStatus { errSecSuccess }
    func copyMatching(query: [String: Any], result: inout CFTypeRef?) -> OSStatus { errSecItemNotFound }
    func makeAccessControl() -> SecAccessControl? { nil }
}
