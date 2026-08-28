import XCTest
@testable import SignstrCore

@MainActor
final class KeysViewModelTests: XCTestCase {
    private func makeViewModel(
        nsecStore: InMemoryNsecStore = InMemoryNsecStore(),
        profileLookup: any NostrProfileLookingUp = NoopNostrProfileLookup()
    ) -> (KeysViewModel, IdentityStore, InMemoryNsecStore) {
        let identityStore = IdentityStore(defaults: makeEphemeralDefaults())
        return (
            KeysViewModel(
                identityStore: identityStore,
                nsecStore: nsecStore,
                profileLookup: profileLookup
            ),
            identityStore,
            nsecStore
        )
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
        XCTAssertEqual(viewModel.identities.first?.origin, .imported)
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

    func testGeneratingKeyStoresAValidNsecAndMakesTheFirstKeyActive() async {
        let (viewModel, identityStore, store) = makeViewModel()
        viewModel.displayName = "Generated"

        await viewModel.generateKey()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.identities.first?.displayName, "Generated")
        XCTAssertEqual(viewModel.identities.first?.origin, .generated)
        guard let identity = viewModel.identities.first else {
            return XCTFail("Expected a generated identity")
        }
        let stored = try? await store.loadNsec(for: identity.id)
        XCTAssertNotNil(stored)
        XCTAssertNoThrow(try NostrKeyDeriver.deriveNpub(fromNsec: stored ?? ""))
        let activeIdentityID = await identityStore.activeIdentityID()
        XCTAssertEqual(activeIdentityID, identity.id)
    }

