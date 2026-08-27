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

    private static func request(id: String) -> NIP46Request {
        .init(
            id: id,
            method: .signEvent,
            params: ["{\"kind\":1}"],
            appName: "App",
            appURL: nil,
            appPubkey: "pub",
            correlationID: "corr-\(id)",
            rawPayloadPreview: "{\"kind\":1}"
        )
    }
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
