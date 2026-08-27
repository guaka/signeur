import XCTest
@testable import SignstrCore

@MainActor
final class SessionViewModelTests: XCTestCase {
    private func makeViewModel(
        executor: RecordingExecutor = RecordingExecutor(),
        transport: RecordingTransport = RecordingTransport(),
        permissionEvaluator: PermissionRuleEvaluating? = nil,
        identities: [Identity] = [Identity(id: "id-1", displayName: "Main", npub: TestVectors.npub)],
        activeIdentityID: String? = "id-1",
        connectionRegistry: ConnectionRegistering? = nil
    ) async -> (SessionViewModel, NIP46SessionManager) {
        let identityStore = IdentityStore(defaults: makeEphemeralDefaults(), seed: identities)
        if let activeIdentityID {
            await identityStore.setActive(identityID: activeIdentityID)
        }
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: executor,
            transport: transport,
            authorizationGuard: AuthorizationGuard(),
            permissionEvaluator: permissionEvaluator
        )
        return (
            SessionViewModel(
                sessionManager: manager,
                identityStore: identityStore,
                connectionRegistry: connectionRegistry
            ),
            manager
        )
    }

    func testIdleWhenNoRequestIsQueued() async {
        let (viewModel, _) = await makeViewModel()
        await viewModel.refresh()

        XCTAssertNil(viewModel.currentSession)
        XCTAssertEqual(viewModel.sessionState, .idle)
    }

    func testRefreshPresentsQueuedRequestAndActiveIdentity() async {
        let (viewModel, manager) = await makeViewModel()
        _ = await manager.onRequestArrived(makeTestRequest(id: "a"))

        await viewModel.refresh()

        XCTAssertEqual(viewModel.currentSession?.request.id, "a")
        XCTAssertEqual(viewModel.sessionState, .requestReceived)
        XCTAssertEqual(viewModel.selectedIdentityID, "id-1")
    }

    func testRefreshFollowsAKeySwitchMadeElsewhere() async {
        let identityStore = IdentityStore(
            defaults: makeEphemeralDefaults(),
            seed: [Identity(id: "id-1", displayName: "One"), Identity(id: "id-2", displayName: "Two")]
        )
        await identityStore.setActive(identityID: "id-1")
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        let viewModel = SessionViewModel(sessionManager: manager, identityStore: identityStore)
        await viewModel.refresh()

        await identityStore.setActive(identityID: "id-2")
        await viewModel.refresh()

        XCTAssertEqual(viewModel.selectedIdentityID, "id-2")
    }

    func testApproveSignsWithTheActiveIdentity() async {
        let executor = RecordingExecutor()
        let (viewModel, manager) = await makeViewModel(executor: executor)
        _ = await manager.onRequestArrived(makeTestRequest(id: "a"))
        await viewModel.refresh()

        await viewModel.approve()

        let identities = await executor.identities()
        XCTAssertEqual(identities, ["id-1"])
        XCTAssertNil(viewModel.currentSession)
    }

    func testApprovingAConnectionReportsSuccessfulNavigationOutcome() async {
        let (viewModel, manager) = await makeViewModel()
        _ = await manager.onRequestArrived(
            makeTestRequest(id: "connect", method: .connect, params: ["pairing-secret"])
        )
        await viewModel.refresh()

        let approvedConnection = await viewModel.approve()

        XCTAssertTrue(approvedConnection)
        XCTAssertNil(viewModel.currentSession)
    }

    func testRefreshPublishesTheActiveIdentityNameForConsentCopy() async {
        let (viewModel, _) = await makeViewModel()

        await viewModel.refresh()

        XCTAssertEqual(viewModel.selectedIdentityName, "Main")
    }

    func testApproveWithoutAnyKeyAsksTheUserToAddOne() async {
        let executor = RecordingExecutor()
        let (viewModel, manager) = await makeViewModel(executor: executor, identities: [], activeIdentityID: nil)
        _ = await manager.onRequestArrived(makeTestRequest(id: "a"))
        await viewModel.refresh()

        await viewModel.approve()

        let signCount = await executor.signCount()
        XCTAssertEqual(signCount, 0)
        XCTAssertEqual(viewModel.errorMessage, "Select an active key in Keys before approving.")
        XCTAssertEqual(viewModel.currentSession?.request.id, "a", "the request must stay pending")
    }

    func testRejectSendsErrorResponseAndClearsPrompt() async {
        let transport = RecordingTransport()
        let (viewModel, manager) = await makeViewModel(transport: transport)
        _ = await manager.onRequestArrived(makeTestRequest(id: "a"))
        await viewModel.refresh()

        await viewModel.reject()

        let responses = await transport.sentResponses()
        XCTAssertEqual(responses.first?.error?.message, SessionFailureReason.userRejected.rawValue)
        XCTAssertNil(viewModel.currentSession)
        XCTAssertEqual(viewModel.sessionState, .idle)
    }

    func testRememberedRequestIsApprovedWithoutPrompting() async {
        let permissions = PermissionRuleStore(defaults: makeEphemeralDefaults())
        await permissions.saveRememberRule(for: makeTestRequest(id: "seed", payload: "{\"kind\":1}"))
        let executor = RecordingExecutor()
        let (viewModel, manager) = await makeViewModel(executor: executor, permissionEvaluator: permissions)
        _ = await manager.onRequestArrived(makeTestRequest(id: "a", payload: "{\"kind\":1}"))

        await viewModel.refresh()

        let signCount = await executor.signCount()
        XCTAssertEqual(signCount, 1)
        XCTAssertNil(viewModel.currentSession, "a remembered request should not stop on the approval screen")
        XCTAssertEqual(viewModel.sessionState, .idle)
    }

    func testUnrememberedRequestStillWaitsForTheUser() async {
        let permissions = PermissionRuleStore(defaults: makeEphemeralDefaults())
        await permissions.saveRememberRule(for: makeTestRequest(id: "seed", payload: "{\"kind\":1}"))
        let executor = RecordingExecutor()
        let (viewModel, manager) = await makeViewModel(executor: executor, permissionEvaluator: permissions)
        _ = await manager.onRequestArrived(makeTestRequest(id: "a", payload: "{\"kind\":4}"))

        await viewModel.refresh()

        let signCount = await executor.signCount()
        XCTAssertEqual(signCount, 0)
        XCTAssertEqual(viewModel.currentSession?.request.id, "a")
    }

    func testRememberedRequestIsNotAutoApprovedWithoutAKey() async {
        let permissions = PermissionRuleStore(defaults: makeEphemeralDefaults())
        await permissions.saveRememberRule(for: makeTestRequest(id: "seed", payload: "{\"kind\":1}"))
        let executor = RecordingExecutor()
        let (viewModel, manager) = await makeViewModel(
            executor: executor,
            permissionEvaluator: permissions,
            identities: [],
            activeIdentityID: nil
        )
        _ = await manager.onRequestArrived(makeTestRequest(id: "a", payload: "{\"kind\":1}"))

        await viewModel.refresh()

        let signCount = await executor.signCount()
        XCTAssertEqual(signCount, 0)
        XCTAssertEqual(viewModel.currentSession?.request.id, "a")
    }

    func testApproveConnectionActivatesListenerWhenApproved() async {
        let registry = SpyConnectionRegistry()
        let executor = RecordingExecutor()
        let (viewModel, manager) = await makeViewModel(
            executor: executor,
            connectionRegistry: registry
        )
        _ = await manager.onRequestArrived(
            makeTestRequest(id: "connect", method: .connect, params: ["pairing-secret"])
        )
        await viewModel.refresh()

        _ = await viewModel.approve()

        let signCount = await executor.signCount()
        let activated = await registry.activatedApps()
        let forgotten = await registry.forgottenApps()
        let registered = await registry.registeredApps()

        XCTAssertEqual(signCount, 1)
        XCTAssertEqual(activated, [TestVectors.pubkeyHex])
        XCTAssertTrue(forgotten.isEmpty)
        XCTAssertEqual(registered.count, 0)
    }

    func testRejectingAConnectionForgetsTheApp() async {
        let registry = SpyConnectionRegistry()
        let (viewModel, manager) = await makeViewModel(connectionRegistry: registry)
        _ = await manager.onRequestArrived(
            makeTestRequest(id: "connect", method: .connect, params: ["pairing-secret"])
        )
        await viewModel.refresh()

        await viewModel.reject()

        let forgotten = await registry.forgottenApps()
        let activated = await registry.activatedApps()

        XCTAssertEqual(forgotten, [TestVectors.pubkeyHex])
        XCTAssertTrue(activated.isEmpty)
    }

    func testRememberedConnectionIsAutoApprovedAndActivated() async {
        let registry = SpyConnectionRegistry()
        let permissions = PermissionRuleStore(defaults: makeEphemeralDefaults())
        await permissions.saveRememberRule(
            for: makeTestRequest(id: "seed", method: .connect, params: ["pairing-secret"])
        )
        let executor = RecordingExecutor()
        let (viewModel, manager) = await makeViewModel(
            executor: executor,
            permissionEvaluator: permissions,
            connectionRegistry: registry
        )
        _ = await manager.onRequestArrived(
            makeTestRequest(id: "connect-a", method: .connect, params: ["pairing-secret"])
        )
        await viewModel.refresh()

        let signCount = await executor.signCount()
        let activated = await registry.activatedApps()

        XCTAssertEqual(signCount, 1)
        XCTAssertEqual(activated, [TestVectors.pubkeyHex])
        XCTAssertNil(viewModel.currentSession)
        XCTAssertEqual(viewModel.sessionState, .idle)
    }
}

private actor SpyConnectionRegistry: ConnectionRegistering {
    private(set) var activatedApps: [String] = []
    private(set) var forgottenApps: [String] = []
    private(set) var registeredApps: [String] = []

    func register(pairing: DeepLinkRequest, identityID: String) async {
        registeredApps.append(pairing.clientPubkey)
    }

    func activate(appPubkey: String) async {
        activatedApps.append(appPubkey)
    }

    func forget(appPubkey: String) async {
        forgottenApps.append(appPubkey)
    }

    func registeredApps() async -> [String] { registeredApps }
    func activatedApps() async -> [String] { activatedApps }
    func forgottenApps() async -> [String] { forgottenApps }
}
