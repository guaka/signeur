import XCTest
@testable import SigneurCore

final class SignerURLRequestTests: XCTestCase {
    private let eventJSON = #"{"kind":1,"content":"gm","created_at":1700000000}"#

    private func url(payload: String = "", query: String) -> String {
        let encoded = payload.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? payload
        return "nostrsigner:\(encoded)?\(query)"
    }

    func testSignEventRequestCarriesTheEventAndCallback() throws {
        let request = try SignerURLRequest.parse(
            url(payload: eventJSON, query: "type=sign_event&appName=Damus&callbackUrl=damus://signed?event=&returnType=event")
        )

        XCTAssertEqual(request.method, .signEvent)
        XCTAssertEqual(request.params, [eventJSON])
        XCTAssertEqual(request.appName, "Damus")
        XCTAssertEqual(request.returnType, .event)
        XCTAssertEqual(request.callbackURL?.scheme, "damus")
    }

    func testTypeDefaultsToSignEventWhenAPayloadIsPresent() throws {
        let request = try SignerURLRequest.parse(url(payload: eventJSON, query: "appName=Damus"))

        XCTAssertEqual(request.method, .signEvent)
    }

    func testAnEmptyPayloadIsReadAsAPublicKeyRequest() throws {
        let request = try SignerURLRequest.parse("nostrsigner:")

        XCTAssertEqual(request.method, .getPublicKey)
        XCTAssertTrue(request.params.isEmpty)
    }

    func testGetPublicKeyRequestKeepsRequestedPermissions() throws {
        let permissions = #"[{"type":"sign_event","kind":1},{"type":"nip44_decrypt"}]"#
        let encoded = permissions.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? permissions

        let request = try SignerURLRequest.parse("nostrsigner:?type=get_public_key&permissions=\(encoded)")

        XCTAssertEqual(request.method, .getPublicKey)
        XCTAssertEqual(request.requestedPermissions, ["sign_event:1", "nip44_decrypt"])
    }

    func testEncryptRequestTakesThePeerFromTheQuery() throws {
        let request = try SignerURLRequest.parse(
            url(payload: "hello", query: "type=nip44_encrypt&pubkey=\(TestVectors.pubkeyHex)")
        )

        XCTAssertEqual(request.method, .nip44Encrypt)
        XCTAssertEqual(request.params, [TestVectors.pubkeyHex, "hello"])
    }

    func testDecryptRequestWithoutAPeerIsRejected() {
        XCTAssertThrowsError(try SignerURLRequest.parse(url(payload: "cipher", query: "type=nip04_decrypt"))) { error in
            XCTAssertEqual(error as? SignerURLParseError, .missingPeerPubkey)
        }
    }

    func testSignEventWithoutAnEventIsRejected() {
        XCTAssertThrowsError(try SignerURLRequest.parse("nostrsigner:?type=sign_event")) { error in
            XCTAssertEqual(error as? SignerURLParseError, .missingPayload)
        }
    }

    func testAnUnknownTypeIsRejectedByName() {
        XCTAssertThrowsError(try SignerURLRequest.parse("nostrsigner:?type=decrypt_zap_event")) { error in
            XCTAssertEqual(error as? SignerURLParseError, .unsupportedType("decrypt_zap_event"))
        }
    }

    func testGzipPayloadsAreRejectedRatherThanMisread() {
        XCTAssertThrowsError(
            try SignerURLRequest.parse(url(payload: eventJSON, query: "type=sign_event&compressionType=gzip"))
        ) { error in
            XCTAssertEqual(error as? SignerURLParseError, .unsupportedCompression("gzip"))
        }
    }

    func testAnotherSchemeIsNotASignerRequest() {
        XCTAssertThrowsError(try SignerURLRequest.parse("nostrconnect://pub?relay=wss://r&secret=s")) { error in
            XCTAssertEqual(error as? SignerURLParseError, .invalidScheme)
        }
    }

    func testReturnTypeSignatureIsHonoured() throws {
        let request = try SignerURLRequest.parse(
            url(payload: eventJSON, query: "type=sign_event&returnType=signature")
        )

        XCTAssertEqual(request.returnType, .signature)
    }

    func testCallersAreIdentifiedByTheirCallbackSchemeSoPermissionsStick() throws {
        let first = try SignerURLRequest.parse(url(payload: eventJSON, query: "callbackUrl=damus://x&appName=Damus"))
        let second = try SignerURLRequest.parse(url(payload: eventJSON, query: "callbackUrl=damus://y&appName=Damus"))

        XCTAssertEqual(first.appIdentifier, second.appIdentifier)
        XCTAssertEqual(first.appIdentifier, "nostrsigner:damus")
    }

