import AppKit
import SignstrCore
import SwiftUI

struct MacKeysView: View {
    @ObservedObject var viewModel: KeysViewModel
    @State private var showNsecInput = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
        case nsec
    }

    var body: some View {
        Form {
            Section("Add a key") {
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

                Button {
                    focusedField = nil
                    Task { await viewModel.generateKey() }
                } label: {
                    Label("Generate New Key", systemImage: "key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isSaving)

                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                } else if let statusMessage = viewModel.statusMessage {
                    Text(statusMessage)
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
            }

            Section("Stored keys") {
                if viewModel.identities.isEmpty {
                    ContentUnavailableView(
                        "No keys yet",
                        systemImage: "key",
                        description: Text("Import an nsec or generate a new key above to start signing on this Mac.")
                    )
                } else {
                    ForEach(viewModel.identities) { identity in
                        identityRow(identity)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await viewModel.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            showNsecInput = false
            viewModel.hideAllRevealedKeys()
        }
    }

    private func identityRow(_ identity: Identity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(identity.displayName).font(.headline)
                Spacer()
                if viewModel.activeIdentityID == identity.id {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Button("Use") { Task { await viewModel.setActive(identity) } }
                }
            }

            Text(identity.npub ?? "npub unavailable")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let revealed = viewModel.revealedNsecs[identity.id] {
                Text(revealed)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } else {
                Text(viewModel.keyPresence[identity.id] == true ? "nsec stored in Keychain" : "nsec missing")
                    .font(.caption)
                    .foregroundStyle(viewModel.keyPresence[identity.id] == true ? Color.secondary : Color.red)
            }

            HStack {
                if viewModel.keyPresence[identity.id] == true {
                    Button(viewModel.revealedNsecs[identity.id] == nil ? "Reveal nsec" : "Hide nsec") {
                        Task { await viewModel.toggleReveal(identity) }
                    }
                }
                Button("Delete", role: .destructive) {
                    Task { await viewModel.deleteIdentity(identity) }
                }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}
