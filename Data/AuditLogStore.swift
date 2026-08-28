import Foundation

public protocol AuditLogProviding: Sendable {
    func append(_ entry: AuditEntry) async throws
    func list() async throws -> [AuditEntry]
    func clear() async
}

public actor AuditLogStore: AuditLogProviding {
    private let defaults: UserDefaults
    private let key = "signstr.audit.entries"
    private let retentionDays: Int

    public init(defaults: UserDefaults = .standard, retentionDays: Int = 90) {
        self.defaults = defaults
        self.retentionDays = retentionDays
    }

    public func append(_ entry: AuditEntry) async throws {
        var entries = try await list()
        entries.append(entry)
        entries = prune(entries)
        defaults.set(try JSONEncoder().encode(entries), forKey: key)
    }

    public func list() async throws -> [AuditEntry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let entries = try JSONDecoder().decode([AuditEntry].self, from: data)
        let retained = prune(entries)
        if retained != entries {
            defaults.set(try JSONEncoder().encode(retained), forKey: key)
        }
        return retained
    }

    public func clear() async {
        defaults.removeObject(forKey: key)
    }

    public func pruneExpired() async throws {
        _ = try await list()
    }

    private func prune(_ entries: [AuditEntry]) -> [AuditEntry] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast
        return entries.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp > $1.timestamp }
    }
}