    func testTheRequestItProducesPassesValidation() throws {
        let signerRequest = try SignerURLRequest.parse(url(payload: eventJSON, query: "type=sign_event&appName=Damus"))

        let request = signerRequest.makeNIP46Request(id: "r1")

        if case let .failure(error) = NIP46Validator().validate(request) {
            XCTFail("a parsed signer request must be valid: \(error)")
        }
        XCTAssertEqual(request.appPubkey, "nostrsigner:Damus")
        XCTAssertEqual(request.rawPayloadPreview, eventJSON, "the user sees the event they are signing")
    }

    func testRejectsUnsupportedCompressionType() {
        XCTAssertThrowsError(
            try SignerURLRequest.parse("nostrsigner:abc?compressionType=zip&type=sign_event")
        ) { error in
            XCTAssertEqual(error as? SignerURLParseError, .unsupportedCompression("zip"))
        }
    }

    func testRejectsUnsafeCallbackScheme() {
        XCTAssertThrowsError(
            try SignerURLRequest.parse(url(payload: eventJSON, query: "type=sign_event&callbackUrl=javascript:alert(1)"))
        ) { error in
            XCTAssertEqual(error as? SignerURLParseError, .invalidCallback)
        }
    }

    func testRejectsRequestPayloadThatExceedsLimits() {
        let payload = String(repeating: "x", count: SecurityPolicy.maxRequestPayloadBytes + SecurityPolicy.maxRelayURLBytes + 1)
        XCTAssertThrowsError(
            try SignerURLRequest.parse("nostrsigner:\(payload)?type=sign_event")
        ) { error in
            XCTAssertEqual(error as? SignerURLParseError, .payloadTooLarge)
        }
    }

    func testMissingPeerForEncryptionIsReportedAsMissingPeerPubkey() {
        XCTAssertThrowsError(
            try SignerURLRequest.parse(url(payload: "hello", query: "type=nip04_decrypt"))
        ) { error in
            XCTAssertEqual(error as? SignerURLParseError, .missingPeerPubkey)
        }
    }

    func testRequestIdentifierFallsBackToUnknownWhenCallbackAndNameAreAbsent() throws {
        let request = try SignerURLRequest.parse(url(payload: eventJSON, query: "type=sign_event"))

        XCTAssertEqual(request.appIdentifier, "nostrsigner:unknown")
        XCTAssertEqual(request.appName, nil)
        XCTAssertNil(request.callbackURL)
    }
}

final class NIP55CallbackTransportTests: XCTestCase {
    func testResultIsAppendedToTheCallbackURL() async throws {
        let opened = Collector<URL>()
        let transport = NIP55CallbackTransport(openURL: { url in await opened.append(url); return true })
        await transport.register(
            requestID: "r1",
            callbackURL: URL(string: "damus://signed?event="),
            returnType: .event
        )

        try await transport.sendResponse(NIP46Response(id: "r1", result: "{\"sig\":\"abc\"}", error: nil), to: "app")

        let urls = await opened.items()
        XCTAssertEqual(urls.count, 1)
        XCTAssertTrue(urls[0].absoluteString.hasPrefix("damus://signed?event="), urls[0].absoluteString)
        XCTAssertTrue(urls[0].absoluteString.contains("sig"), urls[0].absoluteString)
    }

    func testSignatureOnlyCallersGetJustTheSignature() async throws {
        let opened = Collector<URL>()
        let transport = NIP55CallbackTransport(openURL: { url in await opened.append(url); return true })
        await transport.register(requestID: "r1", callbackURL: URL(string: "damus://signed?sig="), returnType: .signature)
        let signedEvent = #"{"id":"abc","sig":"deadbeef","kind":1}"#

        try await transport.sendResponse(NIP46Response(id: "r1", result: signedEvent, error: nil), to: "app")

        let urls = await opened.items()
        XCTAssertEqual(urls.first?.absoluteString, "damus://signed?sig=deadbeef")
    }

    func testWithoutACallbackTheResultGoesToTheClipboard() async {
        let clipboard = Clipboard()
        let transport = NIP55CallbackTransport(
            openURL: { _ in false },
            copyToClipboard: { value in clipboard.store(value) }
        )
        await transport.register(requestID: "r1", callbackURL: nil, returnType: .event)

        do {
            try await transport.sendResponse(NIP46Response(id: "r1", result: "signed", error: nil), to: "app")
            XCTFail("there is no way to hand the result back automatically")
        } catch {
            XCTAssertEqual(error as? NIP55CallbackError, .noWayToReturnResult)
        }
        XCTAssertEqual(clipboard.value, "signed", "the user can still paste it into the app")
    }

