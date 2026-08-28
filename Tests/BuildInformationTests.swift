import Foundation
import XCTest
@testable import SignstrCore

final class BuildInformationTests: XCTestCase {
    func testBundleBuildTimeUsesTheConfiguredValueOrExecutableTimestamp() {
        XCTAssertFalse(BuildInformation.displayBuildTime(bundle: .main).isEmpty)
    }

    func testConfiguredReleaseBuildTimeTakesPrecedence() {
        XCTAssertEqual(
            BuildInformation.displayBuildTime(
                configuredValue: "2026-28-08 12:00 UTC",
                fallbackDate: Date(timeIntervalSince1970: 0)
            ),
            "2026-28-08 12:00 UTC"
        )
    }

    func testDevelopmentBuildUsesExecutableTimestamp() {
        let date = Date(timeIntervalSince1970: 1_777_777_777)

        XCTAssertEqual(
            BuildInformation.displayBuildTime(configuredValue: "$(SIGNSTR_BUILD_TIME)", fallbackDate: date),
            "2026-05-03 03:09:37 UTC"
        )
        XCTAssertEqual(
            BuildInformation.displayBuildTime(configuredValue: "", fallbackDate: date),
            "2026-05-03 03:09:37 UTC"
        )
    }

    func testMissingBuildInformationIsExplicit() {
        XCTAssertEqual(
            BuildInformation.displayBuildTime(configuredValue: nil, fallbackDate: nil),
            "Unknown"
        )
    }
}
