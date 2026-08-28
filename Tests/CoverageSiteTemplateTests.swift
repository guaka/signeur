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
        XCTAssertTrue(styles.contains(".github-mark { width: 20px; height: 20px; fill: currentColor; }"))
    }

    func testCoveragePageKeepsDetailedMetricsAndExactGreenThreshold() throws {
        let template = try String(contentsOf: repositoryFile("Scripts/coverage-site/index.jq"))
        let generator = try String(contentsOf: repositoryFile("Scripts/generate-coverage-report.sh"))

        XCTAssertTrue(template.contains("percentage_number($metric) == 100"))
        XCTAssertTrue(template.contains("<th>Lines</th><th>Functions</th><th>Regions</th>"))
        XCTAssertTrue(template.contains("Build \\($generated) UTC"))
        XCTAssertTrue(generator.contains("date -u '+%Y-%m-%d %H:%M'"))
    }

    private func repositoryFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}
