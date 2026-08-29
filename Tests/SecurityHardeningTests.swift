import XCTest
@testable import SigneurCore

final class SecurityPolicyTests: XCTestCase {
    func testPublicKeysMustBeCanonicalASCIIHex() {
        XCTAssertTrue(SecurityPolicy.isCanonicalPublicKey(TestVectors.pubkeyHex))
        XCTAssertFalse(SecurityPolicy.isCanonicalPublicKey(TestVectors.pubkeyHex.uppercased()))
        XCTAssertFalse(SecurityPolicy.isCanonicalPublicKey(String(repeating: "g", count: 64)))
        XCTAssertFalse(SecurityPolicy.isCanonicalPublicKey(String(repeating: "٠", count: 64)))
    }

    func testRelayPolicyAllowsSecureAndLoopbackDevelopmentURLs() throws {
        XCTAssertEqual(try SecurityPolicy.canonicalRelay("WSS://Relay.Example/path"), "wss://relay.example/path")
        XCTAssertEqual(try SecurityPolicy.canonicalRelay("ws://localhost:8080"), "ws://localhost:8080")
        XCTAssertEqual(try SecurityPolicy.canonicalRelay("ws://127.42.0.1"), "ws://127.42.0.1")
        XCTAssertEqual(try SecurityPolicy.canonicalRelay("ws://[::1]:8080"), "ws://[::1]:8080")
    }

    func testRelayPolicyRejectsUnsafeAndAmbiguousURLs() {
        for relay in [
            "ws://relay.example", "https://relay.example", "wss://user:pass@relay.example",
            "wss://relay.example/#fragment", "wss://", "not a url"
        ] {
            XCTAssertThrowsError(try SecurityPolicy.canonicalRelay(relay), relay)
        }
    }

    func testRelaysAreDeduplicatedAndCountIsBounded() throws {
        XCTAssertEqual(
            try SecurityPolicy.sanitizeRelays(["wss://relay.example", "WSS://RELAY.EXAMPLE"]),
            ["wss://relay.example"]
        )
        XCTAssertThrowsError(
            try SecurityPolicy.sanitizeRelays((0...SecurityPolicy.maxRelays).map { "wss://relay\($0).example" })
        )
        XCTAssertThrowsError(try SecurityPolicy.sanitizeRelays([]))
    }

    func testMetadataURLPolicyAllowsHTTPSAndHTTPOnlyOnLoopback() throws {
        XCTAssertEqual(try SecurityPolicy.canonicalMetadataURL("https://example.com/app"), "https://example.com/app")
        XCTAssertEqual(try SecurityPolicy.canonicalMetadataURL("http://localhost:3000"), "http://localhost:3000")
        XCTAssertThrowsError(try SecurityPolicy.canonicalMetadataURL("http://example.com"))
        XCTAssertThrowsError(try SecurityPolicy.canonicalMetadataURL("file:///tmp/app"))
    }

    func testIdentifiersRejectControlCharactersAndOversizeValues() {
        XCTAssertFalse(SecurityPolicy.validateIdentifier("request\nsmuggled"))
        XCTAssertFalse(SecurityPolicy.validateIdentifier(String(repeating: "x", count: SecurityPolicy.maxIdentifierBytes + 1)))
    }
}

final class StrictRequestValidationTests: XCTestCase {
    func testMalformedAndPreSignedEventsAreRejected() {
        let validator = NIP46Validator()
        for payload in [
            "not-json",
            #"{"kind":-1}"#,
            #"{"kind":1,"pubkey":"forged"}"#,
            #"{"kind":1,"tags":"not-an-array"}"#
        ] {
            let result = validator.validate(makeTestRequest(params: [payload], payload: payload))
            guard case .failure = result else { return XCTFail("accepted \(payload)") }
        }
    }

    func testPeerKeysAndCompletePayloadAreValidated() {
        let badPeer = makeTestRequest(method: .nip44Encrypt, params: ["short", "message"])
        guard case .failure = NIP46Validator().validate(badPeer) else {
            return XCTFail("accepted malformed peer key")
        }

        let huge = String(repeating: "x", count: SecurityPolicy.maxRequestPayloadBytes + 1)
        let oversized = makeTestRequest(method: .nip44Encrypt, params: [TestVectors.otherPubkeyHex, huge], payload: "short preview")
        guard case .failure(.payloadTooLarge) = NIP46Validator().validate(oversized) else {
            return XCTFail("accepted oversized complete payload")
        }
    }

    func testTechnicalPreviewIsTruncatedWithoutChangingProtocolPayload() {
        let payload = String(repeating: "x", count: SecurityPolicy.maxPreviewCharacters + 10)
        XCTAssertEqual(SecurityPolicy.truncatedPreview(payload).count, SecurityPolicy.maxPreviewCharacters)
        XCTAssertEqual(payload.count, SecurityPolicy.maxPreviewCharacters + 10)
    }
}

final class CryptographicFailureTests: XCTestCase {
    func testRandomGenerationFailureIsPropagated() {
        XCTAssertThrowsError(try NIP44.randomBytes(32, using: { _, _ in -1 })) { error in
            XCTAssertEqual(error as? NIP44Error, .randomGenerationFailed(-1))
        }
    }

    func testCryptographicallyInvalidNsecIsRejectedBeforeKeychainStorage() async throws {
        let zeroScalar = try Bech32.encode(hrp: "nsec", bytes: [UInt8](repeating: 0, count: 32))
        do {
            try await NsecKeychainStore().saveNsec(zeroScalar, for: "invalid-scalar")
            XCTFail("zero is not a valid secp256k1 private key")
        } catch {
            XCTAssertEqual(error as? NsecStoreError, .invalidInput)
        }
    }
}

