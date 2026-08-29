import XCTest
import Security
@testable import SigneurCore

final class NIP46SessionManagerTests: XCTestCase {
    func testDuplicateRequestIDDoesNotCreateMultiplePrompts() async {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: MockTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        let request = Self.request(id: "same")
        _ = await manager.onRequestArrived(request)
        _ = await manager.onRequestArrived(request)
        let sessions = await manager.pendingSessions()
        XCTAssertEqual(sessions.count, 1)
    }

    func testRejectProducesRejectedErrorResponse() async {
        let transport = MockTransport()
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: transport,
            authorizationGuard: AuthorizationGuard()
        )
        let request = Self.request(id: "r1")
        _ = await manager.onRequestArrived(request)
        _ = await manager.activateNextPendingIfNeeded()
        let state = await manager.handleReject(requestID: "r1")

        XCTAssertTrue(state.isTerminal)
        let firstMessage = await transport.firstErrorMessage()
        XCTAssertEqual(firstMessage, SessionFailureReason.userRejected.rawValue)
    }

    func testExecutionStateClosesDoubleApprovalRejectionAndTimeoutRaces() async {
        let executor = SuspendingExecutor()
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: executor,
            transport: MockTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        _ = await manager.onRequestArrived(Self.request(id: "race"))
        _ = await manager.activateNextPendingIfNeeded()

        let firstApproval = Task {
            await manager.handleApprove(requestID: "race", identityID: "identity-a")
        }
        await executor.waitUntilStarted()

        let secondApproval = await manager.handleApprove(requestID: "race", identityID: "identity-b")
        let rejection = await manager.handleReject(requestID: "race")
        let timeout = await manager.onTimeout(requestID: "race")

        XCTAssertEqual(secondApproval, .signing)
        XCTAssertEqual(rejection, .signing)
        XCTAssertEqual(timeout, .signing)
        await executor.release()
        let finalState = await firstApproval.value
        let callCount = await executor.callCount()
        let identities = await executor.identities()
        XCTAssertEqual(finalState, .completedSuccess)
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(identities, ["identity-a"])
    }

    func testInvalidRequestsAreRejectedAsProtocolErrors() async {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: MockTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        let invalid = NIP46Request(
            id: "invalid",
            method: .signEvent,
            params: ["{\"kind\":1}"],
            appName: "App",
            appURL: nil,
            appPubkey: "bad",
            correlationID: "corr-invalid",
            rawPayloadPreview: "{\"kind\":1}"
        )
        let state = await manager.onRequestArrived(invalid)

        XCTAssertEqual(state, SessionState.completedError(.invalidProtocol))
    }

    func testShouldAutoApproveUsesPermissionEvaluator() async {
        let evaluator = PermissionDecisionEngine(shouldApprove: true)
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: MockTransport(),
            authorizationGuard: AuthorizationGuard(),
            permissionEvaluator: evaluator
        )
        _ = await manager.onRequestArrived(Self.request(id: "remember-me"))

        let result = await manager.shouldAutoApprove(requestID: "remember-me")

        XCTAssertTrue(result)
        let decisionCount = await evaluator.decisionCount()
        XCTAssertEqual(decisionCount, 1)
    }

    func testAutoApprovalChoiceIsSavedAfterApprovedRequest() async {
        let evaluator = PermissionDecisionEngine()
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: MockTransport(),
            authorizationGuard: AuthorizationGuard(),
            permissionEvaluator: evaluator
        )
        _ = await manager.onRequestArrived(Self.request(id: "remember"))
        _ = await manager.activateNextPendingIfNeeded()

        let state = await manager.handleApprove(requestID: "remember", identityID: "identity-a", rememberChoice: true)
        let saved = await evaluator.savedCount()

        XCTAssertEqual(state, .completedSuccess)
        XCTAssertEqual(saved, 1)
    }

    func testRejectingUnknownRequestIDReturnsProtocolError() async {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: MockTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        let state = await manager.handleReject(requestID: "missing")
        XCTAssertEqual(state, SessionState.completedError(.invalidProtocol))
    }

    func testExecuteFailureReturnsSigningFailedState() async {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(shouldThrow: true),
            transport: MockTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        _ = await manager.onRequestArrived(Self.request(id: "failing"))
        _ = await manager.activateNextPendingIfNeeded()

        let state = await manager.handleApprove(requestID: "failing", identityID: "identity-a")

        XCTAssertEqual(state, .completedError(.signingFailed))
    }

    func testDeliveryFailuresPreserveSafeActionableCategories() {
        XCTAssertEqual(
            NIP46SessionManager.deliveryFailureReason(for: NIP46RelayTransportError.unknownApp),
            .connectionNotRegistered
        )
        XCTAssertEqual(
            NIP46SessionManager.deliveryFailureReason(for: NIP46RelayTransportError.noKeyForIdentity),
            .identityKeyUnavailable
        )
        XCTAssertEqual(
            NIP46SessionManager.deliveryFailureReason(for: NIP46RelayTransportError.encryptionFailed),
            .responseEncryptionFailed
        )
        XCTAssertEqual(
            NIP46SessionManager.deliveryFailureReason(for: NostrRelayPoolError.allRelaysFailed),
            .relayUnavailable
        )
        XCTAssertEqual(
            NIP46SessionManager.deliveryFailureReason(for: RelayConnectionError.publishTimedOut),
            .relayUnavailable
        )
        XCTAssertEqual(
            NIP46SessionManager.deliveryFailureReason(for: RelaySocketError.closed),
            .relayUnavailable
        )
        XCTAssertEqual(
            NIP46SessionManager.deliveryFailureReason(for: URLError(.cannotConnectToHost)),
            .relayUnavailable
        )
        XCTAssertEqual(
            NIP46SessionManager.deliveryFailureReason(for: NSError(domain: "test", code: 1)),
            .transportFailure
        )
    }

    func testKeyExecutionFailuresPreserveSafeActionableCategories() {
        let mappings: [(Error, SessionFailureReason)] = [
            (NsecStoreError.authenticationFailed, .keyAuthenticationFailed),
            (NsecStoreError.authenticationCanceled, .keyAuthenticationCanceled),
            (NsecStoreError.protectionUnavailable, .keychainProtectionUnavailable),
            (NsecStoreError.invalidInput, .storedKeyInvalid),
            (NIP46ExecutionError.invalidStoredKey, .storedKeyInvalid),
            (NIP46ExecutionError.noKeyStoredForIdentity, .identityKeyUnavailable),
            (NsecStoreError.unexpectedStatus(errSecInteractionNotAllowed), .keychainInteractionNotAllowed),
            (NsecStoreError.unexpectedStatus(errSecMissingEntitlement), .keychainPermissionMissing),
            (NsecStoreError.unexpectedStatus(-34010), .keychainProtectionUnavailable),
            (NsecStoreError.unexpectedStatus(errSecNotAvailable), .keychainUnavailable),
            (NsecStoreError.unexpectedStatus(errSecDecode), .keychainUnexpectedError),
            (NIP46ExecutionError.signingFailed, .signingFailed)
        ]

        for (error, expected) in mappings {
            XCTAssertEqual(NIP46SessionManager.executionFailureReason(for: error), expected)
        }
    }

    func testHandleApproveRejectsBadIdentity() async {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: MockTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        _ = await manager.onRequestArrived(Self.request(id: "identity"))
        _ = await manager.activateNextPendingIfNeeded()

        let state = await manager.handleApprove(requestID: "identity", identityID: "\n")

        XCTAssertEqual(state, SessionState.completedError(.unauthorizedSigningAttempt))
    }

    func testAuthorizationRequiresExactSigningStateAndBoundIdentity() {
        let guardUnderTest = AuthorizationGuard()
        var machine = NIP46SessionStateMachine()
        _ = machine.transition(on: .onRequestArrived)
        var session = NIP46Session(request: Self.request(id: "auth"), stateMachine: machine, expiresAt: Date().addingTimeInterval(60))
        XCTAssertFalse(guardUnderTest.canExecute(session: session))

        _ = session.stateMachine.transition(on: .onApprove)
        _ = session.stateMachine.transition(on: .onApprove)
        XCTAssertFalse(guardUnderTest.canExecute(session: session))

        session.identityID = "identity-a"
        XCTAssertTrue(guardUnderTest.canExecute(session: session))
    }

    func testSuccessfulSignEventRecordsManualSafeMetadata() async {
        let auditLog = RecordingAuditLog()
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard(),
            auditLog: auditLog
        )
        _ = await manager.onRequestArrived(
            makeTestRequest(
                id: "audit-success",
                appName: "App",
                payload: "{\"kind\":42,\"content\":\"private event content\"}"
            )
        )

        let state = await manager.handleApprove(requestID: "audit-success", identityID: "identity-a")
        let entries = await auditLog.entries()

        XCTAssertEqual(state, .completedSuccess)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.appName, "App")
        XCTAssertEqual(entries.first?.method, "sign_event")
        XCTAssertEqual(entries.first?.outcome, .signed)
        XCTAssertEqual(entries.first?.eventKind, 42)
        XCTAssertEqual(entries.first?.approvalMode, .manual)
        let encodedEntry = try? JSONEncoder().encode(entries.first)
        let encodedText = encodedEntry.flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertFalse(encodedText?.contains("private event content") ?? true)
    }

    func testRememberedApprovalRecordsItsSource() async {
        let auditLog = RecordingAuditLog()
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard(),
            auditLog: auditLog
        )
        _ = await manager.onRequestArrived(Self.request(id: "audit-remembered"))

        _ = await manager.handleApprove(
            requestID: "audit-remembered",
            identityID: "identity-a",
            approvalMode: .remembered
        )

        let entries = await auditLog.entries()
        XCTAssertEqual(entries.first?.approvalMode, .remembered)
    }

    func testRejectedExpiredAndInvalidRequestsAreAudited() async {
        let auditLog = RecordingAuditLog()
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard(),
            auditLog: auditLog
        )
        _ = await manager.onRequestArrived(Self.request(id: "audit-rejected"))
        _ = await manager.handleReject(requestID: "audit-rejected")
        _ = await manager.onRequestArrived(Self.request(id: "audit-expired"))
        _ = await manager.onTimeout(requestID: "audit-expired")
        _ = await manager.onRequestArrived(
            makeTestRequest(
                id: "audit-invalid",
                params: ["not an event"],
                appName: nil,
                appPubkey: "bad"
            )
        )

        let entries = await auditLog.entries()
        XCTAssertEqual(entries.map(\.outcome), [.rejected, .expired, .invalidRequest])
        XCTAssertEqual(entries[0].approvalMode, .manual)
        XCTAssertEqual(entries[1].approvalMode, .notApplicable)
        XCTAssertEqual(entries[2].appName, "Unknown app")
        XCTAssertNil(entries[2].eventKind)
    }

    func testSigningDeliveryAndAuthorizationFailuresAreAudited() async {
        let signingAudit = RecordingAuditLog()
        let signingManager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(shouldThrow: true),
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard(),
            auditLog: signingAudit
        )
        _ = await signingManager.onRequestArrived(Self.request(id: "audit-sign-failure"))
        _ = await signingManager.handleApprove(requestID: "audit-sign-failure", identityID: "identity-a")

        let deliveryAudit = RecordingAuditLog()
        let deliveryManager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(shouldThrow: true),
            authorizationGuard: AuthorizationGuard(),
            auditLog: deliveryAudit
        )
        _ = await deliveryManager.onRequestArrived(Self.request(id: "audit-delivery-failure"))
        _ = await deliveryManager.handleApprove(requestID: "audit-delivery-failure", identityID: "identity-a")

        let unauthorizedAudit = RecordingAuditLog()
        let unauthorizedManager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard(),
            auditLog: unauthorizedAudit
        )
        _ = await unauthorizedManager.onRequestArrived(Self.request(id: "audit-unauthorized"))
        _ = await unauthorizedManager.handleApprove(requestID: "audit-unauthorized", identityID: "\n")

        let signingEntries = await signingAudit.entries()
        let deliveryEntries = await deliveryAudit.entries()
        let unauthorizedEntries = await unauthorizedAudit.entries()
        XCTAssertEqual(signingEntries.map(\.outcome), [.signingFailed])
        XCTAssertEqual(deliveryEntries.map(\.outcome), [.deliveryFailed])
        XCTAssertEqual(unauthorizedEntries.map(\.outcome), [.unauthorized])

        let guardAudit = RecordingAuditLog()
        let guardManager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: DenyingAuthorization(),
            auditLog: guardAudit
        )
        _ = await guardManager.onRequestArrived(Self.request(id: "audit-guard-denied"))
        _ = await guardManager.handleApprove(requestID: "audit-guard-denied", identityID: "identity-a")
        let guardEntries = await guardAudit.entries()
        XCTAssertEqual(guardEntries.map(\.outcome), [.unauthorized])
    }

    func testAuditEntryIsRecordedOnlyOnceAcrossRacingActions() async {
        let auditLog = RecordingAuditLog()
        let executor = SuspendingExecutor()
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: executor,
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard(),
            auditLog: auditLog
        )
        _ = await manager.onRequestArrived(Self.request(id: "audit-race"))

        let approval = Task {
            await manager.handleApprove(requestID: "audit-race", identityID: "identity-a")
        }
        await executor.waitUntilStarted()
        _ = await manager.handleReject(requestID: "audit-race")
        _ = await manager.onTimeout(requestID: "audit-race")
        await executor.release()
        _ = await approval.value

        let entries = await auditLog.entries()
        XCTAssertEqual(entries.map(\.outcome), [.signed])
    }

    func testNonSignMethodsAreNotAuditedAndAuditFailureDoesNotFailSigning() async {
        let auditLog = RecordingAuditLog(shouldThrow: true)
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard(),
            auditLog: auditLog
        )
        _ = await manager.onRequestArrived(
            makeTestRequest(id: "not-signing", method: .ping, params: [])
        )
        _ = await manager.handleApprove(requestID: "not-signing", identityID: "identity-a")
        let attemptsAfterPing = await auditLog.appendAttempts()
        XCTAssertEqual(attemptsAfterPing, 0)

        _ = await manager.onRequestArrived(Self.request(id: "audit-write-fails"))
        let state = await manager.handleApprove(requestID: "audit-write-fails", identityID: "identity-a")

        XCTAssertEqual(state, .completedSuccess)
        let attemptsAfterSigning = await auditLog.appendAttempts()
        XCTAssertEqual(attemptsAfterSigning, 1)
    }

    private static func request(id: String) -> NIP46Request {
        .init(
            id: id,
            method: .signEvent,
            params: ["{\"kind\":1}"],
            appName: "App",
            appURL: nil,
            appPubkey: TestVectors.pubkeyHex,
            correlationID: "corr-\(id)",
            rawPayloadPreview: "{\"kind\":1}"
        )
    }
}

