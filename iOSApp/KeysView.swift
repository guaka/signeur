import SwiftUI
import UIKit
import SignstrCore

struct KeysView: View {
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
                    .submitLabel(.next)
                    .onSubmit { focusedField = .nsec }

                HStack {
                    if showNsecInput {
                        TextField("nsec1...", text: $viewModel.nsec)
                            .focused($focusedField, equals: .nsec)
                    } else {
                        SecureField("nsec1...", text: $viewModel.nsec)
                            .focused($focusedField, equals: .nsec)
                    }
                    Button {
                        showNsecInput.toggle()
                    } label: {
                        Image(systemName: showNsecInput ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                HStack {
                    Button("Paste") {
                        viewModel.applyPastedValue(UIPasteboard.general.string)
                    }
                    Spacer()
                    Button {
                        focusedField = nil
                        Task { await viewModel.addKey() }
                    } label: {
                        if viewModel.isSaving {
                            ProgressView()
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
                    Text("No keys yet. Import an nsec or generate a new key above to start signing.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.identities) { identity in
                        identityRow(identity)
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .task {
            await viewModel.refresh()
        }
    }

    private func identityRow(_ identity: Identity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(identity.displayName)
                    .font(.headline)
                Spacer()
                if viewModel.activeIdentityID == identity.id {
                    Text("Active")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                } else {
                    Button("Use") {
                        Task { await viewModel.setActive(identity) }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
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

            HStack(spacing: 12) {
                if viewModel.keyPresence[identity.id] == true {
                    Button(viewModel.revealedNsecs[identity.id] == nil ? "Reveal nsec" : "Hide nsec") {
                        Task { await viewModel.toggleReveal(identity) }
                    }
                    .font(.caption)
                }
                Button("Delete", role: .destructive) {
                    Task { await viewModel.deleteIdentity(identity) }
                }
                .font(.caption)
            }
            .buttonStyle(.bordered)
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}
