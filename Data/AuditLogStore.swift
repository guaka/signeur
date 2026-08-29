import Foundation

public actor AuditLogStore {
    private let defaults: UserDefaults
    private let key = "signeur.audit.entries"
    private let retentionDays: Int

    public init(defaults: UserDefaults = .standard, retentionDays: Int = 90) {
        self.defaults = defaults
        self.retentionDays = retentionDays
    }

    public func append(_ entry: AuditEntry) throws {
        var entries = try list()
        entries.append(entry)
        entries = prune(entries)
        defaults.set(try JSONEncoder().encode(entries), forKey: key)
    }

    public func list() throws -> [AuditEntry] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([AuditEntry].self, from: data)
    }

    public func pruneExpired() throws {
        let entries = try list()
        defaults.set(try JSONEncoder().encode(prune(entries)), forKey: key)
    }

    private func prune(_ entries: [AuditEntry]) -> [AuditEntry] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast
        return entries.filter { $0.timestamp >= cutoff }.sorted { $0.timestamp > $1.timestamp }
    }
}
