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
        let activatedAppPubkey = await registerAndActivateConnectionBeforeReplyIfNeeded(
            request: request,
            identityID: identityID
        )
        let newState = await sessionManager.handleApprove(
            requestID: requestID,
            identityID: identityID,
            approvalMode: .remembered
        )
        if case let .completedError(reason) = newState {
            errorMessage = reason.userMessage
        }
        await rollBackConnectionIfNeeded(appPubkey: activatedAppPubkey, state: newState)
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
        let activatedAppPubkey = await registerAndActivateConnectionBeforeReplyIfNeeded(
            request: request,
            identityID: selectedIdentityID
        )
        let newState = await sessionManager.handleApprove(
            requestID: requestID,
            identityID: selectedIdentityID,
            rememberChoice: rememberChoice
        )
        sessionState = newState
        if case let .completedError(reason) = newState {
            errorMessage = reason.userMessage
        }
        await rollBackConnectionIfNeeded(appPubkey: activatedAppPubkey, state: newState)
        await refresh()
        return request?.method == .connect && newState == .completedSuccess
    }

    public func reject() async {
        guard let requestID = currentSession?.request.id else { return }
        let request = currentSession?.request
        let newState = await sessionManager.handleReject(requestID: requestID)
        sessionState = newState
        if case let .completedError(reason) = newState {
            errorMessage = reason.userMessage
        }
        // A refused pairing should not be remembered or listened to.
        if request?.method == .connect, let appPubkey = request?.appPubkey {
            await connectionRegistry?.forget(appPubkey: appPubkey)
        }
        await refresh()
    }

    /// Listen before publishing the connect response. NIP-46 clients may send
    /// `get_public_key` as soon as that response arrives, so subscribing afterwards
    /// leaves a race where the follow-up request can be missed.
    private func registerAndActivateConnectionBeforeReplyIfNeeded(
        request: NIP46Request?,
        identityID: String
    ) async -> String? {
        guard let request, request.method == .connect else { return nil }
        let pairing = DeepLinkRequest(
            clientPubkey: request.appPubkey,
            relays: request.relays,
            secret: request.params.first ?? "",
            requestedPerms: request.requestedPermissions,
            appName: request.appName,
            appURL: request.appURL
        )
        await connectionRegistry?.register(pairing: pairing, identityID: identityID)
        await connectionRegistry?.activate(appPubkey: request.appPubkey)
        return request.appPubkey
    }

    private func rollBackConnectionIfNeeded(appPubkey: String?, state: SessionState) async {
        guard let appPubkey, state != .completedSuccess else { return }
        await connectionRegistry?.forget(appPubkey: appPubkey)
    }
}
