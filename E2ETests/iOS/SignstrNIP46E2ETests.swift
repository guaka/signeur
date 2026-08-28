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

        let openInSignstr = webView.links["Open in Signstr"]
        XCTAssertTrue(openInSignstr.waitForExistence(timeout: 30))
        scrollAndTap(openInSignstr, in: webView)
        confirmOpeningSignstrIfNeeded(in: safari)

        signstr.activate()
        approve("Approve Connection", in: signstr)

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

    private func confirmOpeningSignstrIfNeeded(in safari: XCUIApplication) {
        let confirmationDialog = safari.otherElements["SFDialogView"]
        if confirmationDialog.waitForExistence(timeout: 3) {
            let confirmationButton = confirmationDialog.buttons.element(boundBy: 1)
            if confirmationButton.exists {
                confirmationButton.tap()
                return
            }
        }

        let safariOpen = safari.buttons["Open"]
        if safariOpen.waitForExistence(timeout: 3) {
            safariOpen.tap()
            return
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let systemOpen = springboard.buttons["Open"]
        if systemOpen.waitForExistence(timeout: 3) {
            systemOpen.tap()
        }
    }

    private func approve(_ title: String, in app: XCUIApplication) {
        let button = app.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "Expected \(title) in Signstr")
        button.tap()
    }

    private func scrollAndTap(_ element: XCUIElement, in webView: XCUIElement) {
        for _ in 0..<8 where !element.isHittable {
            webView.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
        element.tap()
    }
}
