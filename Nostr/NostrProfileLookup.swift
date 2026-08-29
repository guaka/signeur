import Foundation

public struct NostrProfileMetadata: Equatable, Sendable {
    public let displayName: String?
    public let nip05: String?

    public init(displayName: String? = nil, nip05: String? = nil) {
        self.displayName = displayName
        self.nip05 = nip05
    }

    public var suggestedName: String? {
        if let nip05 {
            if nip05.hasPrefix("_@") {
                return String(nip05.dropFirst(2))
            }
            return nip05
        }
        return displayName
    }
}

public protocol NostrProfileLookingUp: Sendable {
    var relayURLs: [URL] { get }
    func lookup(pubkey: String) async -> NostrProfileMetadata?
}

public extension NostrProfileLookingUp {
    var relayURLs: [URL] { [] }
}

public struct NoopNostrProfileLookup: NostrProfileLookingUp {
    public init() {}
    public func lookup(pubkey: String) async -> NostrProfileMetadata? { nil }
}

public protocol NostrProfileEventFetching: Sendable {
    func fetchProfileEvents(pubkey: String, relays: [URL]) async -> [NostrEvent]
}

public protocol NIP05Verifying: Sendable {
    func verify(identifier: String, pubkey: String) async -> Bool
}

public struct RelayNostrProfileLookup: NostrProfileLookingUp {
    static let trustrootsProfileKind = 10_390
    static let trustrootsUsernameNamespace = "org.trustroots:username"
    static let extendedProfileRelayHosts: Set<String> = [
        "relay.nomadwiki.org",
        "relay.trustroots.org"
    ]
    public static let defaultRelays = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
        "wss://purplepag.es",
        "wss://relay.nomadwiki.org",
        "wss://relay.trustroots.org"
    ].compactMap(URL.init(string:))

    public let relayURLs: [URL]
    private let eventFetcher: any NostrProfileEventFetching
    private let nip05Verifier: any NIP05Verifying

    public init(
        relays: [URL] = Self.defaultRelays,
        eventFetcher: any NostrProfileEventFetching = WebSocketNostrProfileEventFetcher(),
        nip05Verifier: any NIP05Verifying = URLSessionNIP05Verifier()
    ) {
        self.relayURLs = relays
        self.eventFetcher = eventFetcher
        self.nip05Verifier = nip05Verifier
    }

    public func lookup(pubkey: String) async -> NostrProfileMetadata? {
        guard SecurityPolicy.isCanonicalPublicKey(pubkey) else { return nil }
        let events = await eventFetcher.fetchProfileEvents(pubkey: pubkey, relays: relayURLs)
        let validEvents = events.filter { isValidProfileEvent($0, pubkey: pubkey) }
        let metadata = validEvents
            .filter { $0.kind == 0 }
            .sorted(by: newestFirst)
            .lazy
            .compactMap { parseMetadata($0.content) }
            .first

        var nip05Candidates: [String] = []
        if let identifier = metadata?.nip05 {
            nip05Candidates.append(identifier)
        }
        if let trustrootsEvent = validEvents
            .filter({ $0.kind == Self.trustrootsProfileKind })
            .sorted(by: newestFirst)
            .first,
           let username = trustrootsUsername(from: trustrootsEvent) {
            nip05Candidates.append("\(username.lowercased())@trustroots.org")
        }

        var verifiedNIP05: String?
        for identifier in nip05Candidates where verifiedNIP05 == nil {
            if await nip05Verifier.verify(identifier: identifier, pubkey: pubkey) {
                verifiedNIP05 = identifier
            }
        }

        guard metadata != nil || verifiedNIP05 != nil else { return nil }
        return NostrProfileMetadata(displayName: metadata?.displayName, nip05: verifiedNIP05)
    }

    private func isValidProfileEvent(_ event: NostrEvent, pubkey: String) -> Bool {
        guard [0, Self.trustrootsProfileKind].contains(event.kind), event.pubkey == pubkey else {
            return false
        }
        let eventDate = Date(timeIntervalSince1970: TimeInterval(event.createdAt))
        return (try? event.validate(now: eventDate, maxAge: 1, maxFutureSkew: 1)) != nil
    }

    private func trustrootsUsername(from event: NostrEvent) -> String? {
        let namespace = Self.trustrootsUsernameNamespace
        guard event.tags.contains(where: { $0.count == 2 && $0[0] == "L" && $0[1] == namespace }),
              let label = event.tags.first(where: {
                  $0.count == 3 && $0[0] == "l" && $0[2] == namespace
              })
        else {
            return nil
        }
        let username = label[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard username.count > 3, SecurityPolicy.validateMetadataText(username) else { return nil }
        return username
    }

    static func profileKinds(for relay: URL) -> [Int] {
        guard let host = relay.host?.lowercased(), extendedProfileRelayHosts.contains(host) else {
            return [0]
        }
        return [0, trustrootsProfileKind]
    }

    private func newestFirst(_ lhs: NostrEvent, _ rhs: NostrEvent) -> Bool {
        lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt > rhs.createdAt
    }

    private func parseMetadata(_ content: String) -> NostrProfileMetadata? {
        guard content.utf8.count <= SecurityPolicy.maxRequestPayloadBytes,
              let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        func safeValue(_ key: String) -> String? {
            guard let value = object[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, SecurityPolicy.validateMetadataText(trimmed) else { return nil }
            return trimmed
        }

            return NostrProfileMetadata(
            displayName: safeValue("display_name") ?? safeValue("name"),
            nip05: safeValue("nip05").map { canonicalNIP05($0.lowercased()) }
        )
    }

    private func canonicalNIP05(_ value: String) -> String {
        guard value.hasPrefix("_@") else {
            return value
        }
        return String(value.dropFirst(2))
    }
}

public struct WebSocketNostrProfileEventFetcher: NostrProfileEventFetching {
    private let socketFactory: @Sendable (URL) -> RelaySocketing
    private let timeoutNanoseconds: UInt64

    public init(timeout: TimeInterval = 4) {
        socketFactory = { URLSessionRelaySocket(url: $0) }
        timeoutNanoseconds = UInt64(max(0.1, timeout) * 1_000_000_000)
    }

    public init(
        socketFactory: @escaping @Sendable (URL) -> RelaySocketing,
        timeout: TimeInterval = 4
    ) {
        self.socketFactory = socketFactory
        self.timeoutNanoseconds = UInt64(max(0.1, timeout) * 1_000_000_000)
    }

    public func fetchProfileEvents(pubkey: String, relays: [URL]) async -> [NostrEvent] {
        await withTaskGroup(of: [NostrEvent].self) { group in
            for relay in relays {
                group.addTask {
                    await fetchFromRelay(relay, pubkey: pubkey)
                }
            }
            var events: [NostrEvent] = []
            for await relayEvents in group {
                events.append(contentsOf: relayEvents)
            }
            return events
        }
    }

    private func fetchFromRelay(_ relay: URL, pubkey: String) async -> [NostrEvent] {
        let socket = socketFactory(relay)
        let subscriptionID = "profile-" + UUID().uuidString.prefix(24)

        return await withTaskGroup(of: [NostrEvent].self) { group in
            group.addTask {
                do {
                    try await socket.connect()
                    try await socket.send(
                        try RelayRequest.subscribeToProfile(
                            subscriptionID: String(subscriptionID),
                            authorPubkey: pubkey,
                            kinds: RelayNostrProfileLookup.profileKinds(for: relay)
                        )
                    )
                    var events: [NostrEvent] = []
                    while !Task.isCancelled {
                        switch RelayFrame.decode(try await socket.receive()) {
                        case let .event(receivedID, event) where receivedID == subscriptionID:
                            events.append(event)
                        case let .endOfStoredEvents(receivedID) where receivedID == subscriptionID:
                            return events
                        case let .closed(receivedID, _) where receivedID == subscriptionID:
                            return events
                        default:
                            continue
                        }
                    } // coverage:ignore The loop exits only through a matched frame, thrown receive, or cancellation.
                } catch {
                    return []
                } // coverage:ignore Compiler-generated async catch epilogue.
                return []
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return []
            }

            let firstResult = await group.next() ?? []
            group.cancelAll()
            await socket.close()
            return firstResult
        }
    }
}

public struct URLSessionNIP05Verifier: NIP05Verifying, @unchecked Sendable {
    private let sessionConfiguration: URLSessionConfiguration

    public init() {
        sessionConfiguration = .ephemeral
    }

    init(sessionConfiguration: URLSessionConfiguration) {
        self.sessionConfiguration = sessionConfiguration
    }

    public func verify(identifier: String, pubkey: String) async -> Bool {
        guard let atIndex = identifier.lastIndex(of: "@"),
              identifier.firstIndex(of: "@") == atIndex
        else {
            return false
        }
        let localPart = String(identifier[..<atIndex])
        let domain = String(identifier[identifier.index(after: atIndex)...]).lowercased()
        let allowedLocal = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_.")
        guard !localPart.isEmpty,
              localPart.unicodeScalars.allSatisfy(allowedLocal.contains),
              isSafeDomain(domain),
              SecurityPolicy.isCanonicalPublicKey(pubkey)
        else {
            return false
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = domain
        components.path = "/.well-known/nostr.json"
        components.queryItems = [URLQueryItem(name: "name", value: localPart)]
        guard let url = components.url else { return false } // coverage:ignore-region Validated domain and fixed HTTPS components always form a URL.

        let delegate = NoRedirectURLSessionDelegate()
        let configuration = sessionConfiguration.copy() as? URLSessionConfiguration ?? .ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(from: url)
            guard data.count <= SecurityPolicy.maxRequestPayloadBytes,
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let names = object["names"] as? [String: String]
            else {
                return false
            }
            return names[localPart] == pubkey
        } catch {
            return false
        }
    }

    private func isSafeDomain(_ domain: String) -> Bool {
        guard domain.contains("."),
              !domain.hasSuffix(".local"),
              !SecurityPolicy.isLoopback(host: domain),
              !domain.contains(":"),
              domain.utf8.count <= 253
        else {
            return false
        }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63
                && label.first != "-" && label.last != "-"
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}

final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
