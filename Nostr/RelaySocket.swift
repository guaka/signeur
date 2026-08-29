import Foundation

public enum RelaySocketError: Error, Equatable {
    case notConnected
    case closed
}

/// The websocket surface a relay connection needs, so the protocol logic can be
/// exercised without a network.
public protocol RelaySocketing: Sendable {
    func connect() async throws
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close() async
}

protocol RelayWebSocketTask: Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: RelayWebSocketTask {}

protocol RelayWebSocketTaskFactory: Sendable {
    func makeTask(for url: URL) -> RelayWebSocketTask
}

struct DefaultRelayWebSocketTaskFactory: RelayWebSocketTaskFactory {
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func makeTask(for url: URL) -> RelayWebSocketTask {
        session.webSocketTask(with: url)
    }
}

public actor URLSessionRelaySocket: RelaySocketing {
    private let url: URL
    private let session: URLSession
    private let taskFactory: RelayWebSocketTaskFactory
    private var task: RelayWebSocketTask?

    public init(
        url: URL,
        session: URLSession = .shared
    ) {
        self.url = url
        self.session = session
        self.taskFactory = DefaultRelayWebSocketTaskFactory(session: session)
    }

    init(
        url: URL,
        session: URLSession = .shared,
        taskFactory: RelayWebSocketTaskFactory
    ) {
        self.url = url
        self.session = session
        self.taskFactory = taskFactory
    }

    public func connect() async throws {
        guard task == nil else { return }
        let task = taskFactory.makeTask(for: url)
        task.resume()
        self.task = task
    }

    public func send(_ text: String) async throws {
        guard let task else { throw RelaySocketError.notConnected }
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        guard let task else { throw RelaySocketError.notConnected }
        switch try await task.receive() {
        case let .string(text):
            return text
        case let .data(data):
            return String(decoding: data, as: UTF8.self)
        @unknown default: // coverage:ignore Reserved for WebSocket message cases added by a future SDK.
            throw RelaySocketError.closed
        }
    }

    public func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
