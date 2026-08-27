import Foundation
import Security

public enum IdentityOrigin: String, Codable, Equatable, Sendable {
    case imported
    case generated
}

public struct Identity: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let npub: String?
    public let nip05: String?
    public let origin: IdentityOrigin?
    public let createdAt: Date
    public let lastUsedAt: Date?

    public init(
        id: String,
        displayName: String,
        npub: String? = nil,
        nip05: String? = nil,
        origin: IdentityOrigin? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.npub = npub
        self.nip05 = nip05
        self.origin = origin
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public actor IdentityStore {
    private let activeIdentityKey = "signstr.active.identity"
    private let identitiesKey = "signstr.identities"
    private let defaults: UserDefaults
    private var identities: [Identity]

    public init(defaults: UserDefaults = .standard, seed: [Identity] = []) {
        self.defaults = defaults
        if
            let data = defaults.data(forKey: identitiesKey),
            let decoded = try? JSONDecoder().decode([Identity].self, from: data),
            !decoded.isEmpty
        {
            self.identities = decoded
        } else {
            self.identities = seed
            let encoded = try? JSONEncoder().encode(seed)
            defaults.set(encoded, forKey: identitiesKey)
        }
    }

    public func list() -> [Identity] {
        identities
    }

    public func add(_ identity: Identity) {
        if identities.contains(where: { $0.id == identity.id }) {
            return
        }
        identities.append(identity)
        persistIdentities()
    }

    public func updateNIP05(_ nip05: String, for identityID: String) {
        guard let index = identities.firstIndex(where: { $0.id == identityID }) else { return }
        let identity = identities[index]
        identities[index] = Identity(
            id: identity.id,
            displayName: identity.displayName,
            npub: identity.npub,
            nip05: nip05,
            origin: identity.origin,
            createdAt: identity.createdAt,
            lastUsedAt: identity.lastUsedAt
        )
        persistIdentities()
    }

    public func markUsed(identityID: String, at date: Date = Date()) {
        guard let index = identities.firstIndex(where: { $0.id == identityID }) else { return }
        let identity = identities[index]
        identities[index] = Identity(
            id: identity.id,
            displayName: identity.displayName,
            npub: identity.npub,
            nip05: identity.nip05,
            origin: identity.origin,
            createdAt: identity.createdAt,
            lastUsedAt: date
        )
        persistIdentities()
    }

    public func setActive(identityID: String) {
        defaults.set(identityID, forKey: activeIdentityKey)
    }

    public func activeIdentityID() -> String? {
        defaults.string(forKey: activeIdentityKey)
    }

    public func publicKeyHex(for identityID: String) -> String? {
        guard let npub = identities.first(where: { $0.id == identityID })?.npub,
              let bytes = try? Bech32.decode(npub, expectedHRP: "npub"),
              bytes.count == 32
        else {
            return nil
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    public func delete(identityID: String) {
        identities.removeAll { $0.id == identityID }
        if defaults.string(forKey: activeIdentityKey) == identityID {
            if let first = identities.first {
                defaults.set(first.id, forKey: activeIdentityKey)
            } else {
                defaults.removeObject(forKey: activeIdentityKey)
            }
        }
        persistIdentities()
    }

    private func persistIdentities() {
        let encoded = try? JSONEncoder().encode(identities)
        defaults.set(encoded, forKey: identitiesKey)
    }
}
