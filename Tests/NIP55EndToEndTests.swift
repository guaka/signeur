import P256K
import XCTest
@testable import SigneurCore

/// Plays the part of another app on the phone: opens Signeur with a `nostrsigner:` URL,
/// then reads the result off the callback URL Signeur opens in return.
final class NIP55EndToEndTests: XCTestCase {
    private struct Harness {
        let manager: NIP46SessionManager
        let coordinator: RequestRoutingCoordinator
        let opened: Collector<URL>
        let clipboard: Clipboard
    }

    private func makeHarness() -> Harness {
        let opened = Collector<URL>()
        let clipboard = Clipboard()
        let callbackTransport = NIP55CallbackTransport(
            openURL: { url in await opened.append(url); return true },
            copyToClipboard: { value in clipboard.store(value) }
        )
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: NIP46MethodExecutor(
                nsecStore: InMemoryNsecStore(keys: ["id-1": TestVectors.nsec]),
                now: { Date(timeIntervalSince1970: 1_700_000_000) }
            ),
            transport: RoutingTransport(
                callbackTransport: callbackTransport,
                relayTransport: RecordingTransport()
            ),
            authorizationGuard: AuthorizationGuard()
        )
        return Harness(
            manager: manager,
            coordinator: RequestRoutingCoordinator(sessionManager: manager, callbackTransport: callbackTransport),
            opened: opened,
            clipboard: clipboard
        )
    }

    private func signerURL(payload: String, query: String) throws -> URL {
        let encoded = payload.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? payload
        return try XCTUnwrap(URL(string: "nostrsigner:\(encoded)?\(query)"))
    }

    func testAnotherAppGetsBackASignedEventItCanVerify() async throws {
        let harness = makeHarness()
        let url = try signerURL(
            payload: #"{"kind":1,"content":"gm from Damus","created_at":1700000000}"#,
            query: "type=sign_event&appName=Damus&callbackUrl=damus://signed?event=&returnType=event"
        )

        _ = try await harness.coordinator.routeSignerURL(url)
        let activated = await harness.manager.activateNextPendingIfNeeded()
        let session = try XCTUnwrap(activated)
        XCTAssertEqual(session.request.method, .signEvent)
        XCTAssertEqual(session.request.appName, "Damus")

        let state = await harness.manager.handleApprove(requestID: session.request.id, identityID: "id-1")
        XCTAssertEqual(state, .completedSuccess)

        let urls = await harness.opened.items()
        let callback = try XCTUnwrap(urls.first)
        let returned = try XCTUnwrap(
            String(callback.absoluteString.dropFirst("damus://signed?event=".count)).removingPercentEncoding
        )
        let event = try JSONDecoder().decode(NostrEvent.self, from: Data(returned.utf8))
        XCTAssertEqual(event.content, "gm from Damus")
        XCTAssertEqual(event.pubkey, TestVectors.pubkeyHex)
        XCTAssertTrue(try verify(event))
    }

    func testAnAppAskingOnlyForTheSignatureGetsJustThat() async throws {
        let harness = makeHarness()
        let url = try signerURL(
            payload: #"{"kind":1,"content":"gm","created_at":1700000000}"#,
            query: "type=sign_event&callbackUrl=damus://signed?sig=&returnType=signature"
        )

        _ = try await harness.coordinator.routeSignerURL(url)
        let activated = await harness.manager.activateNextPendingIfNeeded()
        let session = try XCTUnwrap(activated)
        _ = await harness.manager.handleApprove(requestID: session.request.id, identityID: "id-1")

        let urls = await harness.opened.items()
        let signature = try XCTUnwrap(urls.first?.absoluteString.dropFirst("damus://signed?sig=".count))
        XCTAssertEqual(signature.count, 128, "a BIP-340 signature in hex")
    }

    func testAPublicKeyRequestIsAnsweredWithTheActiveIdentity() async throws {
        let harness = makeHarness()
        let url = try XCTUnwrap(URL(string: "nostrsigner:?type=get_public_key&callbackUrl=damus://pubkey?k="))

        _ = try await harness.coordinator.routeSignerURL(url)
        let activated = await harness.manager.activateNextPendingIfNeeded()
        let session = try XCTUnwrap(activated)
        _ = await harness.manager.handleApprove(requestID: session.request.id, identityID: "id-1")

        let urls = await harness.opened.items()
        XCTAssertEqual(urls.first?.absoluteString, "damus://pubkey?k=\(TestVectors.pubkeyHex)")
    }

    func testRefusingASignerRequestReturnsNothingToTheApp() async throws {
        let harness = makeHarness()
        let url = try signerURL(
            payload: #"{"kind":1,"content":"no"}"#,
            query: "type=sign_event&callbackUrl=damus://signed?event="
        )

        _ = try await harness.coordinator.routeSignerURL(url)
        let activated = await harness.manager.activateNextPendingIfNeeded()
        let session = try XCTUnwrap(activated)
        _ = await harness.manager.handleReject(requestID: session.request.id)

        let urls = await harness.opened.items()
        XCTAssertTrue(urls.isEmpty, "the app learns nothing beyond not getting a signature")
    }

    func testARequestWithNoCallbackLeavesTheResultOnTheClipboard() async throws {
        let harness = makeHarness()
        let url = try signerURL(
            payload: #"{"kind":1,"content":"clipboard","created_at":1700000000}"#,
            query: "type=sign_event&appName=SomeWebApp"
        )

        _ = try await harness.coordinator.routeSignerURL(url)
        let activated = await harness.manager.activateNextPendingIfNeeded()
        let session = try XCTUnwrap(activated)
        _ = await harness.manager.handleApprove(requestID: session.request.id, identityID: "id-1")

        XCTAssertTrue(harness.clipboard.value?.contains("clipboard") == true)
    }

    func testAnUnsupportedRequestTypeIsRefusedBeforeItReachesTheUser() async throws {
        let harness = makeHarness()
        let url = try XCTUnwrap(URL(string: "nostrsigner:?type=decrypt_zap_event&callbackUrl=damus://x?r="))

        do {
            _ = try await harness.coordinator.routeSignerURL(url)
            XCTFail("Signeur should not prompt for something it cannot do")
        } catch {
            XCTAssertEqual(error as? SignerURLParseError, .unsupportedType("decrypt_zap_event"))
        }
        let pending = await harness.manager.pendingSessions()
        XCTAssertTrue(pending.isEmpty)
    }

    func testTwoSignerRequestsAreQueuedRatherThanMerged() async throws {
        let harness = makeHarness()
        for content in ["first", "second"] {
            _ = try await harness.coordinator.routeSignerURL(
                try signerURL(
                    payload: #"{"kind":1,"content":"\#(content)","created_at":1700000000}"#,
                    query: "type=sign_event&callbackUrl=damus://signed?event="
                )
            )
        }

        let pending = await harness.manager.pendingSessions()

        XCTAssertEqual(pending.count, 2)
    }

    private func verify(_ event: NostrEvent) throws -> Bool {
        let signature = try P256K.Schnorr.SchnorrSignature(
            dataRepresentation: Data(try NostrEventFactory.hexBytes(event.sig))
        )
        var message = try NostrEventFactory.hexBytes(event.id)
        let xonly = P256K.Schnorr.XonlyKey(dataRepresentation: try NostrEventFactory.hexBytes(event.pubkey))
        return xonly.isValid(signature, for: &message)
    }
}
