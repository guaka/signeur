import XCTest
@testable import SigneurCore

final class StoredConnectionsProviderTests: XCTestCase {
    private func makeStore() -> ConnectionStore {
        ConnectionStore(defaults: makeEphemeralDefaults())
    }

    private func connection(pubkey: String, name: String?, approved: Bool = true) -> AppConnection {
        AppConnection(
            appPubkey: pubkey,
            appName: name,
            relays: ["wss://relay.one"],
            identityID: "id-1",
            isApproved: approved
        )
    }

    func testOnlyApprovedConnectionsAreListed() async {
        let store = makeStore()
        await store.upsert(connection(pubkey: "approved", name: "Amethyst"))
        await store.upsert(connection(pubkey: "pending", name: "Damus", approved: false))

        let apps = await StoredConnectionsProvider(connections: store).listConnectedApps()

        XCTAssertEqual(apps.map(\.appPubkey), ["approved"])
        XCTAssertEqual(apps.first?.appName, "Amethyst")
    }

    func testAnAppWithoutRememberedPermissionsSaysItAsksEveryTime() async {
        let store = makeStore()
        await store.upsert(connection(pubkey: "app-1", name: "Amethyst"))

        let apps = await StoredConnectionsProvider(connections: store).listConnectedApps()

        XCTAssertEqual(apps.first?.methods, ["asks you every time"])
    }

    func testRememberedMethodsAreShownAgainstTheConnection() async {
        let store = makeStore()
        await store.upsert(connection(pubkey: "app-1", name: "Amethyst"))
        let permissions = StubPermissions(items: [
            ConnectedAppItem(appName: "Amethyst", appPubkey: "app-1", methods: ["sign_event", "ping"])
        ])

        let apps = await StoredConnectionsProvider(connections: store, permissions: permissions).listConnectedApps()

        XCTAssertEqual(apps.first?.methods, ["sign_event", "ping"])
    }

    func testConnectionMetadataIsExposedForTheDetailScreen() async {
        let store = makeStore()
        let connectedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let lastUsedAt = Date(timeIntervalSince1970: 1_700_000_100)
        await store.upsert(
            AppConnection(
                appPubkey: "app-1",
                appName: "Amethyst",
                appURL: "https://example.com",
                relays: ["wss://relay.one"],
                requestedPermissions: ["sign_event", "nip44_decrypt"],
                identityID: "id-1",
                isApproved: true,
                usesLegacyEncryption: true,
                createdAt: connectedAt,
                lastUsedAt: lastUsedAt
            )
        )
        let identities = IdentityStore(
            defaults: makeEphemeralDefaults(),
            seed: [Identity(id: "id-1", displayName: "Main")]
        )

        let app = await StoredConnectionsProvider(
            connections: store,
            identities: identities
        ).listConnectedApps().first

        XCTAssertEqual(app?.appURL, "https://example.com")
        XCTAssertEqual(app?.relays, ["wss://relay.one"])
        XCTAssertEqual(app?.requestedPermissions, ["sign_event", "nip44_decrypt"])
        XCTAssertEqual(app?.identityName, "Main")
        XCTAssertEqual(app?.createdAt, connectedAt)
        XCTAssertEqual(app?.lastUsedAt, lastUsedAt)
        XCTAssertEqual(app?.usesLegacyEncryption, true)
    }

    func testAnAppWithoutANameIsStillShown() async {
        let store = makeStore()
        await store.upsert(connection(pubkey: "app-1", name: nil))

        let apps = await StoredConnectionsProvider(connections: store).listConnectedApps()

        XCTAssertEqual(apps.first?.appName, "Unknown app")
    }

    func testDisconnectingForgetsTheConnectionAndItsPermissions() async {
        let store = makeStore()
        await store.upsert(connection(pubkey: "app-1", name: "Amethyst"))
        let permissions = StubPermissions(items: [])
        let provider = StoredConnectionsProvider(connections: store, permissions: permissions)

        await provider.revoke(appPubkey: "app-1")

        let remaining = await store.all()
        let revoked = await permissions.revokedPubkeys()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(revoked, ["app-1"])
    }
}

private actor StubPermissions: ConnectedAppsProviding {
    private let items: [ConnectedAppItem]
    private var revoked: [String] = []

    init(items: [ConnectedAppItem]) {
        self.items = items
    }

    func listConnectedApps() async -> [ConnectedAppItem] { items }

    func revoke(appPubkey: String) async { revoked.append(appPubkey) }

    func revokedPubkeys() -> [String] { revoked }
}
