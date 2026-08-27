import AppKit
import SignstrCore
import SwiftUI

private enum MacRootSection: String, CaseIterable, Identifiable {
    case requests
    case connected
    case keys

    var id: String { rawValue }

    var title: String {
        switch self {
        case .requests: return "Requests"
        case .connected: return "Connected Apps"
        case .keys: return "Keys"
        }
    }

    var icon: String {
        switch self {
        case .requests: return "signature"
        case .connected: return "link"
        case .keys: return "key.fill"
        }
    }
}

struct MacRootView: View {
    @StateObject private var sessionVM = MacAppBootstrap.makeSessionViewModel()
    @StateObject private var connectedAppsVM = MacAppBootstrap.makeConnectedAppsViewModel()
    @StateObject private var keysVM = MacAppBootstrap.makeKeysViewModel()
    @StateObject private var pairingVM = MacAppBootstrap.makePairingViewModel()

    @State private var section: MacRootSection = .requests
    @State private var didStart = false
    @State private var pairingErrorMessage: String?

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 52, height: 52)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signstr")
                            .font(.headline)
                        Text("Nostr signer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                List(MacRootSection.allCases, selection: $section) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.icon)
                    }
                }
            }
            .navigationTitle("Signstr")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            content
                .navigationTitle(section.title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: pasteConnectionLink) {
                            Label("Connect from Clipboard", systemImage: "doc.on.clipboard")
                        }
                        .help("Paste a Nostr Connect or Signstr link")
                    }
                }
        }
        .alert("Could not connect", isPresented: pairingErrorBinding) {
            Button("OK") { pairingErrorMessage = nil }
        } message: {
            Text(pairingErrorMessage ?? "")
        }
        .task {
            guard !didStart else { return }
            didStart = true
            await keysVM.refresh()
            if keysVM.identities.isEmpty {
                section = .keys
            }
            await MacAppBootstrap.startListening()
        }
        .onOpenURL { url in
            Task {
                if await pairingVM.handleIncomingURL(url) {
                    showPairedRequest()
                } else {
                    pairingErrorMessage = pairingVM.errorMessage
                }
            }
        }
    }

    private var pairingErrorBinding: Binding<Bool> {
        Binding(
            get: { pairingErrorMessage != nil },
            set: { if !$0 { pairingErrorMessage = nil } }
        )
    }

    private func pasteConnectionLink() {
        let value = NSPasteboard.general.string(forType: .string)
        Task {
            if await pairingVM.handlePastedText(value) {
                showPairedRequest()
            } else {
                pairingErrorMessage = pairingVM.errorMessage
            }
        }
    }

    private func showPairedRequest() {
        section = .requests
        Task { await sessionVM.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .requests:
            IncomingRequestView(
                viewModel: sessionVM,
                connectActions: [
                    .init(title: "Connect from Clipboard", systemImage: "doc.on.clipboard") {
                        pasteConnectionLink()
                    }
                ],
                onConnectionApproved: showApprovedConnection
            )
        case .connected:
            ConnectedAppsView(viewModel: connectedAppsVM)
        case .keys:
            MacKeysView(viewModel: keysVM)
        }
    }

    private func showApprovedConnection() {
        section = .connected
        Task { await connectedAppsVM.refresh() }
    }
}
