import Foundation
import SwiftUI

@MainActor
public final class KeysViewModel: ObservableObject {
    @Published public private(set) var identities: [Identity] = []
    @Published public private(set) var activeIdentityID: String?
    @Published public private(set) var keyPresence: [String: Bool] = [:]
    @Published public private(set) var revealedNsecs: [String: String] = [:]
    @Published public var displayName: String = ""
    @Published public var nsec: String = ""
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var isSaving = false

    private let identityStore: IdentityStore
    private let nsecStore: NsecStoring

    public init(identityStore: IdentityStore, nsecStore: NsecStoring) {
        self.identityStore = identityStore
        self.nsecStore = nsecStore
    }

    public var canSave: Bool {
        !isSaving && !nsec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func refresh() async {
        identities = await identityStore.list()
        activeIdentityID = await identityStore.activeIdentityID()

        var presence: [String: Bool] = [:]
        for identity in identities {
            presence[identity.id] = await nsecStore.hasNsec(for: identity.id)
        }
        keyPresence = presence

        let liveIDs = Set(identities.map(\.id))
        revealedNsecs = revealedNsecs.filter { liveIDs.contains($0.key) }
    }

    public func addKey() async {
        guard !isSaving else { return }
        statusMessage = nil

        let value = nsec
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        guard !value.isEmpty else {
            errorMessage = "Paste an nsec to continue."
            return
        }
        guard value.hasPrefix("nsec1") else {
            errorMessage = "That is not an nsec. A Nostr private key starts with \"nsec1\"."
            return
        }

        let npub: String
        do {
            npub = try NostrKeyDeriver.deriveNpub(fromNsec: value)
        } catch {
            errorMessage = "This nsec is not valid. Check that the whole key was pasted."
            return
        }
        if let existing = identities.first(where: { $0.npub == npub }) {
            errorMessage = "This key is already stored as \"\(existing.displayName)\"."
            return
        }

        isSaving = true
        defer { isSaving = false }

        let typedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = Identity(
            id: UUID().uuidString,
            displayName: typedName.isEmpty ? "Key \(identities.count + 1)" : typedName,
            npub: npub
        )

        // The key lands in storage before the identity is recorded, so a storage
        // failure can never leave an identity that cannot sign.
        do {
            try await nsecStore.saveNsec(value, for: identity.id)
        } catch {
            errorMessage = Self.message(for: error)
            return
        }

        await identityStore.add(identity)
        if await identityStore.activeIdentityID() == nil {
            await identityStore.setActive(identityID: identity.id)
        }

        displayName = ""
        nsec = ""
        errorMessage = nil
        statusMessage = "Saved \(identity.displayName)."
        await refresh()
    }

    public func setActive(_ identity: Identity) async {
        await identityStore.setActive(identityID: identity.id)
        await refresh()
    }

    public func toggleReveal(_ identity: Identity) async {
        if revealedNsecs[identity.id] != nil {
            revealedNsecs.removeValue(forKey: identity.id)
            return
        }
        do {
            guard let stored = try await nsecStore.loadNsec(for: identity.id) else {
                errorMessage = "No key is stored for \(identity.displayName)."
                return
            }
            revealedNsecs[identity.id] = stored
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    public func deleteIdentity(_ identity: Identity) async {
        revealedNsecs.removeValue(forKey: identity.id)
        await identityStore.delete(identityID: identity.id)
        await nsecStore.deleteNsec(for: identity.id)
        errorMessage = nil
        statusMessage = "Deleted \(identity.displayName)."
        await refresh()
    }

    public func applyPastedValue(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            errorMessage = "The clipboard is empty."
            return
        }
        nsec = trimmed
        errorMessage = nil
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
