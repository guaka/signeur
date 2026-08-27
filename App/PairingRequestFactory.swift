import CryptoKit
import Foundation

/// Turns a scanned or deep-linked pairing into a NIP-46 connect request the user can approve.
public struct PairingRequestFactory: Sendable {
    public init() {}

    public func makeConnectRequest(
        from pairing: DeepLinkRequest,
        id: String? = nil,
        requestedAt: Date = Date()
    ) -> NIP46Request {
        let requestID = id ?? Self.requestID(for: pairing)
        return NIP46Request(
            id: requestID,
            method: .connect,
            params: [pairing.secret],
            appName: pairing.appName,
            appURL: pairing.appURL,
            appPubkey: pairing.clientPubkey,
            requestedPermissions: pairing.requestedPerms,
            relays: pairing.relays,
            requestedAt: requestedAt,
            correlationID: requestID,
            rawPayloadPreview: SecurityPolicy.truncatedPreview(Self.preview(for: pairing)),
            origin: .pairing
        )
    }

    /// Derived from the pairing rather than random, so one code cannot queue two prompts.
    /// It is hashed because the request ID travels back to the app in responses.
    private static func requestID(for pairing: DeepLinkRequest) -> String {
        let digest = SHA256.hash(data: Data("\(pairing.clientPubkey):\(pairing.secret)".utf8))
        return "connect-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The pairing secret is deliberately left out; it is shown to nobody and only travels in `params`.
    private static func preview(for pairing: DeepLinkRequest) -> String {
        var lines = ["app: \(pairing.appName ?? "Unknown app")"]
        if let appURL = pairing.appURL {
            lines.append("url: \(appURL)")
        }
        lines.append("pubkey: \(pairing.clientPubkey)")
        lines.append("relays: \(pairing.relays.joined(separator: ", "))")
        lines.append("permissions: \(pairing.requestedPerms.isEmpty ? "none requested" : pairing.requestedPerms.joined(separator: ", "))")
        return lines.joined(separator: "\n")
    }
}
