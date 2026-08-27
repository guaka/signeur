import Foundation

public actor PermissionRuleStore: ConnectedAppsProviding, PermissionRuleEvaluating {
    private let defaults: UserDefaults
    private let key = "signstr.permission.rules"
    private let appNamesKey = "signstr.permission.appnames"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func save(rule: PermissionRule) throws {
        var rules = try listRules()
        rules.append(rule)
        defaults.set(try JSONEncoder().encode(rules), forKey: key)
    }

    public func listRules() throws -> [PermissionRule] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([PermissionRule].self, from: data)
    }

    public func rememberAppName(_ name: String, pubkey: String) {
        var names = defaults.dictionary(forKey: appNamesKey) as? [String: String] ?? [:]
        names[pubkey] = name
        defaults.set(names, forKey: appNamesKey)
    }

    public func listConnectedApps() async -> [ConnectedAppItem] {
        let rules = (try? listRules()) ?? []
        let grouped = Dictionary(grouping: rules, by: { $0.appPubkey })
        let names = defaults.dictionary(forKey: appNamesKey) as? [String: String] ?? [:]

        return grouped.map { pubkey, appRules in
            let methods = Array(Set(appRules.map { rule in
                if let kind = rule.kind {
                    return "\(rule.method):\(kind)"
                }
                return rule.method
            })).sorted()
            return ConnectedAppItem(
                appName: names[pubkey] ?? "Unknown app",
                appPubkey: pubkey,
                methods: methods
            )
        }.sorted(by: { $0.appName < $1.appName })
    }

    public func revoke(appPubkey: String) async {
        guard var rules = try? listRules() else { return }
        rules.removeAll { $0.appPubkey == appPubkey }
        defaults.set(try? JSONEncoder().encode(rules), forKey: key)
    }

    public func shouldAutoApprove(request: NIP46Request) async -> Bool {
        guard let rules = try? listRules() else { return false }
        let requestedKind = Self.extractKindIfAny(request: request)
        return rules.contains(where: { rule in
            guard rule.appPubkey == request.appPubkey, rule.method == request.method.rawValue else {
                return false
            }
            if request.method == .signEvent {
                return rule.kind == requestedKind
            }
            return true
        })
    }

    public func saveRememberRule(for request: NIP46Request) async {
        let rule = PermissionRule(
            appPubkey: request.appPubkey,
            method: request.method.rawValue,
            kind: Self.extractKindIfAny(request: request)
        )
        try? save(rule: rule)
        rememberAppName(request.appName ?? "Unknown app", pubkey: request.appPubkey)
    }

    private static func extractKindIfAny(request: NIP46Request) -> Int? {
        guard request.method == .signEvent, let raw = request.params.first else {
            return nil
        }
        guard
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let kind = object["kind"] as? Int
        else {
            return nil
        }
        return kind
    }
}
