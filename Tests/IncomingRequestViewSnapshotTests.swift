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
                appPubkey: TestVectors.pubkeyHex,
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

    func testConnectionRequestBuildsForFixtureConnection() async {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: SnapshotTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        _ = await manager.onRequestArrived(
            NIP46Request(
                id: "pair",
                method: .connect,
                params: ["pairing-secret"],
                appName: "Nostrudel",
                appURL: "https://nostrudel.ninja",
                appPubkey: TestVectors.otherPubkeyHex,
                requestedPermissions: ["sign_event", "nip44_encrypt"],
                relays: ["wss://relay.one"],
                requestedAt: Date(timeIntervalSince1970: 1_700_000_100),
                correlationID: "pairing-1",
                rawPayloadPreview: "pairing-secret"
            )
        )
        let store = IdentityStore(seed: [Identity(id: "test", displayName: "Test")])
        await store.setActive(identityID: "test")
        let vm = await MainActor.run { SessionViewModel(sessionManager: manager, identityStore: store) }
        await vm.refresh()
        _ = await MainActor.run { IncomingRequestView(viewModel: vm).body }
        let request = await MainActor.run { vm.currentSession?.request }

        XCTAssertEqual(request?.method, .connect)
        XCTAssertEqual(request?.appPubkey, TestVectors.otherPubkeyHex)
    }

    func testConnectionRequestWithoutAdvertisedPermissionsBuildsFallbackMessage() async {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: SnapshotTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        _ = await manager.onRequestArrived(
            NIP46Request(
                id: "pair-empty",
                method: .connect,
                params: [],
                appName: "Wallet",
                appURL: nil,
                appPubkey: TestVectors.otherPubkeyHex,
                requestedPermissions: [],
                relays: [],
                requestedAt: Date(timeIntervalSince1970: 1_700_000_100),
                correlationID: "pairing-empty",
                rawPayloadPreview: ""
            )
        )
        let store = IdentityStore(seed: [Identity(id: "test", displayName: "Test")])
        await store.setActive(identityID: "test")
        let vm = await MainActor.run { SessionViewModel(sessionManager: manager, identityStore: store) }
        await vm.refresh()
        _ = await MainActor.run { IncomingRequestView(viewModel: vm).body }

        let request = await MainActor.run { vm.currentSession?.request }
        XCTAssertEqual(request?.appName, "Wallet")
        XCTAssertEqual(request?.method, .connect)
    }

    func testNip04EncryptionRequestShowsWarningPath() async {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: SnapshotTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        _ = await manager.onRequestArrived(
            NIP46Request(
                id: "nip04",
                method: .nip04Encrypt,
                params: ["payload"],
                appName: "Legacy Client",
                appURL: nil,
                appPubkey: TestVectors.otherPubkeyHex,
                requestedPermissions: [],
                requestedAt: Date(timeIntervalSince1970: 1_700_000_100),
                correlationID: "nip04-1",
                rawPayloadPreview: "payload"
            )
        )
        let store = IdentityStore(seed: [Identity(id: "test", displayName: "Test")])
        await store.setActive(identityID: "test")
        let vm = await MainActor.run { SessionViewModel(sessionManager: manager, identityStore: store) }
        await vm.refresh()
        _ = await MainActor.run { IncomingRequestView(viewModel: vm).body }

        let request = await MainActor.run { vm.currentSession?.request }
        XCTAssertEqual(request?.method, .nip04Encrypt)
        XCTAssertEqual(request?.appPubkey, TestVectors.otherPubkeyHex)
    }

    func testPingRequestBuildsForFixtureAction() async {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: SnapshotTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        _ = await manager.onRequestArrived(
            NIP46Request(
                id: "ping",
                method: .ping,
                params: [],
                appName: "Ping Client",
                appURL: nil,
                appPubkey: TestVectors.otherPubkeyHex,
                requestedPermissions: [],
                requestedAt: Date(timeIntervalSince1970: 1_700_000_100),
                correlationID: "ping-1",
                rawPayloadPreview: ""
            )
        )
        let store = IdentityStore(seed: [Identity(id: "test", displayName: "Test")])
        await store.setActive(identityID: "test")
        let vm = await MainActor.run { SessionViewModel(sessionManager: manager, identityStore: store) }
        await vm.refresh()
        _ = await MainActor.run { IncomingRequestView(viewModel: vm).body }

        let request = await MainActor.run { vm.currentSession?.request }
        XCTAssertEqual(request?.method, .ping)
    }

    func testLocalSignerRequestBuildsForWarningPath() async {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: SnapshotTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        _ = await manager.onRequestArrived(
            NIP46Request(
                id: "local",
                method: .signEvent,
                params: [#"{"kind":1,"content":"fixture"}"#],
                appName: "LocalSigner",
                appURL: nil,
                appPubkey: "nostrsigner:local",
                requestedPermissions: [],
                requestedAt: Date(timeIntervalSince1970: 1_700_000_100),
                correlationID: "local-1",
                rawPayloadPreview: #"{"kind":1,"content":"fixture"}"#,
                origin: .localSigner
            )
        )
        let store = IdentityStore(seed: [Identity(id: "test", displayName: "Test")])
        await store.setActive(identityID: "test")
        let vm = await MainActor.run { SessionViewModel(sessionManager: manager, identityStore: store) }
        await vm.refresh()
        _ = await MainActor.run { IncomingRequestView(viewModel: vm).body }
        let request = await MainActor.run { vm.currentSession?.request }

        XCTAssertEqual(request?.origin, .localSigner)
        XCTAssertEqual(request?.method, .signEvent)
    }
}


private actor SnapshotTransport: NIP46RespondingTransport {
    func sendResponse(_ response: NIP46Response, to appPubkey: String) async throws {}
}
