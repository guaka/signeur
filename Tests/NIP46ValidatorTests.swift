import XCTest
@testable import SigneurCore

final class NIP46ValidatorTests: XCTestCase {
    func testRejectsUnsupportedMethod() {
        let validator = NIP46Validator(supportedMethods: [.connect])
        let request = NIP46Request(
            id: "1",
            method: .signEvent,
            params: ["{}"],
            appName: "Client",
            appURL: nil,
            appPubkey: TestVectors.pubkeyHex,
            correlationID: "c1",
            rawPayloadPreview: "{}"
        )

        let result = validator.validate(request)
        if case let .failure(error) = result {
            XCTAssertEqual(error, .unsupportedMethod("sign_event"))
        } else {
            XCTFail("Expected unsupported method failure")
        }
    }

    func testRejectsMalformedRequest() {
        let validator = NIP46Validator()
        let request = NIP46Request(
            id: "",
            method: .connect,
            params: [],
            appName: nil,
            appURL: nil,
            appPubkey: "",
            correlationID: "",
            rawPayloadPreview: ""
        )
        XCTAssertEqual(resultError(validator.validate(request)), .missingField("id"))
    }

    func testAcceptsWellFormedRequestsForEveryMethod() {
        let validator = NIP46Validator()
        let cases: [(NIP46Method, [String])] = [
            (.connect, ["anything"]),
            (.getPublicKey, []),
            (.ping, []),
            (.switchRelays, []),
            (.logout, []),
            (.signEvent, ["{\"kind\":1}"]),
            (.nip04Encrypt, [TestVectors.otherPubkeyHex, "plaintext"]),
            (.nip04Decrypt, [TestVectors.otherPubkeyHex, "ciphertext"]),
            (.nip44Encrypt, [TestVectors.otherPubkeyHex, "plaintext"]),
            (.nip44Decrypt, [TestVectors.otherPubkeyHex, "ciphertext"])
        ]

        for (method, params) in cases {
            let result = validator.validate(makeTestRequest(method: method, params: params))
            XCTAssertNil(resultError(result), "\(method.rawValue) should validate")
        }
    }

    func testRejectsMissingCorrelationID() {
        let request = NIP46Request(
            id: "1",
            method: .ping,
            params: [],
            appName: nil,
            appURL: nil,
            appPubkey: TestVectors.pubkeyHex,
            correlationID: "   ",
            rawPayloadPreview: ""
        )
        XCTAssertEqual(resultError(NIP46Validator().validate(request)), .missingField("correlationID"))
    }

    func testRejectsMissingAppPubkey() {
        let request = NIP46Request(
            id: "1",
            method: .ping,
            params: [],
            appName: nil,
            appURL: nil,
            appPubkey: "",
            correlationID: "c1",
            rawPayloadPreview: ""
        )
        XCTAssertEqual(resultError(NIP46Validator().validate(request)), .missingField("appPubkey"))
    }

    func testRejectsOversizedPayload() {
        let validator = NIP46Validator(maxPayloadCharacters: 10)
        let request = makeTestRequest(payload: String(repeating: "x", count: 11))
        XCTAssertEqual(resultError(validator.validate(request)), .payloadTooLarge)
    }

    func testSignEventRequiresExactlyOneParameter() {
        let validator = NIP46Validator()
        XCTAssertEqual(
            resultError(validator.validate(makeTestRequest(method: .signEvent, params: []))),
            .invalidParamShape("sign_event expects one JSON event payload")
        )
        XCTAssertEqual(
            resultError(validator.validate(makeTestRequest(method: .signEvent, params: ["{}", "{}"]))),
            .invalidParamShape("sign_event expects one JSON event payload")
        )
    }

    func testEncryptionMethodsRequireTwoParameters() {
        let validator = NIP46Validator()
        for method in [NIP46Method.nip04Encrypt, .nip04Decrypt, .nip44Encrypt, .nip44Decrypt] {
            XCTAssertEqual(
                resultError(validator.validate(makeTestRequest(method: method, params: ["only-one"]))),
                .invalidParamShape("\(method.rawValue) expects [pubkey, payload]"),
                "\(method.rawValue) should require two parameters"
            )
        }
    }

    func testParameterlessMethodsRejectExtraParameters() {
        let validator = NIP46Validator()
        for method in [NIP46Method.getPublicKey, .ping, .switchRelays, .logout] {
            XCTAssertEqual(
                resultError(validator.validate(makeTestRequest(method: method, params: ["unexpected"]))),
                .invalidParamShape(method.rawValue),
                "\(method.rawValue) should reject parameters"
            )
        }
    }

    func testRejectsMalformedLocalSignerIdentity() {
        let request = NIP46Request(
            id: "r1",
            method: .getPublicKey,
            params: [],
            appName: "App",
            appURL: nil,
            appPubkey: "not-a-valid-key",
            correlationID: "c1",
            rawPayloadPreview: "{}",
            origin: .localSigner
        )

        XCTAssertEqual(
            resultError(NIP46Validator().validate(request)),
            .invalidField("appPubkey")
        )
    }

    func testRejectsTooManyPermissions() {
        let tooMany = Array(repeating: "sign_event", count: 33)
        let request = NIP46Request(
            id: "r2",
            method: .signEvent,
            params: ["{}"],
            appName: "App",
            appURL: nil,
            appPubkey: TestVectors.pubkeyHex,
            requestedPermissions: tooMany,
            correlationID: "c2",
            rawPayloadPreview: "{}"
        )
        XCTAssertEqual(resultError(NIP46Validator().validate(request)), .invalidField("requestedPermissions"))
    }

    func testRejectsInvalidAppNameMetadata() {
        let request = makeTestRequest(method: .getPublicKey, appName: "app\nname")
        XCTAssertEqual(resultError(NIP46Validator().validate(request)), .invalidField("appName"))
    }

    func testRejectsInvalidMetadataURL() {
        let request = NIP46Request(
            id: "r3",
            method: .getPublicKey,
            params: [],
            appName: "App",
            appURL: "ftp://example.com",
            appPubkey: TestVectors.pubkeyHex,
            correlationID: "c3",
            rawPayloadPreview: ""
        )
        XCTAssertEqual(resultError(NIP46Validator().validate(request)), .invalidField("appURL"))
    }

    func testRejectsInvalidRelayList() {
        let request = NIP46Request(
            id: "r4",
            method: .signEvent,
            params: ["{}"],
            appName: "App",
            appURL: nil,
            appPubkey: TestVectors.pubkeyHex,
            relays: ["wss://allowed.example", "ws://not-loopback"],
            correlationID: "c4",
            rawPayloadPreview: "{}",
        )
        XCTAssertEqual(resultError(NIP46Validator().validate(request)), .invalidField("relays"))
    }

    private func resultError(_ result: Result<Void, NIP46ValidationError>) -> NIP46ValidationError? {
        if case let .failure(error) = result { return error }
        return nil
    }
}
