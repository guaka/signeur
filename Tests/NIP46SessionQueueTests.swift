import XCTest
@testable import SigneurCore

final class NIP46SessionQueueTests: XCTestCase {
    private func makeManager(
        executor: RecordingExecutor = RecordingExecutor(),
        transport: RecordingTransport = RecordingTransport(),
        permissionEvaluator: PermissionRuleEvaluating? = nil,
        sessionTTL: TimeInterval = 120
    ) -> NIP46SessionManager {
        NIP46SessionManager(
            validator: NIP46Validator(),
            executor: executor,
            transport: transport,
            authorizationGuard: AuthorizationGuard(),
            permissionEvaluator: permissionEvaluator,
            sessionTTL: sessionTTL
        )
    }

    func testInvalidRequestNeverEntersTheQueue() async {
        let manager = makeManager()
        let state = await manager.onRequestArrived(makeTestRequest(id: "", method: .ping, params: []))

        let pending = await manager.pendingSessions()
        XCTAssertEqual(state, .completedError(.invalidProtocol))
        XCTAssertTrue(pending.isEmpty)
    }

    func testEmptyManagerHasNoActiveSession() async {
        let manager = makeManager()

        let activeSession = await manager.activeSession()
        XCTAssertNil(activeSession)
    }

    func testRequestsAreServedInArrivalOrder() async {
        let manager = makeManager()
        _ = await manager.onRequestArrived(makeTestRequest(id: "first"))
        _ = await manager.onRequestArrived(makeTestRequest(id: "second"))

        let active = await manager.activateNextPendingIfNeeded()
        XCTAssertEqual(active?.request.id, "first")

        let stillFirst = await manager.activateNextPendingIfNeeded()
        XCTAssertEqual(stillFirst?.request.id, "first", "a second request must not preempt the visible prompt")

        _ = await manager.handleApprove(requestID: "first", identityID: "id-1")
        let next = await manager.activateNextPendingIfNeeded()
        XCTAssertEqual(next?.request.id, "second")
    }

    func testQueueEmptiesAfterAllRequestsResolve() async {
        let manager = makeManager()
        _ = await manager.onRequestArrived(makeTestRequest(id: "a"))
        _ = await manager.onRequestArrived(makeTestRequest(id: "b"))
        _ = await manager.activateNextPendingIfNeeded()
        _ = await manager.handleApprove(requestID: "a", identityID: "id-1")
        _ = await manager.activateNextPendingIfNeeded()
        _ = await manager.handleReject(requestID: "b")

        let pending = await manager.pendingSessions()
        let active = await manager.activateNextPendingIfNeeded()
        XCTAssertTrue(pending.isEmpty)
        XCTAssertNil(active)
    }

    func testExpiredRequestIsSkippedAndNeverSigned() async {
        let executor = RecordingExecutor()
        let manager = makeManager(executor: executor, sessionTTL: -1)
        _ = await manager.onRequestArrived(makeTestRequest(id: "stale"))

        let active = await manager.activateNextPendingIfNeeded()
        let state = await manager.handleApprove(requestID: "stale", identityID: "id-1")
        let signCount = await executor.signCount()

        XCTAssertNil(active)
        XCTAssertEqual(state, .expired)
        XCTAssertEqual(signCount, 0)
    }

    func testTimeoutMarksSessionExpiredAndClearsQueue() async {
        let manager = makeManager()
        _ = await manager.onRequestArrived(makeTestRequest(id: "t1"))
        _ = await manager.activateNextPendingIfNeeded()

        let state = await manager.onTimeout(requestID: "t1")
        let pending = await manager.pendingSessions()

        XCTAssertEqual(state, .expired)
        XCTAssertTrue(pending.isEmpty)
    }

    func testUnknownRequestIDIsRejectedForBothDecisions() async {
        let manager = makeManager()
        let approve = await manager.handleApprove(requestID: "ghost", identityID: "id-1")
        let reject = await manager.handleReject(requestID: "ghost")

        XCTAssertEqual(approve, .completedError(.invalidProtocol))
        XCTAssertEqual(reject, .completedError(.invalidProtocol))
    }

    func testUnknownRequestIDCannotTimeOut() async {
        let manager = makeManager()

        let timeout = await manager.onTimeout(requestID: "ghost")

        XCTAssertEqual(timeout, .completedError(.invalidProtocol))
    }

    func testTransportFailureWhileRejectingIsTerminal() async {
        let manager = makeManager(transport: RecordingTransport(shouldThrow: true))
        _ = await manager.onRequestArrived(makeTestRequest(id: "reject-failure"))
        _ = await manager.activateNextPendingIfNeeded()

        let state = await manager.handleReject(requestID: "reject-failure")

        XCTAssertEqual(state, .completedError(.userRejected))
    }

