import SwiftUI

public struct IncomingRequestView: View {
    @ObservedObject private var viewModel: SessionViewModel
    @State private var showDetails = false
    private let connectActions: [ConnectAction]
    private let onConnectionApproved: (() -> Void)?

    /// A way to start a connection from the empty state, e.g. scanning or pasting a link.
    public struct ConnectAction: Identifiable {
        public let id = UUID()
        public let title: String
        public let systemImage: String
        public let action: () -> Void

        public init(title: String, systemImage: String, action: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.action = action
        }
    }

    public init(
        viewModel: SessionViewModel,
        connectActions: [ConnectAction] = [],
        onConnectionApproved: (() -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.connectActions = connectActions
        self.onConnectionApproved = onConnectionApproved
    }

    public var body: some View {
        Group {
            switch viewModel.sessionState {
            case .signing, .sendingResponse:
                LoadingSigningView()
            default:
                if let session = viewModel.currentSession {
                    approvalContent(for: session)
                } else {
                    idleContent
                }
            }
        }
        .task {
            await viewModel.refresh()
        }
    }

    var idleContent: some View {
        VStack(alignment: idleHorizontalAlignment, spacing: 14) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No pending requests")
                .font(.title2.bold())
            Text("Signeur is ready. Approve requests here when an app asks you to sign.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(idleTextAlignment)
            if !connectActions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(connectActions) { item in
                        Button(action: item.action) {
                            Label(item.title, systemImage: item.systemImage)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: 260)
                .padding(.top, 8)
            }
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .multilineTextAlignment(idleTextAlignment)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: idleFrameAlignment)
        .padding()
    }

    var idleHorizontalAlignment: HorizontalAlignment {
#if os(macOS)
        .leading
#else
        .center
#endif
    }

    var idleTextAlignment: TextAlignment {
#if os(macOS)
        .leading
#else
        .center
#endif
    }

    var idleFrameAlignment: Alignment {
#if os(macOS)
        .topLeading
#else
        .center
#endif
    }

    func approvalContent(for session: NIP46Session) -> some View {
        let request = session.request
        let isConnection = request.method == .connect

        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    requestHeader(request, isConnection: isConnection)

                    if isConnection {
                        connectionSummary(request)
                    } else {
                        requestSummary(request)
                    }

                    if request.method == .nip04Encrypt || request.method == .nip04Decrypt {
                        Label(
                            "Legacy NIP-04 encryption is not authenticated. Review this request carefully; Signeur will never approve it automatically.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .font(.callout)
                    } else if request.origin == .localSigner {
                        Label(
                            "This local app identity cannot be verified cryptographically, so Signeur will always ask before acting.",
                            systemImage: "exclamationmark.shield.fill"
                        )
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    }

                    DisclosureGroup("Technical details", isExpanded: $showDetails) {
                        VStack(alignment: .leading, spacing: 12) {
                            detailRow("App public key", value: request.appPubkey, monospaced: true)
                            if !request.relays.isEmpty {
                                detailRow("Relays", value: request.relays.joined(separator: "\n"), monospaced: true)
                            }
                            detailRow(
                                "Requested",
                                value: request.requestedAt.formatted(date: .abbreviated, time: .shortened)
                            )
                            if !request.rawPayloadPreview.isEmpty {
                                detailRow("Request", value: request.rawPayloadPreview, monospaced: true)
                            }
                        }
                        .padding(.top, 12)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }

            Divider()
            ApprovalActionsView(
                approve: {
                    Task {
                        if await viewModel.approve() {
                            onConnectionApproved?()
                        }
                    }
                },
                reject: { Task { await viewModel.reject() } },
                rememberChoice: $viewModel.rememberChoice,
                approveTitle: isConnection ? "Approve Connection" : "Approve",
                rejectTitle: isConnection ? "Decline" : "Reject",
                showsRememberChoice: !isConnection
                    && request.origin.hasCryptographicAppIdentity
                    && request.method != .nip04Encrypt
                    && request.method != .nip04Decrypt
            )
            .padding()
            .background(.bar)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.footnote)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
    }

    func requestHeader(_ request: NIP46Request, isConnection: Bool) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: isConnection ? "link.circle.fill" : "signature")
                .font(.system(size: 38))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 4) {
                Text(isConnection ? "Connection Request" : "Approval Required")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(request.appName ?? "Unknown app")
                    .font(.title2.bold())
                if let appURL = request.appURL, let url = URL(string: appURL) {
                    Link(appURL, destination: url)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }
        }
    }

    func connectionSummary(_ request: NIP46Request) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What you’re approving")
                .font(.headline)

            Label {
                Text("Connect to Signeur using **\(viewModel.selectedIdentityName ?? "your active key")**")
            } icon: {
                Image(systemName: "key.fill")
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Requested access")
                    .font(.subheadline.weight(.semibold))
                if request.requestedPermissions.isEmpty {
                    Label("No broad permissions requested", systemImage: "checkmark.shield")
                    Text("You’ll review each future signing or encryption request.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(request.requestedPermissions, id: \.self) { permission in
                        Label(permissionLabel(permission), systemImage: permissionIcon(permission))
                    }
                    Text("These are the capabilities the app says it may request. Signeur will still ask before sensitive actions unless you later choose to remember one.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !request.relays.isEmpty {
                let relayCount = request.relays.count
                Label(
                    "Connect through \(relayCount) relay\(relayCount == 1 ? "" : "s")",
                    systemImage: "network"
                )
            }
        }
        .padding()
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    func requestSummary(_ request: NIP46Request) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Requested action")
                .font(.headline)
            Label(permissionLabel(request.method.rawValue), systemImage: permissionIcon(request.method.rawValue))
                .font(.title3.weight(.semibold))
            Text("Using \(viewModel.selectedIdentityName ?? "your active key")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    func detailRow(_ title: String, value: String, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
        }
    }

    func permissionLabel(_ permission: String) -> String {
        let method = permission.split(separator: ":", maxSplits: 1).first.map(String.init) ?? permission
        let suffix = permission.contains(":") ? " (\(permission.split(separator: ":", maxSplits: 1)[1]))" : ""
        switch method {
        case "connect": return "Connect to this signer"
        case "get_public_key": return "Read your public key"
        case "sign_event": return "Sign Nostr events\(suffix)"
        case "nip04_encrypt": return "Encrypt NIP-04 messages"
        case "nip04_decrypt": return "Decrypt NIP-04 messages"
        case "nip44_encrypt": return "Encrypt NIP-44 messages"
        case "nip44_decrypt": return "Decrypt NIP-44 messages"
        case "switch_relays": return "Change relay settings"
        case "ping": return "Check signer availability"
        case "logout": return "Disconnect the signer"
        default: return permission.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    func permissionIcon(_ permission: String) -> String {
        let method = permission.split(separator: ":", maxSplits: 1).first.map(String.init) ?? permission
        switch method {
        case "sign_event": return "signature"
        case "nip04_encrypt", "nip44_encrypt": return "lock.fill"
        case "nip04_decrypt", "nip44_decrypt": return "lock.open.fill"
        case "get_public_key": return "person.text.rectangle"
        case "switch_relays": return "network"
        default: return "checkmark.circle"
        }
    }
}
