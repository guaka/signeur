import XCTest
@testable import SigneurCore

final class RelayRecoveryTests: XCTestCase {
    private func event(_ content: String = "test") throws -> NostrEvent {
        try NostrEventFactory.sign(
            UnsignedNostrEvent(createdAt: 1_700_000_000, kind: 24133, tags: [], content: content),
            privateKey: NostrKeyDeriver.secretKeyBytes(fromNsec: TestVectors.nsec)
        )
    }

    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for relay state", file: file, line: line)
    }

    func testAutomaticReconnectRetriesAndRestoresSubscriptionsAndEvents() async throws {
        let socket = RecoveringSocket()
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket, reconnectDelay: 0.01)
        let received = Collector<NostrEvent>()
        try await connection.start { await received.append($0) }
        try await connection.subscribe(subscriptionID: "sub", recipientPubkey: TestVectors.pubkeyHex, since: 123)
        await socket.failConnections(2)
        await socket.disconnect()
        try await waitUntil { await socket.frames().filter { $0.hasPrefix("[\"REQ\"") }.count == 2 }
        let attempts = await socket.attempts()
        XCTAssertEqual(attempts, 4)
        let frames = await socket.frames()
        XCTAssertEqual(frames.first, frames.last, "Reconnect must preserve the recipient and replay window")
        let incoming = try event()
        await socket.deliver("[\"EVENT\",\"sub\"," + (try NostrEventFactory.json(for: incoming)) + "]")
        try await waitUntil { await received.items().count == 1 }

        await socket.disconnect()
        try await waitUntil { await socket.frames().filter { $0.hasPrefix("[\"REQ\"") }.count == 3 }
        await connection.stop()
    }

    func testAutomaticReconnectRetriesAFailedSubscriptionRestore() async throws {
        let socket = RecoveringSocket()
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket, reconnectDelay: 0.01)
        try await connection.start { _ in }
        try await connection.subscribe(subscriptionID: "sub", recipientPubkey: TestVectors.pubkeyHex)
        await socket.failNextSubscription()
        await socket.disconnect()
        try await waitUntil { await socket.frames().filter { $0.hasPrefix("[\"REQ\"") }.count == 2 }
        let attempts = await socket.attempts()
        XCTAssertEqual(attempts, 3)
        await connection.stop()
    }

    func testStoppingDuringBackoffPreventsReconnect() async throws {
        let socket = RecoveringSocket()
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket, reconnectDelay: 0.1)
        try await connection.start { _ in }
        await socket.disconnect()
        try await Task.sleep(for: .milliseconds(20))
        await connection.stop()
        try await Task.sleep(for: .milliseconds(150))
        let attempts = await socket.attempts()
        XCTAssertEqual(attempts, 1)
    }

    func testStoppingDuringReconnectClosesTheLateConnection() async throws {
        let socket = RecoveringSocket()
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket, reconnectDelay: 0.01)
        try await connection.start { _ in }
        await socket.blockNextConnection()
        await socket.disconnect()
        try await waitUntil { await socket.isConnecting() }
        await connection.stop()
        await socket.releaseConnection()
        try await waitUntil { await socket.isClosed() }
        try await Task.sleep(for: .milliseconds(40))
        let attempts = await socket.attempts()
        let closed = await socket.isClosed()
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(closed)
    }

    func testPublishAfterReceiveFailureRecoversWithoutWaitingForBackoff() async throws {
        let socket = RecoveringSocket()
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket, reconnectDelay: 0.2)
        try await connection.start { _ in }
        try await connection.subscribe(subscriptionID: "sub", recipientPubkey: TestVectors.pubkeyHex)
        await socket.disconnect()
        try await Task.sleep(for: .milliseconds(20))
        try await connection.publish(event())
        try await Task.sleep(for: .milliseconds(250))
        let attempts = await socket.attempts()
        XCTAssertEqual(attempts, 2, "Scheduled recovery must not replace a healthy manual reconnect")
        await connection.stop()
    }

    func testConcurrentPublishesWaitForTheSameReconnect() async throws {
        let socket = RecoveringSocket()
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket, reconnectDelay: 0.01)
        try await connection.start { _ in }
        await socket.blockNextConnection()
        await socket.disconnect()
        try await waitUntil { await socket.isConnecting() }
        let first = Task { try await connection.publish(event("one")) }
        let second = Task { try await connection.publish(event("two")) }
        try await Task.sleep(for: .milliseconds(20))
        await socket.releaseConnection()
        try await first.value
        try await second.value
        let attempts = await socket.attempts()
        XCTAssertEqual(attempts, 2)
        await connection.stop()
    }

    func testConcurrentIdenticalPublishesShareTheirAcknowledgement() async throws {
        let socket = FakeRelaySocket(autoAcknowledge: false)
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket)
        try await connection.start { _ in }
        let published = try event()
        let first = Task { try await connection.publish(published) }
        let second = Task { try await connection.publish(published) }
        try await waitUntil { await socket.frames().count == 1 }
        try await Task.sleep(for: .milliseconds(20))
        await socket.deliver("[\"OK\",\"\(published.id)\",true,\"\"]")
        try await first.value
        try await second.value
        let frames = await socket.frames()
        XCTAssertEqual(frames.count, 1)
        await connection.stop()
    }

    func testReceiveFailureResolvesAllPendingPublishesAndSharesRecovery() async throws {
        let socket = RecoveringSocket(autoAcknowledge: false)
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket, reconnectDelay: 0.01)
        try await connection.start { _ in }
        let first = Task { try await connection.publish(event("one")) }
        let second = Task { try await connection.publish(event("two")) }
        try await waitUntil { await socket.frames().count == 2 }
        await socket.blockNextConnection()
        await socket.enableAutoAcknowledge()
        await socket.disconnect()
        try await waitUntil { await socket.isConnecting() }
        try await Task.sleep(for: .milliseconds(20))
        await socket.releaseConnection()
        try await first.value
        try await second.value
        let attempts = await socket.attempts()
        XCTAssertEqual(attempts, 2)
        await connection.stop()
    }

    func testLateSendFailureCannotFailTheNextAttempt() async throws {
        let socket = RecoveringSocket()
        await socket.delayFirstSendFailure()
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket, publishTimeout: 0.05)
        try await connection.start { _ in }
        try await connection.publish(event())
        // The old send finishes after the successful retry and must be ignored.
        try await Task.sleep(for: .milliseconds(100))
        try await connection.publish(event("next"))
        let attempts = await socket.attempts()
        XCTAssertEqual(attempts, 2)
        await connection.stop()
    }

    func testUnsolicitedAcknowledgementsAreIgnored() async throws {
        let socket = FakeRelaySocket()
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket)
        try await connection.start { _ in }
        await socket.deliver("[\"OK\",\"not-pending\",true,\"\"]")
        try await connection.publish(event())
        await connection.stop()
    }

    func testPublishOnStoppedConnectionDoesNotReopenIt() async throws {
        let socket = RecoveringSocket()
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket)
        try await connection.start { _ in }
        await connection.stop()
        do {
            try await connection.publish(event())
            XCTFail("Stopped connections must stay closed")
        } catch {
            XCTAssertEqual(error as? RelaySocketError, .closed)
        }
        let attempts = await socket.attempts()
        XCTAssertEqual(attempts, 1)
    }
}

