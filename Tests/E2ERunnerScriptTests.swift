import Foundation
import XCTest

final class E2ERunnerScriptTests: XCTestCase {
    func testForwardsConfiguredURLToBothTestRunners() throws {
        try checkRunner(url: "http://127.0.0.1:8765/#nip46-test")
    }

    func testLeavesDefaultURLSelectionToTestsWhenUnset() throws {
        try checkRunner(url: nil)
    }

    private func checkRunner(url: String?) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stubs = [
            "git": "#!/bin/bash\npwd\n",
            "xcrun": "#!/bin/bash\nexit 0\n",
            "xcodebuild": "#!/bin/bash\nprintf '%s\\n' \"${TEST_RUNNER_SIGNSTR_E2E_TEST_URL-unset}\"\n"
        ]
        for (name, contents) in stubs {
            let file = directory.appendingPathComponent(name)
            try contents.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for platform in ["ios", "macos"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [root.appendingPathComponent("Scripts/run-nip46-e2e.sh").path, platform]
            process.environment = [
                "PATH": "\(directory.path):/usr/bin:/bin",
                "SIGNSTR_IOS_DESTINATION_ID": "test-simulator"
            ]
            process.environment?["SIGNSTR_E2E_TEST_URL"] = url
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, platform)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "\(url ?? "unset")\n", platform)
        }
    }
}
