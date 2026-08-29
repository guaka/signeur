import AppKit
import SigneurCore
import SwiftUI

struct MacKeysView: View {
    @ObservedObject var viewModel: KeysViewModel
    @State private var showNsecInput = false
    @State private var identityPendingDeletion: Identity?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
        case nsec
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                addKeyCard
                keyStatus

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Stored keys")
                            .font(.title2.bold())
                        Spacer()
                        Button {
                            Task { await viewModel.syncNIP05() }
                        } label: {
                            if viewModel.isSyncing {
                                HStack(spacing: 7) {
                                    ProgressView().controlSize(.small)
                                    Text("Checking NIP-05…")
                                }
                            } else {
                                Label("Sync NIP-05", systemImage: "arrow.triangle.2.circlepath")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.identities.isEmpty || viewModel.isSyncing)
                    }

                    relayList

                    if viewModel.identities.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("No keys yet", systemImage: "key")
                                .font(.headline)
                            Text("Import an nsec or generate a new key above to start signing on this Mac.")
                                .foregroundStyle(.secondary)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(cardBackground)
                    } else {
                        LazyVStack(spacing: 14) {
                            ForEach(viewModel.identities) { identity in
                                identityCard(identity)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await viewModel.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            showNsecInput = false
            viewModel.hideAllRevealedKeys()
        }
        .confirmationDialog(
            "Delete \(identityPendingDeletion?.displayName ?? "this key")?",
            isPresented: deletionConfirmationIsPresented,
            titleVisibility: .visible,
            presenting: identityPendingDeletion
        ) { identity in
            Button("Delete Key", role: .destructive) {
                Task { await viewModel.deleteIdentity(identity) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This permanently removes the key and its nsec from this Mac. This cannot be undone.")
        }
    }

    private var addKeyCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Name (optional)", text: $viewModel.displayName)
                    .focused($focusedField, equals: .name)
                    .onSubmit { focusedField = .nsec }

                HStack {
                    Group {
                        if showNsecInput {
                            TextField("nsec1...", text: $viewModel.nsec)
                        } else {
                            SecureField("nsec1...", text: $viewModel.nsec)
                        }
                    }
                    .focused($focusedField, equals: .nsec)

                    Button {
                        showNsecInput.toggle()
                    } label: {
                        Image(systemName: showNsecInput ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                HStack {
                    Button("Paste") {
                        viewModel.applyPastedValue(NSPasteboard.general.string(forType: .string))
                    }
                    Button {
                        focusedField = nil
                        Task { await viewModel.generateKey() }
                    } label: {
                        Label("Generate New Key", systemImage: "key.fill")
                    }
                    .disabled(viewModel.isSaving)
                    Spacer()
                    Button {
                        focusedField = nil
                        Task { await viewModel.addKey() }
                    } label: {
                        if viewModel.isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Save Key")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.canSave)
                }

            }
            .padding(8)
        } label: {
            Label("Add a key", systemImage: "plus.circle.fill")
                .font(.headline)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var keyStatus: some View {
        if let errorMessage = viewModel.errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let statusMessage = viewModel.statusMessage {
            Label(statusMessage, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var relayList: some View {
        if !viewModel.syncRelayDescriptions.isEmpty {
            Text("Relays: \(viewModel.syncRelayDescriptions.joined(separator: ", "))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func identityCard(_ identity: Identity) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "key.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(identity.displayName)
                        .font(.title3.bold())
                    Spacer()
                    if viewModel.activeIdentityID == identity.id {
                        Label("Active", systemImage: "checkmark.circle.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        Button("Use this key") { Task { await viewModel.setActive(identity) } }
                            .controlSize(.small)
                    }
                }

                Text(identity.npub ?? "npub unavailable")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let nip05 = identity.nip05, nip05 != identity.displayName {
                    Label(nip05, systemImage: "checkmark.seal.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Divider()

                HStack(spacing: 18) {
                    Label(
                        "\(identity.origin == .generated ? "Created" : "Added") \(identity.createdAt.formatted(date: .abbreviated, time: .omitted))",
                        systemImage: "calendar"
                    )
                    Label(
                        identity.lastUsedAt.map {
                            "Last used \($0.formatted(date: .abbreviated, time: .shortened))"
                        } ?? "Not used yet",
                        systemImage: "clock"
                    )
                    Label(
                        viewModel.keyPresence[identity.id] == true ? "Stored in Keychain" : "Key missing",
                        systemImage: viewModel.keyPresence[identity.id] == true ? "lock.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(viewModel.keyPresence[identity.id] == true ? Color.secondary : Color.red)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                if let revealed = viewModel.revealedNsecs[identity.id] {
                    Text(revealed)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }

                HStack(spacing: 10) {
                    if viewModel.keyPresence[identity.id] == true {
                        Button(viewModel.revealedNsecs[identity.id] == nil ? "Reveal nsec" : "Hide nsec") {
                            Task { await viewModel.toggleReveal(identity) }
                        }
                    }
                    Button("Delete", role: .destructive) {
                        identityPendingDeletion = identity
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.quaternary.opacity(0.7))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.separator.opacity(0.7), lineWidth: 1)
            }
    }

    private var deletionConfirmationIsPresented: Binding<Bool> {
        Binding(
            get: { identityPendingDeletion != nil },
            set: { if !$0 { identityPendingDeletion = nil } }
        )
    }
}
