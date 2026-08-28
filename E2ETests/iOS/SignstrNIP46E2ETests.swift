import XCTest

final class SignstrNIP46E2ETests: XCTestCase {
    private let testURL = "https://guaka.github.io/signstr/#nip46-test"
    private let testNsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
    private let expectedNpub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"

    override func setUp() {
        continueAfterFailure = false
    }

    func testPublishedNIP46TesterCompletesOnIOS() {
        let signstr = XCUIApplication()
        signstr.launchEnvironment = [
            "SIGNSTR_E2E_ENABLED": "1",
            "SIGNSTR_E2E_NSEC": testNsec
        ]
        signstr.launch()
        XCTAssertTrue(signstr.staticTexts["No pending requests"].waitForExistence(timeout: 15))

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

        openConnection(connectionURL, in: signstr)

        // iOS may suspend Safari while Signstr is foregrounded. Bring it back so the
        // browser can receive the connect response and publish `get_public_key`, then
        // return to Signstr to approve that follow-up request.
        safari.activate()
        XCTAssertTrue(
            webView.staticTexts["Approve the public-key request in Signstr"].waitForExistence(timeout: 30)
        )
        signstr.activate()
        approve("Approve", in: signstr)

        safari.activate()
        XCTAssertTrue(webView.staticTexts[expectedNpub].waitForExistence(timeout: 45))
        if webView.staticTexts["Acquired permissions"].waitForExistence(timeout: 2) {
            XCTAssertTrue(webView.staticTexts["Read public key · Ping"].exists)
        }
    }

    private func loadTestPage(in safari: XCUIApplication, until element: XCUIElement) -> Bool {
        for _ in 0..<3 {
            safari.typeKey("l", modifierFlags: .command)
            safari.typeText(testURL)
            safari.typeText("\n")
            guard safari.webViews.firstMatch.waitForExistence(timeout: 20) else { continue }
            if element.waitForExistence(timeout: 20) { return true }
        }
        return false
    }

    private func approve(_ title: String, in app: XCUIApplication) {
        let button = app.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "Expected \(title) in Signstr")
        button.tap()
    }

    private func openConnection(_ url: URL, in app: XCUIApplication) {
        let approveConnection = app.buttons["Approve Connection"]
        app.open(url)
        if !approveConnection.waitForExistence(timeout: 15) {
            // A resource-constrained hosted simulator can cold-launch the app without
            // delivering the first URL to SwiftUI. Once launched, delivery is reliable.
            app.open(url)
        }
        XCTAssertTrue(
            approveConnection.waitForExistence(timeout: 30),
            "Expected Approve Connection in Signstr"
        )
        approveConnection.tap()
    }

    private func scrollAndTap(_ element: XCUIElement, in webView: XCUIElement) {
        for _ in 0..<8 where !element.isHittable {
            webView.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
        element.tap()
    }
}
