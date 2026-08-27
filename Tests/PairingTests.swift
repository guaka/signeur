import XCTest
@testable import SignstrCore

final class PairingRequestFactoryTests: XCTestCase {
    private let pairing = DeepLinkRequest(
        clientPubkey: TestVectors.otherPubkeyHex,
        relays: ["wss://relay.one", "wss://relay.two"],
        secret: "s3cret",
        requestedPerms: ["sign_event", "nip44_encrypt"],
        appName: "Nostrudel",
        appURL: "https://nostrudel.ninja"
    )

    func testBuildsConnectRequestFromPairing() {
        let request = PairingRequestFactory().makeConnectRequest(from: pairing, id: "fixed-id")

        XCTAssertEqual(request.id, "fixed-id")
        XCTAssertEqual(request.method, .connect)
        XCTAssertEqual(request.appPubkey, TestVectors.otherPubkeyHex)
        XCTAssertEqual(request.appName, "Nostrudel")
        XCTAssertEqual(request.appURL, "https://nostrudel.ninja")
        XCTAssertEqual(request.params, ["s3cret"])
        XCTAssertEqual(request.requestedPermissions, ["sign_event", "nip44_encrypt"])
        XCTAssertEqual(request.relays, ["wss://relay.one", "wss://relay.two"])
    }

    func testSamePairingAlwaysGetsTheSameRequestID() {
        let factory = PairingRequestFactory()
        let first = factory.makeConnectRequest(from: pairing)
        let second = factory.makeConnectRequest(from: pairing)

        XCTAssertEqual(first.id, second.id)
        XCTAssertFalse(first.id.contains(pairing.secret), "the request ID is sent back to the app")
    }

    func testDifferentPairingsGetDifferentRequestIDs() {
        let factory = PairingRequestFactory()
        let otherSecret = DeepLinkRequest(
            clientPubkey: pairing.clientPubkey,
            relays: pairing.relays,
            secret: "another-secret",
            requestedPerms: [],
            appName: nil,
            appURL: nil
        )
        let otherApp = DeepLinkRequest(
            clientPubkey: TestVectors.pubkeyHex,
            relays: pairing.relays,
            secret: pairing.secret,
            requestedPerms: [],
            appName: nil,
            appURL: nil
        )

        let ids = Set([pairing, otherSecret, otherApp].map { factory.makeConnectRequest(from: $0).id })
        XCTAssertEqual(ids.count, 3)
    }

    func testPreviewDescribesWhatTheUserIsAgreeingTo() {
        let preview = PairingRequestFactory().makeConnectRequest(from: pairing).rawPayloadPreview

        XCTAssertTrue(preview.contains("Nostrudel"))
        XCTAssertTrue(preview.contains(TestVectors.otherPubkeyHex))
        XCTAssertTrue(preview.contains("wss://relay.one, wss://relay.two"))
        XCTAssertTrue(preview.contains("sign_event, nip44_encrypt"))
        XCTAssertFalse(preview.contains("s3cret"), "the pairing secret must not be rendered on screen")
    }

    func testPreviewHandlesMissingMetadata() {
        let sparse = DeepLinkRequest(
            clientPubkey: TestVectors.otherPubkeyHex,
            relays: ["wss://relay.one"],
            secret: "s3cret",
            requestedPerms: [],
            appName: nil,
            appURL: nil
        )
        let preview = PairingRequestFactory().makeConnectRequest(from: sparse).rawPayloadPreview

        XCTAssertTrue(preview.contains("Unknown app"))
        XCTAssertTrue(preview.contains("none requested"))
    }

    func testGeneratedRequestPassesValidation() {
        let request = PairingRequestFactory().makeConnectRequest(from: pairing)
        if case let .failure(error) = NIP46Validator().validate(request) {
            XCTFail("pairing request should validate, got \(error)")
        }
    }
}

final class RequestRoutingCoordinatorTests: XCTestCase {
    private func makeCoordinator() -> (RequestRoutingCoordinator, NIP46SessionManager) {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        return (RequestRoutingCoordinator(sessionManager: manager), manager)
    }

