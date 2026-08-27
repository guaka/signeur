import P256K
import XCTest
@testable import SignstrCore

final class NIP46MethodExecutorTests: XCTestCase {
    private let peerPubkey = "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
    private let peerSecret = "0000000000000000000000000000000000000000000000000000000000000002"

    private func makeExecutor(
        keys: [String: String] = ["id-1": TestVectors.nsec],
        now: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> NIP46MethodExecutor {
        NIP46MethodExecutor(nsecStore: InMemoryNsecStore(keys: keys), now: { now })
    }

    func testGetPublicKeyReturnsTheIdentityPubkeyInHex() async throws {
        let result = try await makeExecutor().execute(
            makeTestRequest(method: .getPublicKey, params: []),
            identityID: "id-1"
        )

        XCTAssertEqual(result, TestVectors.pubkeyHex)
    }

    func testUsingPrivateKeyRecordsLastUsedTimestamp() async throws {
        let usedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let identityStore = IdentityStore(defaults: makeEphemeralDefaults())
        await identityStore.add(Identity(id: "id-1", displayName: "Main", npub: TestVectors.npub))
        let executor = NIP46MethodExecutor(
            nsecStore: InMemoryNsecStore(keys: ["id-1": TestVectors.nsec]),
            identityStore: identityStore,
            now: { usedAt }
        )

        _ = try await executor.execute(
            makeTestRequest(method: .getPublicKey, params: []),
            identityID: "id-1"
        )

        let identity = await identityStore.list().first
        XCTAssertEqual(identity?.lastUsedAt, usedAt)
    }

    func testPingReturnsPong() async throws {
        let result = try await makeExecutor().execute(makeTestRequest(method: .ping, params: []), identityID: "id-1")

        XCTAssertEqual(result, "pong")
    }

    func testConnectEchoesThePairingSecretBackToTheApp() async throws {
        let result = try await makeExecutor().execute(
            makeTestRequest(method: .connect, params: ["s3cret"]),
            identityID: "id-1"
        )

        XCTAssertEqual(result, "s3cret", "the app matches this against the secret in its code")
    }

    func testConnectEchoesTheSecretWhenTheSignerPubkeyComesFirst() async throws {
        let result = try await makeExecutor().execute(
            makeTestRequest(method: .connect, params: [TestVectors.pubkeyHex, "s3cret"]),
            identityID: "id-1"
        )

        XCTAssertEqual(result, "s3cret")
    }

    func testConnectWithoutASecretAcknowledges() async throws {
        let result = try await makeExecutor().execute(
            makeTestRequest(method: .connect, params: [TestVectors.pubkeyHex]),
            identityID: "id-1"
        )

        XCTAssertEqual(result, "ack")
    }

    func testSignEventReturnsAFullySignedVerifiableEvent() async throws {
        let request = makeTestRequest(
            method: .signEvent,
            params: [#"{"kind":1,"content":"hello world","tags":[],"created_at":1700000000}"#]
        )

        let result = try await makeExecutor().execute(request, identityID: "id-1")

        let event = try JSONDecoder().decode(NostrEvent.self, from: Data(result.utf8))
        XCTAssertEqual(event.pubkey, TestVectors.pubkeyHex)
        XCTAssertEqual(event.kind, 1)
        XCTAssertEqual(event.content, "hello world")
        XCTAssertEqual(event.createdAt, 1_700_000_000)
        XCTAssertEqual(
            event.id,
            NostrEvent.computeID(pubkey: event.pubkey, createdAt: event.createdAt, kind: event.kind, tags: event.tags, content: event.content)
        )
        XCTAssertTrue(try verify(event: event), "the app will reject an event whose signature does not check out")
    }

    func testSignEventStampsCreatedAtWhenTheAppLeavesItOut() async throws {
        let request = makeTestRequest(method: .signEvent, params: [#"{"kind":1,"content":"no timestamp"}"#])

        let result = try await makeExecutor(now: Date(timeIntervalSince1970: 1_812_345_678))
            .execute(request, identityID: "id-1")

        let event = try JSONDecoder().decode(NostrEvent.self, from: Data(result.utf8))
        XCTAssertEqual(event.createdAt, 1_812_345_678)
    }

    func testSignEventPreservesTags() async throws {
        let request = makeTestRequest(
            method: .signEvent,
            params: [#"{"kind":7,"content":"+","tags":[["e","abc"],["p","def"]],"created_at":1700000000}"#]
        )

        let result = try await makeExecutor().execute(request, identityID: "id-1")

        let event = try JSONDecoder().decode(NostrEvent.self, from: Data(result.utf8))
        XCTAssertEqual(event.tags, [["e", "abc"], ["p", "def"]])
        XCTAssertTrue(try verify(event: event))
    }

    func testSignEventRejectsMalformedJSON() async {
        let request = makeTestRequest(method: .signEvent, params: ["not an event"])

        await assertThrows(.malformedEvent) {
            try await self.makeExecutor().execute(request, identityID: "id-1")
        }
    }

    func testNIP44EncryptProducesSomethingThePeerCanRead() async throws {
        let request = makeTestRequest(method: .nip44Encrypt, params: [peerPubkey, "secret message"])

        let payload = try await makeExecutor().execute(request, identityID: "id-1")

        let plaintext = try NIP44.decrypt(
            payload: payload,
            privateKey: try NostrEventFactory.hexBytes(peerSecret),
            publicKeyXOnly: try NostrEventFactory.hexBytes(TestVectors.pubkeyHex)
        )
        XCTAssertEqual(plaintext, "secret message")
    }

    func testNIP44DecryptReadsAPayloadFromThePeer() async throws {
        let payload = try NIP44.encrypt(
            plaintext: "from the app",
            privateKey: try NostrEventFactory.hexBytes(peerSecret),
            publicKeyXOnly: try NostrEventFactory.hexBytes(TestVectors.pubkeyHex)
        )
        let request = makeTestRequest(method: .nip44Decrypt, params: [peerPubkey, payload])

        let result = try await makeExecutor().execute(request, identityID: "id-1")

        XCTAssertEqual(result, "from the app")
    }

    func testNIP04RoundTripsWithThePeer() async throws {
        let executor = makeExecutor()
        let encrypted = try await executor.execute(
            makeTestRequest(method: .nip04Encrypt, params: [peerPubkey, "legacy message"]),
            identityID: "id-1"
        )

        let decrypted = try await executor.execute(
            makeTestRequest(method: .nip04Decrypt, params: [peerPubkey, encrypted]),
            identityID: "id-1"
        )

        XCTAssertEqual(decrypted, "legacy message")
    }

    func testEncryptRejectsANonPubkeyFirstParameter() async {
        let request = makeTestRequest(method: .nip44Encrypt, params: ["not-a-pubkey", "text"])

        await assertThrows(.invalidPubkeyParameter) {
            try await self.makeExecutor().execute(request, identityID: "id-1")
        }
    }

    func testEncryptRejectsAMissingPayload() async {
        let request = makeTestRequest(method: .nip44Encrypt, params: [peerPubkey])

        await assertThrows(.missingParameter("nip44_encrypt expects [pubkey, payload]")) {
            try await self.makeExecutor().execute(request, identityID: "id-1")
        }
    }

    func testDecryptRejectsAGarbagePayload() async {
        let request = makeTestRequest(method: .nip44Decrypt, params: [peerPubkey, "not-a-payload"])

        await assertThrows(.decryptionFailed) {
            try await self.makeExecutor().execute(request, identityID: "id-1")
        }
    }

    func testAnIdentityWithNoStoredKeyCannotExecuteAnything() async {
        let executor = makeExecutor(keys: [:])

        await assertThrows(.noKeyStoredForIdentity) {
            try await executor.execute(makeTestRequest(method: .getPublicKey, params: []), identityID: "id-1")
        }
    }

    func testACorruptStoredKeyIsReported() async {
        let executor = makeExecutor(keys: ["id-1": "nsec1garbage"])

        await assertThrows(.invalidStoredKey) {
            try await executor.execute(makeTestRequest(method: .getPublicKey, params: []), identityID: "id-1")
        }
    }

    func testEachIdentitySignsWithItsOwnKey() async throws {
        let executor = makeExecutor(keys: ["id-1": TestVectors.nsec, "id-2": TestVectors.otherNsec])

        let first = try await executor.execute(makeTestRequest(method: .getPublicKey, params: []), identityID: "id-1")
        let second = try await executor.execute(makeTestRequest(method: .getPublicKey, params: []), identityID: "id-2")

        XCTAssertEqual(first, TestVectors.pubkeyHex)
        XCTAssertNotEqual(second, first)
    }

    private func verify(event: NostrEvent) throws -> Bool {
        let signature = try P256K.Schnorr.SchnorrSignature(
            dataRepresentation: Data(try NostrEventFactory.hexBytes(event.sig))
        )
        var message = try NostrEventFactory.hexBytes(event.id)
        let xonly = P256K.Schnorr.XonlyKey(dataRepresentation: try NostrEventFactory.hexBytes(event.pubkey))
        return xonly.isValid(signature, for: &message)
    }

    private func assertThrows(
        _ expected: NIP46ExecutionError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> String
    ) async {
        do {
            let result = try await body()
            XCTFail("expected \(expected) but got \(result)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? NIP46ExecutionError, expected, file: file, line: line)
        }
    }
}
