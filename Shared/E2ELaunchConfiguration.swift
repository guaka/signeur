import Foundation

#if DEBUG
/// A deliberately debug-only way for UI tests to launch either app with a disposable key.
/// Release builds cannot read or activate this configuration.
public struct E2ELaunchConfiguration: Sendable {
    public static let enabledEnvironmentKey = "SIGNSTR_E2E_ENABLED"
    public static let nsecEnvironmentKey = "SIGNSTR_E2E_NSEC"
    public static let identityID = "signstr-e2e-identity"

    public let identity: Identity
    public let nsec: String

    public init?(environment: [String: String]) {
        guard environment[Self.enabledEnvironmentKey] == "1",
              let nsec = environment[Self.nsecEnvironmentKey],
              let npub = try? NostrKeyDeriver.deriveNpub(fromNsec: nsec)
        else {
            return nil
        }

        self.nsec = nsec
        identity = Identity(
            id: Self.identityID,
            displayName: "NIP-46 E2E Key",
            npub: npub,
            origin: .imported
        )
    }

    public func makeIdentityStore() -> IdentityStore {
        let suiteName = "signstr.e2e.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated E2E defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return IdentityStore(defaults: defaults, seed: [identity])
    }

    public func makeNsecStore() -> E2ENsecStore {
        E2ENsecStore(identityID: identity.id, nsec: nsec)
    }
}

/// Volatile key storage used only by debug UI-test launches.
public actor E2ENsecStore: NsecStoring {
    private var keys: [String: String]

    public init(identityID: String, nsec: String) {
        keys = [identityID: nsec]
    }

    public func saveNsec(_ nsec: String, for identityID: String) {
        keys[identityID] = nsec
    }

    public func loadNsec(for identityID: String) -> String? {
        keys[identityID]
    }

    public func hasNsec(for identityID: String) -> Bool {
        keys[identityID] != nil
    }

    public func deleteNsec(for identityID: String) {
        keys.removeValue(forKey: identityID)
    }
}
#endif
