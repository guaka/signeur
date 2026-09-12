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
    private let reconnectDelay: TimeInterval

    private var readerTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Error>?
    private struct PendingPublish {
        let token: UUID
        var continuations: [CheckedContinuation<Void, Error>]
        var timeout: Task<Void, Never>?
    }
    private var pendingPublishes: [String: PendingPublish] = [:]
    private var eventHandler: (@Sendable (NostrEvent) async -> Void)?
    private var subscriptions: [String: (recipientPubkey: String, since: Int?)] = [:]
    private var isStopped = false

    public init(url: URL, socket: RelaySocketing, publishTimeout: TimeInterval = 10, reconnectDelay: TimeInterval = 1) {
        self.url = url
        self.socket = socket
        self.publishTimeout = publishTimeout
        self.reconnectDelay = max(0.01, reconnectDelay)
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
        guard !isStopped else { throw RelaySocketError.closed }
        if let reconnectTask {
            try await reconnectTask.value
        } else if readerTask == nil {
            try await reconnect()
        }
        let frame = try RelayRequest.event(event)
        // Register synchronously before send can yield to the reader's OK handler.
        try await withCheckedThrowingContinuation { continuation in
            if pendingPublishes[event.id] != nil {
                pendingPublishes[event.id]?.continuations.append(continuation)
            } else {
                let pending = PendingPublish(token: UUID(), continuations: [continuation])
                pendingPublishes[event.id] = pending
                Task { await self.sendAndTimeOut(frame, eventID: event.id, token: pending.token) }
            }
        }
    }

    /// iOS can close a WebSocket while Signeur is suspended behind Safari. Reopen it
    /// once and restore subscriptions before retrying the response publish.
    private func reconnect() async throws {
        if let reconnectTask { return try await reconnectTask.value }
        guard !isStopped else { throw RelaySocketError.closed }
        let task = Task { try await self.reopenConnection() }
        reconnectTask = task
        defer { reconnectTask = nil }
        try await task.value
    }

    private func reopenConnection() async throws {
        let previousReader = readerTask
        previousReader?.cancel()
        readerTask = nil
        failAllPending(with: RelaySocketError.closed)
        await socket.close()
        await previousReader?.value
        try Task.checkCancellation()
        do {
            try await socket.connect()
            try Task.checkCancellation()
            for (subscriptionID, subscription) in subscriptions {
                try await socket.send(
                    try RelayRequest.subscribeToNIP46(
                        subscriptionID: subscriptionID,
                        recipientPubkey: subscription.recipientPubkey,
                        since: subscription.since
                    )
                )
            }
            try Task.checkCancellation()
            startReaderIfNeeded()
        } catch {
            await socket.close()
            throw error
        }
    }

    public func stop() async {
        isStopped = true
        recoveryTask?.cancel()
        recoveryTask = nil
        reconnectTask?.cancel()
        readerTask?.cancel()
        readerTask = nil
        await socket.close()
        failAllPending(with: RelaySocketError.closed)
    }

    private func sendAndTimeOut(_ frame: String, eventID: String, token: UUID) async {
        guard pendingPublishes[eventID]?.token == token else { return }
        // The deadline also covers a send that never completes.
        let timeoutTask = Task { [weak self, publishTimeout] in
            do {
                try await Task.sleep(for: .seconds(publishTimeout))
            } catch {
                return
            }
            await self?.finishPublish(eventID, token: token, result: .failure(RelayConnectionError.publishTimedOut))
        }
        pendingPublishes[eventID]?.timeout = timeoutTask
        do {
            try await socket.send(frame)
        } catch {
            finishPublish(eventID, token: token, result: .failure(error))
        }
    }

    private func finishPublish(_ eventID: String, token: UUID? = nil, result: Result<Void, Error>) {
        guard let pending = pendingPublishes[eventID], token == nil || pending.token == token else { return }
        pendingPublishes.removeValue(forKey: eventID)
        pending.timeout?.cancel()
        for continuation in pending.continuations {
            continuation.resume(with: result)
        }
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
                guard !Task.isCancelled else { return }
                failAllPending(with: error)
                await socket.close()
                guard !Task.isCancelled, !isStopped else { return }
                readerTask = nil
                scheduleRecovery()
                return
            }
        }
    }

    private func scheduleRecovery() {
        guard recoveryTask == nil else { return }
        recoveryTask = Task { [weak self, reconnectDelay] in
            var delay = reconnectDelay
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(delay))
                    guard let self else { return }
                    try await self.recoverIfNeeded()
                    return
                } catch {
                    delay = min(delay * 2, 30)
                }
            }
        }
    }

    private func recoverIfNeeded() async throws {
        if readerTask == nil { try await reconnect() }
        guard !Task.isCancelled else { return }
        recoveryTask = nil
        if readerTask == nil, !isStopped { scheduleRecovery() }
    }

    private func handle(_ frame: RelayFrame?) async {
        switch frame {
        case let .event(_, event):
            await eventHandler?(event)

        case let .ok(eventID, accepted, message):
            if accepted {
                finishPublish(eventID, result: .success(()))
            } else {
                finishPublish(eventID, result: .failure(RelayConnectionError.rejected(message)))
            }

        case let .closed(subscriptionID, _):
            subscriptions.removeValue(forKey: subscriptionID)

        case .endOfStoredEvents, .notice, .authChallenge, .none:
            break
        }
    }

    private func failAllPending(with error: Error) {
        for eventID in pendingPublishes.keys {
            finishPublish(eventID, result: .failure(error))
        }
    }
}
