import Foundation

/// Storage for Nostr private keys, so callers can be exercised without the Keychain.
public protocol NsecStoring: Sendable {
    func saveNsec(_ nsec: String, for identityID: String) async throws
    func loadNsec(for identityID: String) async throws -> String?
    func hasNsec(for identityID: String) async -> Bool
    func deleteNsec(for identityID: String) async
}
