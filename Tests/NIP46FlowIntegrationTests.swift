import XCTest
@testable import SignstrCore

final class NIP46FlowIntegrationTests: XCTestCase {
    func testApproveExecutesTheRequestAndSendsTheResult() async {
        let executor = RecordingExecutor()
        let transport = CountingTransport()
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: executor,
            transport: transport,
            authorizationGuard: AuthorizationGuard()
        )

        _ = await manager.onRequestArrived(
            NIP46Request(
                id: "i1",
                method: .signEvent,
                params: ["{\"kind\":1,\"content\":\"hello\"}"],
                appName: "Client",
                appURL: nil,
                appPubkey: TestVectors.pubkeyHex,
                correlationID: "c1",
                rawPayloadPreview: "{\"kind\":1,\"content\":\"hello\"}"
            )
        )
        _ = await manager.activateNextPendingIfNeeded()
        let state = await manager.handleApprove(requestID: "i1", identityID: "default")
        let executionCount = await executor.signCount()
        let transportCount = await transport.currentCount()

        XCTAssertEqual(state, .completedSuccess)
        XCTAssertEqual(executionCount, 1)
        XCTAssertEqual(transportCount, 1)
    }
}

private actor CountingTransport: NIP46RespondingTransport {
    var count = 0
    func sendResponse(_ response: NIP46Response, to appPubkey: String) async throws {
        count += 1
    }

    func currentCount() -> Int { count }
}
