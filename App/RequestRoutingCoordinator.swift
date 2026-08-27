import Foundation

public actor RequestRoutingCoordinator {
    private let sessionManager: NIP46SessionManager
    private let payloadParser: PairingPayloadParser
    private let pairingFactory: PairingRequestFactory
    private let connectionRegistry: ConnectionRegistering?
    private let activeIdentityID: (@Sendable () async -> String?)?
    private let callbackTransport: NIP55CallbackTransport?

    public init(
        sessionManager: NIP46SessionManager,
        payloadParser: PairingPayloadParser = .init(),
        pairingFactory: PairingRequestFactory = .init(),
        connectionRegistry: ConnectionRegistering? = nil,
        activeIdentityID: (@Sendable () async -> String?)? = nil,
        callbackTransport: NIP55CallbackTransport? = nil
    ) {
        self.sessionManager = sessionManager
        self.payloadParser = payloadParser
        self.pairingFactory = pairingFactory
        self.connectionRegistry = connectionRegistry
        self.activeIdentityID = activeIdentityID
        self.callbackTransport = callbackTransport
    }

    @discardableResult
    public func routeIncomingRequest(_ request: NIP46Request) async -> SessionState {
        await sessionManager.onRequestArrived(request)
    }

    @discardableResult
    public func routePairing(_ pairing: DeepLinkRequest) async -> SessionState {
        if let connectionRegistry, let identityID = await activeIdentityID?(), !identityID.isEmpty {
            await connectionRegistry.register(pairing: pairing, identityID: identityID)
        }
        return await sessionManager.onRequestArrived(pairingFactory.makeConnectRequest(from: pairing))
    }

    /// Routes a pairing link from any entry point: scanned, pasted, or opened by another app.
    @discardableResult
    public func routeScannedPayload(_ payload: String) async throws -> SessionState {
        await routePairing(try payloadParser.parse(payload))
    }

    @discardableResult
    public func routeDeepLink(_ url: URL) async throws -> SessionState {
        await routePairing(try payloadParser.parse(url))
    }

    /// Handles a NIP-55 `nostrsigner:` request from another app on this device.
    @discardableResult
    public func routeSignerURL(_ url: URL) async throws -> SessionState {
        let signerRequest = try SignerURLRequest.parse(url)
        let request = signerRequest.makeNIP46Request()
        let state = await sessionManager.onRequestArrived(request)
        if state == .requestReceived {
            await callbackTransport?.register(
                requestID: request.id,
                callbackURL: signerRequest.callbackURL,
                returnType: signerRequest.returnType,
                method: signerRequest.method
            )
        }
        return state
    }
}
