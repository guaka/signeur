import XCTest
@testable import SignstrCore

final class ChaCha20Tests: XCTestCase {
    /// RFC 8439 section 2.4.2 known-answer test.
    func testRFC8439Vector() {
        let key = (0..<32).map { UInt8($0) }
        let nonce: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0x4a, 0, 0, 0, 0]
        let plaintext = Array("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let expected = """
        6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0b\
        f91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d8\
        07ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab7793736\
        5af90bbf74a35be6b40b8eedf2785e42874d
        """

        let ciphertext = ChaCha20.apply(key: key, nonce: nonce, counter: 1, to: plaintext)

        XCTAssertEqual(ciphertext.map { String(format: "%02x", $0) }.joined(), expected)
    }

    func testApplyingTheKeystreamTwiceRestoresTheInput() throws {
        let key = try NIP44.randomBytes(32)
        let nonce = try NIP44.randomBytes(12)
        let plaintext = Array("round trip me".utf8)

        let ciphertext = ChaCha20.apply(key: key, nonce: nonce, to: plaintext)
        XCTAssertNotEqual(ciphertext, plaintext)
        XCTAssertEqual(ChaCha20.apply(key: key, nonce: nonce, to: ciphertext), plaintext)
    }

    func testKeystreamSpansBlockBoundaries() throws {
        let key = try NIP44.randomBytes(32)
        let nonce = try NIP44.randomBytes(12)
        // 200 bytes crosses the 64-byte block boundary three times.
        let plaintext = [UInt8](repeating: 0, count: 200)

        let keystream = ChaCha20.apply(key: key, nonce: nonce, to: plaintext)

        XCTAssertEqual(keystream.count, 200)
        let firstBlock = Array(keystream[0..<64])
        let secondBlock = Array(keystream[64..<128])
        XCTAssertNotEqual(firstBlock, secondBlock, "each block must use a fresh counter")
    }
}
