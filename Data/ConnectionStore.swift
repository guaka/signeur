import Foundation

/// Remembers which apps are connected so Signstr can answer them again after a relaunch.
public actor ConnectionStore {
    private static let storageKey = "signstr.connections"

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
        connections = Dictionary(uniqueKeysWithValues: stored.map { ($0.appPubkey, $0) })
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Array(connections.values)) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}
