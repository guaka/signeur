import XCTest
@testable import SignstrCore

@MainActor
final class KeysViewModelTests: XCTestCase {
    private func makeViewModel(
        nsecStore: InMemoryNsecStore = InMemoryNsecStore()
    ) -> (KeysViewModel, IdentityStore, InMemoryNsecStore) {
        let identityStore = IdentityStore(defaults: makeEphemeralDefaults())
        return (KeysViewModel(identityStore: identityStore, nsecStore: nsecStore), identityStore, nsecStore)
    }

    func testSaveIsBlockedOnlyByMissingNsec() async {
        let (viewModel, _, _) = makeViewModel()
        XCTAssertFalse(viewModel.canSave)

        viewModel.nsec = TestVectors.nsec
        XCTAssertTrue(viewModel.canSave, "a display name must not be required to save a key")
    }

    func testAddingKeyStoresNsecAndDerivesNpub() async {
        let (viewModel, _, store) = makeViewModel()
        viewModel.nsec = TestVectors.nsec

        await viewModel.addKey()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.identities.count, 1)
        XCTAssertEqual(viewModel.identities.first?.npub, TestVectors.npub)
        let identityID = viewModel.identities[0].id
        let stored = try? await store.loadNsec(for: identityID)
        XCTAssertEqual(stored, TestVectors.nsec)
        XCTAssertEqual(viewModel.keyPresence[identityID], true)
    }

    func testAddingFirstKeyMakesItActive() async {
        let (viewModel, identityStore, _) = makeViewModel()
        viewModel.nsec = TestVectors.nsec

        await viewModel.addKey()

        let active = await identityStore.activeIdentityID()
        XCTAssertEqual(active, viewModel.identities.first?.id)
        XCTAssertEqual(viewModel.activeIdentityID, active)
    }

    func testAddingSecondKeyLeavesFirstActive() async {
        let (viewModel, _, _) = makeViewModel()
        viewModel.nsec = TestVectors.nsec
        await viewModel.addKey()
        let firstID = viewModel.identities[0].id

        viewModel.nsec = TestVectors.otherNsec
        await viewModel.addKey()

        XCTAssertEqual(viewModel.identities.count, 2)
        XCTAssertEqual(viewModel.activeIdentityID, firstID)
    }

    func testAddingKeyClearsInputAndReportsStatus() async {
        let (viewModel, _, _) = makeViewModel()
        viewModel.displayName = "Main"
        viewModel.nsec = TestVectors.nsec

        await viewModel.addKey()

        XCTAssertTrue(viewModel.nsec.isEmpty)
        XCTAssertTrue(viewModel.displayName.isEmpty)
        XCTAssertEqual(viewModel.statusMessage, "Saved Main.")
        XCTAssertEqual(viewModel.identities.first?.displayName, "Main")
    }

    func testUnnamedKeysGetGeneratedNames() async {
        let (viewModel, _, _) = makeViewModel()
        viewModel.nsec = TestVectors.nsec
        await viewModel.addKey()
        viewModel.nsec = TestVectors.otherNsec
        await viewModel.addKey()

        XCTAssertEqual(viewModel.identities.map(\.displayName), ["Key 1", "Key 2"])
    }

    func testAcceptsPastedKeyWithWhitespaceAndCasing() async {
        let (viewModel, _, _) = makeViewModel()
        viewModel.nsec = "  \(TestVectors.nsec.uppercased())  "

        await viewModel.addKey()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.identities.first?.npub, TestVectors.npub)
    }

    func testRejectsNpubPastedAsPrivateKey() async {
        let (viewModel, _, _) = makeViewModel()
        viewModel.nsec = TestVectors.npub

        await viewModel.addKey()

        XCTAssertEqual(viewModel.identities.count, 0)
        XCTAssertTrue(viewModel.errorMessage?.contains("nsec1") == true)
    }

    func testRejectsCorruptedKeyWithoutCreatingIdentity() async {
        let (viewModel, _, store) = makeViewModel()
        viewModel.nsec = String(TestVectors.nsec.dropLast()) + "q"

        await viewModel.addKey()

        XCTAssertEqual(viewModel.identities.count, 0)
        let storedCount = await store.storedCount()
        XCTAssertEqual(storedCount, 0)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    func testRejectsDuplicateKey() async {
        let (viewModel, _, _) = makeViewModel()
        viewModel.displayName = "Main"
        viewModel.nsec = TestVectors.nsec
        await viewModel.addKey()

        viewModel.nsec = TestVectors.nsec
        await viewModel.addKey()

        XCTAssertEqual(viewModel.identities.count, 1)
        XCTAssertEqual(viewModel.errorMessage, "This key is already stored as \"Main\".")
    }

    func testStorageFailureSurfacesReasonAndSkipsIdentity() async {
        let (viewModel, identityStore, _) = makeViewModel(nsecStore: InMemoryNsecStore(failOnSave: true))
        viewModel.nsec = TestVectors.nsec

        await viewModel.addKey()

        XCTAssertEqual(viewModel.errorMessage, "Stub storage refused to write.")
        XCTAssertEqual(viewModel.identities.count, 0)
        let persisted = await identityStore.list()
        XCTAssertTrue(persisted.isEmpty, "a failed save must not leave an identity that cannot sign")
    }

    func testRevealTogglesStoredKey() async {
        let (viewModel, _, _) = makeViewModel()
        viewModel.nsec = TestVectors.nsec
        await viewModel.addKey()
        let identity = viewModel.identities[0]

        await viewModel.toggleReveal(identity)
        XCTAssertEqual(viewModel.revealedNsecs[identity.id], TestVectors.nsec)

        await viewModel.toggleReveal(identity)
        XCTAssertNil(viewModel.revealedNsecs[identity.id])
    }

    func testRevealReportsStorageFailure() async {
        let store = InMemoryNsecStore(keys: ["known": TestVectors.nsec], failOnLoad: true)
        let (viewModel, identityStore, _) = makeViewModel(nsecStore: store)
        await identityStore.add(Identity(id: "known", displayName: "Known", npub: TestVectors.npub))
        await viewModel.refresh()

        await viewModel.toggleReveal(viewModel.identities[0])

        XCTAssertNil(viewModel.revealedNsecs["known"])
        XCTAssertEqual(viewModel.errorMessage, "Stub storage refused to write.")
    }

    func testDeleteRemovesIdentityAndStoredKey() async {
        let (viewModel, identityStore, store) = makeViewModel()
        viewModel.nsec = TestVectors.nsec
        await viewModel.addKey()
        let identity = viewModel.identities[0]
        await viewModel.toggleReveal(identity)

        await viewModel.deleteIdentity(identity)

        XCTAssertTrue(viewModel.identities.isEmpty)
        XCTAssertNil(viewModel.revealedNsecs[identity.id])
        let storedCount = await store.storedCount()
        XCTAssertEqual(storedCount, 0)
        let remaining = await identityStore.list()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testRefreshFlagsIdentityWithoutStoredKey() async {
        let (viewModel, identityStore, _) = makeViewModel()
        await identityStore.add(Identity(id: "orphan", displayName: "Orphan", npub: TestVectors.npub))

        await viewModel.refresh()

        XCTAssertEqual(viewModel.keyPresence["orphan"], false)
    }

    func testPasteAppliesClipboardValue() {
        let (viewModel, _, _) = makeViewModel()

        viewModel.applyPastedValue("  \(TestVectors.nsec) ")
        XCTAssertEqual(viewModel.nsec, TestVectors.nsec)
        XCTAssertNil(viewModel.errorMessage)

        viewModel.applyPastedValue(nil)
        XCTAssertEqual(viewModel.errorMessage, "The clipboard is empty.")
    }
}
