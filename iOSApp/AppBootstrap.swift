import Foundation
import SignstrCore
import UIKit

enum AppBootstrap {
    #if DEBUG
    static let e2eConfiguration = E2ELaunchConfiguration(environment: ProcessInfo.processInfo.environment)
    #endif
    static let permissionStore = PermissionRuleStore()
    static let identityStore: IdentityStore = {
        #if DEBUG
        if let e2eConfiguration { return e2eConfiguration.makeIdentityStore() }
        #endif
        return IdentityStore(seed: [])
    }()
    static let keychainStore = NsecKeychainStore()
    static let nsecStore: any NsecStoring = {
        #if DEBUG
        if let e2eConfiguration { return e2eConfiguration.makeNsecStore() }
        #endif
        return keychainStore
    }()
    static let connectionStore = ConnectionStore()
    static let auditLog = AuditLogStore()
    static let executor = NIP46MethodExecutor(nsecStore: nsecStore, identityStore: identityStore)
    static let relayPool = NostrRelayPool()
    static let profileLookup = RelayNostrProfileLookup()

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
            Task { @MainActor in
                UIPasteboard.general.setItems(
                    [["public.utf8-plain-text": value]],
                    options: [
                        .localOnly: true,
                        .expirationDate: Date().addingTimeInterval(120)
                    ]
                )
            }
        }
    )

    static let manager = NIP46SessionManager(
        validator: NIP46Validator(),
        executor: executor,
        transport: RoutingTransport(callbackTransport: callbackTransport, relayTransport: relayTransport),
        authorizationGuard: AuthorizationGuard(),
        permissionEvaluator: permissionStore,
        auditLog: auditLog
    )

    static let relayListener = NIP46RelayListener(
        pool: relayPool,
        connections: connectionStore,
        nsecStore: nsecStore,
        identities: identityStore,
        coordinator: routingCoordinator,
        onRequestReceived: {
            await MainActor.run {
                NotificationCenter.default.post(name: NIP46RelayListener.requestReceivedNotification, object: nil)
            }
        }
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

    static func prepareForLaunch() async {
        #if DEBUG
        if let e2eConfiguration {
            await identityStore.setActive(identityID: e2eConfiguration.identity.id)
        }
        #endif
    }

    static func lockKeySession() async {
        await keychainStore.lock()
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
    static func makeActivityViewModel() -> ActivityViewModel {
        ActivityViewModel(provider: auditLog)
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
