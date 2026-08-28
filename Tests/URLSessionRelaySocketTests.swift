import Foundation
import XCTest
@testable import SignstrCore

private final class FakeRelayTask: RelayWebSocketTask, @unchecked Sendable {
    private(set) var receivedMessages: [String] = []
    private(set) var closed: Bool = false
    private(set) var resumed = false
    private(set) var resumeCount = 0

    enum FakeMessage {
        case string(String)
        case data(Data)
        case binary(Data)
    }

    private var queue: [FakeMessage] = []
    private var continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private let receiveStarted = DispatchSemaphore(value: 0)

    func resume() {
        resumed = true
        resumeCount += 1
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        if case .string(let text) = message {
            receivedMessages.append(text)
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        if queue.isEmpty {
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                receiveStarted.signal()
            }
        }
        return try popMessage()
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        closed = true
        continuation?.resume(throwing: RelaySocketError.closed)
        continuation = nil
    }

    func deliver(_ message: FakeMessage) {
        if let continuation {
            self.continuation = nil
            do {
                continuation.resume(returning: try makeMessage(from: message))
            } catch {
                continuation.resume(throwing: error)
            }
        } else {
            queue.append(message)
        }
    }

    func deliveredCount() -> Int { receivedMessages.count }
    func didResume() -> Bool { resumed }
    func didClose() -> Bool { closed }
    func waitUntilReceiving() -> Bool {
        receiveStarted.wait(timeout: .now() + 1) == .success
    }

    private func popMessage() throws -> URLSessionWebSocketTask.Message {
        let message = queue.removeFirst()
        return try makeMessage(from: message)
    }

    private func makeMessage(from message: FakeMessage) throws -> URLSessionWebSocketTask.Message {
        switch message {
        case .string(let text):
            return .string(text)
        case .data(let data):
            return .data(data)
        case .binary:
            throw RelaySocketError.closed
        }
    }
}

private struct FakeRelayTaskFactory: RelayWebSocketTaskFactory {
    let task: FakeRelayTask

    func makeTask(for url: URL) -> RelayWebSocketTask {
        task
    }
}

final class URLSessionRelaySocketTests: XCTestCase {
    func testSecondConnectOnlySetsTaskOnce() async throws {
        let task = FakeRelayTask()
        let socket = URLSessionRelaySocket(
            url: URL(string: "wss://example.com/relay")!,
            taskFactory: FakeRelayTaskFactory(task: task)
        )

        try await socket.connect()
        try await socket.connect()

        let wasResumed = task.didResume()
        let delivered = task.resumeCount
        XCTAssertEqual(delivered, 1)
        XCTAssertTrue(wasResumed)
    }

    func testSendAndReceiveThrowWhenNotConnected() async {
        let task = FakeRelayTask()
        let socket = URLSessionRelaySocket(
            url: URL(string: "wss://example.com/relay")!,
            taskFactory: FakeRelayTaskFactory(task: task)
        )

        do {
            try await socket.send("payload")
            XCTFail("sending without connect() must fail")
        } catch {
            XCTAssertEqual(error as? RelaySocketError, .notConnected)
        }

        do {
            _ = try await socket.receive()
            XCTFail("receiving without connect() must fail")
        } catch {
            XCTAssertEqual(error as? RelaySocketError, .notConnected)
        }
    }

    func testCloseBeforeConnectionIsSafe() async {
        let task = FakeRelayTask()
        let socket = URLSessionRelaySocket(
            url: URL(string: "wss://example.com/relay")!,
            taskFactory: FakeRelayTaskFactory(task: task)
        )

        await socket.close()

        let sentCount = task.deliveredCount()
        XCTAssertEqual(sentCount, 0)
    }

    func testReceiveUnknownWebSocketMessageTreatsSocketAsClosed() async throws {
        let task = FakeRelayTask()
        let socket = URLSessionRelaySocket(
            url: URL(string: "wss://example.com/relay")!,
            taskFactory: FakeRelayTaskFactory(task: task)
        )

        try await socket.connect()
        task.deliver(.binary(Data([0x00, 0x01, 0x02])))

        do {
            _ = try await socket.receive()
            XCTFail("unknown message types must fail")
        } catch {
            XCTAssertEqual(error as? RelaySocketError, .closed)
        }
    }

    func testConnectedTaskCanSendAndReceiveStringMessages() async throws {
        let task = FakeRelayTask()
        let socket = URLSessionRelaySocket(
            url: URL(string: "wss://example.com/relay")!,
            taskFactory: FakeRelayTaskFactory(task: task)
        )

        try await socket.connect()
        try await socket.send("hi")
        task.deliver(.string("payload"))
        let received = try await socket.receive()

        let sentCount = task.deliveredCount()
        let wasResumed = task.didResume()

        XCTAssertEqual(sentCount, 1)
        XCTAssertEqual(wasResumed, true)
        XCTAssertEqual(received, "payload")
    }

    func testReceiveCanConvertBinaryPayloadToString() async throws {
        let task = FakeRelayTask()
        let socket = URLSessionRelaySocket(
            url: URL(string: "wss://example.com/relay")!,
            taskFactory: FakeRelayTaskFactory(task: task)
        )

        try await socket.connect()
        task.deliver(.data("signed-binary".data(using: .utf8)!))
        let received = try await socket.receive()

        XCTAssertEqual(received, "signed-binary")
    }

    func testSendAfterCloseThrowsNotConnected() async throws {
        let task = FakeRelayTask()
        let socket = URLSessionRelaySocket(
            url: URL(string: "wss://example.com/relay")!,
            taskFactory: FakeRelayTaskFactory(task: task)
        )
        try await socket.connect()
        await socket.close()

        do {
            try await socket.send("late")
            XCTFail("sending without an active connection should fail")
        } catch {
            XCTAssertEqual(error as? RelaySocketError, .notConnected)
        }
    }

    func testClosingConnectedTaskCancelsReceive() async throws {
        let task = FakeRelayTask()
        let socket = URLSessionRelaySocket(
            url: URL(string: "wss://example.com/relay")!,
            taskFactory: FakeRelayTaskFactory(task: task)
        )

        try await socket.connect()
        let receiveTask = Task {
            try await socket.receive()
        }
        XCTAssertTrue(task.waitUntilReceiving(), "receive should be pending before close")
        await socket.close()

        do {
            _ = try await receiveTask.value
            XCTFail("receive should fail after socket is closed")
        } catch {
            XCTAssertEqual(error as? RelaySocketError, .closed)
        }

        let didClose = task.didClose()
        XCTAssertTrue(didClose)
    }
}
