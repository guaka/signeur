import Foundation
import SignstrCore
import UIKit

enum AppBootstrap {
    static let permissionStore = PermissionRuleStore()
    static let identityStore = IdentityStore(seed: [])
    static let nsecStore = NsecKeychainStore()
    static let connectionStore = ConnectionStore()
    static let executor = NIP46MethodExecutor(nsecStore: nsecStore)
    static let relayPool = NostrRelayPool()

    static let relayTransport = NIP46RelayTransport(
        pool: relayPool,
        connections: connectionStore,
        nsecStore: nsecStore
    )

    /// Returns NIP-55 results to the app that opened us, falling back to the clipboard.
    static let callbackTransport = NIP55CallbackTransport(
        openURL: { url in
            await MainActor.run {
                guard UIApplication.shared.canOpenURL(url) else { return false }
                UIApplication.shared.open(url)
                return true
            }
        },
        copyToClipboard: { value in
            Task { @MainActor in UIPasteboard.general.string = value }
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

    /// Reconnects to the relays of every app that was already approved.
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
        KeysViewModel(identityStore: identityStore, nsecStore: nsecStore)
    }

    @MainActor
    static func makePairingViewModel() -> PairingViewModel {
        PairingViewModel(coordinator: routingCoordinator)
    }
}
