import Foundation

public protocol NIP46RespondingTransport: Sendable {
    func sendResponse(_ response: NIP46Response, to appPubkey: String) async throws
}

public protocol RequestAuthorization: Sendable {
    func canExecute(session: NIP46Session) -> Bool
}

public actor NIP46SessionManager {
    private let validator: NIP46Validator
    private let executor: NIP46RequestExecuting
    private let transport: NIP46RespondingTransport
    private let authorizationGuard: RequestAuthorization
    private let permissionEvaluator: PermissionRuleEvaluating?
    private let auditLog: AuditLogProviding?
    private let sessionTTL: TimeInterval

    private var sessionsByRequestID: [String: NIP46Session] = [:]
    private var processingQueue: [String] = []
    private var activeSessionID: String?
    private var auditedRequestIDs: Set<String> = []

    public init(
        validator: NIP46Validator,
        executor: NIP46RequestExecuting,
        transport: NIP46RespondingTransport,
        authorizationGuard: RequestAuthorization,
        permissionEvaluator: PermissionRuleEvaluating? = nil,
        auditLog: AuditLogProviding? = nil,
        sessionTTL: TimeInterval = 120
    ) {
        self.validator = validator
        self.executor = executor
        self.transport = transport
        self.authorizationGuard = authorizationGuard
        self.permissionEvaluator = permissionEvaluator
        self.auditLog = auditLog
        self.sessionTTL = sessionTTL
    }

    @discardableResult
    public func onRequestArrived(_ request: NIP46Request) async -> SessionState {
        if sessionsByRequestID[request.id] != nil {
            return .requestReceived
        }
        guard case .success = validator.validate(request) else {
            await recordAudit(for: request, outcome: .invalidRequest, approvalMode: .notApplicable)
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
            guard let session = sessionsByRequestID.values.first(where: { $0.id == nextID }) else { // coverage:ignore-region Queue and session mutations are actor-isolated and preserve this invariant.
                processingQueue.removeFirst()
                continue
            }
            if session.expiresAt < Date() {
                await expireSession(session.request.id)
                continue
            }
            activeSessionID = nextID
            return session
        }
        return nil
    }

    /// Whether a previously remembered permission covers this request.
    public func shouldAutoApprove(requestID: String) async -> Bool {
        guard let session = sessionsByRequestID[requestID],
              session.stateMachine.state == .requestReceived,
              let permissionEvaluator
        else {
            return false
        }
        return await permissionEvaluator.shouldAutoApprove(request: session.request)
    }

    public func handleApprove(
        requestID: String,
        identityID: String,
        rememberChoice: Bool = false,
        approvalMode: AuditApprovalMode = .manual
    ) async -> SessionState {
        guard var session = sessionsByRequestID[requestID] else { return .completedError(.invalidProtocol) }
        guard session.expiresAt > Date() else { return await expireSession(requestID) }
        guard session.stateMachine.state == .requestReceived else {
            return session.stateMachine.state
        }
        guard SecurityPolicy.validateIdentifier(identityID) else {
            finishSession(session.id)
            await recordAudit(for: session.request, outcome: .unauthorized, approvalMode: approvalMode)
            return .completedError(.unauthorizedSigningAttempt)
        }

        session.identityID = identityID
        _ = session.stateMachine.transition(on: .onApprove)
        _ = session.stateMachine.transition(on: .onApprove)
        // Commit the in-flight state before the first await. Actor reentrancy must not
        // allow a second click, timeout, or rejection to execute the request twice.
        sessionsByRequestID[requestID] = session

        guard authorizationGuard.canExecute(session: session) else {
            _ = session.stateMachine.transition(on: .onSignComplete(.failure(SessionFailureReason.unauthorizedSigningAttempt)))
            sessionsByRequestID[requestID] = session
            finishSession(session.id)
            await recordAudit(for: session.request, outcome: .unauthorized, approvalMode: approvalMode)
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
            await recordAudit(for: session.request, outcome: .signingFailed, approvalMode: approvalMode)
            return session.stateMachine.state
        }

        do {
            _ = session.stateMachine.transition(on: .onSignComplete(.success(Data(result.utf8))))
            sessionsByRequestID[requestID] = session
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
        let outcome: AuditOutcome = session.stateMachine.state == .completedSuccess ? .signed : .deliveryFailed
        await recordAudit(for: session.request, outcome: outcome, approvalMode: approvalMode)
        return session.stateMachine.state
    }

    public func handleReject(requestID: String) async -> SessionState {
        guard var session = sessionsByRequestID[requestID] else { return .completedError(.invalidProtocol) }
        guard session.stateMachine.state == .requestReceived || session.stateMachine.state == .awaitingUserDecision else {
            return session.stateMachine.state
        }
        _ = session.stateMachine.transition(on: .onReject)
        sessionsByRequestID[requestID] = session

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
        await recordAudit(for: session.request, outcome: .rejected, approvalMode: .manual)
        return session.stateMachine.state
    }

    public func onTimeout(requestID: String) async -> SessionState {
        await expireSession(requestID)
    }

    @discardableResult
    private func expireSession(_ requestID: String) async -> SessionState {
        guard var session = sessionsByRequestID[requestID] else { return .completedError(.invalidProtocol) }
        guard session.stateMachine.state == .requestReceived || session.stateMachine.state == .awaitingUserDecision else {
            return session.stateMachine.state
        }
        _ = session.stateMachine.transition(on: .onTimeout)
        sessionsByRequestID[requestID] = session
        finishSession(session.id)
        await recordAudit(for: session.request, outcome: .expired, approvalMode: .notApplicable)
        return session.stateMachine.state
    }

    private func recordAudit(
        for request: NIP46Request,
        outcome: AuditOutcome,
        approvalMode: AuditApprovalMode
    ) async {
        guard request.method == .signEvent, let auditLog else { return }
        guard auditedRequestIDs.insert(request.id).inserted else { return } // coverage:ignore-region Terminal session guards prevent the same request from reaching audit twice.

        let eventKind = request.params.first.flatMap { payload in
            try? UnsignedNostrEvent.decode(json: payload).kind
        }
        let entry = AuditEntry(
            appName: request.appName ?? "Unknown app",
            method: request.method.rawValue,
            outcome: outcome,
            eventKind: eventKind,
            approvalMode: approvalMode
        )
        try? await auditLog.append(entry)
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
