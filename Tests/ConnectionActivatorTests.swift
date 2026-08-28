import Foundation
import XCTest
@testable import SignstrCore

final class ConnectionActivatorTests: XCTestCase {
    func testRegisterStoresPairingRequestsWithExpectedMetadata() async throws {
        let appPubkey = try NostrKeyDeriver.derivePublicKeyHex(fromNsec: TestVectors.otherNsec)
        let connections = ConnectionStore(defaults: makeEphemeralDefaults())
        let activator = ConnectionActivator(connections: connections)
        let pairing = DeepLinkRequest(
            clientPubkey: appPubkey,
            relays: ["wss://relay.one", "wss://relay.two"],
            secret: "secret",
            requestedPerms: ["sign_event", "nip44_encrypt"],
            appName: "Nostrudel",
            appURL: "https://nostrudel.app"
        )

        await activator.register(pairing: pairing, identityID: "id-1")

        let connection = await connections.connection(forAppPubkey: appPubkey)
        XCTAssertNotNil(connection)
        XCTAssertEqual(connection?.isApproved, false)
        XCTAssertEqual(connection?.appName, "Nostrudel")
        XCTAssertEqual(connection?.appURL, "https://nostrudel.app")
        XCTAssertEqual(connection?.requestedPermissions, ["sign_event", "nip44_encrypt"])
        XCTAssertEqual(connection?.relays, ["wss://relay.one", "wss://relay.two"])
        XCTAssertEqual(connection?.identityID, "id-1")
    }

    func testActivateMarksAppAsApprovedAndStartsListeningWhenListenerIsConfigured() async throws {
        let appPubkey = try NostrKeyDeriver.derivePublicKeyHex(fromNsec: TestVectors.otherNsec)
        let sockets = SocketRegistry()
        let pool = NostrRelayPool(socketFactory: { url in sockets.socket(for: url) })
        let connections = ConnectionStore(defaults: makeEphemeralDefaults())
        let identities = IdentityStore(
            defaults: makeEphemeralDefaults(),
            seed: [Identity(id: "id-1", displayName: "Main", npub: TestVectors.npub)]
        )
        let manager = NIP46SessionManager(
            validator: NIP46Validator(),
            executor: RecordingExecutor(),
            transport: RecordingTransport(),
            authorizationGuard: AuthorizationGuard()
        )
        let coordinator = RequestRoutingCoordinator(sessionManager: manager)
        let listener = NIP46RelayListener(
            pool: pool,
            connections: connections,
            nsecStore: InMemoryNsecStore(keys: ["id-1": TestVectors.nsec]),
            identities: identities,
            coordinator: coordinator,
            logger: RedactedLogger(emit: { _ in }),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let activator = ConnectionActivator(connections: connections, listener: listener)

        await activator.register(
            pairing: DeepLinkRequest(
                clientPubkey: appPubkey,
                relays: ["wss://relay.one"],
                secret: "secret",
                requestedPerms: [],
                appName: "Amethyst",
                appURL: nil
            ),
            identityID: "id-1"
        )

        let before = await connections.connection(forAppPubkey: appPubkey)
        XCTAssertEqual(before?.isApproved, false)

        await activator.activate(appPubkey: appPubkey)

        let connection = await connections.connection(forAppPubkey: appPubkey)
        XCTAssertEqual(connection?.isApproved, true)
        let frames = await sockets.socket(for: URL(string: "wss://relay.one")!).frames()
        XCTAssertTrue(
            frames.contains(where: { $0.hasPrefix("[\"REQ\",") }),
            "activating an approved app must reopen its listener subscription"
        )

        await pool.stop()
    }

    func testActivateApprovesPendingConnectionWithoutListener() async throws {
        let appPubkey = try NostrKeyDeriver.derivePublicKeyHex(fromNsec: TestVectors.otherNsec)
        let connections = ConnectionStore(defaults: makeEphemeralDefaults())
        await connections.upsert(
            AppConnection(
                appPubkey: appPubkey,
                appName: "Amethyst",
                relays: ["wss://relay.one"],
                identityID: "id-1",
                isApproved: false
            )
        )

        let activator = ConnectionActivator(connections: connections, listener: nil)

        await activator.activate(appPubkey: appPubkey)

        let connection = await connections.connection(forAppPubkey: appPubkey)
        XCTAssertEqual(connection?.isApproved, true)
    }

    func testActivateDoesNothingWhenConnectionDoesNotExist() async throws {
        let connections = ConnectionStore(defaults: makeEphemeralDefaults())
        let activator = ConnectionActivator(connections: connections, listener: nil)

        await activator.activate(appPubkey: "does-not-exist")

        let connection = await connections.connection(forAppPubkey: "does-not-exist")
        XCTAssertNil(connection)
    }

    func testForgettingConnectionRemovesItFromStore() async throws {
        let appPubkey = try NostrKeyDeriver.derivePublicKeyHex(fromNsec: TestVectors.otherNsec)
        let connections = ConnectionStore(defaults: makeEphemeralDefaults())
        await connections.upsert(
            AppConnection(
                appPubkey: appPubkey,
                appName: "Amethyst",
                relays: ["wss://relay.one"],
                identityID: "id-1"
            )
        )
        let activator = ConnectionActivator(connections: connections, listener: nil)

        await activator.forget(appPubkey: appPubkey)

        let connection = await connections.connection(forAppPubkey: appPubkey)
        XCTAssertNil(connection)
    }
}
