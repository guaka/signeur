import XCTest
@testable import SignstrCore

final class PermissionRuleStoreTests: XCTestCase {
    func testNothingIsAutoApprovedByDefault() async {
        let store = PermissionRuleStore(defaults: makeEphemeralDefaults())
        let approved = await store.shouldAutoApprove(request: makeTestRequest())
        XCTAssertFalse(approved)
    }

    func testRememberedSignEventAppliesToSameAppAndKind() async {
        let store = PermissionRuleStore(defaults: makeEphemeralDefaults())
        let request = makeTestRequest(payload: "{\"kind\":1,\"content\":\"note\"}")

        await store.saveRememberRule(for: request)

        let approved = await store.shouldAutoApprove(request: request)
        XCTAssertTrue(approved)
    }

    func testRememberedSignEventDoesNotCoverOtherKinds() async {
        let store = PermissionRuleStore(defaults: makeEphemeralDefaults())
        await store.saveRememberRule(for: makeTestRequest(payload: "{\"kind\":1}"))

        let otherKind = makeTestRequest(id: "req-2", payload: "{\"kind\":4}")
        let approved = await store.shouldAutoApprove(request: otherKind)
        XCTAssertFalse(approved, "approving kind 1 must not silently approve DMs")
    }

    func testRememberedRuleDoesNotCoverOtherApps() async {
        let store = PermissionRuleStore(defaults: makeEphemeralDefaults())
        await store.saveRememberRule(for: makeTestRequest(appPubkey: "app-a"))

        let otherApp = makeTestRequest(id: "req-2", appPubkey: "app-b")
        let approved = await store.shouldAutoApprove(request: otherApp)
        XCTAssertFalse(approved)
    }

    func testRememberedNonSigningMethodIgnoresKind() async {
        let store = PermissionRuleStore(defaults: makeEphemeralDefaults())
        let request = makeTestRequest(id: "p1", method: .getPublicKey, payload: "{}")
        await store.saveRememberRule(for: request)

        let approved = await store.shouldAutoApprove(request: request)
        XCTAssertTrue(approved)

        let differentMethod = makeTestRequest(id: "p2", method: .ping, payload: "{}")
        let pingApproved = await store.shouldAutoApprove(request: differentMethod)
        XCTAssertFalse(pingApproved)
    }

    func testConnectedAppsGroupRulesByAppWithNames() async {
        let store = PermissionRuleStore(defaults: makeEphemeralDefaults())
        await store.saveRememberRule(for: makeTestRequest(appName: "Nostrudel", appPubkey: "app-a", payload: "{\"kind\":1}"))
        await store.saveRememberRule(for: makeTestRequest(id: "r2", appName: "Nostrudel", appPubkey: "app-a", payload: "{\"kind\":7}"))
        await store.saveRememberRule(for: makeTestRequest(id: "r3", method: .ping, appName: "Amethyst", appPubkey: "app-b", payload: "{}"))

        let apps = await store.listConnectedApps()

        XCTAssertEqual(apps.map(\.appName), ["Amethyst", "Nostrudel"])
        XCTAssertEqual(apps.first(where: { $0.appPubkey == "app-a" })?.methods, ["sign_event:1", "sign_event:7"])
        XCTAssertEqual(apps.first(where: { $0.appPubkey == "app-b" })?.methods, ["ping"])
    }

    func testUnnamedAppsAreLabelled() async {
        let store = PermissionRuleStore(defaults: makeEphemeralDefaults())
        await store.saveRememberRule(for: makeTestRequest(appName: nil))

        let apps = await store.listConnectedApps()
        XCTAssertEqual(apps.map(\.appName), ["Unknown app"])
    }

    func testRevokeRemovesOnlyThatAppsRules() async {
        let store = PermissionRuleStore(defaults: makeEphemeralDefaults())
        let keptRequest = makeTestRequest(id: "r2", appPubkey: "app-b")
        await store.saveRememberRule(for: makeTestRequest(appPubkey: "app-a"))
        await store.saveRememberRule(for: keptRequest)

        await store.revoke(appPubkey: "app-a")

        let revokedApproved = await store.shouldAutoApprove(request: makeTestRequest(appPubkey: "app-a"))
        let keptApproved = await store.shouldAutoApprove(request: keptRequest)
        let apps = await store.listConnectedApps()

        XCTAssertFalse(revokedApproved)
        XCTAssertTrue(keptApproved)
        XCTAssertEqual(apps.map(\.appPubkey), ["app-b"])
    }

    func testMalformedEventPayloadIsRememberedWithoutKind() async {
        let store = PermissionRuleStore(defaults: makeEphemeralDefaults())
        let request = makeTestRequest(params: ["not json"], payload: "not json")

        await store.saveRememberRule(for: request)
        let rules = try? await store.listRules()

        XCTAssertEqual(rules?.count, 1)
        XCTAssertNil(rules?.first?.kind)
    }
}
