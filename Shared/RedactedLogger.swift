import Foundation

public struct RedactedLogger: Sendable {
    public static let redactionPlaceholder = "[REDACTED]"

    /// Metadata keys whose values are never safe to print.
    private static let sensitiveKeyFragments = ["nsec", "secret", "seckey", "privkey", "private", "signature", "token"]

    private let maxPlainValueLength: Int
    private let emit: @Sendable (String) -> Void

    public init(
        maxPlainValueLength: Int = 48,
        emit: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.maxPlainValueLength = maxPlainValueLength
        self.emit = emit
    }

    public func log(event: String, metadata: [String: String]) {
        emit("[signstr] \(event) \(redact(metadata))")
    }

    public func redact(_ metadata: [String: String]) -> [String: String] {
        metadata.reduce(into: [:]) { result, pair in
            result[pair.key] = shouldRedact(key: pair.key, value: pair.value)
                ? Self.redactionPlaceholder
                : pair.value
        }
    }

    private func shouldRedact(key: String, value: String) -> Bool {
        let loweredKey = key.lowercased()
        if Self.sensitiveKeyFragments.contains(where: { loweredKey.contains($0) }) {
            return true
        }
        // Catches key material pasted into an unexpected field, plus anything
        // long enough to be an event body or signature.
        return value.lowercased().hasPrefix("nsec1") || value.count > maxPlainValueLength
    }
}
