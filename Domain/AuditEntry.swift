import Foundation

public enum AuditOutcome: String, Codable, Equatable, Sendable {
    case signed
    case rejected
    case expired
    case invalidRequest = "invalid_request"
    case signingFailed = "signing_failed"
    case deliveryFailed = "delivery_failed"
    case unauthorized
    case unknown
}

public enum AuditApprovalMode: String, Codable, Equatable, Sendable {
    case manual
    case remembered
    case notApplicable = "not_applicable"
}

public struct AuditEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let appName: String
    public let method: String
    public let outcome: AuditOutcome
    public let eventKind: Int?
    public let approvalMode: AuditApprovalMode

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        appName: String,
        method: String,
        outcome: AuditOutcome,
        eventKind: Int? = nil,
        approvalMode: AuditApprovalMode = .notApplicable
    ) {
        self.id = id
        self.timestamp = timestamp
        self.appName = appName
        self.method = method
        self.outcome = outcome
        self.eventKind = eventKind
        self.approvalMode = approvalMode
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case appName
        case method
        case outcome
        case eventKind
        case approvalMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        appName = try container.decode(String.self, forKey: .appName)
        method = try container.decode(String.self, forKey: .method)
        eventKind = try container.decodeIfPresent(Int.self, forKey: .eventKind)
        approvalMode = try container.decodeIfPresent(AuditApprovalMode.self, forKey: .approvalMode) ?? .notApplicable

        let storedOutcome = try container.decode(String.self, forKey: .outcome)
        outcome = AuditOutcome(rawValue: storedOutcome) ?? Self.migrateLegacyOutcome(storedOutcome)
    }

    private static func migrateLegacyOutcome(_ outcome: String) -> AuditOutcome {
        switch outcome {
        case "approved", "success": return .signed
        case "userRejected": return .rejected
        case "timeout": return .expired
        case "invalidProtocol": return .invalidRequest
        case "signingFailed": return .signingFailed
        case "transportFailure": return .deliveryFailed
        case "unauthorizedSigningAttempt": return .unauthorized
        default: return .unknown
        }
    }
}
