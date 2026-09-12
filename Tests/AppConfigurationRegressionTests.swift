import Foundation
import XCTest

final class AppConfigurationRegressionTests: XCTestCase {
    func testE2ERunnerForwardsConfiguredSiteToBothPlatforms() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for (name, script) in [
            ("git", "#!/bin/sh\necho /test-repository\n"),
            ("xcrun", "#!/bin/sh\nexit 0\n"),
            ("xcodebuild", "#!/bin/sh\nprintf '%s' \"$TEST_RUNNER_SIGNEUR_E2E_TEST_URL\" > \"$CAPTURE_PATH\"\n")
        ] {
            let url = directory.appendingPathComponent(name)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        for platform in ["ios", "macos"] {
            let capture = directory.appendingPathComponent(platform)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [repositoryFile("Scripts/run-nip46-e2e.sh").path, platform]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = directory.path + ":/usr/bin:/bin"
            environment["SIGNEUR_E2E_TEST_URL"] = "http://127.0.0.1:8765/#nip46-test"
            environment["SIGNEUR_IOS_DESTINATION_ID"] = "test-device"
            environment["CAPTURE_PATH"] = capture.path
            process.environment = environment
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(try String(contentsOf: capture), environment["SIGNEUR_E2E_TEST_URL"])
        }
    }

    func testRebrandPreservesInstalledAppIdentityAndBuildTimeSetting() throws {
        let project = try String(contentsOf: repositoryFile("Signeur.xcodeproj/project.pbxproj"))
        let spec = try String(contentsOf: repositoryFile("project.yml"))
        for identifier in ["org.trustroots.signstr", "org.trustroots.signstr.mac"] {
            XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = \(identifier);"))
            XCTAssertTrue(spec.contains("PRODUCT_BUNDLE_IDENTIFIER: \(identifier)"))
        }
        for path in ["iOSApp/Info.plist", "MacOSApp/Info.plist"] {
            let data = try Data(contentsOf: repositoryFile(path))
            let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            XCTAssertEqual(plist["SigneurBuildTime"] as? String, "$(SIGNEUR_BUILD_TIME)")
            let types = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
            let schemes = try XCTUnwrap(types.first?["CFBundleURLSchemes"] as? [String])
            XCTAssertTrue(schemes.contains("signstr"))
            XCTAssertTrue(schemes.contains("signeur"))
        }
        for path in ["Scripts/archive-ios.sh", "Scripts/release-macos.sh"] {
            XCTAssertTrue(try String(contentsOf: repositoryFile(path)).contains("SIGNEUR_BUILD_TIME="))
        }
    }

    func testMacAppUsesASingleWindowScene() throws {
        let source = try String(contentsOf: repositoryFile("MacOSApp/SigneurMacApp.swift"))

        XCTAssertTrue(source.contains("Window(\"Signeur\", id: \"main\")"))
        XCTAssertFalse(source.contains("WindowGroup"))
    }

