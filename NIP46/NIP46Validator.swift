import Foundation

public enum NIP46ValidationError: Error, Equatable, Sendable {
    case missingField(String)
    case invalidField(String)
    case unsupportedMethod(String)
    case invalidParamShape(String)
    case payloadTooLarge
}

public struct NIP46Validator: Sendable {
    public let supportedMethods: Set<NIP46Method>
    public let maxPayloadCharacters: Int
    public let maxPayloadBytes: Int

    public init(
        supportedMethods: Set<NIP46Method> = Set(NIP46Method.allCases),
        maxPayloadCharacters: Int = SecurityPolicy.maxPreviewCharacters,
        maxPayloadBytes: Int = SecurityPolicy.maxRequestPayloadBytes
    ) {
        self.supportedMethods = supportedMethods
        self.maxPayloadCharacters = maxPayloadCharacters
        self.maxPayloadBytes = maxPayloadBytes
    }

    public func validate(_ request: NIP46Request) -> Result<Void, NIP46ValidationError> {
        guard !request.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.missingField("id"))
        }
        guard !request.correlationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.missingField("correlationID"))
        }
        guard !request.appPubkey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(.missingField("appPubkey"))
        }
        guard SecurityPolicy.validateIdentifier(request.id) else {
            return .failure(.invalidField("id"))
        }
        guard SecurityPolicy.validateIdentifier(request.correlationID) else {
            return .failure(.invalidField("correlationID"))
        }
        switch request.origin {
        case .pairing, .relay:
            guard SecurityPolicy.isCanonicalPublicKey(request.appPubkey) else {
                return .failure(.invalidField("appPubkey"))
            }
        case .localSigner:
            guard request.appPubkey.hasPrefix("nostrsigner:"), SecurityPolicy.validateIdentifier(request.appPubkey) else {
                return .failure(.invalidField("appPubkey"))
            }
        }
        if let appName = request.appName, !SecurityPolicy.validateMetadataText(appName) {
            return .failure(.invalidField("appName"))
        }
        if let appURL = request.appURL, request.origin != .localSigner,
           (try? SecurityPolicy.canonicalMetadataURL(appURL)) == nil {
            return .failure(.invalidField("appURL"))
        }
        if !request.relays.isEmpty, (try? SecurityPolicy.sanitizeRelays(request.relays)) == nil {
            return .failure(.invalidField("relays"))
        }
        guard request.requestedPermissions.count <= 32,
              request.requestedPermissions.allSatisfy(SecurityPolicy.validateMetadataText)
        else {
            return .failure(.invalidField("requestedPermissions"))
        }
        guard supportedMethods.contains(request.method) else {
            return .failure(.unsupportedMethod(request.method.rawValue))
        }
        guard request.rawPayloadPreview.count <= maxPayloadCharacters else {
            return .failure(.payloadTooLarge)
        }
        let payloadBytes = request.params.reduce(0) { $0 + $1.utf8.count }
        guard payloadBytes <= maxPayloadBytes else {
            return .failure(.payloadTooLarge)
        }
        return validateMethodParams(request)
    }

    private func validateMethodParams(_ request: NIP46Request) -> Result<Void, NIP46ValidationError> {
        switch request.method {
        case .connect:
            guard request.params.count == 1, SecurityPolicy.validateSecret(request.params[0]) else {
                return .failure(.invalidParamShape("connect expects one bounded secret"))
            }
            return .success(())
        case .getPublicKey, .ping, .switchRelays, .logout:
            return request.params.isEmpty ? .success(()) : .failure(.invalidParamShape(request.method.rawValue))
        case .signEvent:
            guard request.params.count == 1 else {
                return .failure(.invalidParamShape("sign_event expects one JSON event payload"))
            }
            guard (try? UnsignedNostrEvent.decode(json: request.params[0])) != nil else {
                return .failure(.invalidParamShape("sign_event expects a valid bounded event"))
            }
            return .success(())
        case .nip04Encrypt, .nip04Decrypt, .nip44Encrypt, .nip44Decrypt:
            guard request.params.count == 2,
                  SecurityPolicy.isCanonicalPublicKey(request.params[0]),
                  !request.params[1].isEmpty
            else {
                return .failure(.invalidParamShape("\(request.method.rawValue) expects [pubkey, payload]"))
            }
            return .success(())
        }
    }
}
