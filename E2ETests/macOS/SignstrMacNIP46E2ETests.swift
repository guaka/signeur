import XCTest

final class SignstrMacNIP46E2ETests: XCTestCase {
    private var testURL: String {
        ProcessInfo.processInfo.environment["SIGNSTR_E2E_TEST_URL"]
            ?? "https://guaka.github.io/signstr/#nip46-test"
    }
    private let testNsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
    private let expectedNpub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"

    override func setUp() {
        continueAfterFailure = false
    }

    func testPublishedNIP46TesterCompletesOnMacOS() {
        let signstr = XCUIApplication()
        signstr.launchEnvironment = [
            "SIGNSTR_E2E_ENABLED": "1",
            "SIGNSTR_E2E_NSEC": testNsec
        ]
        signstr.launch()
        XCTAssertTrue(signstr.staticTexts["No pending requests"].waitForExistence(timeout: 15))

        let safari = XCUIApplication(bundleIdentifier: "com.apple.Safari")
        safari.launch()

        let webArea = safari.webViews.firstMatch
        let start = webArea.buttons["Start NIP-46 test"]
        XCTAssertTrue(loadTestPage(in: safari, until: start), "Expected the published NIP-46 tester to load")
        scrollAndClick(start, in: webArea)

        let copyLink = webArea.buttons["Copy link"]
        XCTAssertTrue(copyLink.waitForExistence(timeout: 30))
        scrollAndClick(copyLink, in: webArea)

        signstr.activate()
        let connectFromClipboard = signstr.buttons["Connect from Clipboard"].firstMatch
        XCTAssertTrue(connectFromClipboard.waitForExistence(timeout: 10))
        connectFromClipboard.click()
        approve("Approve Connection", in: signstr)
        approve("Approve", in: signstr)

        safari.activate()
        XCTAssertTrue(webArea.staticTexts[expectedNpub].waitForExistence(timeout: 45))
        if webArea.staticTexts["Acquired permissions"].waitForExistence(timeout: 2) {
            XCTAssertTrue(webArea.staticTexts["Read public key · Ping"].exists)
        }
    }

    private func approve(_ title: String, in app: XCUIApplication) {
        let button = app.buttons[title]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "Expected \(title) in Signstr")
        button.click()
    }

    private func loadTestPage(in safari: XCUIApplication, until element: XCUIElement) -> Bool {
        for _ in 0..<3 {
            safari.typeKey("l", modifierFlags: .command)
            safari.typeText(testURL)
            safari.typeKey(.enter, modifierFlags: [])
            guard safari.webViews.firstMatch.waitForExistence(timeout: 20) else { continue }
            if element.waitForExistence(timeout: 20) { return true }
        }
        return false
    }

    private func scrollAndClick(_ element: XCUIElement, in webArea: XCUIElement) {
        for _ in 0..<8 where !element.isHittable {
            webArea.scroll(byDeltaX: 0, deltaY: -500)
        }
        XCTAssertTrue(element.isHittable)
        element.click()
    }
}