final class PermissionHardeningTests: XCTestCase {
    func testLocalSignerAndLegacyNIP04RequestsCannotBeRemembered() async throws {
        let defaults = makeEphemeralDefaults()
        let store = PermissionRuleStore(defaults: defaults)
        let local = makeTestRequest(appPubkey: "nostrsigner:damus", origin: .localSigner)
        let legacy = makeTestRequest(method: .nip04Encrypt, params: [TestVectors.otherPubkeyHex, "secret"])

        await store.saveRememberRule(for: local)
        await store.saveRememberRule(for: legacy)

        let rules = try await store.listRules()
        let localApproved = await store.shouldAutoApprove(request: local)
        let legacyApproved = await store.shouldAutoApprove(request: legacy)
        XCTAssertTrue(rules.isEmpty)
        XCTAssertFalse(localApproved)
        XCTAssertFalse(legacyApproved)
    }

    func testLegacyRulesAreRemovedDuringMigration() async throws {
        let defaults = makeEphemeralDefaults()
        let rules = [
            PermissionRule(appPubkey: TestVectors.pubkeyHex, method: NIP46Method.nip04Decrypt.rawValue),
            PermissionRule(appPubkey: "nostrsigner:damus", method: NIP46Method.signEvent.rawValue),
            PermissionRule(appPubkey: TestVectors.pubkeyHex, method: NIP46Method.ping.rawValue)
        ]
        defaults.set(try JSONEncoder().encode(rules), forKey: "signeur.permission.rules")

        let migrated = try await PermissionRuleStore(defaults: defaults).listRules()

        XCTAssertEqual(migrated.map(\.method), [NIP46Method.ping.rawValue])
    }
}

final class CallbackHardeningTests: XCTestCase {
    func testUnsafeCallbackSchemesAndFragmentsAreRejected() {
        for callback in [
            "https://example.com/return", "file:///tmp/x", "data:text/plain,x", "javascript:alert(1)",
            "signeur://pair", "nostrsigner:payload", "damus://signed#fragment", "damus://user:pass@host/x"
        ] {
            let encoded = callback.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
            XCTAssertThrowsError(try SignerURLRequest.parse("nostrsigner:?type=get_public_key&callbackUrl=\(encoded)"), callback)
        }
    }

    func testCallbackPayloadCannotInjectQueryItems() throws {
        let callback = try XCTUnwrap(URL(string: "damus://signed?event=&fixed=1"))
        let target = try XCTUnwrap(NIP55CallbackTransport.callbackTarget(callback, payload: "x&admin=true#fragment"))
        let components = try XCTUnwrap(URLComponents(url: target, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "event" })?.value, "x&admin=true#fragment")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "fixed" })?.value, "1")
        XCTAssertNil(components.queryItems?.first(where: { $0.name == "admin" }))
        XCTAssertNil(components.fragment)
    }
}

final class ConnectionMigrationSecurityTests: XCTestCase {
    private struct LegacyConnection: Encodable {
        let appPubkey: String
        let appName: String? = "Legacy App"
        let appURL: String? = "https://example.com"
        let relays: [String] = ["wss://relay.example", "ws://relay.example"]
        let requestedPermissions: [String]? = ["sign_event"]
        let identityID: String = "id-1"
        let secret: String = "must-not-survive"
        let isApproved: Bool = true
        let usesLegacyEncryption: Bool = false
        let createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
        let lastUsedAt: Date? = nil
    }

    func testLegacyConnectionMigrationStripsSecretsAndUnsafeRelays() async throws {
        let defaults = makeEphemeralDefaults()
        defaults.set(try JSONEncoder().encode([LegacyConnection(appPubkey: TestVectors.otherPubkeyHex)]), forKey: "signeur.connections")

        let migrated = await ConnectionStore(defaults: defaults).all()
        let rewritten = try XCTUnwrap(defaults.data(forKey: "signeur.connections"))
        let rewrittenText = String(decoding: rewritten, as: UTF8.self)

        XCTAssertEqual(migrated.first?.relays, ["wss://relay.example"])
        XCTAssertEqual(migrated.first?.appName, "Legacy App")
        XCTAssertFalse(rewrittenText.contains("must-not-survive"))
        XCTAssertFalse(rewrittenText.contains("\"secret\""))
    }

    func testConnectionWithoutSecureRelayIsFlaggedForReconnection() {
        let connection = AppConnection(appPubkey: TestVectors.otherPubkeyHex, relays: ["ws://relay.example"], identityID: "id-1")
        XCTAssertTrue(connection.needsSecureRelay)
    }
}

@MainActor
final class RevealedKeySecurityTests: XCTestCase {
    func testRevealedNsecAutoHidesAndCanBeHiddenImmediately() async throws {
        let identity = Identity(id: "id-1", displayName: "Main", npub: TestVectors.npub)
        let identities = IdentityStore(defaults: makeEphemeralDefaults(), seed: [identity])
        let model = KeysViewModel(
            identityStore: identities,
            nsecStore: InMemoryNsecStore(keys: [identity.id: TestVectors.nsec]),
            revealDuration: .milliseconds(10)
        )
        await model.refresh()
        await model.toggleReveal(identity)
        XCTAssertEqual(model.revealedNsecs[identity.id], TestVectors.nsec)

        let deadline = ContinuousClock.now + .seconds(1)
        while model.revealedNsecs[identity.id] != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.revealedNsecs[identity.id])

        await model.toggleReveal(identity)
        model.hideAllRevealedKeys()
        XCTAssertTrue(model.revealedNsecs.isEmpty)
    }
}
