import XCTest
@testable import SignstrCore

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

private actor MockTransport: NIP46RespondingTransport {
    var sentResponses: [NIP46Response] = []

    func sendResponse(_ response: NIP46Response, to appPubkey: String) async throws {
        sentResponses.append(response)
    }

    func firstErrorMessage() -> String? {
        sentResponses.first?.error?.message
    }
}
