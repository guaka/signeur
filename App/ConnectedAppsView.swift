import SwiftUI

public struct ConnectedAppItem: Identifiable, Equatable, Sendable {
    public var id: String { appPubkey }
    public let appName: String
    public let appPubkey: String
    public let methods: [String]
    public let requestedPermissions: [String]
    public let appURL: String?
    public let relays: [String]
    public let identityName: String?
    public let createdAt: Date?
    public let lastUsedAt: Date?
    public let usesLegacyEncryption: Bool

    public init(
        appName: String,
        appPubkey: String,
        methods: [String],
        requestedPermissions: [String] = [],
        appURL: String? = nil,
        relays: [String] = [],
        identityName: String? = nil,
        createdAt: Date? = nil,
        lastUsedAt: Date? = nil,
        usesLegacyEncryption: Bool = false
    ) {
        self.appName = appName
        self.appPubkey = appPubkey
        self.methods = methods
        self.requestedPermissions = requestedPermissions
        self.appURL = appURL
        self.relays = relays
        self.identityName = identityName
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.usesLegacyEncryption = usesLegacyEncryption
    }
}

public protocol ConnectedAppsProviding: Sendable {
    func listConnectedApps() async -> [ConnectedAppItem]
    func revoke(appPubkey: String) async
}

@MainActor
public final class ConnectedAppsViewModel: ObservableObject {
    @Published public private(set) var apps: [ConnectedAppItem] = []
    private let provider: ConnectedAppsProviding

    public init(provider: ConnectedAppsProviding) {
        self.provider = provider
    }

    public func refresh() async {
        apps = await provider.listConnectedApps()
    }

    public func revoke(_ app: ConnectedAppItem) async {
        await provider.revoke(appPubkey: app.appPubkey)
        await refresh()
    }
}

public struct ConnectedAppsView: View {
    @ObservedObject private var viewModel: ConnectedAppsViewModel
    @State private var connectionPendingDeletion: ConnectedAppItem?

