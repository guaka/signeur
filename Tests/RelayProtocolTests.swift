import XCTest
@testable import SigneurCore

final class RelayFrameTests: XCTestCase {
    func testDecodesAnEventFrame() throws {
        let event = try NostrEventFactory.sign(
            UnsignedNostrEvent(createdAt: 1_700_000_000, kind: 24133, tags: [["p", TestVectors.pubkeyHex]], content: "cipher"),
            privateKey: try NostrKeyDeriver.secretKeyBytes(fromNsec: TestVectors.nsec)
        )
        let frame = "[\"EVENT\",\"sub-1\"," + (try NostrEventFactory.json(for: event)) + "]"

        guard case let .event(subscriptionID, decoded) = try XCTUnwrap(RelayFrame.decode(frame)) else {
            return XCTFail("expected an event frame")
        }

        XCTAssertEqual(subscriptionID, "sub-1")
        XCTAssertEqual(decoded, event)
    }

    func testDecodesAcceptedAndRejectedOKFrames() throws {
        guard case let .ok(acceptedID, accepted, _) = try XCTUnwrap(RelayFrame.decode("[\"OK\",\"abc\",true,\"\"]")) else {
            return XCTFail("expected an OK frame")
        }
        XCTAssertEqual(acceptedID, "abc")
        XCTAssertTrue(accepted)

        guard case let .ok(_, rejected, message) = try XCTUnwrap(RelayFrame.decode("[\"OK\",\"abc\",false,\"blocked: spam\"]")) else {
            return XCTFail("expected an OK frame")
        }
        XCTAssertFalse(rejected)
        XCTAssertEqual(message, "blocked: spam")
    }

    func testDecodesTheRemainingRelayMessages() throws {
        XCTAssertEqual(RelayFrame.decode("[\"EOSE\",\"sub-1\"]"), .endOfStoredEvents(subscriptionID: "sub-1"))
        XCTAssertEqual(RelayFrame.decode("[\"CLOSED\",\"sub-1\",\"auth-required\"]"), .closed(subscriptionID: "sub-1", message: "auth-required"))
        XCTAssertEqual(RelayFrame.decode("[\"NOTICE\",\"slow down\"]"), .notice("slow down"))
        XCTAssertEqual(RelayFrame.decode("[\"AUTH\",\"challenge\"]"), .authChallenge("challenge"))
    }

    func testRejectsFramesItCannotUnderstand() {
        XCTAssertNil(RelayFrame.decode("not json"))
        XCTAssertNil(RelayFrame.decode("{\"not\":\"an array\"}"))
        XCTAssertNil(RelayFrame.decode("[\"WAT\",\"x\"]"))
        XCTAssertNil(RelayFrame.decode("[\"OK\"]"))
        XCTAssertNil(RelayFrame.decode("[\"EVENT\",\"sub-1\",{\"kind\":1}]"), "an event missing id/sig is not usable")
    }

    func testSubscriptionRequestAsksForNIP46EventsAddressedToUs() throws {
        let frame = try RelayRequest.subscribeToNIP46(
            subscriptionID: "sub-1",
            recipientPubkey: TestVectors.pubkeyHex,
            since: 1_700_000_000
        )

        XCTAssertTrue(frame.hasPrefix("[\"REQ\",\"sub-1\","), frame)
        XCTAssertTrue(frame.contains("\"kinds\":[24133]"), frame)
        XCTAssertTrue(frame.contains("\"#p\":[\"\(TestVectors.pubkeyHex)\"]"), frame)
        XCTAssertTrue(frame.contains("\"since\":1700000000"), frame)
    }

    func testSubscriptionRequestOmitsSinceWhenNotGiven() throws {
        let frame = try RelayRequest.subscribeToNIP46(subscriptionID: "s", recipientPubkey: TestVectors.pubkeyHex, since: nil)

        XCTAssertFalse(frame.contains("since"), frame)
    }

    func testCloseFrameNamesTheSubscription() {
        XCTAssertEqual(RelayRequest.close(subscriptionID: "sub-1"), "[\"CLOSE\",\"sub-1\"]")
    }
}

