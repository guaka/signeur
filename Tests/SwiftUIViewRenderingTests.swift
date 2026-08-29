import AppKit
import SwiftUI
import XCTest
@testable import SigneurCore

@MainActor
final class SwiftUIViewRenderingTests: XCTestCase {
    func testConnectedAppsViewsRenderTheirCompleteHierarchy() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let requested = ConnectedAppItem(
            appName: "Nostrudel",
            appPubkey: TestVectors.otherPubkeyHex,
            methods: ["sign_event", "logout"],
            requestedPermissions: ["sign_event:1", "nip44_encrypt"],
            appURL: "https://nostrudel.example",
            relays: ["wss://relay.one", "wss://relay.two"],
            identityName: "Main",
            createdAt: now,
            lastUsedAt: now,
            usesLegacyEncryption: true
        )
        let remembered = ConnectedAppItem(
            appName: "No metadata",
            appPubkey: TestVectors.pubkeyHex,
            methods: ["asks you every time"],
            requestedPermissions: [],
            relays: [],
            usesLegacyEncryption: false
        )
        let provider = RenderingConnectedAppsProvider(items: [requested, remembered])
        let viewModel = ConnectedAppsViewModel(provider: provider)
        await viewModel.refresh()

        render(ConnectedAppsView(viewModel: viewModel))
        render(ConnectedAppRow(app: requested))
        render(ConnectedAppRow(app: remembered))
        render(ConnectedAppDetailView(app: requested) {})
        render(ConnectedAppDetailView(app: remembered) {})

