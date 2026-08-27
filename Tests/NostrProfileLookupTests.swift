import XCTest
@testable import SignstrCore

final class NostrProfileLookupTests: XCTestCase {
    func testDefaultRelaysIncludeNomadwikiAndTrustroots() {
        let relays = Set(RelayNostrProfileLookup.defaultRelays.map(\.absoluteString))
        XCTAssertTrue(relays.contains("wss://relay.nomadwiki.org"))
        XCTAssertTrue(relays.contains("wss://relay.trustroots.org"))
    }

    func testNewestValidProfileSuppliesVerifiedNIP05() async throws {
        let older = try profileEvent(
            createdAt: 100,
            content: #"{"display_name":"Old","nip05":"old@example.com"}"#
        )
        let newest = try profileEvent(
            createdAt: 200,
            content: #"{"display_name":"Kasper","nip05":"kasper@trustroots.org"}"#
        )
        let verifier = StubNIP05Verifier(validIdentifiers: ["kasper@trustroots.org"])
        let lookup = RelayNostrProfileLookup(
            relays: [URL(string: "wss://relay.one")!],
            eventFetcher: StubProfileEventFetcher(events: [older, newest]),
            nip05Verifier: verifier
        )

        let profile = await lookup.lookup(pubkey: TestVectors.pubkeyHex)

        XCTAssertEqual(profile?.displayName, "Kasper")
        XCTAssertEqual(profile?.nip05, "kasper@trustroots.org")
    }

    func testUnverifiedNIP05IsNotSuggested() async throws {
        let event = try profileEvent(
            createdAt: 100,
            content: #"{"name":"Kasper","nip05":"spoofed@example.com"}"#
        )
        let lookup = RelayNostrProfileLookup(
            relays: [],
            eventFetcher: StubProfileEventFetcher(events: [event]),
            nip05Verifier: StubNIP05Verifier(validIdentifiers: [])
        )

        let profile = await lookup.lookup(pubkey: TestVectors.pubkeyHex)

        XCTAssertEqual(profile?.suggestedName, "Kasper")
        XCTAssertNil(profile?.nip05)
    }

    func testProfileRequestUsesKindZeroAuthorFilterAndLimit() throws {
        let text = try RelayRequest.subscribeToProfile(
            subscriptionID: "profile-1",
            authorPubkey: TestVectors.pubkeyHex
        )
        let data = try XCTUnwrap(text.data(using: .utf8))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        let filter = try XCTUnwrap(request[2] as? [String: Any])

        XCTAssertEqual(request[0] as? String, "REQ")
        XCTAssertEqual(request[1] as? String, "profile-1")
        XCTAssertEqual(filter["authors"] as? [String], [TestVectors.pubkeyHex])
        XCTAssertEqual(filter["kinds"] as? [Int], [0])
        XCTAssertEqual(filter["limit"] as? Int, 1)
    }

    func testLookupSkipsFetchForInvalidPubkey() async throws {
        let fetcher = TrackingProfileEventFetcher(events: [])
        let lookup = RelayNostrProfileLookup(
            eventFetcher: fetcher,
            nip05Verifier: StubNIP05Verifier(validIdentifiers: [])
        )

        let profile = await lookup.lookup(pubkey: "not-a-valid-pubkey")
        let requestCount = await fetcher.requestCount()

        XCTAssertNil(profile)
        XCTAssertEqual(requestCount, 0)
    }

