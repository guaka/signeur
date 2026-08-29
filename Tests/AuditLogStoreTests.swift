import XCTest
@testable import SigneurCore

final class AuditLogStoreTests: XCTestCase {
    private func entry(
        daysAgo: Int,
        outcome: AuditOutcome = .signed,
        eventKind: Int? = 1,
        approvalMode: AuditApprovalMode = .manual
    ) -> AuditEntry {
        AuditEntry(
            timestamp: Date().addingTimeInterval(TimeInterval(-daysAgo * 86_400)),
            appName: "App",
            method: "sign_event",
            outcome: outcome,
            eventKind: eventKind,
            approvalMode: approvalMode
        )
    }

    func testStartsEmpty() async throws {
        let store = AuditLogStore(defaults: makeEphemeralDefaults())
        let entries = try await store.list()
        XCTAssertTrue(entries.isEmpty)
    }

    func testAppendedEntriesAreListedNewestFirstWithSafeMetadata() async throws {
        let store = AuditLogStore(defaults: makeEphemeralDefaults())
        try await store.append(entry(daysAgo: 5, outcome: .rejected, eventKind: 7))
        try await store.append(entry(daysAgo: 1, outcome: .signed, eventKind: 1, approvalMode: .remembered))

        let entries = try await store.list()
        XCTAssertEqual(entries.map(\.outcome), [.signed, .rejected])
        XCTAssertEqual(entries.first?.eventKind, 1)
        XCTAssertEqual(entries.first?.approvalMode, .remembered)
    }

    func testEntriesOlderThanRetentionAreDroppedOnAppend() async throws {
        let store = AuditLogStore(defaults: makeEphemeralDefaults(), retentionDays: 90)
        try await store.append(entry(daysAgo: 91, outcome: .expired))
        try await store.append(entry(daysAgo: 89, outcome: .signed))

        let entries = try await store.list()
        XCTAssertEqual(entries.map(\.outcome), [.signed])
    }

    func testPruneExpiredHonoursCustomRetentionWindow() async throws {
        let store = AuditLogStore(defaults: makeEphemeralDefaults(), retentionDays: 2)
        try await store.append(entry(daysAgo: 0, outcome: .signed))
        try await store.append(entry(daysAgo: 1, outcome: .rejected))

        try await store.pruneExpired()

        let entries = try await store.list()
        XCTAssertEqual(entries.map(\.outcome), [.signed, .rejected])
    }

    func testRetentionIsAppliedWhenAStoreInstanceReadsHistory() async throws {
        let defaults = makeEphemeralDefaults()
        let writer = AuditLogStore(defaults: defaults, retentionDays: 90)
        try await writer.append(entry(daysAgo: 10))

        let reader = AuditLogStore(defaults: defaults, retentionDays: 5)
        let entries = try await reader.list()
        XCTAssertTrue(entries.isEmpty)
    }

    func testClearRemovesAllEntries() async throws {
        let store = AuditLogStore(defaults: makeEphemeralDefaults())
        try await store.append(entry(daysAgo: 0))

        await store.clear()

        let entries = try await store.list()
        XCTAssertTrue(entries.isEmpty)
    }

    func testDecodesLegacyEntryWithoutNewMetadata() async throws {
        let defaults = makeEphemeralDefaults()
        let legacy = LegacyAuditEntry(
            id: UUID(),
            timestamp: Date(),
            appName: "Legacy App",
            method: "sign_event",
            outcome: "approved"
        )
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "signeur.audit.entries")

        let entries = try await AuditLogStore(defaults: defaults).list()

        XCTAssertEqual(entries.first?.outcome, .signed)
        XCTAssertNil(entries.first?.eventKind)
        XCTAssertEqual(entries.first?.approvalMode, .notApplicable)
    }

    func testUnknownLegacyOutcomeRemainsReadable() async throws {
        let defaults = makeEphemeralDefaults()
        let legacy = LegacyAuditEntry(
            id: UUID(),
            timestamp: Date(),
            appName: "Legacy App",
            method: "sign_event",
            outcome: "custom-old-value"
        )
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "signeur.audit.entries")

        let entries = try await AuditLogStore(defaults: defaults).list()

        XCTAssertEqual(entries.first?.outcome, .unknown)
    }

    func testMigratesEveryKnownLegacyOutcome() async throws {
        let defaults = makeEphemeralDefaults()
        let mappings: [(String, AuditOutcome)] = [
            ("approved", .signed),
            ("userRejected", .rejected),
            ("timeout", .expired),
            ("invalidProtocol", .invalidRequest),
            ("signingFailed", .signingFailed),
            ("transportFailure", .deliveryFailed),
            ("unauthorizedSigningAttempt", .unauthorized)
        ]
        let legacyEntries = mappings.map { outcome, _ in
            LegacyAuditEntry(
                id: UUID(),
                timestamp: Date(),
                appName: "Legacy App",
                method: "sign_event",
                outcome: outcome
            )
        }
        defaults.set(try JSONEncoder().encode(legacyEntries), forKey: "signeur.audit.entries")

        let entries = try await AuditLogStore(defaults: defaults).list()

        XCTAssertEqual(
            entries.map(\.outcome.rawValue).sorted(),
            mappings.map(\.1.rawValue).sorted()
        )
    }
}

private struct LegacyAuditEntry: Codable {
    let id: UUID
    let timestamp: Date
    let appName: String
    let method: String
    let outcome: String
}
