import SwiftUI
import XCTest
@testable import SignstrCore

@MainActor
final class IncomingRequestViewTests: XCTestCase {
    private func makeViewModel() async -> (SessionViewModel, NIP46SessionManager) {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        let identities = IdentityStore(
            defaults: makeEphemeralDefaults(),
            seed: [Identity(id: "id-1", displayName: "Main", npub: TestVectors.npub)]
        )
        await identities.setActive(identityID: "id-1")
        return (
            SessionViewModel(sessionManager: manager, identityStore: identities),
            manager
        )
    }

    private func sampleRequest(
        id: String,
        method: NIP46Method = .signEvent,
        params: [String]? = nil,
        appName: String? = "Fixture Client",
        appURL: String? = "https://signstr.app",
        appPubkey: String = TestVectors.otherPubkeyHex,
        requestedPermissions: [String] = [],
        relays: [String] = [],
        rawPayloadPreview: String = "fixture payload",
        origin: NIP46RequestOrigin = .relay
    ) -> NIP46Request {
        let payload: [String]
        switch params {
        case .some(let provided):
            payload = provided
        case .none:
            switch method {
            case .connect:
                payload = ["pairing-secret"]
            case .getPublicKey, .ping, .switchRelays, .logout:
                payload = []
            case .signEvent:
                payload = ["{\"kind\":1,\"content\":\"from view\"}"]
            case .nip04Encrypt, .nip04Decrypt, .nip44Encrypt, .nip44Decrypt:
                payload = [TestVectors.otherPubkeyHex, "payload"]
            }
        }
        return NIP46Request(
            id: id,
            method: method,
            params: payload,
            appName: appName,
            appURL: appURL,
            appPubkey: appPubkey,
            requestedPermissions: requestedPermissions,
            relays: relays,
            requestedAt: Date(timeIntervalSince1970: 1_700_000_100),
            correlationID: "corr-\(id)",
            rawPayloadPreview: rawPayloadPreview,
            origin: origin
        )
    }

    func testPermissionHelpersCoverKnownUnknownMappings() async {
        let (viewModel, _) = await makeViewModel()
        let view = await MainActor.run {
            IncomingRequestView(viewModel: viewModel)
        }

        XCTAssertEqual(view.permissionLabel("connect"), "Connect to this signer")
        XCTAssertEqual(view.permissionLabel("sign_event:7"), "Sign Nostr events (7)")
        XCTAssertEqual(view.permissionLabel("nip04_decrypt"), "Decrypt NIP-04 messages")
        XCTAssertEqual(view.permissionLabel("nip44_encrypt"), "Encrypt NIP-44 messages")
        XCTAssertEqual(view.permissionLabel("logout"), "Disconnect the signer")
        XCTAssertEqual(view.permissionLabel("mystery"), "Mystery")

        XCTAssertEqual(view.permissionIcon("sign_event"), "signature")
        XCTAssertEqual(view.permissionIcon("nip04_encrypt"), "lock.fill")
        XCTAssertEqual(view.permissionIcon("nip04_decrypt"), "lock.open.fill")
        XCTAssertEqual(view.permissionIcon("nip44_encrypt"), "lock.fill")
        XCTAssertEqual(view.permissionIcon("nip44_decrypt"), "lock.open.fill")
        XCTAssertEqual(view.permissionIcon("connect"), "checkmark.circle")
        XCTAssertEqual(view.permissionIcon("mystery"), "checkmark.circle")
    }

    func testIdleViewCanBuildWithActionsAndErrorMessage() async {
        let (viewModel, manager) = await makeViewModel()
        _ = await manager.onRequestArrived(
            sampleRequest(id: "approve-error", method: .connect)
        )
        await viewModel.refresh()
        await MainActor.run { viewModel.selectedIdentityID = nil }
        _ = await viewModel.approve()
        await viewModel.refresh()

        let actions = [
            IncomingRequestView.ConnectAction(title: "Scan QR", systemImage: "qrcode") {},
            IncomingRequestView.ConnectAction(title: "Paste Link", systemImage: "doc.on.clipboard") {}
        ]
        let view = IncomingRequestView(
            viewModel: viewModel,
            connectActions: actions
        )

        await MainActor.run {
            _ = view.idleContent
            _ = view.idleTextAlignment
            _ = view.idleHorizontalAlignment
            _ = view.idleFrameAlignment
            _ = view.body
        }
    }