private actor RecoveringSocket: RelaySocketing {
    private let wrapped: FakeRelaySocket
    private var connectionAttempts = 0
    private var connectionFailures = 0
    private var failSubscription = false
    private var delaySendFailure = false
    private var blockConnection = false
    private var connectionGate: CheckedContinuation<Void, Never>?

    init(autoAcknowledge: Bool = true) { wrapped = FakeRelaySocket(autoAcknowledge: autoAcknowledge) }
    func connect() async throws {
        connectionAttempts += 1
        if connectionFailures > 0 {
            connectionFailures -= 1
            throw RelaySocketError.notConnected
        }
        if blockConnection {
            blockConnection = false
            await withCheckedContinuation { connectionGate = $0 }
        }
        try await wrapped.connect()
    }
    func send(_ text: String) async throws {
        if failSubscription && text.hasPrefix("[\"REQ\"") {
            failSubscription = false
            throw RelaySocketError.closed
        }
        if delaySendFailure {
            delaySendFailure = false
            try await Task.sleep(for: .milliseconds(100))
            throw RelaySocketError.closed
        }
        try await wrapped.send(text)
    }
    func receive() async throws -> String { try await wrapped.receive() }
    func close() async { await wrapped.close() }
    func disconnect() async { await wrapped.close() }
    func deliver(_ frame: String) async { await wrapped.deliver(frame) }
    func frames() async -> [String] { await wrapped.frames() }
    func attempts() -> Int { connectionAttempts }
    func isClosed() async -> Bool { await wrapped.closedYet() }
    func failConnections(_ count: Int) { connectionFailures = count }
    func failNextSubscription() { failSubscription = true }
    func delayFirstSendFailure() { delaySendFailure = true }
    func enableAutoAcknowledge() async { await wrapped.enableAutoAcknowledge() }
    func blockNextConnection() { blockConnection = true }
    func isConnecting() -> Bool { connectionGate != nil }
    func releaseConnection() { connectionGate?.resume(); connectionGate = nil }
}