    func testMalformedMetadataIsIgnored() async throws {
        let event = try profileEvent(createdAt: 100, content: #"{"display_name":"Alice""#)
        let lookup = RelayNostrProfileLookup(
            relays: [],
            eventFetcher: StubProfileEventFetcher(events: [event]),
            nip05Verifier: StubNIP05Verifier(validIdentifiers: ["alice@trustroots.org"])
        )

        let profile = await lookup.lookup(pubkey: TestVectors.pubkeyHex)

        XCTAssertNil(profile)
    }

    func testNameFallsBackWhenDisplayNameIsMissing() async throws {
        let event = try profileEvent(createdAt: 100, content: #"{"name":"Kasper"}"#)
        let lookup = RelayNostrProfileLookup(
            relays: [],
            eventFetcher: StubProfileEventFetcher(events: [event]),
            nip05Verifier: StubNIP05Verifier(validIdentifiers: [])
        )

        let profile = await lookup.lookup(pubkey: TestVectors.pubkeyHex)

        XCTAssertEqual(profile?.displayName, "Kasper")
        XCTAssertNil(profile?.nip05)
    }

    func testProfileLookupForwardsConfiguredRelaysToFetcher() async throws {
        let fetcher = TrackingProfileEventFetcher(events: [])
        let relays = [URL(string: "wss://relay.custom.one")!, URL(string: "wss://relay.custom.two")!]
        let lookup = RelayNostrProfileLookup(
            relays: relays,
            eventFetcher: fetcher,
            nip05Verifier: StubNIP05Verifier(validIdentifiers: [])
        )

        _ = await lookup.lookup(pubkey: TestVectors.pubkeyHex)
        let requested = await fetcher.requestedRelays(for: TestVectors.pubkeyHex)

        XCTAssertEqual(requested, relays)
    }

    func testInvalidPubkeyEventsAreIgnored() async throws {
        let wrongEvent = try profileEvent(
            createdAt: 200,
            content: #"{"display_name":"Wrong"}"#,
            signerNsec: TestVectors.otherNsec
        )
        let valid = try profileEvent(
            createdAt: 100,
            content: #"{"display_name":"Valid"}"#
        )
        let lookup = RelayNostrProfileLookup(
            relays: [],
            eventFetcher: StubProfileEventFetcher(events: [wrongEvent, valid]),
            nip05Verifier: StubNIP05Verifier(validIdentifiers: [])
        )

        let profile = await lookup.lookup(pubkey: TestVectors.pubkeyHex)

        XCTAssertEqual(profile?.displayName, "Valid")
    }

    func testOversizedMetadataIsIgnored() async throws {
        let giantName = String(repeating: "x", count: SecurityPolicy.maxRequestPayloadBytes + 1)
        let event = try profileEvent(createdAt: 100, content: #"{"display_name":""# + giantName + #""}"#)
        let lookup = RelayNostrProfileLookup(
            relays: [],
            eventFetcher: StubProfileEventFetcher(events: [event]),
            nip05Verifier: StubNIP05Verifier(validIdentifiers: [])
        )

        let profile = await lookup.lookup(pubkey: TestVectors.pubkeyHex)

        XCTAssertNil(profile)
    }

    func testWebSocketFetcherReturnsProfileEventsAndStopsOnEOSE() async throws {
        let relay = URL(string: "wss://relay.one")!
        let socket = FakeRelaySocket()
        let fetcher = WebSocketNostrProfileEventFetcher(
            socketFactory: { _ in socket },
            timeout: 2
        )
        let request = Task { await fetcher.fetchProfileEvents(pubkey: TestVectors.pubkeyHex, relays: [relay]) }

        try await Task.sleep(for: .milliseconds(50))
        let frames = await socket.frames()
        let subscribeFrame = try XCTUnwrap(
            frames.first { $0.hasPrefix("[\"REQ\",") },
            "subscription should be sent before any assertions"
        )
        let requestData = try XCTUnwrap(subscribeFrame.data(using: .utf8))
        let requestArray = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData) as? [Any])
        let subscriptionID = try XCTUnwrap(requestArray[1] as? String)

        let event = try profileEvent(
            createdAt: 1_700_000_000,
            content: #"{"display_name":"Alice"}"#
        )
        await socket.deliver("[\"EVENT\",\"\(subscriptionID)\"," + (try NostrEventFactory.json(for: event)) + "]")
        await socket.deliver("[\"EOSE\",\"\(subscriptionID)\"]")

        let events = await request.value

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.content, #"{"display_name":"Alice"}"#)
        XCTAssertEqual(await socket.closedYet(), true)
    }

    func testWebSocketFetcherTimesOutWhenNoRelayReplies() async {
        let relay = URL(string: "wss://relay.one")!
        let socket = FakeRelaySocket()
        let fetcher = WebSocketNostrProfileEventFetcher(
            socketFactory: { _ in socket },
            timeout: 0.01
        )

        let events = await fetcher.fetchProfileEvents(pubkey: TestVectors.pubkeyHex, relays: [relay])

        XCTAssertEqual(events.count, 0)
        XCTAssertTrue(await socket.closedYet())
    }

    func testNIP05VerifierRejectsMalformedNip05IdentifiersWithoutNetworking() async {
        let verifier = URLSessionNIP05Verifier()
        let noAt = await verifier.verify(identifier: "not-an-id", pubkey: TestVectors.pubkeyHex)
        let uppercase = await verifier.verify(identifier: "UPPER@trustroots.org", pubkey: TestVectors.pubkeyHex)
        let localhost = await verifier.verify(identifier: "user@localhost", pubkey: TestVectors.pubkeyHex)
        let bad = await verifier.verify(identifier: "bad:name@trustroots.org", pubkey: TestVectors.pubkeyHex)

        XCTAssertFalse(noAt)
        XCTAssertFalse(uppercase)
        XCTAssertFalse(localhost)
        XCTAssertFalse(bad)
    }

    private func profileEvent(createdAt: Int, content: String, signerNsec: String = TestVectors.nsec) throws -> NostrEvent {
        try NostrEventFactory.sign(
            UnsignedNostrEvent(createdAt: createdAt, kind: 0, tags: [], content: content),
            privateKey: try NostrKeyDeriver.secretKeyBytes(fromNsec: signerNsec)
        )
    }
}

private struct StubProfileEventFetcher: NostrProfileEventFetching {
    let events: [NostrEvent]

    func fetchProfileEvents(pubkey: String, relays: [URL]) async -> [NostrEvent] {
        events
    }
}

private actor TrackingProfileEventFetcher: NostrProfileEventFetching {
    private let events: [NostrEvent]
    private var requests: [String] = []
    private var relaysByPubkey: [String: [URL]] = [:]

    init(events: [NostrEvent]) {
        self.events = events
    }

    func fetchProfileEvents(pubkey: String, relays: [URL]) async -> [NostrEvent] {
        requests.append(pubkey)
        relaysByPubkey[pubkey] = relays
        return events
    }

    func requestCount() async -> Int {
        requests.count
    }

    func requestedRelays(for pubkey: String) async -> [URL] {
        relaysByPubkey[pubkey, default: []]
    }
}

private actor StubNIP05Verifier: NIP05Verifying {
    let validIdentifiers: Set<String>

    init(validIdentifiers: Set<String>) {
        self.validIdentifiers = validIdentifiers
    }

    func verify(identifier: String, pubkey: String) async -> Bool {
        validIdentifiers.contains(identifier)
    }
}
