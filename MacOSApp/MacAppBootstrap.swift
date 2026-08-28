import AppKit
import Foundation
import SignstrCore

enum MacAppBootstrap {
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
