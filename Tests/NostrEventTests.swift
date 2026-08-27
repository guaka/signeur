import P256K
import XCTest
@testable import SignstrCore

final class NostrEventTests: XCTestCase {
    private let pubkey = TestVectors.pubkeyHex

    /// Expected IDs produced independently (Tools/derive_event_ids.py) from the NIP-01 rule:
    /// sha256 of the compact JSON array [0, pubkey, created_at, kind, tags, content].
    func testEventIDMatchesReferenceSerialization() {
        XCTAssertEqual(
            NostrEvent.computeID(pubkey: pubkey, createdAt: 1_700_000_000, kind: 1, tags: [], content: "hello world"),
            "216882a79fd0376e139aed513ec061d3b5abf041cc25adc25303f1e937c3dda2"
        )
    }

    func testEventIDEscapesControlCharactersAndKeepsUnicodeLiteral() {
        let content = "quote \" backslash \\ newline \n tab \t emoji 🔑 unicode ñ"
        let id = NostrEvent.computeID(
            pubkey: pubkey,
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [["e", "abc"], ["p", "def", "wss://relay.one"]],
            content: content
        )

        XCTAssertEqual(id, "f0b8e554efb5cac63e673bd81e4709a38daf8fc2802a209bf22ec7c373b47c9f")
    }

    func testEventIDForNIP46Envelope() {
        XCTAssertEqual(
            NostrEvent.computeID(pubkey: pubkey, createdAt: 0, kind: 24133, tags: [["p", pubkey]], content: ""),
            "1c84217d393a7a814fa8792d71a4c42c9e4cb2702570507c6de52ddda04379f0"
        )
    }

    func testSerializationIsCompactWithNoWhitespace() {
        let serialized = NostrEvent.serializeForID(
            pubkey: pubkey,
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [["e", "abc"]],
            content: "hi"
        )

        XCTAssertEqual(
            serialized,
            "[0,\"\(pubkey)\",1700000000,1,[[\"e\",\"abc\"]],\"hi\"]"
        )
    }

    func testSigningProducesAVerifiableEventWithDerivedIDAndPubkey() throws {
        let secret = try NostrKeyDeriver.secretKeyBytes(fromNsec: TestVectors.nsec)
        let unsigned = UnsignedNostrEvent(createdAt: 1_700_000_000, kind: 1, tags: [], content: "hello world")

        let event = try NostrEventFactory.sign(unsigned, privateKey: secret)

        XCTAssertEqual(event.pubkey, pubkey)
        XCTAssertEqual(event.id, "216882a79fd0376e139aed513ec061d3b5abf041cc25adc25303f1e937c3dda2")
        XCTAssertEqual(event.sig.count, 128)
        XCTAssertTrue(
            try verify(signatureHex: event.sig, idHex: event.id, pubkeyHex: event.pubkey),
            "any Nostr client must be able to verify the signature"
        )
    }

    func testSigningFillsInCreatedAtWhenTheAppOmitsIt() throws {
        let secret = try NostrKeyDeriver.secretKeyBytes(fromNsec: TestVectors.nsec)
        let unsigned = UnsignedNostrEvent(createdAt: nil, kind: 1, tags: [], content: "now")

        let event = try NostrEventFactory.sign(unsigned, privateKey: secret, now: Date(timeIntervalSince1970: 1_800_000_000))

        XCTAssertEqual(event.createdAt, 1_800_000_000)
    }

    func testSigningRespectsAnAppSuppliedCreatedAt() throws {
        let secret = try NostrKeyDeriver.secretKeyBytes(fromNsec: TestVectors.nsec)
        let unsigned = UnsignedNostrEvent(createdAt: 1_234_567, kind: 1, tags: [], content: "then")

        let event = try NostrEventFactory.sign(unsigned, privateKey: secret, now: Date())

        XCTAssertEqual(event.createdAt, 1_234_567)
    }

    func testSignedEventJSONUsesNostrFieldNamesAndUnescapedSlashes() throws {
        let secret = try NostrKeyDeriver.secretKeyBytes(fromNsec: TestVectors.nsec)
        let unsigned = UnsignedNostrEvent(
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [["r", "wss://relay.one"]],
            content: "see wss://relay.one"
        )

        let json = try NostrEventFactory.json(for: try NostrEventFactory.sign(unsigned, privateKey: secret))

        XCTAssertTrue(json.contains("\"created_at\":1700000000"), json)
        XCTAssertTrue(json.contains("wss://relay.one"), "slashes must not be escaped")
        XCTAssertFalse(json.contains("createdAt"))
    }

    func testDecodingAnUnsignedEventFromAnAppTakesKindTagsAndContent() throws {
        let json = """
        {"kind":22242,"created_at":1700000000,"tags":[["relay","wss://relay.one"],["challenge","abc"]],"content":"auth"}
        """

        let unsigned = try UnsignedNostrEvent.decode(json: json)

        XCTAssertEqual(unsigned.kind, 22242)
        XCTAssertEqual(unsigned.createdAt, 1_700_000_000)
        XCTAssertEqual(unsigned.tags, [["relay", "wss://relay.one"], ["challenge", "abc"]])
        XCTAssertEqual(unsigned.content, "auth")
    }

    func testDecodingToleratesMissingOptionalFields() throws {
        let unsigned = try UnsignedNostrEvent.decode(json: #"{"kind":1}"#)

        XCTAssertEqual(unsigned.kind, 1)
        XCTAssertNil(unsigned.createdAt)
        XCTAssertEqual(unsigned.tags, [])
        XCTAssertEqual(unsigned.content, "")
    }

    func testDecodingRejectsAnEventWithoutAKind() {
        XCTAssertThrowsError(try UnsignedNostrEvent.decode(json: #"{"content":"no kind"}"#)) { error in
            XCTAssertEqual(error as? NostrEventError, .malformedJSON)
        }
    }

    func testDecodingRejectsGarbage() {
        XCTAssertThrowsError(try UnsignedNostrEvent.decode(json: "not json")) { error in
            XCTAssertEqual(error as? NostrEventError, .malformedJSON)
        }
    }

    func testDifferentContentYieldsADifferentSignatureAndID() throws {
        let secret = try NostrKeyDeriver.secretKeyBytes(fromNsec: TestVectors.nsec)
        let first = try NostrEventFactory.sign(
            UnsignedNostrEvent(createdAt: 1_700_000_000, kind: 1, tags: [], content: "one"),
            privateKey: secret
        )
        let second = try NostrEventFactory.sign(
            UnsignedNostrEvent(createdAt: 1_700_000_000, kind: 1, tags: [], content: "two"),
            privateKey: secret
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.sig, second.sig)
    }

    private func verify(signatureHex: String, idHex: String, pubkeyHex: String) throws -> Bool {
        let signature = try P256K.Schnorr.SchnorrSignature(
            dataRepresentation: Data(try NostrEventFactory.hexBytes(signatureHex))
        )
        var message = try NostrEventFactory.hexBytes(idHex)
        let xonly = P256K.Schnorr.XonlyKey(dataRepresentation: try NostrEventFactory.hexBytes(pubkeyHex))
        return xonly.isValid(signature, for: &message)
    }
}
