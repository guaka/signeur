import Foundation

public enum SecurityPolicyError: Error, Equatable, Sendable {
    case invalidPublicKey
    case invalidRelay
    case tooManyRelays
    case invalidMetadataURL
    case invalidText
    case valueTooLarge
}

/// Central limits and URL/key validation for data that crosses Signstr's trust boundary.
public enum SecurityPolicy {
    public static let maxIdentifierBytes = 256
    public static let maxSecretBytes = 256
    public static let maxMetadataBytes = 512
    public static let maxRelays = 8
    public static let maxRelayURLBytes = 2_048
    public static let maxRequestPayloadBytes = 65_535
    public static let maxPreviewCharacters = 12_000
    public static let maxEventTags = 256
    public static let maxTagValues = 32

    public static func isCanonicalPublicKey(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    public static func validateIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed.utf8.count <= maxIdentifierBytes
            && !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    public static func validateSecret(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maxSecretBytes
    }

    public static func validateMetadataText(_ value: String) -> Bool {
        value.utf8.count <= maxMetadataBytes
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    public static func sanitizeRelays(_ values: [String]) throws -> [String] {
        guard !values.isEmpty else { throw SecurityPolicyError.invalidRelay }
        guard values.count <= maxRelays else { throw SecurityPolicyError.tooManyRelays }

        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let canonical = try canonicalRelay(value)
            if seen.insert(canonical).inserted {
                result.append(canonical)
            }
        }
        guard !result.isEmpty else { throw SecurityPolicyError.invalidRelay }
        return result
    }

    public static func validRelays(from values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { try? canonicalRelay($0) }.filter { seen.insert($0).inserted }
    }

    public static func canonicalRelay(_ value: String) throws -> String {
        guard value.utf8.count <= maxRelayURLBytes,
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              scheme == "wss" || (scheme == "ws" && isLoopback(host: host))
        else {
            throw SecurityPolicyError.invalidRelay
        }

        components.scheme = scheme
        components.host = host
        guard let canonical = components.url?.absoluteString else {
            throw SecurityPolicyError.invalidRelay
        }
        return canonical
    }

    public static func canonicalMetadataURL(_ value: String) throws -> String {
        guard value.utf8.count <= maxRelayURLBytes,
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              scheme == "https" || (scheme == "http" && isLoopback(host: host))
        else {
            throw SecurityPolicyError.invalidMetadataURL
        }
        components.scheme = scheme
        components.host = host
        guard let canonical = components.url?.absoluteString else {
            throw SecurityPolicyError.invalidMetadataURL
        }
        return canonical
    }

    public static func truncatedPreview(_ value: String) -> String {
        String(value.prefix(maxPreviewCharacters))
    }

    public static func isLoopback(host: String) -> Bool {
        let lowered = host.lowercased()
        let normalized = lowered.hasPrefix("[") && lowered.hasSuffix("]")
            ? String(lowered.dropFirst().dropLast())
            : lowered
        if normalized == "localhost" || normalized == "::1" { return true }
        let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = Int(octets[0]), first == 127,
              octets.allSatisfy({ part in Int(part).map { (0...255).contains($0) } == true })
        else {
            return false
        }
        return true
    }
}
