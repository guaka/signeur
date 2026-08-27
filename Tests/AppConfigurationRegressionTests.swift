import Foundation
import XCTest

final class AppConfigurationRegressionTests: XCTestCase {
    func testMacTargetCarriesItsKeychainEntitlements() throws {
        let entitlementsData = try Data(contentsOf: repositoryFile("MacOSApp/SignstrMac.entitlements"))
        let entitlements = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: entitlementsData, format: nil) as? [String: Any]
        )
        let groups = try XCTUnwrap(entitlements["keychain-access-groups"] as? [String])

        XCTAssertEqual(groups, ["$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)"])

        let project = try String(contentsOf: repositoryFile("Signstr.xcodeproj/project.pbxproj"))
        XCTAssertTrue(project.contains("CODE_SIGN_ENTITLEMENTS = MacOSApp/SignstrMac.entitlements;"))
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

    private func repositoryFile(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
    }
}
