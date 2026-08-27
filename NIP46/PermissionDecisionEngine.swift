import Foundation

public protocol PermissionRuleEvaluating: Sendable {
    func shouldAutoApprove(request: NIP46Request) async -> Bool
    func saveRememberRule(for request: NIP46Request) async
}