    func testApprovalContentBuildsConnectionAndRequestSummaries() async {
        let (viewModel, manager) = await makeViewModel()
        _ = await manager.onRequestArrived(
            sampleRequest(
                id: "connect",
                method: .connect,
                appName: "Nocti",
                appURL: "https://app.example",
                requestedPermissions: ["sign_event", "nip44_encrypt"],
                relays: ["wss://relay.one", "wss://relay.two"],
                rawPayloadPreview: "requested permissions: sign_event, nip44_encrypt"
            )
        )
        _ = await manager.onRequestArrived(
            sampleRequest(
                id: "event",
                method: .signEvent,
                params: [#"{"kind":1,"content":"fixture"}"#],
                appName: "Legacy",
                appURL: nil,
                requestedPermissions: [],
                relays: ["wss://relay.three"],
                rawPayloadPreview: "signed payload"
            )
        )
        _ = await manager.onRequestArrived(
            sampleRequest(
                id: "nip04",
                method: .nip04Encrypt,
                params: [TestVectors.otherPubkeyHex, "payload"],
                appName: nil,
                appURL: nil,
                requestedPermissions: [],
                relays: [],
                rawPayloadPreview: "legacy payload"
            )
        )
        _ = await manager.onRequestArrived(
            sampleRequest(
                id: "local-signer",
                method: .signEvent,
                appName: "Local",
                appURL: "http://local.bad", // invalid scheme ignored by rendering path
                requestedPermissions: [],
                relays: [],
                rawPayloadPreview: "",
                origin: .localSigner
            )
        )

        await viewModel.refresh()
        let requestSession = await MainActor.run { viewModel.currentSession }
        let sessions = await manager.pendingSessions()
        guard
            let requestSession,
            let request = sessions.first(where: { $0.request.method == .connect }),
            let nonConnection = sessions.first(where: { $0.request.method != .connect })
        else {
            return XCTFail("expected a non-connection request in queue")
        }

        let view = IncomingRequestView(viewModel: viewModel)
        await MainActor.run {
            _ = view.requestHeader(requestSession.request, isConnection: true)
            _ = view.requestHeader(requestSession.request, isConnection: false)
            _ = view.connectionSummary(request.request)
            _ = view.requestSummary(nonConnection.request)
            _ = view.approvalContent(for: requestSession)
            _ = view.approvalContent(for: nonConnection)
            _ = view.detailRow("Requested", value: requestSession.request.appPubkey, monospaced: true)
            _ = view.permissionLabel("nip04_encrypt")
            _ = view.permissionIcon("nip04_encrypt")
        }
    }

    func testApprovalContentCoversRequestBranchesWithoutMetadataAndPayload() async {
        let (viewModel, manager) = await makeViewModel()
        _ = await manager.onRequestArrived(
            sampleRequest(
                id: "connect-empty",
                method: .connect,
                appName: "No metadata",
                appURL: nil,
                requestedPermissions: [],
                relays: [],
                rawPayloadPreview: ""
            )
        )
        _ = await manager.onRequestArrived(
            sampleRequest(
                id: "local-only",
                method: .signEvent,
                appName: nil,
                appURL: nil,
                appPubkey: "nostrsigner:local",
                requestedPermissions: [],
                relays: [],
                rawPayloadPreview: "",
                origin: .localSigner
            )
        )

        await viewModel.refresh()
        let sessions = await manager.pendingSessions()
        guard
            let connectSession = sessions.first(where: { $0.request.method == .connect }),
            let localSession = sessions.first(where: { $0.request.origin == .localSigner })
        else {
            return XCTFail("expected both connection and local-signer requests in queue")
        }

        let view = IncomingRequestView(viewModel: viewModel)
        await MainActor.run {
            _ = view.approvalContent(for: localSession)
            _ = view.connectionSummary(connectSession.request)
            _ = view.requestHeader(localSession.request, isConnection: false)
            _ = view.permissionLabel("sign_event:3")
            _ = view.permissionIcon("sign_event")
        }
    }
}
