import XCTest
@testable import SignstrCore

final class RedactedLoggerTests: XCTestCase {
    private let logger = RedactedLogger()

    func testRedactsValuesUnderSensitiveKeys() {
        let redacted = logger.redact([
            "nsec": "short",
            "secret": "abc",
            "signature": "abc",
            "access_token": "abc"
        ])
        XCTAssertEqual(Set(redacted.values), [RedactedLogger.redactionPlaceholder])
    }

    func testRedactsPrivateKeyMaterialUnderAnyKey() {
        let redacted = logger.redact(["pasted": TestVectors.nsec])
        XCTAssertEqual(redacted["pasted"], RedactedLogger.redactionPlaceholder)
    }

    func testRedactsOversizedValues() {
        let long = String(repeating: "a", count: 49)
        XCTAssertEqual(logger.redact(["value": long])["value"], RedactedLogger.redactionPlaceholder)
        XCTAssertEqual(logger.redact(["value": String(repeating: "a", count: 48)])["value"], String(repeating: "a", count: 48))
    }

    func testKeepsMethodNamesReadable() {
        let redacted = logger.redact([
            "method": "sign_event",
            "app": "Nostrudel",
            "outcome": "approved",
            "npub": TestVectors.npub.prefix(20).description
        ])
        XCTAssertEqual(redacted["method"], "sign_event", "audit history is useless if method names are redacted")
        XCTAssertEqual(redacted["app"], "Nostrudel")
        XCTAssertEqual(redacted["outcome"], "approved")
    }

    func testLoggedLineNeverContainsSecrets() {
        let captured = CapturedLines()
        let logger = RedactedLogger(emit: { captured.append($0) })

        logger.log(event: "request_approved", metadata: ["nsec": TestVectors.nsec, "method": "sign_event"])

        let line = captured.lines.first ?? ""
        XCTAssertTrue(line.contains("request_approved"))
        XCTAssertTrue(line.contains("sign_event"))
        XCTAssertFalse(line.contains(TestVectors.nsec))
    }
}

private final class CapturedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var lines: [String] {
        lock.withLock { storage }
    }

    func append(_ line: String) {
        lock.withLock { storage.append(line) }
    }
}
