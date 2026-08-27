import XCTest
import SwiftUI
@testable import SignstrCore

final class IncomingRequestViewSnapshotTests: XCTestCase {
    func testApprovalViewBuildsForFixtureRequest() async {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: SnapshotTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        _ = await manager.onRequestArrived(
            NIP46Request(
                id: "snap",
                method: .signEvent,
                params: ["{\"kind\":1,\"content\":\"fixture\"}"],
                appName: "Fixture Client",
                appURL: nil,
                appPubkey: "pub",
                correlationID: "snap-c1",
                rawPayloadPreview: "{\"kind\":1,\"content\":\"fixture\"}"
            )
        )
        let store = IdentityStore(seed: [Identity(id: "test", displayName: "Test")])
        await store.setActive(identityID: "test")
        let vm = await MainActor.run { SessionViewModel(sessionManager: manager, identityStore: store) }
        await vm.refresh()
        _ = await MainActor.run { IncomingRequestView(viewModel: vm).body }
        let name = await MainActor.run { vm.currentSession?.request.appName }
        XCTAssertEqual(name, "Fixture Client")
    }
}


private actor SnapshotTransport: NIP46RespondingTransport {
    func sendResponse(_ response: NIP46Response, to appPubkey: String) async throws {}
}
