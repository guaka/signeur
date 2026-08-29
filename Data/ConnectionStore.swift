import Foundation

/// Remembers which apps are connected so Signeur can answer them again after a relaunch.
public actor ConnectionStore {
    private static let storageKey = "signeur.connections"

    private let defaults: UserDefaults
    private var connections: [String: AppConnection] = [:]
    private var didLoad = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func all() -> [AppConnection] {
        load()
        return connections.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func approved() -> [AppConnection] {
        all().filter(\.isApproved)
    }

    public func connection(forAppPubkey appPubkey: String) -> AppConnection? {
        load()
        return connections[appPubkey]
    }

    /// Records a pairing before approval, because the reply must go back over its relays.
    public func upsert(_ connection: AppConnection) {
        load()
        if let existing = connections[connection.appPubkey] {
            var merged = connection
            merged.isApproved = connection.isApproved || existing.isApproved
            merged.createdAt = existing.createdAt
            merged.lastUsedAt = connection.lastUsedAt ?? existing.lastUsedAt
            merged.usesLegacyEncryption = connection.usesLegacyEncryption || existing.usesLegacyEncryption
            connections[connection.appPubkey] = merged
        } else {
            connections[connection.appPubkey] = connection
        }
        persist()
    }

    public func approve(appPubkey: String, at date: Date = Date()) {
        load()
        guard var connection = connections[appPubkey] else { return }
        connection.isApproved = true
        connection.lastUsedAt = date
        connections[appPubkey] = connection
        persist()
    }

    public func markUsed(appPubkey: String, legacyEncryption: Bool? = nil, at date: Date = Date()) {
        load()
        guard var connection = connections[appPubkey] else { return }
        connection.lastUsedAt = date
        if let legacyEncryption {
            connection.usesLegacyEncryption = legacyEncryption
        }
        connections[appPubkey] = connection
        persist()
    }

    public func remove(appPubkey: String) {
        load()
        connections.removeValue(forKey: appPubkey)
        persist()
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        guard
            let data = defaults.data(forKey: Self.storageKey),
            let stored = try? JSONDecoder().decode([AppConnection].self, from: data)
        else {
            return
        }
        let sanitized = stored.compactMap { connection -> AppConnection? in
            guard SecurityPolicy.isCanonicalPublicKey(connection.appPubkey),
                  SecurityPolicy.validateIdentifier(connection.identityID)
            else { return nil }
            var value = connection
            value.appName = connection.appName.flatMap { SecurityPolicy.validateMetadataText($0) ? $0 : nil }
            value.appURL = connection.appURL.flatMap { try? SecurityPolicy.canonicalMetadataURL($0) }
            value.relays = SecurityPolicy.validRelays(from: connection.relays)
            value.requestedPermissions = Array((connection.requestedPermissions ?? []).prefix(32))
                .filter(SecurityPolicy.validateMetadataText)
            return value
        }
        connections = Dictionary(uniqueKeysWithValues: sanitized.map { ($0.appPubkey, $0) })
        // Rewrites legacy records without their obsolete pairing secret and strips unsafe relays.
        if !stored.isEmpty {
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Array(connections.values)) else { return } // coverage:ignore-region AppConnection contains only JSON-encodable value types.
        defaults.set(data, forKey: Self.storageKey)
    }
}