        XCTAssertEqual(requested.id, TestVectors.otherPubkeyHex)
    }

    func testAppIconRendersLoadedAndFallbackPhases() {
        let icon = AppIconView(appName: "Nostrudel", appURL: "https://nostrudel.example")
        render(icon.content(for: .success(Image(systemName: "app.fill"))))
        render(icon.content(for: .empty))
    }

    func testConnectedAppDetailActionsRequestAndCompleteDisconnect() async {
        let disconnected = expectation(description: "disconnect completed")
        let app = ConnectedAppItem(
            appName: "Nostrudel",
            appPubkey: TestVectors.otherPubkeyHex,
            methods: ["sign_event"]
        )
        let view = ConnectedAppDetailView(app: app) {
            disconnected.fulfill()
        }

        view.requestDisconnect()
        view.confirmDisconnect()

        await fulfillment(of: [disconnected], timeout: 1)
    }

    func testIncomingRequestViewsRenderIdleConnectionAndSigningRequests() async {
        let (viewModel, manager) = await makeSessionViewModel()
        var actionCount = 0
        let idleView = IncomingRequestView(
            viewModel: viewModel,
            connectActions: [
                .init(title: "Scan QR", systemImage: "qrcode") { actionCount += 1 },
                .init(title: "Paste Link", systemImage: "doc.on.clipboard") { actionCount += 1 }
            ]
        )
        render(idleView)
        _ = idleView.idleContent
        XCTAssertEqual(actionCount, 0)

        let connection = renderingRequest(
            id: "connect-render",
            method: .connect,
            params: ["pairing-secret"],
            appName: "Nostrudel",
            appURL: "https://nostrudel.example",
            requestedPermissions: ["sign_event:1", "nip44_encrypt"],
            relays: ["wss://relay.one", "wss://relay.two"],
            rawPayloadPreview: "pairing-secret"
        )
        _ = await manager.onRequestArrived(connection)
        await viewModel.refresh()
        render(IncomingRequestView(viewModel: viewModel))

        _ = await viewModel.reject()
        let localRequest = renderingRequest(
            id: "local-render",
            method: .nip04Decrypt,
            params: [TestVectors.otherPubkeyHex, "ciphertext"],
            appName: nil,
            appURL: nil,
            requestedPermissions: [],
            relays: [],
            rawPayloadPreview: "",
            origin: .localSigner,
            appPubkey: "nostrsigner:local"
        )
        _ = await manager.onRequestArrived(localRequest)
        await viewModel.refresh()
        render(IncomingRequestView(viewModel: viewModel))
    }

    func testIncomingRequestActionsApproveConnectionsAndRejectRequests() async {
        let (viewModel, manager) = await makeSessionViewModel()
        let approved = expectation(description: "connection approval callback")
        _ = await manager.onRequestArrived(renderingRequest(
            id: "connect-action",
            method: .connect,
            params: ["pairing-secret"],
            appName: "Nostrudel",
            appURL: nil,
            requestedPermissions: [],
            relays: [],
            rawPayloadPreview: "pairing-secret"
        ))
        await viewModel.refresh()

        IncomingRequestView(viewModel: viewModel, onConnectionApproved: {
            approved.fulfill()
        }).approveRequest()
        await fulfillment(of: [approved], timeout: 1)

        _ = await manager.onRequestArrived(renderingRequest(
            id: "reject-action",
            method: .ping,
            params: [],
            appName: nil,
            appURL: nil,
            requestedPermissions: [],
            relays: [],
            rawPayloadPreview: ""
        ))
        await viewModel.refresh()
        IncomingRequestView(viewModel: viewModel).rejectRequest()

        for _ in 0..<20 where viewModel.currentSession != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(viewModel.currentSession)
    }

    func testIncomingRequestRendersSigningProgress() async {
        let executor = RenderingSuspendingExecutor()
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: executor,
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        let identities = IdentityStore(
            defaults: makeEphemeralDefaults(),
            seed: [Identity(id: "render-signing", displayName: "Main", npub: TestVectors.npub)]
        )
        await identities.setActive(identityID: "render-signing")
        let viewModel = SessionViewModel(sessionManager: manager, identityStore: identities)
        _ = await manager.onRequestArrived(makeTestRequest(id: "render-signing"))
        await viewModel.refresh()

        let approval = Task { await viewModel.approve() }
        await executor.waitUntilStarted()
        await viewModel.refresh()
        XCTAssertEqual(viewModel.sessionState, .signing)
        render(IncomingRequestView(viewModel: viewModel))

        await executor.resume()
        _ = await approval.value
    }

    private func makeSessionViewModel() async -> (SessionViewModel, NIP46SessionManager) {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        let identities = IdentityStore(
            defaults: makeEphemeralDefaults(),
            seed: [Identity(id: "render-id", displayName: "Main", npub: TestVectors.npub)]
        )
        await identities.setActive(identityID: "render-id")
        return (SessionViewModel(sessionManager: manager, identityStore: identities), manager)
    }

    private func renderingRequest(
        id: String,
        method: NIP46Method,
        params: [String],
        appName: String?,
        appURL: String?,
        requestedPermissions: [String],
        relays: [String],
        rawPayloadPreview: String,
        origin: NIP46RequestOrigin = .relay,
        appPubkey: String = TestVectors.otherPubkeyHex
    ) -> NIP46Request {
        NIP46Request(
            id: id,
            method: method,
            params: params,
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

    private func render<Content: View>(_ view: Content) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 900)
        host.layoutSubtreeIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("Expected the SwiftUI hierarchy to produce a bitmap")
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
    }
}

private actor RenderingConnectedAppsProvider: ConnectedAppsProviding {
    private var items: [ConnectedAppItem]

    init(items: [ConnectedAppItem]) {
        self.items = items
    }

    func listConnectedApps() async -> [ConnectedAppItem] { items }

    func revoke(appPubkey: String) async {
        items.removeAll { $0.appPubkey == appPubkey }
    }
}

private actor RenderingSuspendingExecutor: NIP46RequestExecuting {
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func execute(_ request: NIP46Request, identityID: String) async throws -> String {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return RecordingExecutor.stubResult
    }

    func publicKeyHex(identityID: String) async throws -> String { TestVectors.pubkeyHex }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
