import Foundation
import XCTest
@testable import SigneurCore

// NIP-19 test vector, cross-checked against Tools/derive_reference.py.
enum TestVectors {
    static let nsec = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
    static let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
    static let pubkeyHex = "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"
    static let otherPubkeyHex = "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
    static let secretHex = "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"

    /// A second valid nsec, so duplicate detection can be told apart from "any second key".
    static let otherNsec = "nsec1qgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqxjfw7x"
    static let otherNpub = "npub1f49ke5fkzqev4x7j46uajq92f4zan6kcpty5yvm5c3g6wf2dqanqn7qsy2"
}

/// Isolated `UserDefaults` so store tests never touch the developer's real domain.
func makeEphemeralDefaults(function: String = #function) -> UserDefaults {
    let name = "signeur.tests.\(function).\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: name) else {
        fatalError("Could not create test defaults for \(name)")
    }
    defaults.removePersistentDomain(forName: name)
    return defaults
}

struct StubStorageError: Error, LocalizedError {
    let errorDescription: String? = "Stub storage refused to write."
}

actor InMemoryNsecStore: NsecStoring {
    private var keys: [String: String] = [:]
    private var failOnSave = false
    private var failOnLoad = false

    init(keys: [String: String] = [:], failOnSave: Bool = false, failOnLoad: Bool = false) {
        self.keys = keys
        self.failOnSave = failOnSave
        self.failOnLoad = failOnLoad
    }

    func saveNsec(_ nsec: String, for identityID: String) async throws {
        if failOnSave { throw StubStorageError() }
        keys[identityID] = nsec
    }

    func loadNsec(for identityID: String) async throws -> String? {
        if failOnLoad { throw StubStorageError() }
        return keys[identityID]
    }

    func hasNsec(for identityID: String) async -> Bool {
        keys[identityID] != nil
    }

    func deleteNsec(for identityID: String) async {
        keys.removeValue(forKey: identityID)
    }

    func storedCount() -> Int { keys.count }
}

actor StubProfileLookup: NostrProfileLookingUp {
    private let metadata: NostrProfileMetadata?
    nonisolated let relayURLs: [URL]
    private var pubkeys: [String] = []

    init(metadata: NostrProfileMetadata?, relayURLs: [URL] = []) {
        self.metadata = metadata
        self.relayURLs = relayURLs
    }

    func lookup(pubkey: String) async -> NostrProfileMetadata? {
        pubkeys.append(pubkey)
        return metadata
    }

    func lookedUpPubkeys() -> [String] { pubkeys }
}

func makeTestRequest(
    id: String = "req-1",
    method: NIP46Method = .signEvent,
    params: [String]? = nil,
    appName: String? = "Test App",
    appPubkey: String = TestVectors.pubkeyHex,
    payload: String = "{\"kind\":1,\"content\":\"hi\"}",
    origin: NIP46RequestOrigin = .relay
) -> NIP46Request {
    NIP46Request(
        id: id,
        method: method,
        params: params ?? (method == .signEvent ? [payload] : []),
        appName: appName,
        appURL: nil,
        appPubkey: appPubkey,
        correlationID: "corr-\(id)",
        rawPayloadPreview: payload,
        origin: origin
    )
}

actor RecordingExecutor: NIP46RequestExecuting {
    static let stubResult = "executed"

    private(set) var executedIdentityIDs: [String] = []
    private(set) var executedRequests: [NIP46Request] = []
    private let shouldThrow: Bool

    init(shouldThrow: Bool = false) {
        self.shouldThrow = shouldThrow
    }

    func execute(_ request: NIP46Request, identityID: String) async throws -> String {
        if shouldThrow { throw StubStorageError() }
        executedIdentityIDs.append(identityID)
        executedRequests.append(request)
        return Self.stubResult
    }

    func publicKeyHex(identityID: String) async throws -> String {
        TestVectors.pubkeyHex
    }

    func signCount() -> Int { executedIdentityIDs.count }
    func identities() -> [String] { executedIdentityIDs }
    func requests() -> [NIP46Request] { executedRequests }
}

actor RecordingTransport: NIP46RespondingTransport {
    private(set) var responses: [NIP46Response] = []
    private let shouldThrow: Bool

    init(shouldThrow: Bool = false) {
        self.shouldThrow = shouldThrow
    }

    func sendResponse(_ response: NIP46Response, to appPubkey: String) async throws {
        responses.append(response)
        if shouldThrow { throw NostrRelayPoolError.allRelaysFailed }
    }

    func sentCount() -> Int { responses.count }
    func sentResponses() -> [NIP46Response] { responses }
}

/// A relay socket driven by the test: frames sent are recorded, frames received are queued.
actor FakeRelaySocket: RelaySocketing {
    private(set) var sentFrames: [String] = []
    private(set) var connectCount = 0
    private(set) var isClosed = false
    private var isConnected = false

    private var incoming: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var remainingSendFailures = 0
    private let failOnConnect: Bool
    /// Answers every published event with an OK, the way a healthy relay does.
    private var autoAcknowledge: Bool

    init(autoAcknowledge: Bool = true, failOnConnect: Bool = false) {
        self.autoAcknowledge = autoAcknowledge
        self.failOnConnect = failOnConnect
    }

    func connect() async throws {
        guard !isConnected else { return }
        if failOnConnect { throw RelaySocketError.notConnected }
        connectCount += 1
        isConnected = true
        isClosed = false
    }

    func send(_ text: String) async throws {
        if remainingSendFailures > 0 {
            remainingSendFailures -= 1
            throw RelaySocketError.closed
        }
        sentFrames.append(text)
        guard autoAcknowledge, text.hasPrefix("[\"EVENT\"") else { return }
        guard
            let data = text.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
            let event = array.last as? [String: Any],
            let id = event["id"] as? String
        else {
            return
        }
        deliver("[\"OK\",\"\(id)\",true,\"\"]")
    }

    func receive() async throws -> String {
        if !incoming.isEmpty {
            return incoming.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func close() async {
        isClosed = true
        isConnected = false
        waiter?.resume(throwing: RelaySocketError.closed)
        waiter = nil
    }

    func deliver(_ frame: String) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: frame)
        } else {
            incoming.append(frame)
        }
    }

    func frames() -> [String] { sentFrames }
    func connectionsMade() -> Int { connectCount }
    func closedYet() -> Bool { isClosed }
    func failNextSend() { remainingSendFailures += 1 }
    func enableAutoAcknowledge() { autoAcknowledge = true }
    func resetFrames() { sentFrames.removeAll() }
}

/// Builds a signed kind 24133 event carrying an encrypted NIP-46 payload, as a client would.
func makeNIP46Event(
    body: String,
    senderNsec: String,
    recipientPubkeyHex: String,
    createdAt: Int = 1_700_000_000,
    legacy: Bool = false
) throws -> NostrEvent {
    let secret = try NostrKeyDeriver.secretKeyBytes(fromNsec: senderNsec)
    let peer = try NostrEventFactory.hexBytes(recipientPubkeyHex)
    let content = legacy
        ? try NIP04.encrypt(plaintext: body, privateKey: secret, publicKeyXOnly: peer)
        : try NIP44.encrypt(plaintext: body, privateKey: secret, publicKeyXOnly: peer)

    return try NostrEventFactory.sign(
        UnsignedNostrEvent(
            createdAt: createdAt,
            kind: NIP46RelayTransport.nip46Kind,
            tags: [["p", recipientPubkeyHex]],
            content: content
        ),
        privateKey: secret
    )
}