    func testARefusedCallbackFallsBackToTheClipboard() async {
        let clipboard = Clipboard()
        let transport = NIP55CallbackTransport(
            openURL: { _ in false },
            copyToClipboard: { value in clipboard.store(value) }
        )
        await transport.register(requestID: "r1", callbackURL: URL(string: "damus://signed?event="), returnType: .event)

        do {
            try await transport.sendResponse(NIP46Response(id: "r1", result: "signed", error: nil), to: "app")
            XCTFail("an app that cannot be opened must be reported")
        } catch {
            XCTAssertEqual(error as? NIP55CallbackError, .callbackRefused)
        }
        XCTAssertEqual(clipboard.value, "signed")
    }

    func testARejectedRequestOpensNothing() async throws {
        let opened = Collector<URL>()
        let transport = NIP55CallbackTransport(openURL: { url in await opened.append(url); return true })
        await transport.register(requestID: "r1", callbackURL: URL(string: "damus://signed?event="), returnType: .event)

        try await transport.sendResponse(
            NIP46Response(id: "r1", result: nil, error: NIP46ResponseError(code: 4_001, message: "userRejected")),
            to: "app"
        )

        let urls = await opened.items()
        XCTAssertTrue(urls.isEmpty, "a refusal must not look like a result")
    }

    func testOnlyRegisteredRequestsAreHandledHere() async {
        let transport = NIP55CallbackTransport(openURL: { _ in true })

        let handles = await transport.handles(requestID: "unknown")

        XCTAssertFalse(handles, "relay-connected apps must not be answered by URL")
    }

    func testCallbackTargetFillsEmptyQueryValue() {
        let callbackURL = URL(string: "damus://signed?event=")!

        let resolved = NIP55CallbackTransport.callbackTarget(callbackURL, payload: "deadbeef")

        XCTAssertEqual(
            resolved,
            URL(string: "damus://signed?event=deadbeef"),
            "callback URLs with an empty query slot must fill that slot"
        )
    }

    func testCallbackTargetAddsResultWhenNoEmptyQueryExists() {
        let callbackURL = URL(string: "damus://signed?event=payload")!

        let resolved = NIP55CallbackTransport.callbackTarget(callbackURL, payload: "deadbeef")

        XCTAssertEqual(
            resolved,
            URL(string: "damus://signed?event=payload&result=deadbeef"),
            "a missing slot should fall back to a result query key"
        )
    }

    func testEachRequestIsAnsweredOnce() async throws {
        let opened = Collector<URL>()
        let transport = NIP55CallbackTransport(openURL: { url in await opened.append(url); return true })
        await transport.register(requestID: "r1", callbackURL: URL(string: "damus://x?e="), returnType: .event)

        try await transport.sendResponse(NIP46Response(id: "r1", result: "one", error: nil), to: "app")
        let handlesAfter = await transport.handles(requestID: "r1")

        XCTAssertFalse(handlesAfter)
    }

    func testPayloadForSignatureFallsBackWhenResultMissingSigField() {
        let result = NIP55CallbackTransport.payload(for: #"{"error":"missing"}"#, returnType: .signature)

        XCTAssertEqual(result, #"{"error":"missing"}"#)
    }
}

final class RoutingTransportTests: XCTestCase {
    func testSignerURLRequestsGoBackToTheCallingApp() async throws {
        let opened = Collector<URL>()
        let callback = NIP55CallbackTransport(openURL: { url in await opened.append(url); return true })
        let relay = RecordingTransport()
        await callback.register(requestID: "r1", callbackURL: URL(string: "damus://x?e="), returnType: .event)

        try await RoutingTransport(callbackTransport: callback, relayTransport: relay)
            .sendResponse(NIP46Response(id: "r1", result: "signed", error: nil), to: "app")

        let relayCount = await relay.sentCount()
        let urls = await opened.items()
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(relayCount, 0)
    }

    func testRelayRequestsStillGoOverTheRelays() async throws {
        let opened = Collector<URL>()
        let callback = NIP55CallbackTransport(openURL: { url in await opened.append(url); return true })
        let relay = RecordingTransport()

        try await RoutingTransport(callbackTransport: callback, relayTransport: relay)
            .sendResponse(NIP46Response(id: "relay-req", result: "signed", error: nil), to: "app")

        let relayCount = await relay.sentCount()
        let urls = await opened.items()
        XCTAssertEqual(relayCount, 1)
        XCTAssertTrue(urls.isEmpty)
    }
}

/// Stands in for UIPasteboard.
final class Clipboard: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ value: String) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