    func testMacTargetCarriesItsKeychainEntitlements() throws {
        let entitlementsData = try Data(contentsOf: repositoryFile("MacOSApp/SigneurMac.entitlements"))
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: entitlementsData, format: nil) as? [String: Any]
        )
        let groups = try XCTUnwrap(entitlements["keychain-access-groups"] as? [String])

        XCTAssertEqual(groups, ["$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)"])

        let project = try String(contentsOf: repositoryFile("Signeur.xcodeproj/project.pbxproj"))
        XCTAssertTrue(project.contains("CODE_SIGN_ENTITLEMENTS = MacOSApp/SigneurMac.entitlements;"))
        XCTAssertTrue(project.contains("PRODUCT_BUNDLE_IDENTIFIER = org.trustroots.signstr.mac;"))
        XCTAssertTrue(project.contains("DEVELOPMENT_TEAM = SUJ594N47C;"))
    }

    func testMacSidebarUsesBoundSelectionForEveryPane() throws {
        let source = try String(contentsOf: repositoryFile("MacOSApp/MacRootView.swift"))

        XCTAssertTrue(source.contains("@State private var section: MacRootSection = .requests"))
        XCTAssertTrue(source.contains("List(MacRootSection.allCases, selection: $section)"))
        XCTAssertTrue(source.contains("NavigationLink(value: item)"))
        XCTAssertFalse(source.contains("MacRootSection?"))
    }

    func testBothPlatformKeyScreensExposeGeneration() throws {
        for path in ["MacOSApp/MacKeysView.swift", "iOSApp/KeysView.swift"] {
            let source = try String(contentsOf: repositoryFile(path))

            XCTAssertTrue(source.contains("await viewModel.generateKey()"), path)
            XCTAssertTrue(source.contains("Label(\"Generate New Key\""), path)
        }
    }

    func testBothPlatformKeyScreensConfirmDeletion() throws {
        for path in ["MacOSApp/MacKeysView.swift", "iOSApp/KeysView.swift"] {
            let source = try String(contentsOf: repositoryFile(path))

            XCTAssertTrue(source.contains(".confirmationDialog("), path)
            XCTAssertTrue(source.contains("Button(\"Delete Key\", role: .destructive)"), path)
            XCTAssertTrue(source.contains("This cannot be undone."), path)
        }
    }

    func testMacSidebarLogoUsesEnlargedSize() throws {
        let source = try String(contentsOf: repositoryFile("MacOSApp/MacRootView.swift"))

        XCTAssertTrue(source.contains(".frame(width: 76, height: 76)"))
        XCTAssertTrue(source.contains(".font(.title2.bold())"))
        XCTAssertTrue(source.contains(".font(.body.weight(.medium))"))
    }

    func testIOSNavigationLogoUsesEnlargedSize() throws {
        let source = try String(contentsOf: repositoryFile("iOSApp/RootView.swift"))

        XCTAssertTrue(source.contains(".frame(width: 30, height: 30)"))
    }

    func testIOSLocksKeySessionOnlyAfterEnteringBackground() throws {
        let source = try String(contentsOf: repositoryFile("iOSApp/RootView.swift"))

        XCTAssertTrue(source.contains("UIApplication.didEnterBackgroundNotification"))
        XCTAssertFalse(source.contains("UIApplication.willResignActiveNotification"))
        XCTAssertTrue(source.contains("await AppBootstrap.lockKeySession()"))
    }

    func testIOSRefreshesRelaySubscriptionsAfterReturningToTheForeground() throws {
        let root = try String(contentsOf: repositoryFile("iOSApp/RootView.swift"))
        let bootstrap = try String(contentsOf: repositoryFile("iOSApp/AppBootstrap.swift"))

        XCTAssertTrue(root.contains("UIApplication.didBecomeActiveNotification"))
        XCTAssertTrue(root.contains("await AppBootstrap.resumeListening()"))
        XCTAssertTrue(bootstrap.contains("await relayListener.resumeAfterSuspension()"))
    }

    func testBothHelpScreensLinkToThePublishedGuide() throws {
        for path in ["MacOSApp/MacRootView.swift", "iOSApp/RootView.swift"] {
            let source = try String(contentsOf: repositoryFile(path))

            XCTAssertTrue(source.contains("Open the Signeur guide and NIP-46 tester"), path)
            XCTAssertTrue(source.contains("https://guaka.github.io/signeur/"), path)
        }
    }

    func testBothAppsExposeActivityUsingTheSharedAuditStore() throws {
        let platformFiles = [
            ("iOSApp/RootView.swift", "AppBootstrap.makeActivityViewModel()"),
            ("MacOSApp/MacRootView.swift", "MacAppBootstrap.makeActivityViewModel()")
        ]
        for (path, factory) in platformFiles {
            let source = try String(contentsOf: repositoryFile(path))
            XCTAssertTrue(source.contains("case activity"), path)
            XCTAssertTrue(source.contains(factory), path)
            XCTAssertTrue(source.contains("ActivityView(viewModel: activityVM)"), path)
        }

        for path in ["iOSApp/AppBootstrap.swift", "MacOSApp/MacAppBootstrap.swift"] {
            let source = try String(contentsOf: repositoryFile(path))
            XCTAssertTrue(source.contains("static let auditLog = AuditLogStore()"), path)
            XCTAssertTrue(source.contains("auditLog: auditLog"), path)
            XCTAssertTrue(source.contains("ActivityViewModel(provider: auditLog)"), path)
        }
    }

    private func repositoryFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}