private actor RecordingAuditLog: AuditLogProviding {
    private var recordedEntries: [AuditEntry] = []
    private var attempts = 0
    private let shouldThrow: Bool

    init(shouldThrow: Bool = false) {
        self.shouldThrow = shouldThrow
    }

    func append(_ entry: AuditEntry) async throws {
        attempts += 1
        if shouldThrow { throw StubStorageError() }
        recordedEntries.append(entry)
    }

    func list() async throws -> [AuditEntry] { recordedEntries }

    func clear() async {
        recordedEntries = []
    }

    func entries() -> [AuditEntry] { recordedEntries }
    func appendAttempts() -> Int { attempts }
}

private struct DenyingAuthorization: RequestAuthorization {
    func canExecute(session: NIP46Session) -> Bool { false }
}

private actor SuspendingExecutor: NIP46RequestExecuting {
    private var continuation: CheckedContinuation<Void, Never>?
    private var calls = 0
    private var identityIDs: [String] = []

    func execute(_ request: NIP46Request, identityID: String) async throws -> String {
        calls += 1
        identityIDs.append(identityID)
        await withCheckedContinuation { continuation = $0 }
        return "executed"
    }

    func publicKeyHex(identityID: String) async throws -> String { TestVectors.pubkeyHex }

    func waitUntilStarted() async {
        while calls == 0 { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func callCount() -> Int { calls }
    func identities() -> [String] { identityIDs }
}

private actor PermissionDecisionEngine: PermissionRuleEvaluating {
    private(set) var decisions = 0
    private var shouldApprove = false
    private(set) var savedRequests: [NIP46Request] = []

    init(shouldApprove: Bool = false) {
        self.shouldApprove = shouldApprove
    }

    func shouldAutoApprove(request: NIP46Request) async -> Bool {
        decisions += 1
        return shouldApprove
    }

    func saveRememberRule(for request: NIP46Request) async {
        savedRequests.append(request)
    }

    func decisionCount() -> Int { decisions }
    func savedCount() -> Int { savedRequests.count }
}

private actor MockTransport: NIP46RespondingTransport {
    var sentResponses: [NIP46Response] = []

    func sendResponse(_ response: NIP46Response, to appPubkey: String) async throws {
        sentResponses.append(response)
    }

    func firstErrorMessage() -> String? {
        sentResponses.first?.error?.message
    }
}
