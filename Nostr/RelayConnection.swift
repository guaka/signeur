import Foundation

public enum RelayConnectionError: Error, Equatable {
    case rejected(String)
    case publishTimedOut
}

/// One relay: a single reader loop that resolves publishes and forwards subscribed events.
public actor RelayConnection {
    public let url: URL

    private let socket: RelaySocketing
    private let publishTimeout: TimeInterval

    private var readerTask: Task<Void, Never>?
    private var pendingPublishes: [String: CheckedContinuation<Void, Error>] = [:]
    private var eventHandler: (@Sendable (NostrEvent) async -> Void)?
    private var subscriptions: [String: (recipientPubkey: String, since: Int?)] = [:]
    private var isStopped = false

    public init(url: URL, socket: RelaySocketing, publishTimeout: TimeInterval = 10) {
        self.url = url
        self.socket = socket
        self.publishTimeout = publishTimeout
    }

    public func start(onEvent handler: @escaping @Sendable (NostrEvent) async -> Void) async throws {
        eventHandler = handler
        isStopped = false
        try await socket.connect()
        startReaderIfNeeded()
    }

    public func subscribe(subscriptionID: String, recipientPubkey: String, since: Int? = nil) async throws {
        subscriptions[subscriptionID] = (recipientPubkey, since)
        try await socket.send(
            try RelayRequest.subscribeToNIP46(subscriptionID: subscriptionID, recipientPubkey: recipientPubkey, since: since)
        )
    }

    public func unsubscribe(subscriptionID: String) async {
        subscriptions.removeValue(forKey: subscriptionID)
        try? await socket.send(RelayRequest.close(subscriptionID: subscriptionID))
    }

    /// Publishes and waits for the relay's `OK`, so a caller learns whether the event was stored.
    public func publish(_ event: NostrEvent) async throws {
        do {
            try await publishOnce(event)
        } catch let error as RelayConnectionError {
            guard !isStopped, case .publishTimedOut = error else { throw error }
            try await reconnect()
            try await publishOnce(event)
        } catch {
            guard !isStopped else { throw error }
            try await reconnect()
            try await publishOnce(event)
        }
    }

    private func publishOnce(_ event: NostrEvent) async throws {
        try await socket.connect()
        startReaderIfNeeded()
        try await socket.send(try RelayRequest.event(event))
        try await waitForAcknowledgement(of: event.id)
    }

    /// iOS can close a WebSocket while Signeur is suspended behind Safari. Reopen it
    /// once and restore subscriptions before retrying the response publish.
    private func reconnect() async throws {
        let previousReader = readerTask
        previousReader?.cancel()
        readerTask = nil
        await socket.close()
        await previousReader?.value
        try await socket.connect()
        startReaderIfNeeded()
        for (subscriptionID, subscription) in subscriptions {
            try await socket.send(
                try RelayRequest.subscribeToNIP46(
                    subscriptionID: subscriptionID,
                    recipientPubkey: subscription.recipientPubkey,
                    since: subscription.since
                )
            )
        }
    }

    public func stop() async {
        isStopped = true
        readerTask?.cancel()
        readerTask = nil
        await socket.close()
        failAllPending(with: RelaySocketError.closed)
    }

    private func waitForAcknowledgement(of eventID: String) async throws {
        let nanoseconds = UInt64(publishTimeout * 1_000_000_000)
        // A silent relay must not leave the caller waiting forever.
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            await self?.timeOutPublish(eventID)
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            pendingPublishes[eventID] = continuation
        }
    }

    private func timeOutPublish(_ eventID: String) {
        pendingPublishes.removeValue(forKey: eventID)?.resume(throwing: RelayConnectionError.publishTimedOut)
    }

    private func startReaderIfNeeded() {
        guard readerTask == nil else { return }
        readerTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    private func readLoop() async {
        while !isStopped, !Task.isCancelled {
            do {
                let text = try await socket.receive()
                await handle(RelayFrame.decode(text))
            } catch {
                failAllPending(with: error)
                await socket.close()
                readerTask = nil
                return
            }
        }
    }

    private func handle(_ frame: RelayFrame?) async {
        switch frame {
        case let .event(_, event):
            await eventHandler?(event)

        case let .ok(eventID, accepted, message):
            guard let continuation = pendingPublishes.removeValue(forKey: eventID) else { return } // coverage:ignore-region An unsolicited OK has no local continuation and is intentionally ignored.
            if accepted {
                continuation.resume()
            } else {
                continuation.resume(throwing: RelayConnectionError.rejected(message))
            }

        case let .closed(subscriptionID, _):
            subscriptions.removeValue(forKey: subscriptionID)

        case .endOfStoredEvents, .notice, .authChallenge, .none:
            break
        }
    }

    private func failAllPending(with error: Error) {
        let pending = pendingPublishes
        pendingPublishes.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }
}
