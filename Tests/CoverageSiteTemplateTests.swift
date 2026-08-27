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
        XCTAssertTrue(template.contains("View source on GitHub"))
        XCTAssertTrue(styles.contains(".github-mark { width: 20px; height: 20px; fill: currentColor; }"))
    }

    private func repositoryFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}
