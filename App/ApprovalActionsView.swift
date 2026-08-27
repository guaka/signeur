import SwiftUI

public struct ApprovalActionsView: View {
    public let approve: () -> Void
    public let reject: () -> Void
    @Binding public var rememberChoice: Bool
    private let approveTitle: String
    private let rejectTitle: String
    private let showsRememberChoice: Bool

    public init(
        approve: @escaping () -> Void,
        reject: @escaping () -> Void,
        rememberChoice: Binding<Bool>,
        approveTitle: String = "Approve",
        rejectTitle: String = "Reject",
        showsRememberChoice: Bool = true
    ) {
        self.approve = approve
        self.reject = reject
        _rememberChoice = rememberChoice
        self.approveTitle = approveTitle
        self.rejectTitle = rejectTitle
        self.showsRememberChoice = showsRememberChoice
    }

    public var body: some View {
        VStack(spacing: 12) {
            if showsRememberChoice {
                Toggle("Remember for this app + method", isOn: $rememberChoice)
            }
            HStack {
                Button(rejectTitle, role: .destructive, action: reject)
                Spacer()
                Button(approveTitle, action: approve)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
