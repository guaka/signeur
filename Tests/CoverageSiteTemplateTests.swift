import Foundation
import XCTest

final class CoverageSiteTemplateTests: XCTestCase {
    func testStandaloneGitHubNavigationLabelUsesAnAccessibleIcon() throws {
        let template = try String(contentsOf: repositoryFile("Scripts/coverage-site/index.jq"))
        let styles = try String(contentsOf: repositoryFile("Scripts/coverage-site/coverage.css"))

        XCTAssertTrue(template.contains("class=\\\"github-icon-link\\\""))
        XCTAssertTrue(template.contains("aria-label=\\\"GitHub repository\\\""))
        XCTAssertTrue(template.contains("class=\\\"github-mark\\\""))
        XCTAssertFalse(template.contains(">GitHub <span"))
        XCTAssertFalse(template.contains("Get the source"))
        XCTAssertFalse(template.contains("<span></span> AGPL-3.0"))
        XCTAssertTrue(template.contains(">AGPL-3.0</a>"))
        XCTAssertTrue(template.contains("does not currently keep Nostr keys or signing inside the Secure Enclave"))
        XCTAssertTrue(template.contains("https://github.com/guaka/signstr/issues/18"))
        XCTAssertTrue(styles.contains(".github-mark { width: 20px; height: 20px; fill: currentColor; }"))
    }

    func testCoveragePageKeepsDetailedMetricsAndExactGreenThreshold() throws {
        let template = try String(contentsOf: repositoryFile("Scripts/coverage-site/index.jq"))
        let generator = try String(contentsOf: repositoryFile("Scripts/generate-coverage-report.sh"))

        XCTAssertTrue(template.contains("percentage_number($metric) == 100"))
        XCTAssertTrue(template.contains("line_metric($items; $excluded)"))
        XCTAssertTrue(template.contains("function_metric($all_functions; $root; $items)"))
        XCTAssertTrue(template.contains("region_metric($all_functions; $root; $items; $excluded)"))
        XCTAssertTrue(template.contains("Source-declared functions entered at least once."))
        XCTAssertTrue(template.contains("<th>Lines</th><th>Functions</th><th>Regions</th>"))
        XCTAssertTrue(template.contains("Build \\($generated) UTC"))
        XCTAssertTrue(generator.contains("date -u '+%Y-%m-%d %H:%M'"))
        XCTAssertTrue(generator.contains("coverage:ignore"))
        XCTAssertTrue(generator.contains("coverage:ignore-region"))
        XCTAssertTrue(generator.contains("compiler-generated functions"))
        XCTAssertTrue(generator.contains("grep -R -n -H"))
    }

    func testHowItWorksCardsShareOneDesktopRow() throws {
        let template = try String(contentsOf: repositoryFile("Scripts/coverage-site/index.jq"))
        let styles = try String(contentsOf: repositoryFile("Scripts/coverage-site/coverage.css"))

        XCTAssertEqual(template.components(separatedBy: "class=\\\"product-card\\\"").count - 1, 3)
        XCTAssertFalse(template.contains("feature-card"))
        XCTAssertTrue(styles.contains("grid-template-columns: repeat(3, 1fr);"))
        XCTAssertTrue(styles.contains(".product-grid { grid-template-columns: 1fr; }"))
    }

    func testHeroHasOnlyThePrimaryActionAndTesterUsesAContainedLayout() throws {
        let template = try String(contentsOf: repositoryFile("Scripts/coverage-site/index.jq"))
        let styles = try String(contentsOf: repositoryFile("Scripts/coverage-site/coverage.css"))

        XCTAssertFalse(template.contains("See how it works"))
        XCTAssertTrue(template.contains("<h1>A Nostr signer <em>for iPhone and Mac.</em></h1>"))
        XCTAssertTrue(template.contains("<h2>See NIP-46 <em>in motion.</em></h2>"))
        XCTAssertFalse(template.contains("Interactive protocol lab"))
        XCTAssertLessThan(
            try XCTUnwrap(template.range(of: "id=\\\"nip46-test\\\"")) .lowerBound,
            try XCTUnwrap(template.range(of: "id=\\\"how-it-works\\\"")) .lowerBound
        )
        XCTAssertFalse(template.contains("A Nostr signer<br>"))
        XCTAssertFalse(template.contains("See NIP-46<br>"))
        XCTAssertTrue(styles.contains(".nip46-section { padding-top: 32px;"))
        XCTAssertTrue(styles.contains(".nip46-heading h2 { margin-top: 0; white-space: nowrap; }"))
        XCTAssertTrue(template.contains("<div class=\\\"hero-actions\\\"><a class=\\\"primary-action\\\" href=\\\"#nip46-test\\\">Test NIP-46</a></div>"))
        XCTAssertTrue(styles.contains("max-width: 1440px;"))
        XCTAssertTrue(styles.contains("grid-template-columns: minmax(0, 720px) auto;"))
        XCTAssertTrue(styles.contains(".tester-privacy {"))
        XCTAssertTrue(styles.contains("border-top: 1px solid var(--border);"))
    }

    func testSuccessfulNIP46PanelShowsIdentityAndAcquiredPermissions() throws {
        let template = try String(contentsOf: repositoryFile("Scripts/coverage-site/index.jq"))
        let styles = try String(contentsOf: repositoryFile("Scripts/coverage-site/coverage.css"))

        XCTAssertTrue(template.contains("id=\\\"nip46-npub\\\""))
        XCTAssertTrue(template.contains("Acquired permissions"))
        XCTAssertTrue(template.contains("id=\\\"nip46-status-npub\\\""))
        XCTAssertTrue(template.contains("id=\\\"nip46-pairing-content\\\""))
        XCTAssertTrue(template.contains("id=\\\"nip46-permissions\\\""))
        XCTAssertTrue(template.contains("id=\\\"nip46-copy-error\\\""))
        XCTAssertTrue(template.contains("id=\\\"nip46-error-code\\\""))
        XCTAssertTrue(styles.contains(".tester-grid[hidden] { display: none; }"))
    }

    func testCoveragePageShowsLatestPlatformE2EResults() throws {
        let template = try String(contentsOf: repositoryFile("Scripts/coverage-site/index.jq"))
        let generator = try String(contentsOf: repositoryFile("Scripts/generate-coverage-report.sh"))

        XCTAssertTrue(template.contains("id=\\\"e2e-results\\\""))
        XCTAssertTrue(template.contains("e2e_card(\"iOS\"; $e2eIOSStatus)"))
        XCTAssertTrue(template.contains("e2e_card(\"macOS\"; $e2eMacOSStatus)"))
        XCTAssertTrue(template.contains("Last checked"))
        XCTAssertTrue(generator.contains("SIGNSTR_E2E_IOS_STATUS"))
        XCTAssertTrue(generator.contains("SIGNSTR_E2E_MACOS_STATUS"))
    }

    private func repositoryFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}
