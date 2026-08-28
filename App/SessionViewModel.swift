import Foundation
import SwiftUI

@MainActor
public final class SessionViewModel: ObservableObject {
    @Published public private(set) var currentSession: NIP46Session?
    @Published public private(set) var sessionState: SessionState = .idle
    @Published public private(set) var errorMessage: String?
    @Published public var rememberChoice: Bool = false
    @Published public var selectedIdentityID: String?
    @Published public private(set) var selectedIdentityName: String?

    private let sessionManager: NIP46SessionManager
    private let identityStore: IdentityStore
    private let connectionRegistry: ConnectionRegistering?

    public init(
        sessionManager: NIP46SessionManager,
        identityStore: IdentityStore,
        connectionRegistry: ConnectionRegistering? = nil
    ) {
        self.sessionManager = sessionManager
        self.identityStore = identityStore
        self.connectionRegistry = connectionRegistry
    }

    public func refresh() async {
        currentSession = await sessionManager.activateNextPendingIfNeeded()
        selectedIdentityID = await identityStore.activeIdentityID()
        let identities = await identityStore.list()
        selectedIdentityName = identities.first { $0.id == selectedIdentityID }?.displayName
        sessionState = currentSession?.stateMachine.state ?? .idle
        await autoApproveRememberedRequest()
    }

    /// Honours a "remember this app" choice without prompting again.
    private func autoApproveRememberedRequest() async {
        guard
            let requestID = currentSession?.request.id,
            let identityID = selectedIdentityID,
            !identityID.isEmpty,
            await sessionManager.shouldAutoApprove(requestID: requestID)
        else {
            return
        }

        let request = currentSession?.request
        let newState = await sessionManager.handleApprove(
            requestID: requestID,
            identityID: identityID,
            approvalMode: .remembered
        )
        if case let .completedError(reason) = newState {
            errorMessage = reason.rawValue
        }
        await activateConnectionIfNeeded(request: request, state: newState)
        currentSession = await sessionManager.activateNextPendingIfNeeded()
        sessionState = currentSession?.stateMachine.state ?? .idle
    }

    @discardableResult
    public func approve() async -> Bool {
        guard let requestID = currentSession?.request.id else { return false }
        guard let selectedIdentityID, !selectedIdentityID.isEmpty else {
            errorMessage = "Select an active key in Keys before approving."
            return false
        }
        let request = currentSession?.request
        let newState = await sessionManager.handleApprove(
            requestID: requestID,
            identityID: selectedIdentityID,
            rememberChoice: rememberChoice
        )
        sessionState = newState
        if case let .completedError(reason) = newState {
            errorMessage = reason.rawValue
        }
        await activateConnectionIfNeeded(request: request, state: newState)
        await refresh()
        return request?.method == .connect && newState == .completedSuccess
    }

    public func reject() async {
        guard let requestID = currentSession?.request.id else { return }
        let request = currentSession?.request
        let newState = await sessionManager.handleReject(requestID: requestID)
        sessionState = newState
        if case let .completedError(reason) = newState {
            errorMessage = reason.rawValue
        }
        // A refused pairing should not be remembered or listened to.
        if request?.method == .connect, let appPubkey = request?.appPubkey {
            await connectionRegistry?.forget(appPubkey: appPubkey)
        }
        await refresh()
    }

    /// An approved pairing is where a connection becomes real: it is remembered and we
    /// start listening for that app's later requests.
    private func activateConnectionIfNeeded(request: NIP46Request?, state: SessionState) async {
        guard let request, request.method == .connect, state == .completedSuccess else { return }
        await connectionRegistry?.activate(appPubkey: request.appPubkey)
    }
}
