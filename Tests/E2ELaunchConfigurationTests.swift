import XCTest
@testable import SignstrCore

#if DEBUG
final class E2ELaunchConfigurationTests: XCTestCase {
    func testDisabledOrInvalidEnvironmentDoesNotCreateConfiguration() {
        XCTAssertNil(E2ELaunchConfiguration(environment: [:]))
        XCTAssertNil(E2ELaunchConfiguration(environment: [
            E2ELaunchConfiguration.enabledEnvironmentKey: "0",
            E2ELaunchConfiguration.nsecEnvironmentKey: TestVectors.nsec
        ]))
        XCTAssertNil(E2ELaunchConfiguration(environment: [
            E2ELaunchConfiguration.enabledEnvironmentKey: "1",
            E2ELaunchConfiguration.nsecEnvironmentKey: "not-an-nsec"
        ]))
    }

    func testEnabledEnvironmentSeedsAnIsolatedActiveCapableIdentityAndVolatileKey() async throws {
        let configuration = try XCTUnwrap(E2ELaunchConfiguration(environment: [
            E2ELaunchConfiguration.enabledEnvironmentKey: "1",
            E2ELaunchConfiguration.nsecEnvironmentKey: TestVectors.nsec
        ]))

        XCTAssertEqual(configuration.identity.id, E2ELaunchConfiguration.identityID)
        XCTAssertEqual(configuration.identity.npub, TestVectors.npub)
        XCTAssertNil(configuration.pairingURL)

        let identities = configuration.makeIdentityStore()
        let seededIdentities = await identities.list()
        let initialActiveIdentityID = await identities.activeIdentityID()
        XCTAssertEqual(seededIdentities, [configuration.identity])
        XCTAssertNil(initialActiveIdentityID)
        await identities.setActive(identityID: configuration.identity.id)
        let activeIdentityID = await identities.activeIdentityID()
        XCTAssertEqual(activeIdentityID, configuration.identity.id)

        let keys = configuration.makeNsecStore()
        let initiallyPresent = await keys.hasNsec(for: configuration.identity.id)
        let initialNsec = await keys.loadNsec(for: configuration.identity.id)
        XCTAssertTrue(initiallyPresent)
        XCTAssertEqual(initialNsec, TestVectors.nsec)
        await keys.deleteNsec(for: configuration.identity.id)
        let presentAfterDelete = await keys.hasNsec(for: configuration.identity.id)
        XCTAssertFalse(presentAfterDelete)
        await keys.saveNsec(TestVectors.otherNsec, for: configuration.identity.id)
        let replacedNsec = await keys.loadNsec(for: configuration.identity.id)
        XCTAssertEqual(replacedNsec, TestVectors.otherNsec)
    }

    func testPairingURLOnlyAcceptsNostrConnectURLs() throws {
        let pairingURL = "nostrconnect://\(TestVectors.pubkeyHex)?relay=wss%3A%2F%2Frelay.example&secret=test"
        let configuration = try XCTUnwrap(E2ELaunchConfiguration(environment: [
            E2ELaunchConfiguration.enabledEnvironmentKey: "1",
            E2ELaunchConfiguration.nsecEnvironmentKey: TestVectors.nsec,
            E2ELaunchConfiguration.pairingEnvironmentKey: pairingURL
        ]))
        XCTAssertEqual(configuration.pairingURL?.absoluteString, pairingURL)

        let unsafeConfiguration = try XCTUnwrap(E2ELaunchConfiguration(environment: [
            E2ELaunchConfiguration.enabledEnvironmentKey: "1",
            E2ELaunchConfiguration.nsecEnvironmentKey: TestVectors.nsec,
            E2ELaunchConfiguration.pairingEnvironmentKey: "https://example.com"
        ]))
        XCTAssertNil(unsafeConfiguration.pairingURL)
    }
}
#endif
