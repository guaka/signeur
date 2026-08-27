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
    @Published public private(set) var isSyncing = false

    private let identityStore: IdentityStore
    private let nsecStore: NsecStoring
    private let profileLookup: any NostrProfileLookingUp
    private let revealDuration: Duration
    private let statusDuration: Duration
    private var revealTasks: [String: Task<Void, Never>] = [:]
    private var statusTask: Task<Void, Never>?

    public init(
        identityStore: IdentityStore,
        nsecStore: NsecStoring,
        profileLookup: any NostrProfileLookingUp = NoopNostrProfileLookup(),
        revealDuration: Duration = .seconds(30),
        statusDuration: Duration = .seconds(3)
    ) {
        self.identityStore = identityStore
        self.nsecStore = nsecStore
        self.profileLookup = profileLookup
        self.revealDuration = revealDuration
        self.statusDuration = statusDuration
    }

    public var canSave: Bool {
        !isSaving && !nsec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var syncRelayHosts: [String] {
        profileLookup.relayURLs.compactMap(\.host)
    }

    public var syncRelayDescriptions: [String] {
        profileLookup.relayURLs.compactMap { relay in
            guard let host = relay.host else { return nil }
            let kinds = RelayNostrProfileLookup.profileKinds(for: relay)
            return kinds.contains(RelayNostrProfileLookup.trustrootsProfileKind)
                ? "\(host) (kinds 0, 10390)"
                : "\(host) (kind 0)"
        }
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
        await saveKey(origin: .imported)
    }

    private func saveKey(origin: IdentityOrigin) async {
        guard !isSaving else { return }
        statusTask?.cancel()
        statusTask = nil
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
        var profile: NostrProfileMetadata?
        if origin == .imported && typedName.isEmpty,
           let pubkey = try? NostrKeyDeriver.derivePublicKeyHex(fromNsec: value) {
            statusMessage = "Looking up this key's profile…"
            profile = await profileLookup.lookup(pubkey: pubkey)
            statusMessage = nil
        }
        let identity = Identity(
            id: UUID().uuidString,
            displayName: typedName.isEmpty
                ? (profile?.suggestedName ?? "Key \(identities.count + 1)")
                : typedName,
            npub: npub,
            nip05: profile?.nip05,
            origin: origin
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
        showStatus("Saved \(identity.displayName).")
        await refresh()
    }

    public func generateKey() async {
        guard !isSaving else { return }
        do {
            nsec = try NostrKeyDeriver.generateNsec()
            await saveKey(origin: .generated)
        } catch {
            nsec = ""
            statusMessage = nil
            errorMessage = "A new key could not be generated. Please try again."
        }
    }

    public func setActive(_ identity: Identity) async {
        await identityStore.setActive(identityID: identity.id)
        await refresh()
    }

    public func syncNIP05() async {
        guard !isSyncing, !identities.isEmpty else { return }
        statusTask?.cancel()
        statusTask = nil
        isSyncing = true
        errorMessage = nil
        if syncRelayHosts.isEmpty {
            statusMessage = "Checking NIP-05 addresses…"
        } else {
            statusMessage = "Checking NIP-05 via \(syncRelayHosts.joined(separator: ", "))…"
        }
        defer { isSyncing = false }

        var foundCount = 0
        for identity in identities {
            guard let pubkey = await identityStore.publicKeyHex(for: identity.id),
                  let nip05 = await profileLookup.lookup(pubkey: pubkey)?.nip05
            else {
                continue
            }
            await identityStore.updateNIP05(nip05, for: identity.id)
            foundCount += 1
        }

        await refresh()
        let keyDescription = identities.count == 1 ? "key" : "keys"
        let addressDescription = foundCount == 1 ? "address" : "addresses"
        showStatus("Checked \(identities.count) \(keyDescription). Found \(foundCount) NIP-05 \(addressDescription).")
    }

    public func toggleReveal(_ identity: Identity) async {
        if revealedNsecs[identity.id] != nil {
            revealedNsecs.removeValue(forKey: identity.id)
            revealTasks.removeValue(forKey: identity.id)?.cancel()
            return
        }
        do {
            guard let stored = try await nsecStore.loadNsec(for: identity.id) else {
                errorMessage = "No key is stored for \(identity.displayName)."
                return
            }
            revealedNsecs[identity.id] = stored
            revealTasks.removeValue(forKey: identity.id)?.cancel()
            let duration = revealDuration
            revealTasks[identity.id] = Task { [weak self] in
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.revealedNsecs.removeValue(forKey: identity.id)
                    self?.revealTasks.removeValue(forKey: identity.id)
                }
            }
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    public func deleteIdentity(_ identity: Identity) async {
        revealTasks.removeValue(forKey: identity.id)?.cancel()
        revealedNsecs.removeValue(forKey: identity.id)
        await identityStore.delete(identityID: identity.id)
        await nsecStore.deleteNsec(for: identity.id)
        errorMessage = nil
        showStatus("Deleted \(identity.displayName).")
        await refresh()
    }

    public func hideAllRevealedKeys() {
        revealTasks.values.forEach { $0.cancel() }
        revealTasks.removeAll()
        revealedNsecs.removeAll()
        nsec = ""
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

    private func showStatus(_ message: String) {
        statusTask?.cancel()
        statusMessage = message
        let duration = statusDuration
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                self?.statusMessage = nil
            }
            self?.statusTask = nil
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
