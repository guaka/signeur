import CryptoKit
import XCTest
@testable import SignstrCore

/// Runs the official NIP-44 v2 vectors from https://github.com/paulmillr/nip44
/// (vendored at Tests/Vectors/nip44.vectors.json) against our implementation.
final class NIP44VectorTests: XCTestCase {
    private static var vectors: [String: Any] = [:]

    override class func setUp() {
        super.setUp()
        guard
            let url = Bundle.module.url(forResource: "nip44.vectors", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let v2 = root["v2"] as? [String: Any]
        else {
            XCTFail("NIP-44 vectors could not be loaded")
            return
        }
        vectors = v2
    }

    private func validCases(_ name: String) throws -> [[String: Any]] {
        let valid = try XCTUnwrap(Self.vectors["valid"] as? [String: Any])
        return try XCTUnwrap(valid[name] as? [[String: Any]])
    }

    private func invalidCases(_ name: String) throws -> [[String: Any]] {
        let invalid = try XCTUnwrap(Self.vectors["invalid"] as? [String: Any])
        return try XCTUnwrap(invalid[name] as? [[String: Any]])
    }

    func testConversationKeyVectors() throws {
        let cases = try validCases("get_conversation_key")
        XCTAssertGreaterThan(cases.count, 30)

        for testCase in cases {
            let sec1 = try NostrEventFactory.hexBytes(try XCTUnwrap(testCase["sec1"] as? String))
            let pub2 = try NostrEventFactory.hexBytes(try XCTUnwrap(testCase["pub2"] as? String))
            let expected = try XCTUnwrap(testCase["conversation_key"] as? String)

            let derived = try NIP44.conversationKey(privateKey: sec1, publicKeyXOnly: pub2)
            XCTAssertEqual(hex(derived), expected)
        }
    }

    func testMessageKeyVectors() throws {
        let valid = try XCTUnwrap(Self.vectors["valid"] as? [String: Any])
        let group = try XCTUnwrap(valid["get_message_keys"] as? [String: Any])
        let conversationKey = try NostrEventFactory.hexBytes(try XCTUnwrap(group["conversation_key"] as? String))
        let cases = try XCTUnwrap(group["keys"] as? [[String: Any]])
        XCTAssertGreaterThan(cases.count, 30)

        for testCase in cases {
            let nonce = try NostrEventFactory.hexBytes(try XCTUnwrap(testCase["nonce"] as? String))
            let keys = NIP44.messageKeys(conversationKey: conversationKey, nonce: nonce)

            XCTAssertEqual(hex(keys.chachaKey), try XCTUnwrap(testCase["chacha_key"] as? String))
            XCTAssertEqual(hex(keys.chachaNonce), try XCTUnwrap(testCase["chacha_nonce"] as? String))
            XCTAssertEqual(hex(keys.hmacKey), try XCTUnwrap(testCase["hmac_key"] as? String))
        }
    }

    func testPaddedLengthVectors() throws {
        let valid = try XCTUnwrap(Self.vectors["valid"] as? [String: Any])
        let cases = try XCTUnwrap(valid["calc_padded_len"] as? [[Int]])
        XCTAssertGreaterThan(cases.count, 20)

        for pair in cases {
            XCTAssertEqual(NIP44.paddedLength(for: pair[0]), pair[1], "padding for \(pair[0])")
        }
    }

    func testEncryptDecryptVectorsProduceTheExpectedPayload() throws {
        let cases = try validCases("encrypt_decrypt")
        XCTAssertGreaterThan(cases.count, 5)

        for testCase in cases {
            let sec1 = try NostrEventFactory.hexBytes(try XCTUnwrap(testCase["sec1"] as? String))
            let sec2 = try NostrEventFactory.hexBytes(try XCTUnwrap(testCase["sec2"] as? String))
            let nonce = try NostrEventFactory.hexBytes(try XCTUnwrap(testCase["nonce"] as? String))
            let plaintext = try XCTUnwrap(testCase["plaintext"] as? String)
            let expectedPayload = try XCTUnwrap(testCase["payload"] as? String)
            let expectedConversationKey = try XCTUnwrap(testCase["conversation_key"] as? String)

            let pub1 = try NostrKeyDeriver.xonlyPublicKeyBytes(fromSecretKey: sec1)
            let pub2 = try NostrKeyDeriver.xonlyPublicKeyBytes(fromSecretKey: sec2)

            let conversationKey = try NIP44.conversationKey(privateKey: sec1, publicKeyXOnly: pub2)
            XCTAssertEqual(hex(conversationKey), expectedConversationKey)

            let payload = try NIP44.encrypt(plaintext: plaintext, privateKey: sec1, publicKeyXOnly: pub2, nonce: nonce)
            XCTAssertEqual(payload, expectedPayload)

            // The other side decrypts with its own key and the sender's pubkey.
            let roundTripped = try NIP44.decrypt(payload: payload, privateKey: sec2, publicKeyXOnly: pub1)
            XCTAssertEqual(roundTripped, plaintext)
        }
    }

    func testLongMessageVectors() throws {
        let cases = try validCases("encrypt_decrypt_long_msg")

        for testCase in cases {
            let conversationKey = try NostrEventFactory.hexBytes(try XCTUnwrap(testCase["conversation_key"] as? String))
            let nonce = try NostrEventFactory.hexBytes(try XCTUnwrap(testCase["nonce"] as? String))
            let pattern = try XCTUnwrap(testCase["pattern"] as? String)
            let repeatCount = try XCTUnwrap(testCase["repeat"] as? Int)
            let expectedSHA = try XCTUnwrap(testCase["plaintext_sha256"] as? String)
            let expectedPayloadSHA = try XCTUnwrap(testCase["payload_sha256"] as? String)

            let plaintext = String(repeating: pattern, count: repeatCount)
            XCTAssertEqual(sha256Hex(plaintext), expectedSHA, "vector plaintext mismatch")

            let payload = try NIP44.encrypt(plaintext: plaintext, conversationKey: conversationKey, nonce: nonce)
            XCTAssertEqual(sha256Hex(payload), expectedPayloadSHA)
            XCTAssertEqual(try NIP44.decrypt(payload: payload, conversationKey: conversationKey), plaintext)
        }
    }

    func testInvalidMessageLengthsAreRejected() throws {
        let invalid = try XCTUnwrap(Self.vectors["invalid"] as? [String: Any])
        let lengths = try XCTUnwrap(invalid["encrypt_msg_lengths"] as? [Int])

        for length in lengths {
            let plaintext = String(repeating: "a", count: length)
            let conversationKey = NIP44.randomBytes(32)
            XCTAssertThrowsError(
                try NIP44.encrypt(plaintext: plaintext, conversationKey: conversationKey),
                "length \(length) must be rejected"
            )
        }
    }

    func testInvalidPayloadsAreRejected() throws {
        let cases = try invalidCases("decrypt")

        for testCase in cases {
            let conversationKey = try NostrEventFactory.hexBytes(try XCTUnwrap(testCase["conversation_key"] as? String))
            let payload = try XCTUnwrap(testCase["payload"] as? String)
            let note = testCase["note"] as? String ?? "no note"

            XCTAssertThrowsError(
                try NIP44.decrypt(payload: payload, conversationKey: conversationKey),
                "should reject: \(note)"
            )
        }
    }

    func testInvalidConversationKeyInputsAreRejected() throws {
        let cases = try invalidCases("get_conversation_key")

        for testCase in cases {
            let sec1 = try XCTUnwrap(testCase["sec1"] as? String)
            let pub2 = try XCTUnwrap(testCase["pub2"] as? String)
            let note = testCase["note"] as? String ?? "no note"

            XCTAssertThrowsError(
                try NIP44.conversationKey(
                    privateKey: try NostrEventFactory.hexBytes(sec1),
                    publicKeyXOnly: try NostrEventFactory.hexBytes(pub2)
                ),
                "should reject: \(note)"
            )
        }
    }

    func testTamperedPayloadFailsAuthentication() throws {
        let conversationKey = NIP44.randomBytes(32)
        let payload = try NIP44.encrypt(plaintext: "hello", conversationKey: conversationKey)
        var raw = Array(try XCTUnwrap(Data(base64Encoded: payload)))
        raw[raw.count - 1] ^= 0x01

        XCTAssertThrowsError(
            try NIP44.decrypt(payload: Data(raw).base64EncodedString(), conversationKey: conversationKey)
        ) { error in
            XCTAssertEqual(error as? NIP44Error, .invalidMAC)
        }
    }

    func testRandomNoncesMeanRepeatEncryptionsDiffer() throws {
        let conversationKey = NIP44.randomBytes(32)
        let first = try NIP44.encrypt(plaintext: "hello", conversationKey: conversationKey)
        let second = try NIP44.encrypt(plaintext: "hello", conversationKey: conversationKey)

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try NIP44.decrypt(payload: first, conversationKey: conversationKey), "hello")
        XCTAssertEqual(try NIP44.decrypt(payload: second, conversationKey: conversationKey), "hello")
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func sha256Hex(_ text: String) -> String {
        hex(Array(CryptoKit.SHA256.hash(data: Data(text.utf8))))
    }
}
