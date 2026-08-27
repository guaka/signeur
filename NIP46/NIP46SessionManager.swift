import Foundation

public protocol NIP46RespondingTransport: Sendable {
    func sendResponse(_ response: NIP46Response, to appPubkey: String) async throws
}

public protocol RequestAuthorization: Sendable {
    func canSign(session: NIP46Session) -> Bool
}

public actor NIP46SessionManager {
    private let validator: NIP46Validator
    private let executor: NIP46RequestExecuting
    private let transport: NIP46RespondingTransport
    private let authorizationGuard: RequestAuthorization
    private let permissionEvaluator: PermissionRuleEvaluating?
    private let sessionTTL: TimeInterval

    private var sessionsByRequestID: [String: NIP46Session] = [:]
    private var processingQueue: [String] = []
    private var activeSessionID: String?

    public init(
        validator: NIP46Validator,
        executor: NIP46RequestExecuting,
        transport: NIP46RespondingTransport,
        authorizationGuard: RequestAuthorization,
        permissionEvaluator: PermissionRuleEvaluating? = nil,
        sessionTTL: TimeInterval = 120
    ) {
        self.validator = validator
        self.executor = executor
        self.transport = transport
        self.authorizationGuard = authorizationGuard
        self.permissionEvaluator = permissionEvaluator
        self.sessionTTL = sessionTTL
    }

    @discardableResult
    public func onRequestArrived(_ request: NIP46Request) -> SessionState {
        if sessionsByRequestID[request.id] != nil {
            return .requestReceived
        }
        guard case .success = validator.validate(request) else {
            return .completedError(.invalidProtocol)
        }

        var machine = NIP46SessionStateMachine()
        _ = machine.transition(on: .onRequestArrived)
        let session = NIP46Session(
            request: request,
            stateMachine: machine,
            expiresAt: Date().addingTimeInterval(sessionTTL)
        )
        sessionsByRequestID[request.id] = session
        processingQueue.append(session.id)
        return machine.state
    }

    public func pendingSessions() -> [NIP46Session] {
        processingQueue.compactMap { queueID in
            sessionsByRequestID.values.first(where: { $0.id == queueID })
        }
    }

    public func activeSession() -> NIP46Session? {
        guard let activeSessionID else { return nil }
        return sessionsByRequestID.values.first(where: { $0.id == activeSessionID })
    }

    public func activateNextPendingIfNeeded() async -> NIP46Session? {
        if activeSessionID != nil { return activeSession() }
        while let nextID = processingQueue.first {
            guard let session = sessionsByRequestID.values.first(where: { $0.id == nextID }) else {
                processingQueue.removeFirst()
                continue
            }
            if session.expiresAt < Date() {
                expireSession(session.request.id)
                continue
            }
            activeSessionID = nextID
            return session
        }
        return nil
    }

    /// Whether a previously remembered permission covers this request.
    public func shouldAutoApprove(requestID: String) async -> Bool {
        guard let session = sessionsByRequestID[requestID], let permissionEvaluator else {
            return false
        }
        return await permissionEvaluator.shouldAutoApprove(request: session.request)
    }

    public func handleApprove(requestID: String, identityID: String, rememberChoice: Bool = false) async -> SessionState {
        guard var session = sessionsByRequestID[requestID] else { return .completedError(.invalidProtocol) }
        guard session.expiresAt > Date() else { return expireSession(requestID) }

        _ = session.stateMachine.transition(on: .onApprove)
        _ = session.stateMachine.transition(on: .onApprove)

        guard authorizationGuard.canSign(session: session) else {
            _ = session.stateMachine.transition(on: .onSignComplete(.failure(SessionFailureReason.unauthorizedSigningAttempt)))
            sessionsByRequestID[requestID] = session
            return .completedError(.unauthorizedSigningAttempt)
        }

        let result: String
        do {
            result = try await executor.execute(session.request, identityID: identityID)
        } catch {
            _ = session.stateMachine.transition(on: .onSignComplete(.failure(error)))
            sessionsByRequestID[requestID] = session
            // The requesting app is told, otherwise it waits for a reply that never comes.
            await sendFailure(.signingFailed, for: session)
            finishSession(session.id)
            return session.stateMachine.state
        }

        do {
            _ = session.stateMachine.transition(on: .onSignComplete(.success(Data(result.utf8))))
            let response = NIP46Response(id: requestID, result: result, error: nil)
            try await transport.sendResponse(response, to: session.request.appPubkey)
            _ = session.stateMachine.transition(on: .onSendComplete(.success(())))
            if rememberChoice {
                await permissionEvaluator?.saveRememberRule(for: session.request)
            }
        } catch {
            _ = session.stateMachine.transition(on: .onSendComplete(.failure(error)))
        }

        sessionsByRequestID[requestID] = session
        finishSession(session.id)
        return session.stateMachine.state
    }

    public func handleReject(requestID: String) async -> SessionState {
        guard var session = sessionsByRequestID[requestID] else { return .completedError(.invalidProtocol) }
        _ = session.stateMachine.transition(on: .onReject)

        let response = NIP46Response(
            id: requestID,
            result: nil,
            error: NIP46ResponseError(code: 4_001, message: SessionFailureReason.userRejected.rawValue)
        )
        do {
            try await transport.sendResponse(response, to: session.request.appPubkey)
        } catch {
            _ = session.stateMachine.transition(on: .onSendComplete(.failure(error)))
        }

        sessionsByRequestID[requestID] = session
        finishSession(session.id)
        return session.stateMachine.state
    }

    public func onTimeout(requestID: String) -> SessionState {
        expireSession(requestID)
    }

    @discardableResult
    private func expireSession(_ requestID: String) -> SessionState {
        guard var session = sessionsByRequestID[requestID] else { return .completedError(.invalidProtocol) }
        _ = session.stateMachine.transition(on: .onTimeout)
        sessionsByRequestID[requestID] = session
        finishSession(session.id)
        return session.stateMachine.state
    }

    private func sendFailure(_ reason: SessionFailureReason, for session: NIP46Session) async {
        let response = NIP46Response(
            id: session.request.id,
            result: nil,
            error: NIP46ResponseError(code: 5_000, message: reason.rawValue)
        )
        try? await transport.sendResponse(response, to: session.request.appPubkey)
    }

    private func finishSession(_ sessionID: String) {
        processingQueue.removeAll { $0 == sessionID }
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
    }
}
