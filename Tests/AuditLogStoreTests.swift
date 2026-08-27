import XCTest
@testable import SignstrCore

final class AuditLogStoreTests: XCTestCase {
    private func entry(daysAgo: Int, outcome: String = "approved") -> AuditEntry {
        AuditEntry(
            timestamp: Date().addingTimeInterval(TimeInterval(-daysAgo * 86_400)),
            appName: "App",
            method: "sign_event",
            outcome: outcome
        )
    }

    func testStartsEmpty() async throws {
        let store = AuditLogStore(defaults: makeEphemeralDefaults())
        let entries = try await store.list()
        XCTAssertTrue(entries.isEmpty)
    }

    func testAppendedEntriesAreListedNewestFirst() async throws {
        let store = AuditLogStore(defaults: makeEphemeralDefaults())
        try await store.append(entry(daysAgo: 5, outcome: "older"))
        try await store.append(entry(daysAgo: 1, outcome: "newer"))

        let entries = try await store.list()
        XCTAssertEqual(entries.map(\.outcome), ["newer", "older"])
    }

    func testEntriesOlderThanRetentionAreDroppedOnAppend() async throws {
        let store = AuditLogStore(defaults: makeEphemeralDefaults(), retentionDays: 90)
        try await store.append(entry(daysAgo: 91, outcome: "expired"))
        try await store.append(entry(daysAgo: 89, outcome: "kept"))

        let entries = try await store.list()
        XCTAssertEqual(entries.map(\.outcome), ["kept"])
    }

    func testPruneExpiredHonoursCustomRetentionWindow() async throws {
        let store = AuditLogStore(defaults: makeEphemeralDefaults(), retentionDays: 2)
        try await store.append(entry(daysAgo: 0, outcome: "today"))
        try await store.append(entry(daysAgo: 1, outcome: "yesterday"))

        try await store.pruneExpired()

        let entries = try await store.list()
        XCTAssertEqual(entries.map(\.outcome), ["today", "yesterday"])
    }

    func testRetentionIsAppliedAcrossStoreInstances() async throws {
        let defaults = makeEphemeralDefaults()
        let writer = AuditLogStore(defaults: defaults, retentionDays: 90)
        try await writer.append(entry(daysAgo: 10))

        let reader = AuditLogStore(defaults: defaults, retentionDays: 5)
        try await reader.pruneExpired()

        let entries = try await reader.list()
        XCTAssertTrue(entries.isEmpty)
    }
}
