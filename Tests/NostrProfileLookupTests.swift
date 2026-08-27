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

    private func profileEvent(createdAt: Int, content: String) throws -> NostrEvent {
        try NostrEventFactory.sign(
            UnsignedNostrEvent(createdAt: createdAt, kind: 0, tags: [], content: content),
            privateKey: try NostrKeyDeriver.secretKeyBytes(fromNsec: TestVectors.nsec)
        )
    }
}

private struct StubProfileEventFetcher: NostrProfileEventFetching {
    let events: [NostrEvent]

    func fetchProfileEvents(pubkey: String, relays: [URL]) async -> [NostrEvent] {
        events
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
