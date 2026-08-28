import SwiftUI

@MainActor
public final class ActivityViewModel: ObservableObject {
    @Published public private(set) var entries: [AuditEntry] = []
    @Published public private(set) var errorMessage: String?

    private let provider: AuditLogProviding

    public init(provider: AuditLogProviding) {
        self.provider = provider
    }

    public func refresh() async {
        do {
            entries = try await provider.list()
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = "Signstr could not load activity history."
        }
    }

    public func clear() async {
        await provider.clear()
        await refresh()
    }
}

public struct ActivityView: View {
    @ObservedObject private var viewModel: ActivityViewModel
    @State private var confirmingClear = false

    public init(viewModel: ActivityViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        List {
            if let errorMessage = viewModel.errorMessage {
                ContentUnavailableView(
                    "Couldn’t Load Activity",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if viewModel.entries.isEmpty {
                ContentUnavailableView(
                    "No Signing Activity",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Sign-event attempts from the last 90 days will appear here.")
                )
            } else {
                ForEach(viewModel.entries) { entry in // coverage:ignore SwiftUI evaluates this row builder while rendering the live list.
                    ActivityRow(entry: entry)
                }
            }
        }
        .task { await refreshActivity() }
        .refreshable { await refreshActivity() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear History", role: .destructive, action: requestClear)
                .disabled(viewModel.entries.isEmpty)
            }
        }
        .confirmationDialog(
            "Clear signing activity?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive, action: clearHistory)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all stored signing activity from this device.")
        }
    }

    func refreshActivity() async {
        await viewModel.refresh()
    }

    func requestClear() {
        confirmingClear = true
    }

    func clearHistory() {
        Task { await viewModel.clear() }
    }
}

struct ActivityRow: View {
    let entry: AuditEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: outcomeIcon)
                .foregroundStyle(outcomeColor)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(entry.appName)
                        .font(.headline)
                    Spacer()
                    Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(eventDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Text(outcomeTitle)
                    if entry.approvalMode == .remembered {
                        Text("• Automatically approved")
                    } else if entry.approvalMode == .manual && entry.outcome != .rejected {
                        Text("• Manually approved")
                    }
                }
                .font(.caption)
                .foregroundStyle(outcomeColor)
            }
        }
        .padding(.vertical, 4)
    }

    var eventDescription: String {
        entry.eventKind.map { "Nostr event kind \($0)" } ?? "Nostr event"
    }

    var outcomeTitle: String {
        switch entry.outcome {
        case .signed: return "Signed"
        case .rejected: return "Rejected"
        case .expired: return "Expired"
        case .invalidRequest: return "Invalid request"
        case .signingFailed: return "Signing failed"
        case .deliveryFailed: return "Response delivery failed"
        case .unauthorized: return "Unauthorized"
        case .unknown: return "Unknown outcome"
        }
    }

    var outcomeIcon: String {
        switch entry.outcome {
        case .signed: return "checkmark.circle.fill"
        case .rejected: return "xmark.circle.fill"
        case .expired: return "clock.badge.exclamationmark"
        case .invalidRequest, .unauthorized: return "exclamationmark.shield.fill"
        case .signingFailed, .deliveryFailed, .unknown: return "exclamationmark.triangle.fill"
        }
    }

    var outcomeColor: Color {
        switch entry.outcome {
        case .signed: return .green
        case .rejected: return .secondary
        case .expired, .invalidRequest, .signingFailed, .deliveryFailed, .unauthorized, .unknown: return .orange
        }
    }
}
