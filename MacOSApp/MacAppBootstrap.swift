import AppKit
import Foundation
import SignstrCore

enum MacAppBootstrap {
    static let permissionStore = PermissionRuleStore()
    static let identityStore = IdentityStore(seed: [])
    static let nsecStore = NsecKeychainStore()
    static let connectionStore = ConnectionStore()
    static let executor = NIP46MethodExecutor(nsecStore: nsecStore)
    static let relayPool = NostrRelayPool()
    static let profileLookup = RelayNostrProfileLookup()

    static let relayTransport = NIP46RelayTransport(
        pool: relayPool,
        connections: connectionStore,
        nsecStore: nsecStore
    )

    static let callbackTransport = NIP55CallbackTransport(
        openURL: { url in
            await MainActor.run { NSWorkspace.shared.open(url) }
        },
        copyToClipboard: { value in
            Task { @MainActor in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(120))
                    guard NSPasteboard.general.string(forType: .string) == value else { return }
                    NSPasteboard.general.clearContents()
                }
            }
        }
    )

    static let manager = NIP46SessionManager(
        validator: NIP46Validator(),
        executor: executor,
        transport: RoutingTransport(callbackTransport: callbackTransport, relayTransport: relayTransport),
        authorizationGuard: AuthorizationGuard(),
        permissionEvaluator: permissionStore
    )

    static let relayListener = NIP46RelayListener(
        pool: relayPool,
        connections: connectionStore,
        nsecStore: nsecStore,
        identities: identityStore,
        coordinator: routingCoordinator
    )

    static let connectionActivator = ConnectionActivator(
        connections: connectionStore,
        listener: relayListener
    )

    static let routingCoordinator: RequestRoutingCoordinator = {
        RequestRoutingCoordinator(
            sessionManager: manager,
            connectionRegistry: ConnectionActivator(connections: connectionStore),
            activeIdentityID: { await identityStore.activeIdentityID() },
            callbackTransport: callbackTransport
        )
    }()

    static func startListening() async {
        await relayListener.start()
    }

    @MainActor
    static func makeSessionViewModel() -> SessionViewModel {
        SessionViewModel(
            sessionManager: manager,
            identityStore: identityStore,
            connectionRegistry: connectionActivator
        )
    }

    @MainActor
    static func makeConnectedAppsViewModel() -> ConnectedAppsViewModel {
        ConnectedAppsViewModel(
            provider: StoredConnectionsProvider(
                connections: connectionStore,
                permissions: permissionStore,
                identities: identityStore
            )
        )
    }

    @MainActor
    static func makeKeysViewModel() -> KeysViewModel {
        KeysViewModel(identityStore: identityStore, nsecStore: nsecStore, profileLookup: profileLookup)
    }

    @MainActor
    static func makePairingViewModel() -> PairingViewModel {
        PairingViewModel(coordinator: routingCoordinator)
    }
}
