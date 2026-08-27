import XCTest
@testable import SignstrCore

final class IdentityStoreTests: XCTestCase {
    func testSeedIsUsedWhenNothingPersisted() async {
        let store = IdentityStore(defaults: makeEphemeralDefaults(), seed: [Identity(id: "a", displayName: "A")])
        let identities = await store.list()
        XCTAssertEqual(identities.map(\.id), ["a"])
    }

    func testIdentitiesSurviveANewStoreInstance() async {
        let defaults = makeEphemeralDefaults()
        let store = IdentityStore(defaults: defaults)
        await store.add(Identity(id: "a", displayName: "A", npub: TestVectors.npub))
        await store.setActive(identityID: "a")

        let reloaded = IdentityStore(defaults: defaults)
        let identities = await reloaded.list()
        let active = await reloaded.activeIdentityID()

        XCTAssertEqual(identities.map(\.id), ["a"])
        XCTAssertEqual(identities.first?.npub, TestVectors.npub)
        XCTAssertEqual(active, "a")
    }

    func testPersistedIdentitiesWinOverSeed() async {
        let defaults = makeEphemeralDefaults()
        let store = IdentityStore(defaults: defaults)
        await store.add(Identity(id: "persisted", displayName: "Persisted"))

        let reloaded = IdentityStore(defaults: defaults, seed: [Identity(id: "seed", displayName: "Seed")])
        let identities = await reloaded.list()

        XCTAssertEqual(identities.map(\.id), ["persisted"])
    }

    func testAddIgnoresDuplicateIdentityIDs() async {
        let store = IdentityStore(defaults: makeEphemeralDefaults())
        await store.add(Identity(id: "a", displayName: "First"))
        await store.add(Identity(id: "a", displayName: "Second"))

        let identities = await store.list()
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities.first?.displayName, "First")
    }

    func testDeletingActiveIdentityPromotesAnother() async {
        let store = IdentityStore(defaults: makeEphemeralDefaults())
        await store.add(Identity(id: "a", displayName: "A"))
        await store.add(Identity(id: "b", displayName: "B"))
        await store.setActive(identityID: "a")

        await store.delete(identityID: "a")

        let active = await store.activeIdentityID()
        XCTAssertEqual(active, "b")
    }

    func testDeletingLastIdentityClearsActiveSelection() async {
        let store = IdentityStore(defaults: makeEphemeralDefaults())
        await store.add(Identity(id: "a", displayName: "A"))
        await store.setActive(identityID: "a")

        await store.delete(identityID: "a")

        let active = await store.activeIdentityID()
        let identities = await store.list()
        XCTAssertNil(active)
        XCTAssertTrue(identities.isEmpty)
    }

    func testDeletingInactiveIdentityKeepsActiveSelection() async {
        let store = IdentityStore(defaults: makeEphemeralDefaults())
        await store.add(Identity(id: "a", displayName: "A"))
        await store.add(Identity(id: "b", displayName: "B"))
        await store.setActive(identityID: "a")

        await store.delete(identityID: "b")

        let active = await store.activeIdentityID()
        XCTAssertEqual(active, "a")
    }
}