final class RelayConnectionTests: XCTestCase {
    private func makeEvent(content: String = "cipher") throws -> NostrEvent {
        try NostrEventFactory.sign(
            UnsignedNostrEvent(createdAt: 1_700_000_000, kind: 24133, tags: [], content: content),
            privateKey: try NostrKeyDeriver.secretKeyBytes(fromNsec: TestVectors.nsec)
        )
    }

    func testPublishSendsAnEventFrameAndWaitsForTheRelayToAcceptIt() async throws {
        let socket = FakeRelaySocket()
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket)
        try await connection.start { _ in }

        try await connection.publish(try makeEvent())

        let frames = await socket.frames()
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(frames[0].hasPrefix("[\"EVENT\","), frames[0])
        await connection.stop()
    }

    func testPublishFailsWhenTheRelayRejectsTheEvent() async throws {
        let socket = FakeRelaySocket(autoAcknowledge: false)
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket)
        try await connection.start { _ in }
        let event = try makeEvent()

        async let publish: Void = connection.publish(event)
        try await Task.sleep(nanoseconds: 100_000_000)
        await socket.deliver("[\"OK\",\"\(event.id)\",false,\"blocked: no\"]")

        do {
            try await publish
            XCTFail("a rejected event must throw")
        } catch {
            XCTAssertEqual(error as? RelayConnectionError, .rejected("blocked: no"))
        }
        await connection.stop()
    }

    func testPublishTimesOutWhenNoAcknowledgementArrives() async throws {
        let socket = FakeRelaySocket(autoAcknowledge: false)
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket, publishTimeout: 0.1)
        try await connection.start { _ in }

        do {
            try await connection.publish(try makeEvent())
            XCTFail("a silent relay must time out")
        } catch {
            XCTAssertEqual(error as? RelayConnectionError, .publishTimedOut)
        }
        await connection.stop()
    }

    func testSubscribedEventsReachTheHandler() async throws {
        let socket = FakeRelaySocket()
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket)
        let received = Collector<NostrEvent>()
        try await connection.start { event in await received.append(event) }
        try await connection.subscribe(subscriptionID: "sub-1", recipientPubkey: TestVectors.pubkeyHex)

        let event = try makeEvent(content: "for the handler")
        await socket.deliver("[\"EVENT\",\"sub-1\"," + (try NostrEventFactory.json(for: event)) + "]")
        try await Task.sleep(nanoseconds: 150_000_000)

        let items = await received.items()
        XCTAssertEqual(items.map(\.content), ["for the handler"])
        await connection.stop()
    }

    func testSubscribeSendsAREQFrame() async throws {
        let socket = FakeRelaySocket()
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket)
        try await connection.start { _ in }

        try await connection.subscribe(subscriptionID: "sub-1", recipientPubkey: TestVectors.pubkeyHex)

        let frames = await socket.frames()
        XCTAssertTrue(frames.contains { $0.hasPrefix("[\"REQ\",\"sub-1\"") }, "\(frames)")
        await connection.stop()
    }

    func testStopClosesTheSocket() async throws {
        let socket = FakeRelaySocket()
        let connection = RelayConnection(url: URL(string: "wss://relay.one")!, socket: socket)
        try await connection.start { _ in }

        await connection.stop()

        let closed = await socket.closedYet()
        XCTAssertTrue(closed)
    }
}

final class NostrRelayPoolTests: XCTestCase {
    private let relayA = URL(string: "wss://relay.one")!
    private let relayB = URL(string: "wss://relay.two")!

    private func makeEvent(content: String = "cipher") throws -> NostrEvent {
        try NostrEventFactory.sign(
            UnsignedNostrEvent(createdAt: 1_700_000_000, kind: 24133, tags: [], content: content),
            privateKey: try NostrKeyDeriver.secretKeyBytes(fromNsec: TestVectors.nsec)
        )
    }