    func testScannedPayloadBecomesAPendingRequest() async throws {
        let (coordinator, manager) = makeCoordinator()

        let state = try await coordinator.routeScannedPayload(
            "nostrconnect://\(TestVectors.otherPubkeyHex)?relay=wss://relay.one&secret=s3cret&name=Amethyst"
        )

        let pending = await manager.pendingSessions()
        XCTAssertEqual(state, .requestReceived)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.request.method, .connect)
        XCTAssertEqual(pending.first?.request.appName, "Amethyst")
    }

    func testDeepLinkAndQRCodeTakeTheSamePath() async throws {
        let link = "nostrconnect://\(TestVectors.otherPubkeyHex)?relay=wss://relay.one&secret=s3cret"
        let (fromQR, qrManager) = makeCoordinator()
        let (fromLink, linkManager) = makeCoordinator()

        _ = try await fromQR.routeScannedPayload(link)
        _ = try await fromLink.routeDeepLink(try XCTUnwrap(URL(string: link)))

        let qrRequest = await qrManager.pendingSessions().first?.request
        let linkRequest = await linkManager.pendingSessions().first?.request
        XCTAssertEqual(qrRequest?.appPubkey, linkRequest?.appPubkey)
        XCTAssertEqual(qrRequest?.params, linkRequest?.params)
        XCTAssertEqual(qrRequest?.rawPayloadPreview, linkRequest?.rawPayloadPreview)
    }

    func testUnrelatedQRCodeIsRejectedWithoutQueueingAnything() async {
        let (coordinator, manager) = makeCoordinator()

        do {
            _ = try await coordinator.routeScannedPayload("https://example.com/hello")
            XCTFail("a non-pairing code must not be routed")
        } catch {
            XCTAssertEqual(error as? DeepLinkParseError, .invalidScheme)
        }
        let pending = await manager.pendingSessions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testRescanningTheSameCodeDoesNotQueueTwice() async throws {
        let (coordinator, manager) = makeCoordinator()
        let link = "nostrconnect://\(TestVectors.otherPubkeyHex)?relay=wss://relay.one&secret=s3cret"

        _ = try await coordinator.routeScannedPayload(link)
        _ = try await coordinator.routeScannedPayload(link)

        let pending = await manager.pendingSessions()
        XCTAssertEqual(pending.count, 1, "a code held in front of the camera must produce one prompt")
    }
}

@MainActor
final class PairingViewModelTests: XCTestCase {
    private func makeViewModel() -> (PairingViewModel, NIP46SessionManager) {
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        return (PairingViewModel(coordinator: RequestRoutingCoordinator(sessionManager: manager)), manager)
    }

    func testSuccessfulScanReportsTheAppName() async {
        let (viewModel, manager) = makeViewModel()

        let paired = await viewModel.handleScannedPayload(
            "nostrconnect://\(TestVectors.otherPubkeyHex)?relay=wss://relay.one&secret=s3cret&name=Amethyst"
        )

        let pending = await manager.pendingSessions()
        XCTAssertTrue(paired)
        XCTAssertEqual(viewModel.pairedAppName, "Amethyst")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(pending.count, 1)
    }

    func testAnonymousAppStillPairs() async {
        let (viewModel, _) = makeViewModel()

        let paired = await viewModel.handleScannedPayload("nostrconnect://\(TestVectors.otherPubkeyHex)?relay=wss://relay.one&secret=s3cret")

        XCTAssertTrue(paired)
        XCTAssertEqual(viewModel.pairedAppName, "the app")
    }

    func testWrongKindOfQRCodeExplainsItself() async {
        let (viewModel, _) = makeViewModel()

        let paired = await viewModel.handleScannedPayload("https://example.com")

        XCTAssertFalse(paired)
        XCTAssertTrue(viewModel.errorMessage?.contains("not a Nostr Connect link") == true)
        XCTAssertNil(viewModel.pairedAppName)
    }

    func testIncompleteCodesNameTheMissingPiece() async {
        let (viewModel, _) = makeViewModel()

        _ = await viewModel.handleScannedPayload("nostrconnect://\(TestVectors.otherPubkeyHex)?secret=s3cret")
        XCTAssertEqual(viewModel.errorMessage, "This link does not name a relay to answer on.")

        _ = await viewModel.handleScannedPayload("nostrconnect://\(TestVectors.otherPubkeyHex)?relay=wss://relay.one")
        XCTAssertEqual(viewModel.errorMessage, "This link is missing its pairing secret.")

        _ = await viewModel.handleScannedPayload("nostrconnect://?relay=wss://relay.one&secret=s3cret")
        XCTAssertEqual(viewModel.errorMessage, "This link is missing the app's public key.")
    }

