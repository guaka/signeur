import CryptoKit
import P256K
import XCTest
@testable import SigneurCore

final class NostrKeyDeriverTests: XCTestCase {
    // NIP-19 test vector; expected pubkey cross-checked with Tools/derive_reference.py.
    private let nsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
    private let secretHex = "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"
    private let pubkeyHex = "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"
    private let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"

    func testGeneratedNsecIsAValidPrivateKey() throws {
        let generated = try NostrKeyDeriver.generateNsec()

        XCTAssertTrue(generated.hasPrefix("nsec1"))
        XCTAssertEqual(try NostrKeyDeriver.secretKeyBytes(fromNsec: generated).count, 32)
        XCTAssertTrue(try NostrKeyDeriver.deriveNpub(fromNsec: generated).hasPrefix("npub1"))
    }

    func testSecretKeyBytesMatchNIP19Vector() throws {
        let bytes = try NostrKeyDeriver.secretKeyBytes(fromNsec: nsec)
        XCTAssertEqual(bytes.map { String(format: "%02x", $0) }.joined(), secretHex)
    }

    func testDerivesExpectedPublicKey() throws {
        XCTAssertEqual(try NostrKeyDeriver.derivePublicKeyHex(fromNsec: nsec), pubkeyHex)
        XCTAssertEqual(try NostrKeyDeriver.deriveNpub(fromNsec: nsec), npub)
    }

    func testToleratesSurroundingWhitespace() throws {
        XCTAssertEqual(try NostrKeyDeriver.deriveNpub(fromNsec: "  \(nsec)\n"), npub)
    }

    func testRejectsCorruptedChecksum() {
        let corrupted = String(nsec.dropLast()) + "q"
        XCTAssertThrowsError(try NostrKeyDeriver.deriveNpub(fromNsec: corrupted))
    }

    func testRejectsNpubAsNsec() {
        XCTAssertThrowsError(try NostrKeyDeriver.secretKeyBytes(fromNsec: npub))
    }

    func testSignatureVerifiesAgainstDerivedPublicKey() throws {
        let secret = try NostrKeyDeriver.secretKeyBytes(fromNsec: nsec)
        let privateKey = try P256K.Schnorr.PrivateKey(dataRepresentation: Data(secret))
        var digest = Array(CryptoKit.SHA256.hash(data: Data("signeur".utf8)))
        let signature = try privateKey.signature(message: &digest, auxiliaryRand: nil, strict: true)

        let xonly = try NostrKeyDeriver.xonlyPublicKeyBytes(fromNsec: nsec)
        let publicKey = P256K.Schnorr.XonlyKey(dataRepresentation: xonly)
        XCTAssertTrue(publicKey.isValid(signature, for: &digest))
    }
}