    func testPublishReachesEveryConfiguredRelay() async throws {
        let sockets = SocketRegistry()
        let pool = NostrRelayPool(socketFactory: { url in sockets.socket(for: url) })

        try await pool.publish(try makeEvent(), to: [relayA, relayB])

        let framesA = await sockets.socket(for: relayA).frames()
        let framesB = await sockets.socket(for: relayB).frames()
        XCTAssertEqual(framesA.count, 1)
        XCTAssertEqual(framesB.count, 1)
        await pool.stop()
    }

    func testPublishSucceedsWhenOnlyOneRelayIsReachable() async throws {
        let sockets = SocketRegistry(failing: [URL(string: "wss://relay.two")!])
        let pool = NostrRelayPool(socketFactory: { url in sockets.socket(for: url) })

        try await pool.publish(try makeEvent(), to: [relayA, relayB])

        let framesA = await sockets.socket(for: relayA).frames()
        XCTAssertEqual(framesA.count, 1, "the reachable relay still gets the event")
        await pool.stop()
    }

    func testPublishFailsWhenNoRelayAccepts() async throws {
        let sockets = SocketRegistry(failing: [relayA, relayB])
        let pool = NostrRelayPool(socketFactory: { url in sockets.socket(for: url) })

        do {
            try await pool.publish(try makeEvent(), to: [relayA, relayB])
            XCTFail("with every relay down the publish must fail")
        } catch {
            XCTAssertEqual(error as? NostrRelayPoolError, .allRelaysFailed)
        }
    }

    func testPublishWithoutRelaysIsReported() async throws {
        let pool = NostrRelayPool(socketFactory: { _ in FakeRelaySocket() })

        do {
            try await pool.publish(try makeEvent(), to: [])
            XCTFail("there is nowhere to send this")
        } catch {
            XCTAssertEqual(error as? NostrRelayPoolError, .noRelaysConfigured)
        }
    }

    func testTheSameEventFromTwoRelaysIsOnlyHandledOnce() async throws {
        let sockets = SocketRegistry()
        let pool = NostrRelayPool(socketFactory: { url in sockets.socket(for: url) })
        let received = Collector<NostrEvent>()
        await pool.setEventHandler { event in await received.append(event) }
        await pool.subscribe(subscriptionID: "sub-1", recipientPubkey: TestVectors.pubkeyHex, on: [relayA, relayB])

        let event = try makeEvent(content: "duplicate")
        let frame = "[\"EVENT\",\"sub-1\"," + (try NostrEventFactory.json(for: event)) + "]"
        await sockets.socket(for: relayA).deliver(frame)
        await sockets.socket(for: relayB).deliver(frame)
        try await Task.sleep(nanoseconds: 200_000_000)

        let items = await received.items()
        XCTAssertEqual(items.count, 1, "relays echo each other; the user must be asked once")
        await pool.stop()
    }

    func testSubscribeOpensOneConnectionPerRelay() async throws {
        let sockets = SocketRegistry()
        let pool = NostrRelayPool(socketFactory: { url in sockets.socket(for: url) })

        await pool.subscribe(subscriptionID: "sub-1", recipientPubkey: TestVectors.pubkeyHex, on: [relayA, relayB])

        let count = await pool.connectedRelayCount()
        XCTAssertEqual(count, 2)
        await pool.stop()
    }
}

/// Hands out one fake socket per relay URL so tests can inspect both ends.
final class SocketRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [URL: FakeRelaySocket] = [:]
    private let failing: Set<URL>

    init(failing: [URL] = []) {
        self.failing = Set(failing)
    }

    func socket(for url: URL) -> FakeRelaySocket {
        lock.lock()
        defer { lock.unlock() }
        if let existing = sockets[url] { return existing }
        let socket = FakeRelaySocket(failOnConnect: failing.contains(url))
        sockets[url] = socket
        return socket
    }
}

actor Collector<Element: Sendable> {
    private var stored: [Element] = []

    func append(_ element: Element) { stored.append(element) }
    func items() -> [Element] { stored }
}
