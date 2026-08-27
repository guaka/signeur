import Foundation
import SwiftUI

@MainActor
public final class PairingViewModel: ObservableObject {
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var pairedAppName: String?
    @Published public private(set) var isBusy = false

    private let coordinator: RequestRoutingCoordinator
    private let payloadParser: PairingPayloadParser

    public init(
        coordinator: RequestRoutingCoordinator,
        payloadParser: PairingPayloadParser = .init()
    ) {
        self.coordinator = coordinator
        self.payloadParser = payloadParser
    }

    /// Returns `true` once the pairing is queued for approval.
    public func handleScannedPayload(_ payload: String) async -> Bool {
        await pair { try payloadParser.parse(payload) }
    }

    public func handlePastedText(_ text: String?) async -> Bool {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            errorMessage = "Nothing to paste. Copy the connection link from the app first."
            pairedAppName = nil
            return false
        }
        return await pair { try payloadParser.parse(trimmed) }
    }

    public func handleDeepLink(_ url: URL) async -> Bool {
        await pair { try payloadParser.parse(url) }
    }

    /// The single entry point for URLs another app opens us with: a pairing link,
    /// or a NIP-55 signing request.
    public func handleIncomingURL(_ url: URL) async -> Bool {
        if url.scheme?.lowercased() == "nostrsigner" {
            return await handleSignerURL(url)
        }
        return await handleDeepLink(url)
    }

    private func handleSignerURL(_ url: URL) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }

        do {
            _ = try await coordinator.routeSignerURL(url)
        } catch {
            errorMessage = Self.message(for: error)
            pairedAppName = nil
            return false
        }

        errorMessage = nil
        // Not a pairing, so no "connected" alert: the request itself is what needs review.
        pairedAppName = nil
        return true
    }

    public func reset() {
        errorMessage = nil
        pairedAppName = nil
    }

    private func pair(_ parse: () throws -> DeepLinkRequest) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }

        let pairing: DeepLinkRequest
        do {
            pairing = try parse()
        } catch {
            errorMessage = Self.message(for: error)
            pairedAppName = nil
            return false
        }

        let state = await coordinator.routePairing(pairing)
        if case .completedError = state {
            errorMessage = "This pairing request was not accepted. Ask the app to show a new code."
            pairedAppName = nil
            return false
        }

        errorMessage = nil
        pairedAppName = pairing.appName ?? "the app"
        return true
    }

    private static func message(for error: Error) -> String {
        if let signerError = error as? SignerURLParseError {
            switch signerError {
            case .invalidScheme:
                return "This is not a signing request Signstr understands."
            case let .unsupportedType(type):
                return "This app asked for \"\(type)\", which Signstr cannot do yet."
            case .missingPayload:
                return "This signing request has nothing in it to sign."
            case .missingPeerPubkey:
                return "This request does not say whose key to encrypt to."
            case let .unsupportedCompression(kind):
                return "This request is \(kind)-compressed, which Signstr cannot read yet."
            case .invalidCallback:
                return "This request contains an unsafe callback address."
            case .payloadTooLarge:
                return "This signing request is too large to process safely."
            }
        }

        switch error as? DeepLinkParseError {
        case .invalidScheme:
            return "That is not a Nostr Connect link. Look for a link starting with \"nostrconnect://\"."
        case .missingClientPubkey:
            return "This link is missing the app's public key."
        case .missingRelay:
            return "This link does not name a relay to answer on."
        case .missingSecret:
            return "This link is missing its pairing secret."
        case .invalidClientPubkey:
            return "This link contains an invalid app public key."
        case .invalidRelay:
            return "This link uses an insecure or invalid relay. Signstr requires WSS except for local development."
        case .invalidSecret:
            return "This link contains an invalid or oversized pairing secret."
        case .invalidMetadata:
            return "This link contains unsafe or oversized app metadata."
        case nil:
            return "This link could not be read."
        }
    }
}