    func testDeepLinkPairsThroughTheSameViewModel() async {
        let (viewModel, manager) = makeViewModel()
        let url = URL(string: "nostrconnect://\(TestVectors.otherPubkeyHex)?relay=wss://relay.one&secret=s3cret&name=Nostrudel")!

        let paired = await viewModel.handleDeepLink(url)

        let pending = await manager.pendingSessions()
        XCTAssertTrue(paired)
        XCTAssertEqual(viewModel.pairedAppName, "Nostrudel")
        XCTAssertEqual(pending.count, 1)
    }

    func testPastedLinkPairs() async {
        let (viewModel, manager) = makeViewModel()

        let paired = await viewModel.handlePastedText(
            " nostrconnect://\(TestVectors.otherPubkeyHex)?relay=wss://relay.one&secret=s3cret&name=Amethyst\n"
        )

        let pending = await manager.pendingSessions()
        XCTAssertTrue(paired)
        XCTAssertEqual(viewModel.pairedAppName, "Amethyst")
        XCTAssertEqual(pending.count, 1)
    }

    func testEmptyClipboardIsExplained() async {
        let (viewModel, _) = makeViewModel()

        let pairedFromNil = await viewModel.handlePastedText(nil)
        XCTAssertFalse(pairedFromNil)
        XCTAssertEqual(viewModel.errorMessage, "Nothing to paste. Copy the connection link from the app first.")

        let pairedFromBlank = await viewModel.handlePastedText("   \n ")
        XCTAssertFalse(pairedFromBlank)
        XCTAssertEqual(viewModel.errorMessage, "Nothing to paste. Copy the connection link from the app first.")
    }

    func testPastedTextThatIsNotALinkIsExplained() async {
        let (viewModel, manager) = makeViewModel()

        let paired = await viewModel.handlePastedText("hey, here's my npub instead")

        let pending = await manager.pendingSessions()
        XCTAssertFalse(paired)
        XCTAssertTrue(viewModel.errorMessage?.contains("nostrconnect://") == true)
        XCTAssertTrue(pending.isEmpty)
    }

    func testFailedPairingClearsAnyEarlierSuccess() async {
        let (viewModel, _) = makeViewModel()
        _ = await viewModel.handlePastedText("nostrconnect://\(TestVectors.otherPubkeyHex)?relay=wss://relay.one&secret=s3cret&name=Amethyst")
        XCTAssertNotNil(viewModel.pairedAppName)

        _ = await viewModel.handlePastedText("not a link")

        XCTAssertNil(viewModel.pairedAppName, "a stale success must not trigger a connected alert")
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testPairingOpenedByAnotherAppThroughOurScheme() async {
        let (viewModel, manager) = makeViewModel()
        let wrapped = "nostrconnect://\(TestVectors.otherPubkeyHex)?relay=wss://relay.one&secret=s3cret&name=Damus"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let url = URL(string: "signstr://pair?uri=\(wrapped)")!

        let paired = await viewModel.handleDeepLink(url)

        let pending = await manager.pendingSessions()
        XCTAssertTrue(paired)
        XCTAssertEqual(viewModel.pairedAppName, "Damus")
        XCTAssertEqual(pending.count, 1)
    }

    func testResetClearsPreviousOutcome() async {
        let (viewModel, _) = makeViewModel()
        _ = await viewModel.handleScannedPayload("https://example.com")

        viewModel.reset()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(viewModel.pairedAppName)
    }

    func testErrorIsClearedByALaterSuccessfulScan() async {
        let (viewModel, _) = makeViewModel()
        _ = await viewModel.handleScannedPayload("https://example.com")

        _ = await viewModel.handleScannedPayload("nostrconnect://\(TestVectors.otherPubkeyHex)?relay=wss://relay.one&secret=s3cret")

        XCTAssertNil(viewModel.errorMessage)
    }
}
