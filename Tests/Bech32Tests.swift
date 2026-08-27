import XCTest
@testable import SignstrCore

final class Bech32Tests: XCTestCase {
    func testDecodesNsecToExpectedBytes() throws {
        let bytes = try Bech32.decode(TestVectors.nsec, expectedHRP: "nsec")
        XCTAssertEqual(bytes.count, 32)
        XCTAssertEqual(bytes.map { String(format: "%02x", $0) }.joined(), TestVectors.secretHex)
    }

    func testEncodeDecodeRoundTripsArbitraryPayloads() throws {
        for length in [1, 20, 32, 65] {
            let payload = (0..<length).map { UInt8($0 % 256) }
            let encoded = try Bech32.encode(hrp: "npub", bytes: payload)
            XCTAssertEqual(try Bech32.decode(encoded, expectedHRP: "npub"), payload, "round trip failed at \(length) bytes")
        }
    }

    func testEncodedOutputIsLowercaseAndHRPPrefixed() throws {
        let encoded = try Bech32.encode(hrp: "npub", bytes: Array(repeating: 0xAB, count: 32))
        XCTAssertTrue(encoded.hasPrefix("npub1"))
        XCTAssertEqual(encoded, encoded.lowercased())
    }

    func testDecodeAcceptsUppercaseInput() throws {
        let bytes = try Bech32.decode(TestVectors.nsec.uppercased(), expectedHRP: "nsec")
        XCTAssertEqual(bytes.map { String(format: "%02x", $0) }.joined(), TestVectors.secretHex)
    }

    func testRejectsWrongHumanReadablePart() {
        XCTAssertThrowsError(try Bech32.decode(TestVectors.nsec, expectedHRP: "npub")) { error in
            XCTAssertEqual(error as? Bech32Error, .invalidFormat)
        }
    }

    func testRejectsCharacterOutsideCharset() {
        // "b" is excluded from the Bech32 charset.
        let invalid = "nsec1bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        XCTAssertThrowsError(try Bech32.decode(invalid, expectedHRP: "nsec")) { error in
            XCTAssertEqual(error as? Bech32Error, .invalidCharacter)
        }
    }

    func testRejectsMutatedChecksum() {
        let mutated = String(TestVectors.nsec.dropLast()) + "q"
        XCTAssertThrowsError(try Bech32.decode(mutated, expectedHRP: "nsec")) { error in
            XCTAssertEqual(error as? Bech32Error, .invalidChecksum)
        }
    }

    func testRejectsMissingSeparator() {
        XCTAssertThrowsError(try Bech32.decode("nsecqqqqqq", expectedHRP: "nsec")) { error in
            XCTAssertEqual(error as? Bech32Error, .invalidFormat)
        }
    }

    func testRejectsDataPartShorterThanChecksum() {
        XCTAssertThrowsError(try Bech32.decode("nsec1qqq", expectedHRP: "nsec")) { error in
            XCTAssertEqual(error as? Bech32Error, .invalidFormat)
        }
    }

    func testRejectsEmptyHumanReadablePart() {
        XCTAssertThrowsError(try Bech32.decode("1qqqqqqqq", expectedHRP: "")) { error in
            XCTAssertEqual(error as? Bech32Error, .invalidFormat)
        }
    }
}
