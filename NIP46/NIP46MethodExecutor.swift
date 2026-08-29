import Foundation

public enum NIP46ExecutionError: Error, Equatable {
    case noKeyStoredForIdentity
    case invalidStoredKey
    case missingParameter(String)
    case invalidPubkeyParameter
    case malformedEvent
    case signingFailed
    case encryptionFailed
    case decryptionFailed
}

/// Produces the `result` a NIP-46 client expects for a request it asked us to perform.
public protocol NIP46RequestExecuting: Sendable {
    func execute(_ request: NIP46Request, identityID: String) async throws -> String
    func publicKeyHex(identityID: String) async throws -> String
}

/// Carries out approved NIP-46 requests with the identity's key material.
///
/// Each method returns the exact string the requesting app expects as `result`:
/// a signed event JSON for `sign_event`, a pubkey for `get_public_key`, and so on.
public actor NIP46MethodExecutor: NIP46RequestExecuting {
    private let nsecStore: NsecStoring
    private let identityStore: IdentityStore?
    private let now: @Sendable () -> Date

    public init(
        nsecStore: NsecStoring,
        identityStore: IdentityStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.nsecStore = nsecStore
        self.identityStore = identityStore
        self.now = now
    }

    public func publicKeyHex(identityID: String) async throws -> String {
        let secret = try await secretKey(for: identityID)
        return try hex(NostrKeyDeriver.xonlyPublicKeyBytes(fromSecretKey: secret))
    }

    public func execute(_ request: NIP46Request, identityID: String) async throws -> String {
        switch request.method {
        case .connect:
            // Unlock the identity while the approval sheet is active. The response transport
            // needs this key immediately afterwards to encrypt and sign the pairing reply.
            _ = try await secretKey(for: identityID)
            // The app expects its pairing secret echoed back. A bunker-style request puts the
            // signer pubkey first, while a nostrconnect pairing sends the secret on its own.
            return request.params.first { !$0.isEmpty && !isPubkeyHex($0) } ?? "ack"

        case .ping:
            return "pong"

        case .getPublicKey:
            return try await publicKeyHex(identityID: identityID)

        case .signEvent:
            guard let json = request.params.first else {
                throw NIP46ExecutionError.missingParameter("event")
            }
            let secret = try await secretKey(for: identityID)
            let unsigned: UnsignedNostrEvent
            do {
                unsigned = try UnsignedNostrEvent.decode(json: json)
            } catch {
                throw NIP46ExecutionError.malformedEvent
            }
            do {
                return try NostrEventFactory.json(for: try NostrEventFactory.sign(unsigned, privateKey: secret, now: now()))
            } catch { // coverage:ignore Signing cannot fail after the validated secret and event checks above.
                throw NIP46ExecutionError.signingFailed
            }

        case .nip04Encrypt, .nip44Encrypt:
            let (peer, payload) = try parameters(of: request)
            let secret = try await secretKey(for: identityID)
            do {
                return request.method == .nip04Encrypt
                    ? try NIP04.encrypt(plaintext: payload, privateKey: secret, publicKeyXOnly: peer)
                    : try NIP44.encrypt(plaintext: payload, privateKey: secret, publicKeyXOnly: peer)
            } catch {
                throw NIP46ExecutionError.encryptionFailed
            }

        case .nip04Decrypt, .nip44Decrypt:
            let (peer, payload) = try parameters(of: request)
            let secret = try await secretKey(for: identityID)
            do {
                return request.method == .nip04Decrypt
                    ? try NIP04.decrypt(payload: payload, privateKey: secret, publicKeyXOnly: peer)
                    : try NIP44.decrypt(payload: payload, privateKey: secret, publicKeyXOnly: peer)
            } catch {
                throw NIP46ExecutionError.decryptionFailed
            }

        case .switchRelays, .logout:
            // Handled by the app itself; the client only needs an acknowledgement.
            return "ack"
        }
    }

    private func parameters(of request: NIP46Request) throws -> (peer: [UInt8], payload: String) {
        guard request.params.count >= 2 else {
            throw NIP46ExecutionError.missingParameter("\(request.method.rawValue) expects [pubkey, payload]")
        }
        guard isPubkeyHex(request.params[0]), let peer = try? NostrEventFactory.hexBytes(request.params[0]) else {
            throw NIP46ExecutionError.invalidPubkeyParameter
        }
        return (peer, request.params[1])
    }

    private func secretKey(for identityID: String) async throws -> [UInt8] {
        guard let nsec = try await nsecStore.loadNsec(for: identityID) else {
            throw NIP46ExecutionError.noKeyStoredForIdentity
        }
        do {
            let secret = try NostrKeyDeriver.secretKeyBytes(fromNsec: nsec)
            await identityStore?.markUsed(identityID: identityID, at: now())
            return secret
        } catch {
            throw NIP46ExecutionError.invalidStoredKey
        }
    }

    private func isPubkeyHex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
