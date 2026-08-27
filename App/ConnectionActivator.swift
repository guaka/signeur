import Foundation

/// Records a pairing before approval and starts listening once the user says yes.
public protocol ConnectionRegistering: Sendable {
    func register(pairing: DeepLinkRequest, identityID: String) async
    func activate(appPubkey: String) async
    func forget(appPubkey: String) async
}

public struct ConnectionActivator: ConnectionRegistering {
    private let connections: ConnectionStore
    private let listener: NIP46RelayListener?

    public init(connections: ConnectionStore, listener: NIP46RelayListener? = nil) {
        self.connections = connections
        self.listener = listener
    }

    /// Stored before approval because the reply has to travel over the relays in the pairing code.
    public func register(pairing: DeepLinkRequest, identityID: String) async {
        await connections.upsert(
            AppConnection(
                appPubkey: pairing.clientPubkey,
                appName: pairing.appName,
                appURL: pairing.appURL,
                relays: pairing.relays,
                requestedPermissions: pairing.requestedPerms,
                identityID: identityID
            )
        )
    }

    public func activate(appPubkey: String) async {
        await connections.approve(appPubkey: appPubkey)
        guard let connection = await connections.connection(forAppPubkey: appPubkey) else { return }
        await listener?.listen(to: connection)
    }

    public func forget(appPubkey: String) async {
        await connections.remove(appPubkey: appPubkey)
    }
}