    func testApprovalSignsWithTheChosenIdentity() async {
        let executor = RecordingExecutor()
        let manager = makeManager(executor: executor)
        _ = await manager.onRequestArrived(makeTestRequest(id: "a"))
        _ = await manager.activateNextPendingIfNeeded()

        _ = await manager.handleApprove(requestID: "a", identityID: "chosen-identity")

        let identities = await executor.identities()
        XCTAssertEqual(identities, ["chosen-identity"])
    }

    func testApprovalResponseCarriesTheExecutedResultVerbatim() async {
        let transport = RecordingTransport()
        let manager = makeManager(transport: transport)
        _ = await manager.onRequestArrived(makeTestRequest(id: "a"))
        _ = await manager.activateNextPendingIfNeeded()

        _ = await manager.handleApprove(requestID: "a", identityID: "id-1")

        let responses = await transport.sentResponses()
        XCTAssertEqual(responses.count, 1)
        // NIP-46 results are protocol strings (a signed event, a pubkey, "pong"), not encoded blobs.
        XCTAssertEqual(responses.first?.result, RecordingExecutor.stubResult)
        XCTAssertNil(responses.first?.error)
    }

    func testSigningFailureIsTerminalAndReportedToTheApp() async {
        let transport = RecordingTransport()
        let manager = makeManager(executor: RecordingExecutor(shouldThrow: true), transport: transport)
        _ = await manager.onRequestArrived(makeTestRequest(id: "a"))
        _ = await manager.activateNextPendingIfNeeded()

        let state = await manager.handleApprove(requestID: "a", identityID: "id-1")
        let responses = await transport.sentResponses()

        XCTAssertEqual(state, .completedError(.signingFailed))
        XCTAssertTrue(state.isTerminal, "a signing failure must not leave the UI spinning")
        XCTAssertEqual(responses.count, 1, "the app must be told signing failed rather than waiting forever")
        XCTAssertEqual(responses.first?.error?.message, SessionFailureReason.signingFailed.rawValue)
        XCTAssertNil(responses.first?.result)
        let pending = await manager.pendingSessions()
        XCTAssertTrue(pending.isEmpty, "a failed request must not stay in the queue")
    }

    func testRelayFailureOnApprovalIsTerminalAndSpecific() async {
        let manager = makeManager(transport: RecordingTransport(shouldThrow: true))
        _ = await manager.onRequestArrived(makeTestRequest(id: "a"))
        _ = await manager.activateNextPendingIfNeeded()

        let state = await manager.handleApprove(requestID: "a", identityID: "id-1")
        XCTAssertEqual(state, .completedError(.relayUnavailable))
    }

    func testRememberChoiceStoresRuleOnlyWhenRequested() async {
        let defaults = makeEphemeralDefaults()
        let permissions = PermissionRuleStore(defaults: defaults)
        let manager = makeManager(permissionEvaluator: permissions)

        _ = await manager.onRequestArrived(makeTestRequest(id: "a", payload: "{\"kind\":1}"))
        _ = await manager.activateNextPendingIfNeeded()
        _ = await manager.handleApprove(requestID: "a", identityID: "id-1", rememberChoice: false)
        let rulesAfterPlainApproval = try? await permissions.listRules()
        XCTAssertEqual(rulesAfterPlainApproval?.count, 0)

        _ = await manager.onRequestArrived(makeTestRequest(id: "b", payload: "{\"kind\":1}"))
        _ = await manager.activateNextPendingIfNeeded()
        _ = await manager.handleApprove(requestID: "b", identityID: "id-1", rememberChoice: true)
        let rulesAfterRemember = try? await permissions.listRules()
        XCTAssertEqual(rulesAfterRemember?.count, 1)
        XCTAssertEqual(rulesAfterRemember?.first?.kind, 1)
    }

    func testAutoApprovalIsReportedOnlyForRememberedRequests() async {
        let permissions = PermissionRuleStore(defaults: makeEphemeralDefaults())
        let manager = makeManager(permissionEvaluator: permissions)
        await permissions.saveRememberRule(for: makeTestRequest(id: "seed", payload: "{\"kind\":1}"))

        _ = await manager.onRequestArrived(makeTestRequest(id: "remembered", payload: "{\"kind\":1}"))
        _ = await manager.onRequestArrived(makeTestRequest(id: "novel", payload: "{\"kind\":4}"))

        let rememberedDecision = await manager.shouldAutoApprove(requestID: "remembered")
        let novelDecision = await manager.shouldAutoApprove(requestID: "novel")
        let unknownDecision = await manager.shouldAutoApprove(requestID: "ghost")

        XCTAssertTrue(rememberedDecision)
        XCTAssertFalse(novelDecision)
        XCTAssertFalse(unknownDecision)
    }

    func testNothingIsAutoApprovedWithoutAPermissionStore() async {
        let manager = makeManager(permissionEvaluator: nil)
        _ = await manager.onRequestArrived(makeTestRequest(id: "a"))

        let decision = await manager.shouldAutoApprove(requestID: "a")
        XCTAssertFalse(decision)
    }
}