    public init(viewModel: ConnectedAppsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        List {
            if viewModel.apps.isEmpty {
#if os(macOS)
                VStack(alignment: .leading, spacing: 8) {
                    Label("No connected apps", systemImage: "link")
                        .font(.title2.bold())
                    Text("Paste an app's connection link, then approve it. Connected apps appear here.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 12)
#else
                ContentUnavailableView(
                    "No connected apps",
                    systemImage: "link",
                    description: Text("Scan or paste an app's connection link, then approve it. Connected apps appear here.")
                )
#endif
            }
            ForEach(viewModel.apps) { app in
                NavigationLink {
                    ConnectedAppDetailView(app: app) { // coverage:ignore SwiftUI evaluates this lazy destination on navigation.
                        await viewModel.revoke(app)
                    }
                } label: {
                    ConnectedAppRow(app: app)
                }
#if os(iOS)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        connectionPendingDeletion = app
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
#endif
            }
        }
        .task {
            await viewModel.refresh()
        }
        .refreshable { await viewModel.refresh() }
#if os(iOS)
        .confirmationDialog(
            "Delete connection to \(connectionPendingDeletion?.appName ?? "this app")?",
            isPresented: deletionConfirmationIsPresented,
            titleVisibility: .visible,
            presenting: connectionPendingDeletion
        ) { app in
            Button("Delete Connection", role: .destructive) {
                Task { await viewModel.revoke(app) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Signstr will stop listening for this app and forget its remembered approvals.")
        }
#endif
    }

#if os(iOS)
    var deletionConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { connectionPendingDeletion != nil },
            set: { if !$0 { connectionPendingDeletion = nil } }
        )
    }
#endif
}

struct ConnectedAppRow: View {
    let app: ConnectedAppItem

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                AppIconView(appName: app.appName, appURL: app.appURL, size: 28)
                Text(app.appName)
                    .font(.headline)
                Spacer()
                if let lastUsedAt = app.lastUsedAt {
                    Text(activityLabel(for: lastUsedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(permissionSummary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if let signingKeyLabel {
                Label(signingKeyLabel, systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let createdAt = app.createdAt {
                Label {
                    Text("Connected \(createdAt.formatted(date: .abbreviated, time: .omitted))")
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    var signingKeyLabel: String? {
        app.identityName.map { "Signing key: \($0)" }
    }

    var permissionSummary: String {
        let requested = app.requestedPermissions
        if !requested.isEmpty {
            return requested.map(permissionDisplayName).joined(separator: ", ")
        }
        return app.methods.first == "asks you every time"
            ? "Asks before every action"
            : app.methods.map(permissionDisplayName).joined(separator: ", ")
    }

    func activityLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) {
            return "Today, \(time)"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday, \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

struct ConnectedAppDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let app: ConnectedAppItem
    let disconnect: () async -> Void
    @State private var confirmingDisconnect = false // coverage:ignore SwiftUI synthesizes and owns this storage.

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    AppIconView(appName: app.appName, appURL: app.appURL, size: 44)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(app.appName)
                            .font(.title2.bold())
                        if let appURL = app.appURL, let url = URL(string: appURL) {
                            Link(appURL, destination: url)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Activity") {
                if let createdAt = app.createdAt {
                    LabeledContent("Connected", value: createdAt.formatted(date: .long, time: .shortened))
                }
                if let lastUsedAt = app.lastUsedAt {
                    LabeledContent("Last used", value: lastUsedAt.formatted(date: .long, time: .shortened))
                } else {
                    LabeledContent("Last used", value: "Never")
                }
                if let identityName = app.identityName {
                    LabeledContent("Signing key", value: identityName)
                }
            }

            Section("Requested access") {
                if app.requestedPermissions.isEmpty {
                    Text("No broad permissions were advertised when this app connected.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.requestedPermissions, id: \.self) { permission in
                        Label(permissionDisplayName(permission), systemImage: permissionDisplayIcon(permission))
                    }
                }
            }

            Section("Remembered approvals") {
                if app.methods.first == "asks you every time" {
                    Text("Signstr asks before every sensitive action.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.methods, id: \.self) { method in
                        Label(permissionDisplayName(method), systemImage: "checkmark.shield.fill")
                    }
                }
            }

            Section("Connection") {
                LabeledContent("Encryption", value: app.usesLegacyEncryption ? "NIP-04 (legacy)" : "NIP-44")
                VStack(alignment: .leading, spacing: 4) {
                    Text("App public key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(app.appPubkey)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                ForEach(app.relays, id: \.self) { relay in
                    Label(relay, systemImage: "network")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Section {
                Button("Disconnect App", role: .destructive, action: requestDisconnect)
            }
        }
        .navigationTitle("Connection")
        .confirmationDialog(
            "Disconnect \(app.appName)?",
            isPresented: $confirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive, action: confirmDisconnect)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Signstr will stop listening for this app and forget its remembered approvals.")
        }
    }

    func requestDisconnect() {
        confirmingDisconnect = true
    }

    func confirmDisconnect() {
        Task {
            await disconnect()
            dismiss()
        }
    }
}

func permissionDisplayName(_ permission: String) -> String {
    let parts = permission.split(separator: ":", maxSplits: 1).map(String.init)
    let method = parts.first ?? permission
    let qualifier = parts.count == 2 ? " (kind \(parts[1]))" : ""
    switch method {
    case "get_public_key": return "Read public key"
    case "sign_event": return "Sign events\(qualifier)"
    case "nip04_encrypt": return "NIP-04 encryption"
    case "nip04_decrypt": return "NIP-04 decryption"
    case "nip44_encrypt": return "NIP-44 encryption"
    case "nip44_decrypt": return "NIP-44 decryption"
    case "switch_relays": return "Change relays"
    case "ping": return "Signer availability"
    case "logout": return "Disconnect signer"
    default: return permission.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

func permissionDisplayIcon(_ permission: String) -> String {
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
