import Foundation

public enum NIP46ValidationError: Error, Equatable, Sendable {
    case missingField(String)
    case unsupportedMethod(String)
    case invalidParamShape(String)
    case payloadTooLarge
}

public struct NIP46Validator: Sendable {
    public let supportedMethods: Set<NIP46Method>
    public let maxPayloadCharacters: Int

    public init(
        supportedMethods: Set<NIP46Method> = Set(NIP46Method.allCases),
        maxPayloadCharacters: Int = 12_000
    ) {
        self.supportedMethods = supportedMethods
        self.maxPayloadCharacters = maxPayloadCharacters
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
        guard supportedMethods.contains(request.method) else {
            return .failure(.unsupportedMethod(request.method.rawValue))
        }
        guard request.rawPayloadPreview.count <= maxPayloadCharacters else {
            return .failure(.payloadTooLarge)
        }
        return validateMethodParams(request)
    }

    private func validateMethodParams(_ request: NIP46Request) -> Result<Void, NIP46ValidationError> {
        switch request.method {
        case .connect:
            return .success(())
        case .getPublicKey, .ping, .switchRelays, .logout:
            return request.params.isEmpty ? .success(()) : .failure(.invalidParamShape(request.method.rawValue))
        case .signEvent:
            return request.params.count == 1 ? .success(()) : .failure(.invalidParamShape("sign_event expects one JSON event payload"))
        case .nip04Encrypt, .nip04Decrypt, .nip44Encrypt, .nip44Decrypt:
            return request.params.count == 2 ? .success(()) : .failure(.invalidParamShape("\(request.method.rawValue) expects [pubkey, payload]"))
        }
    }
}