    func testProtectedStorageFailureDoesNotCreateGeneratedIdentity() async {
        let identityStore = IdentityStore(defaults: makeEphemeralDefaults())
        let viewModel = KeysViewModel(
            identityStore: identityStore,
            nsecStore: ProtectedStorageFailingNsecStore()
        )

        await viewModel.generateKey()

        XCTAssertEqual(
            viewModel.errorMessage,
            "Keychain could not create protected storage. Please try again. (error -34010)"
        )
        XCTAssertTrue(viewModel.identities.isEmpty)
        let persistedIdentities = await identityStore.list()
        XCTAssertTrue(persistedIdentities.isEmpty)
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

    func testSavedStatusFadesAfterItsDisplayWindow() async {
        let identityStore = IdentityStore(defaults: makeEphemeralDefaults())
        let viewModel = KeysViewModel(
            identityStore: identityStore,
            nsecStore: InMemoryNsecStore(),
            statusDuration: .milliseconds(10)
        )
        viewModel.nsec = TestVectors.nsec

        await viewModel.addKey()
        XCTAssertEqual(viewModel.statusMessage, "Saved Key 1.")

        let deadline = ContinuousClock.now + .seconds(1)
        while viewModel.statusMessage != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(viewModel.statusMessage)
    }

    func testUnnamedKeysGetGeneratedNames() async {
        let (viewModel, _, _) = makeViewModel()
        viewModel.nsec = TestVectors.nsec
        await viewModel.addKey()
        viewModel.nsec = TestVectors.otherNsec
        await viewModel.addKey()

        XCTAssertEqual(viewModel.identities.map(\.displayName), ["Key 1", "Key 2"])
    }

    func testImportedKeyUsesVerifiedNIP05AsSuggestedName() async {
        let lookup = StubProfileLookup(
            metadata: NostrProfileMetadata(displayName: "Kasper", nip05: "kasper@trustroots.org")
        )
        let (viewModel, _, _) = makeViewModel(profileLookup: lookup)
        viewModel.nsec = TestVectors.nsec

        await viewModel.addKey()

        XCTAssertEqual(viewModel.identities.first?.displayName, "kasper@trustroots.org")
        let lookedUpPubkeys = await lookup.lookedUpPubkeys()
        XCTAssertEqual(lookedUpPubkeys, [TestVectors.pubkeyHex])
    }

    func testImportedKeyFallsBackToProfileNameWithoutNIP05() async {
        let lookup = StubProfileLookup(metadata: NostrProfileMetadata(displayName: "Kasper"))
        let (viewModel, _, _) = makeViewModel(profileLookup: lookup)
        viewModel.nsec = TestVectors.nsec

        await viewModel.addKey()

        XCTAssertEqual(viewModel.identities.first?.displayName, "Kasper")
    }

    func testGeneratedKeyDoesNotPerformProfileLookup() async {
        let lookup = StubProfileLookup(
            metadata: NostrProfileMetadata(displayName: "Should not be used", nip05: "no@example.com")
        )
        let (viewModel, _, _) = makeViewModel(profileLookup: lookup)

        await viewModel.generateKey()

        XCTAssertEqual(viewModel.identities.first?.displayName, "Key 1")
        let lookedUpPubkeys = await lookup.lookedUpPubkeys()
        XCTAssertTrue(lookedUpPubkeys.isEmpty)
    }

    func testSyncChecksExistingKeysAndStoresVerifiedNIP05() async {
        let lookup = StubProfileLookup(
            metadata: NostrProfileMetadata(displayName: "Remote name", nip05: "kasper@trustroots.org")
        )
        let (viewModel, identityStore, _) = makeViewModel(profileLookup: lookup)
        await identityStore.add(Identity(id: "known", displayName: "Personal", npub: TestVectors.npub))
        await viewModel.refresh()

        await viewModel.syncNIP05()

        XCTAssertEqual(viewModel.identities.first?.displayName, "Personal")
        XCTAssertEqual(viewModel.identities.first?.nip05, "kasper@trustroots.org")
        XCTAssertEqual(viewModel.statusMessage, "Checked 1 key. Found 1 NIP-05 address.")
        let lookedUpPubkeys = await lookup.lookedUpPubkeys()
        XCTAssertEqual(lookedUpPubkeys, [TestVectors.pubkeyHex])
    }

    func testSyncDescribesConfiguredRelaysAndMultipleResults() async {
        let lookup = StubProfileLookup(
            metadata: NostrProfileMetadata(nip05: "verified@example.com"),
            relayURLs: [URL(string: "wss://relay.example")!]
        )
        let (viewModel, identityStore, _) = makeViewModel(profileLookup: lookup)
        await identityStore.add(Identity(id: "one", displayName: "One", npub: TestVectors.npub))
        await identityStore.add(Identity(id: "two", displayName: "Two", npub: TestVectors.otherNpub))
        await viewModel.refresh()

        await viewModel.syncNIP05()

        XCTAssertEqual(viewModel.statusMessage, "Checked 2 keys. Found 2 NIP-05 addresses.")
    }

    func testSyncExposesTheRelaysBeingChecked() async {
        let lookup = StubProfileLookup(
            metadata: nil,
            relayURLs: [
                URL(string: "wss://relay.nomadwiki.org")!,
                URL(string: "wss://relay.trustroots.org")!
            ]
        )
        let (viewModel, _, _) = makeViewModel(profileLookup: lookup)

        XCTAssertEqual(
            viewModel.syncRelayHosts,
            ["relay.nomadwiki.org", "relay.trustroots.org"]
        )
        XCTAssertEqual(
            viewModel.syncRelayDescriptions,
            [
                "relay.nomadwiki.org (kinds 0, 10390)",
                "relay.trustroots.org (kinds 0, 10390)"
            ]
        )
    }

    func testSyncDoesNotReplaceExistingNIP05WhenLookupFindsNone() async {
        let lookup = StubProfileLookup(metadata: nil)
        let (viewModel, identityStore, _) = makeViewModel(profileLookup: lookup)
        await identityStore.add(
            Identity(
                id: "known",
                displayName: "Personal",
                npub: TestVectors.npub,
                nip05: "existing@example.com"
            )
        )
        await viewModel.refresh()

        await viewModel.syncNIP05()

        XCTAssertEqual(viewModel.identities.first?.nip05, "existing@example.com")
        XCTAssertEqual(viewModel.statusMessage, "Checked 1 key. Found 0 NIP-05 addresses.")
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

    func testPasteWithOnlyWhitespaceIsRejected() {
        let (viewModel, _, _) = makeViewModel()

        viewModel.applyPastedValue("   \n  ")

        XCTAssertEqual(viewModel.errorMessage, "The clipboard is empty.")
        XCTAssertEqual(viewModel.nsec, "")
    }

    func testHideAllRevealedKeysClearsState() async {
        let (viewModel, _, _) = makeViewModel()
        viewModel.nsec = TestVectors.nsec
        await viewModel.addKey()
        let identity = viewModel.identities[0]

        await viewModel.toggleReveal(identity)
        viewModel.hideAllRevealedKeys()

        XCTAssertTrue(viewModel.revealedNsecs.isEmpty)
        XCTAssertEqual(viewModel.nsec, "")
    }

    func testSyncNIP05SkipsWhenNoIdentitiesAreLoaded() async {
        let (viewModel, _, _) = makeViewModel(profileLookup: StubProfileLookup(metadata: nil))
        await viewModel.refresh()

        await viewModel.syncNIP05()

        XCTAssertNil(viewModel.statusMessage)
        XCTAssertEqual(viewModel.identities.count, 0)
    }
}

private actor ProtectedStorageFailingNsecStore: NsecStoring {
    func saveNsec(_ nsec: String, for identityID: String) async throws {
        throw NsecStoreError.unexpectedStatus(-34010)
    }

    func loadNsec(for identityID: String) async -> String? { nil }

    func hasNsec(for identityID: String) async -> Bool { false }

    func deleteNsec(for identityID: String) async {}
}
