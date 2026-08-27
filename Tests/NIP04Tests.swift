import XCTest
@testable import SignstrCore

final class NIP04Tests: XCTestCase {
    private let sec1 = TestVectors.secretHex
    private let sec2 = "0000000000000000000000000000000000000000000000000000000000000002"
    private let pub2 = "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"

    /// Cross-checked against an independent Python implementation (Tools/derive_reference_vectors.py).
    private let referencePayload = "zgC5jLLvz2rjne1LFgo0YJPMj1AjMfVYmW7UrUnOhng=?iv=AAAAAAAAAAAAAAAAAAAAAA=="

    func testEncryptMatchesAnIndependentImplementation() throws {
        let payload = try NIP04.encrypt(
            plaintext: "hello from python",
            privateKey: try NostrEventFactory.hexBytes(sec1),
            publicKeyXOnly: try NostrEventFactory.hexBytes(pub2),
            iv: [UInt8](repeating: 0, count: 16)
        )

        XCTAssertEqual(payload, referencePayload)
    }

    func testDecryptReadsAPayloadFromAnotherImplementation() throws {
        let plaintext = try NIP04.decrypt(
            payload: referencePayload,
            privateKey: try NostrEventFactory.hexBytes(sec1),
            publicKeyXOnly: try NostrEventFactory.hexBytes(pub2)
        )

        XCTAssertEqual(plaintext, "hello from python")
    }

    func testEitherSideCanDecryptTheOthersMessage() throws {
        let secret1 = try NostrEventFactory.hexBytes(sec1)
        let secret2 = try NostrEventFactory.hexBytes(sec2)
        let pubkey1 = try NostrKeyDeriver.xonlyPublicKeyBytes(fromSecretKey: secret1)
        let pubkey2 = try NostrEventFactory.hexBytes(pub2)

        let payload = try NIP04.encrypt(plaintext: "shared", privateKey: secret1, publicKeyXOnly: pubkey2)

        XCTAssertEqual(try NIP04.decrypt(payload: payload, privateKey: secret2, publicKeyXOnly: pubkey1), "shared")
    }

    func testRandomIVsMeanRepeatEncryptionsDiffer() throws {
        let secret = try NostrEventFactory.hexBytes(sec1)
        let peer = try NostrEventFactory.hexBytes(pub2)

        let first = try NIP04.encrypt(plaintext: "same text", privateKey: secret, publicKeyXOnly: peer)
        let second = try NIP04.encrypt(plaintext: "same text", privateKey: secret, publicKeyXOnly: peer)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try NIP04.decrypt(payload: first, privateKey: secret, publicKeyXOnly: peer), "same text")
    }

    func testLongMessagesSurviveTheBlockBoundary() throws {
        let secret = try NostrEventFactory.hexBytes(sec1)
        let peer = try NostrEventFactory.hexBytes(pub2)
        let text = String(repeating: "long message ", count: 500)

        let payload = try NIP04.encrypt(plaintext: text, privateKey: secret, publicKeyXOnly: peer)

        XCTAssertEqual(try NIP04.decrypt(payload: payload, privateKey: secret, publicKeyXOnly: peer), text)
    }

    func testUnicodeSurvivesTheRoundTrip() throws {
        let secret = try NostrEventFactory.hexBytes(sec1)
        let peer = try NostrEventFactory.hexBytes(pub2)

        let payload = try NIP04.encrypt(plaintext: "zap ⚡️ ñ 日本語", privateKey: secret, publicKeyXOnly: peer)

        XCTAssertEqual(try NIP04.decrypt(payload: payload, privateKey: secret, publicKeyXOnly: peer), "zap ⚡️ ñ 日本語")
    }

    func testPayloadWithoutAnIVIsRejected() throws {
        let secret = try NostrEventFactory.hexBytes(sec1)
        let peer = try NostrEventFactory.hexBytes(pub2)

        XCTAssertThrowsError(
            try NIP04.decrypt(payload: "zgC5jLLvz2rjne1LFgo0YA==", privateKey: secret, publicKeyXOnly: peer)
        ) { error in
            XCTAssertEqual(error as? NIP04Error, .malformedPayload)
        }
    }

    func testPayloadWithAWrongLengthIVIsRejected() throws {
        let secret = try NostrEventFactory.hexBytes(sec1)
        let peer = try NostrEventFactory.hexBytes(pub2)

        XCTAssertThrowsError(
            try NIP04.decrypt(payload: "zgC5jLLvz2rjne1LFgo0YA==?iv=AAAA", privateKey: secret, publicKeyXOnly: peer)
        ) { error in
            XCTAssertEqual(error as? NIP04Error, .malformedPayload)
        }
    }

    func testDecryptingWithTheWrongKeyDoesNotReturnThePlaintext() throws {
        let wrongSecret = try NostrKeyDeriver.secretKeyBytes(fromNsec: TestVectors.otherNsec)
        let peer = try NostrEventFactory.hexBytes(pub2)

        // AES-CBC has no authentication tag, so this either throws on padding or returns junk;
        // what matters is that it never yields the original message.
        let plaintext = try? NIP04.decrypt(payload: referencePayload, privateKey: wrongSecret, publicKeyXOnly: peer)

        XCTAssertNotEqual(plaintext, "hello from python")
    }
}
