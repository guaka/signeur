import XCTest
@testable import SignstrCore

final class DeepLinkParsingTests: XCTestCase {
    private let handler = DeepLinkHandler()
    private let clientPubkey = TestVectors.otherPubkeyHex

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }

    func testParsesFullConnectLink() throws {
        let parsed = try handler.parse(try url(
            "nostrconnect://\(clientPubkey)?relay=wss://relay.one&relay=wss://relay.two&secret=s3cret&perms=sign_event,nip44_encrypt&name=Nostrudel&url=https://nostrudel.ninja"
        ))

        XCTAssertEqual(parsed.clientPubkey, clientPubkey)
        XCTAssertEqual(parsed.relays, ["wss://relay.one", "wss://relay.two"])
        XCTAssertEqual(parsed.secret, "s3cret")
        XCTAssertEqual(parsed.requestedPerms, ["sign_event", "nip44_encrypt"])
        XCTAssertEqual(parsed.appName, "Nostrudel")
        XCTAssertEqual(parsed.appURL, "https://nostrudel.ninja")
    }

    func testOptionalMetadataMayBeAbsent() throws {
        let parsed = try handler.parse(try url("nostrconnect://\(clientPubkey)?relay=wss://relay.one&secret=s3cret"))

        XCTAssertTrue(parsed.requestedPerms.isEmpty)
        XCTAssertNil(parsed.appName)
        XCTAssertNil(parsed.appURL)
    }

    func testRejectsForeignScheme() throws {
        XCTAssertThrowsError(try handler.parse(try url("https://clientpub?relay=wss://r&secret=s"))) { error in
            XCTAssertEqual(error as? DeepLinkParseError, .invalidScheme)
        }
    }

    func testRejectsMissingClientPubkey() throws {
        XCTAssertThrowsError(try handler.parse(try url("nostrconnect://?relay=wss://r&secret=s"))) { error in
            XCTAssertEqual(error as? DeepLinkParseError, .missingClientPubkey)
        }
    }

    func testRejectsMissingRelay() throws {
        XCTAssertThrowsError(try handler.parse(try url("nostrconnect://\(clientPubkey)?secret=s"))) { error in
            XCTAssertEqual(error as? DeepLinkParseError, .missingRelay)
        }
    }

    func testRejectsMissingOrEmptySecret() throws {
        XCTAssertThrowsError(try handler.parse(try url("nostrconnect://\(clientPubkey)?relay=wss://r"))) { error in
            XCTAssertEqual(error as? DeepLinkParseError, .missingSecret)
        }
        XCTAssertThrowsError(try handler.parse(try url("nostrconnect://\(clientPubkey)?relay=wss://r&secret="))) { error in
            XCTAssertEqual(error as? DeepLinkParseError, .missingSecret)
        }
    }

    func testPayloadParserAcceptsScannedLink() throws {
        let parsed = try PairingPayloadParser().parse("nostrconnect://\(clientPubkey)?relay=wss://relay.one&secret=s3cret")
        XCTAssertEqual(parsed.clientPubkey, clientPubkey)
        XCTAssertEqual(parsed.secret, "s3cret")
    }

    func testPayloadParserRejectsUnparseableText() {
        XCTAssertThrowsError(try PairingPayloadParser().parse("not a url at all")) { error in
            XCTAssertEqual(error as? DeepLinkParseError, .invalidScheme)
        }
    }

    func testPayloadParserIgnoresSurroundingWhitespaceAndNewlines() throws {
        let parsed = try PairingPayloadParser().parse("\n  nostrconnect://\(clientPubkey)?relay=wss://relay.one&secret=s3cret \n")
        XCTAssertEqual(parsed.clientPubkey, clientPubkey)
    }

    func testPayloadParserFindsLinkPastedWithSurroundingText() throws {
        let parsed = try PairingPayloadParser().parse(
            "Connect your signer: nostrconnect://\(clientPubkey)?relay=wss://relay.one&secret=s3cret (expires in 5 min)"
        )
        XCTAssertEqual(parsed.clientPubkey, clientPubkey)
        XCTAssertEqual(parsed.secret, "s3cret")
    }

    func testPayloadParserAcceptsUppercasedScheme() throws {
        let parsed = try PairingPayloadParser().parse("NOSTRCONNECT://\(clientPubkey)?relay=wss://relay.one&secret=s3cret")
        XCTAssertEqual(parsed.clientPubkey, clientPubkey)
    }

    func testPayloadParserUnwrapsOurOwnScheme() throws {
        let wrapped = "nostrconnect://\(clientPubkey)?relay=wss://relay.one&secret=s3cret"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let parsed = try PairingPayloadParser().parse("signstr://pair?uri=\(wrapped)")
        XCTAssertEqual(parsed.clientPubkey, clientPubkey)
        XCTAssertEqual(parsed.secret, "s3cret")
    }

    func testPayloadParserRejectsOurSchemeWithoutAPairingLink() {
        XCTAssertThrowsError(try PairingPayloadParser().parse("signstr://pair")) { error in
            XCTAssertEqual(error as? DeepLinkParseError, .invalidScheme)
        }
    }

    func testPayloadParserAcceptsAURLDirectly() throws {
        let url = try XCTUnwrap(URL(string: "nostrconnect://\(clientPubkey)?relay=wss://relay.one&secret=s3cret"))
        XCTAssertEqual(try PairingPayloadParser().parse(url).clientPubkey, clientPubkey)
    }

    func testRejectsInvalidClientPublicKey() throws {
        XCTAssertThrowsError(
            try handler.parse(try url("nostrconnect://not-a-key?relay=wss://relay.one&secret=s"))
        ) { error in
            XCTAssertEqual(error as? DeepLinkParseError, .invalidClientPubkey)
        }
    }

    func testRejectsInsecureRelayURLs() throws {
        XCTAssertThrowsError(
            try handler.parse(try url("nostrconnect://\(clientPubkey)?relay=ws://relay.example.com&secret=s3cret"))
        ) { error in
            XCTAssertEqual(error as? DeepLinkParseError, .invalidRelay)
        }
    }

    func testRejectsInvalidMetadataText() {
        XCTAssertThrowsError(
            try handler.parse(try url("nostrconnect://\(clientPubkey)?relay=wss://relay.one&secret=s3cret&name=%0A"))
        ) { error in
            XCTAssertEqual(error as? DeepLinkParseError, .invalidMetadata)
        }
    }

    func testRejectsInvalidAppMetadataURL() throws {
        XCTAssertThrowsError(
            try handler.parse(try url("nostrconnect://\(clientPubkey)?relay=wss://relay.one&secret=s3cret&url=ftp://example.com"))
        ) { error in
            XCTAssertEqual(error as? DeepLinkParseError, .invalidMetadata)
        }
    }
}
