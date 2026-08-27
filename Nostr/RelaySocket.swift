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

public actor URLSessionRelaySocket: RelaySocketing {
    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func connect() async throws {
        guard task == nil else { return }
        let task = session.webSocketTask(with: url)
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
        @unknown default:
            throw RelaySocketError.closed
        }
    }

    public func close() async {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}
