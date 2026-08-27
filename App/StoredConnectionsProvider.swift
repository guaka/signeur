import Foundation

/// Lists the apps Signstr answers for, annotated with any permissions the user chose to remember.
public struct StoredConnectionsProvider: ConnectedAppsProviding {
    private let connections: ConnectionStore
    private let permissions: ConnectedAppsProviding?
    private let identities: IdentityStore?

    public init(
        connections: ConnectionStore,
        permissions: ConnectedAppsProviding? = nil,
        identities: IdentityStore? = nil
    ) {
        self.connections = connections
        self.permissions = permissions
        self.identities = identities
    }

    public func listConnectedApps() async -> [ConnectedAppItem] {
        let remembered = await permissions?.listConnectedApps() ?? []
        let identityNames = await identities?.list().reduce(into: [String: String]()) {
            $0[$1.id] = $1.displayName
        } ?? [:]

        return await connections.approved().map { connection in
            let methods = remembered.first { $0.appPubkey == connection.appPubkey }?.methods ?? []
            return ConnectedAppItem(
                appName: connection.appName ?? "Unknown app",
                appPubkey: connection.appPubkey,
                methods: methods.isEmpty ? ["asks you every time"] : methods,
                requestedPermissions: connection.requestedPermissions ?? [],
                appURL: connection.appURL,
                relays: connection.relays,
                identityName: identityNames[connection.identityID],
                createdAt: connection.createdAt,
                lastUsedAt: connection.lastUsedAt,
                usesLegacyEncryption: connection.usesLegacyEncryption
            )
        }
    }

    public func revoke(appPubkey: String) async {
        await connections.remove(appPubkey: appPubkey)
        await permissions?.revoke(appPubkey: appPubkey)
    }
}
