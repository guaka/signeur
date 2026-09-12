import XCTest
@testable import SigneurCore

final class NIP46SessionStateMachineTests: XCTestCase {
    func testEveryFailureHasUniqueUnderstandableUserCopyAndDiagnosticCode() {
        let failures: [SessionFailureReason] = [
            .userRejected, .invalidProtocol, .timeout, .signingFailed, .transportFailure,
            .connectionNotRegistered, .identityKeyUnavailable, .responseEncryptionFailed,
            .relayUnavailable, .keyAuthenticationFailed, .keyAuthenticationCanceled,
            .keychainInteractionNotAllowed, .keychainPermissionMissing,
            .keychainProtectionUnavailable, .keychainUnavailable, .storedKeyInvalid,
            .keychainUnexpectedError, .unauthorizedSigningAttempt
        ]
        let messages = failures.map(\.userMessage)

        XCTAssertEqual(Set(messages).count, failures.count)
        XCTAssertTrue(messages.allSatisfy { $0.contains("N46-") })
        XCTAssertTrue(messages.allSatisfy { $0.contains(" ") })
    }

    func testExpiryTransitionsToExpired() {
        var machine = NIP46SessionStateMachine()
        _ = machine.transition(on: .onRequestArrived)
        _ = machine.transition(on: .onTimeout)
        XCTAssertEqual(machine.state, .expired)
    }

    func testStartsIdle() {
        XCTAssertEqual(NIP46SessionStateMachine().state, .idle)
    }

    func testHappyPathWalksToCompletedSuccess() {
        var machine = NIP46SessionStateMachine()
        XCTAssertEqual(machine.transition(on: .onRequestArrived), .requestReceived)
        XCTAssertEqual(machine.transition(on: .onApprove), .awaitingUserDecision)
        XCTAssertEqual(machine.transition(on: .onApprove), .signing)
        XCTAssertEqual(machine.transition(on: .onSignComplete(.success(Data("sig".utf8)))), .sendingResponse)
        XCTAssertEqual(machine.transition(on: .onSendComplete(.success(()))), .completedSuccess)
        XCTAssertTrue(machine.state.isTerminal)
    }

    func testRejectingAPromptEndsInUserRejected() {
        var machine = NIP46SessionStateMachine()
        _ = machine.transition(on: .onRequestArrived)
        XCTAssertEqual(machine.transition(on: .onReject), .completedError(.userRejected))
    }

    func testRejectingDuringConfirmationCancels() {
        var machine = NIP46SessionStateMachine()
        _ = machine.transition(on: .onRequestArrived)
        _ = machine.transition(on: .onApprove)
        XCTAssertEqual(machine.transition(on: .onReject), .cancelled)
    }

    func testSigningFailureIsReportedAsFailure() {
        var machine = NIP46SessionStateMachine()
        _ = machine.transition(on: .onRequestArrived)
        _ = machine.transition(on: .onApprove)
        _ = machine.transition(on: .onApprove)
        XCTAssertEqual(
            machine.transition(on: .onSignComplete(.failure(SessionFailureReason.signingFailed))),
            .completedError(.signingFailed)
        )
    }

    func testSendFailureIsReportedAsFailure() {
        var machine = NIP46SessionStateMachine()
        _ = machine.transition(on: .onRequestArrived)
        _ = machine.transition(on: .onApprove)
        _ = machine.transition(on: .onApprove)
        _ = machine.transition(on: .onSignComplete(.success(Data())))
        XCTAssertEqual(
            machine.transition(on: .onSendComplete(.failure(SessionFailureReason.transportFailure))),
            .completedError(.transportFailure)
        )
    }

    func testSigningCannotBeReachedWithoutTwoApprovals() {
        var machine = NIP46SessionStateMachine()
        _ = machine.transition(on: .onRequestArrived)
        _ = machine.transition(on: .onSignComplete(.success(Data("sig".utf8))))
        XCTAssertEqual(machine.state, .requestReceived, "a signature must not be accepted before approval")
    }

    func testUnrelatedEventsLeaveStateUnchanged() {
        var machine = NIP46SessionStateMachine()
        _ = machine.transition(on: .onRequestArrived)
        _ = machine.transition(on: .onSendComplete(.success(())))
        XCTAssertEqual(machine.state, .requestReceived)
    }

    func testCancelIsAcceptedFromAnyState() {
        for events in [[SessionEvent.onRequestArrived], [.onRequestArrived, .onApprove], [.onRequestArrived, .onApprove, .onApprove]] {
            var machine = NIP46SessionStateMachine()
            events.forEach { _ = machine.transition(on: $0) }
            XCTAssertEqual(machine.transition(on: .onCancel), .cancelled)
        }
    }

    func testTerminalStatesAreClassifiedCorrectly() {
        XCTAssertFalse(SessionState.idle.isTerminal)
        XCTAssertFalse(SessionState.requestReceived.isTerminal)
        XCTAssertFalse(SessionState.awaitingUserDecision.isTerminal)
        XCTAssertFalse(SessionState.signing.isTerminal)
        XCTAssertFalse(SessionState.sendingResponse.isTerminal)
        XCTAssertTrue(SessionState.completedSuccess.isTerminal)
        XCTAssertTrue(SessionState.completedError(.timeout).isTerminal)
        XCTAssertTrue(SessionState.expired.isTerminal)
        XCTAssertTrue(SessionState.cancelled.isTerminal)
    }
}
