import XCTest

final class SigneurNIP46E2ETests: XCTestCase {
    private var testURL: String {
        ProcessInfo.processInfo.environment["SIGNEUR_E2E_TEST_URL"]
            ?? "https://guaka.github.io/signeur/#nip46-test"
    }
    private let testNsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
    private let expectedNpub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"

    override func setUp() {
        continueAfterFailure = false
    }

    func testPublishedNIP46TesterCompletesOnIOS() {
        let signeur = XCUIApplication()
        signeur.launchEnvironment = [
            "SIGNEUR_E2E_ENABLED": "1",
            "SIGNEUR_E2E_NSEC": testNsec
        ]
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()

        let webView = safari.webViews.firstMatch
        let start = webView.buttons["Start NIP-46 test"]
        XCTAssertTrue(loadTestPage(in: safari, until: start), "Expected the published NIP-46 tester to load")
        scrollAndTap(start, in: webView)

        let connectionLink = webView.textViews.firstMatch
        XCTAssertTrue(connectionLink.waitForExistence(timeout: 30))
        guard
            let rawConnectionLink = connectionLink.value as? String,
            let connectionURL = URL(string: rawConnectionLink)
        else {
            XCTFail("Expected the tester to expose a valid Nostr Connect link")
            return
        }

        openConnection(connectionURL, in: signeur)

        // iOS may suspend Safari while Signeur is foregrounded. Bring it back so the
        // browser can receive the connect response and publish `get_public_key`, then
        // return to Signeur to approve that follow-up request.
        safari.activate()
        XCTAssertTrue(
            webView.staticTexts["Approve the public-key request in Signeur"].waitForExistence(timeout: 30)
        )
        signeur.activate()
        approve("Approve", in: signeur)

        safari.activate()
        XCTAssertTrue(webView.staticTexts[expectedNpub].waitForExistence(timeout: 45))
        if webView.staticTexts["Acquired permissions"].waitForExistence(timeout: 2) {
            XCTAssertTrue(webView.staticTexts["Read public key · Ping"].exists)
        }
    }

    private func loadTestPage(in safari: XCUIApplication, until element: XCUIElement) -> Bool {
        for _ in 0..<3 {
            if element.waitForExistence(timeout: 2) { return true }

            let addressField = safari.textFields.firstMatch
            if addressField.waitForExistence(timeout: 5) {
                addressField.tap()
                safari.typeKey("a", modifierFlags: .command)
            } else {
                safari.typeKey("l", modifierFlags: .command)
            }
            safari.typeText(testURL)
            safari.typeText("\n")
            guard safari.webViews.firstMatch.waitForExistence(timeout: 20) else { continue }
            if element.waitForExistence(timeout: 20) { return true }
        }
        return false
    }

    private func approve(_ title: String, in app: XCUIApplication) {
        let button = app.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "Expected \(title) in Signeur")
        button.tap()
    }

    private func openConnection(_ url: URL, in app: XCUIApplication) {
        let approveConnection = app.buttons["Approve Connection"]
        app.launchEnvironment["SIGNEUR_E2E_PAIRING_URI"] = url.absoluteString
        app.launch()
        XCTAssertTrue(
            approveConnection.waitForExistence(timeout: 30),
            "Expected Approve Connection in Signeur"
        )
        approveConnection.tap()
        let connectedClient = app.staticTexts["Signeur NIP-46 tester"]
        let followUpApproval = app.buttons["Approve"]
        XCTAssertTrue(
            waitForEither(connectedClient, or: followUpApproval, timeout: 30),
            "Expected the connection to remain visible or its public-key follow-up request to arrive"
        )
        XCTAssertFalse(app.staticTexts["transportFailure"].exists)
    }

    private func waitForEither(
        _ first: XCUIElement,
        or second: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if first.exists || second.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return first.exists || second.exists
    }

    private func scrollAndTap(_ element: XCUIElement, in webView: XCUIElement) {
        for _ in 0..<8 where !element.isHittable {
            webView.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
        element.tap()
    }
}
