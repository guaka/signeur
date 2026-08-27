import XCTest
@testable import SignstrCore

final class NIP46ValidatorTests: XCTestCase {
    func testRejectsUnsupportedMethod() {
        let validator = NIP46Validator(supportedMethods: [.connect])
        let request = NIP46Request(
            id: "1",
            method: .signEvent,
            params: ["{}"],
            appName: "Client",
            appURL: nil,
            appPubkey: "pubkey",
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
            (.nip04Encrypt, ["peer-pubkey", "plaintext"]),
            (.nip04Decrypt, ["peer-pubkey", "ciphertext"]),
            (.nip44Encrypt, ["peer-pubkey", "plaintext"]),
            (.nip44Decrypt, ["peer-pubkey", "ciphertext"])
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
            appPubkey: "pubkey",
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

    private func resultError(_ result: Result<Void, NIP46ValidationError>) -> NIP46ValidationError? {
        if case let .failure(error) = result { return error }
        return nil
    }
}
