import SwiftUI
import XCTest
@testable import SignstrCore

@MainActor
final class ActivityViewTests: XCTestCase {
    func testViewModelRefreshLoadsEntries() async {
        let provider = StubActivityProvider(entries: [entry(outcome: .signed)])
        let viewModel = ActivityViewModel(provider: provider)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.entries.map(\.outcome), [.signed])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testViewModelReportsLoadFailure() async {
        let provider = StubActivityProvider(entries: [], shouldThrow: true)
        let viewModel = ActivityViewModel(provider: provider)

        await viewModel.refresh()

        XCTAssertTrue(viewModel.entries.isEmpty)
        XCTAssertEqual(viewModel.errorMessage, "Signstr could not load activity history.")
    }

    func testViewModelClearForwardsAndRefreshes() async {
        let provider = StubActivityProvider(entries: [entry(outcome: .signed)])
        let viewModel = ActivityViewModel(provider: provider)
        await viewModel.refresh()

        await viewModel.clear()

        XCTAssertTrue(viewModel.entries.isEmpty)
        let clearCount = await provider.clearCount()
        XCTAssertEqual(clearCount, 1)
    }

    func testActivityViewBuildsEmptyPopulatedAndErrorStates() async {
        let emptyViewModel = ActivityViewModel(provider: StubActivityProvider(entries: []))
        await emptyViewModel.refresh()
        _ = ActivityView(viewModel: emptyViewModel).body

        let populatedViewModel = ActivityViewModel(
            provider: StubActivityProvider(entries: [entry(outcome: .signed)])
        )
        await populatedViewModel.refresh()
        _ = ActivityView(viewModel: populatedViewModel).body

        let errorViewModel = ActivityViewModel(
            provider: StubActivityProvider(entries: [], shouldThrow: true)
        )
        await errorViewModel.refresh()
        _ = ActivityView(viewModel: errorViewModel).body
    }

    func testRowsFormatEveryOutcomeAndApprovalMode() {
        let expectations: [(AuditOutcome, String, String)] = [
            (.signed, "Signed", "checkmark.circle.fill"),
            (.rejected, "Rejected", "xmark.circle.fill"),
            (.expired, "Expired", "clock.badge.exclamationmark"),
            (.invalidRequest, "Invalid request", "exclamationmark.shield.fill"),
            (.signingFailed, "Signing failed", "exclamationmark.triangle.fill"),
            (.deliveryFailed, "Response delivery failed", "exclamationmark.triangle.fill"),
            (.unauthorized, "Unauthorized", "exclamationmark.shield.fill"),
            (.unknown, "Unknown outcome", "exclamationmark.triangle.fill")
        ]

        for (outcome, title, icon) in expectations {
            let row = ActivityRow(entry: entry(outcome: outcome))
            XCTAssertEqual(row.outcomeTitle, title)
            XCTAssertEqual(row.outcomeIcon, icon)
            _ = row.outcomeColor
            _ = row.body
        }

        XCTAssertEqual(ActivityRow(entry: entry(outcome: .signed)).eventDescription, "Nostr event kind 1")
        XCTAssertEqual(
            ActivityRow(entry: entry(outcome: .signed, eventKind: nil, approvalMode: .notApplicable)).eventDescription,
            "Nostr event"
        )
        _ = ActivityRow(entry: entry(outcome: .signed, approvalMode: .remembered)).body
        _ = ActivityRow(entry: entry(outcome: .signed, approvalMode: .manual)).body
        _ = ActivityRow(entry: entry(outcome: .rejected, approvalMode: .manual)).body
    }

    private func entry(
        outcome: AuditOutcome,
        eventKind: Int? = 1,
        approvalMode: AuditApprovalMode = .manual
    ) -> AuditEntry {
        AuditEntry(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            appName: "Damus",
            method: "sign_event",
            outcome: outcome,
            eventKind: eventKind,
            approvalMode: approvalMode
        )
    }
}

private actor StubActivityProvider: AuditLogProviding {
    private var entries: [AuditEntry]
    private let shouldThrow: Bool
    private var clears = 0

    init(entries: [AuditEntry], shouldThrow: Bool = false) {
        self.entries = entries
        self.shouldThrow = shouldThrow
    }

    func append(_ entry: AuditEntry) async throws {
        entries.append(entry)
    }

    func list() async throws -> [AuditEntry] {
        if shouldThrow { throw StubStorageError() }
        return entries
    }

    func clear() async {
        clears += 1
        entries = []
    }

    func clearCount() -> Int { clears }
}
