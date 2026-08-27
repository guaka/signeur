import Foundation

public enum NostrRelayPoolError: Error, Equatable {
    case noRelaysConfigured
    case allRelaysFailed
}

/// Keeps one connection per relay and fans requests out across them.
public actor NostrRelayPool {
    private let socketFactory: @Sendable (URL) -> RelaySocketing
    private let seenEventLimit: Int

    private var connections: [URL: RelayConnection] = [:]
    private var eventHandler: (@Sendable (NostrEvent) async -> Void)?
    private var seenEventIDs: [String] = []
    private var seenEventLookup: Set<String> = []

    public init(
        socketFactory: @escaping @Sendable (URL) -> RelaySocketing = { URLSessionRelaySocket(url: $0) },
        seenEventLimit: Int = 500
    ) {
        self.socketFactory = socketFactory
        self.seenEventLimit = seenEventLimit
    }

    public func setEventHandler(_ handler: @escaping @Sendable (NostrEvent) async -> Void) {
        eventHandler = handler
    }

    public func subscribe(subscriptionID: String, recipientPubkey: String, on relays: [URL], since: Int? = nil) async {
        for relay in relays {
            do {
                let connection = try await connection(for: relay)
                try await connection.subscribe(
                    subscriptionID: subscriptionID,
                    recipientPubkey: recipientPubkey,
                    since: since
                )
            } catch {
                // One unreachable relay must not stop the others from listening.
                continue
            }
        }
    }

    /// Succeeds when at least one relay accepts the event.
    public func publish(_ event: NostrEvent, to relays: [URL]) async throws {
        guard !relays.isEmpty else { throw NostrRelayPoolError.noRelaysConfigured }

        var accepted = false
        for relay in relays {
            do {
                try await (try await connection(for: relay)).publish(event)
                accepted = true
            } catch {
                continue
            }
        }
        guard accepted else { throw NostrRelayPoolError.allRelaysFailed }
    }

    public func stop() async {
        for connection in connections.values {
            await connection.stop()
        }
        connections.removeAll()
    }

    public func connectedRelayCount() -> Int { connections.count }

    private func connection(for relay: URL) async throws -> RelayConnection {
        if let existing = connections[relay] { return existing }

        let connection = RelayConnection(url: relay, socket: socketFactory(relay))
        do {
            try await connection.start { [weak self] event in
                await self?.forwardIfUnseen(event)
            }
        } catch {
            // Not cached, so a later attempt can retry a relay that was briefly down.
            throw error
        }
        connections[relay] = connection
        return connection
    }

    /// The same event usually arrives from several relays; the app should only act once.
    private func forwardIfUnseen(_ event: NostrEvent) async {
        guard !seenEventLookup.contains(event.id) else { return }
        seenEventLookup.insert(event.id)
        seenEventIDs.append(event.id)
        if seenEventIDs.count > seenEventLimit {
            seenEventLookup.remove(seenEventIDs.removeFirst())
        }
        await eventHandler?(event)
    }
}
