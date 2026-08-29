import AppKit
import SigneurCore
import SwiftUI

private enum MacRootSection: String, CaseIterable, Identifiable {
    case requests
    case connected
    case keys
    case help

    var id: String { rawValue }

    var title: String {
        switch self {
        case .requests: return "Requests"
        case .connected: return "Connected Apps"
        case .keys: return "Keys"
        case .help: return "Help"
        }
    }

    var icon: String {
        switch self {
        case .requests: return "signature"
        case .connected: return "link"
        case .keys: return "key.fill"
        case .help: return "questionmark.circle"
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
                HStack(alignment: .center, spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 76, height: 76)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Signeur")
                            .font(.title2.bold())
                        Text("Nostr signer")
                            .font(.body.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, 16)
                .padding(.vertical, 16)

                List(MacRootSection.allCases, selection: $section) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.icon)
                    }
                }
            }
            .navigationTitle("Signeur")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .dynamicTypeSize(.large)
                .navigationTitle(section.title)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: pasteConnectionLink) {
                            Label("Connect from Clipboard", systemImage: "doc.on.clipboard")
                        }
                        .help("Paste a Nostr Connect or Signeur link")
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
        case .help:
            MacSigneurHelpView()
        }
    }

    private func showApprovedConnection() {
        section = .connected
        Task { await connectedAppsVM.refresh() }
    }
}

private struct MacSigneurHelpView: View {
    private let buildTime: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SigneurBuildTime") as? String,
              !value.isEmpty,
              !value.hasPrefix("$(")
        else {
            return "Development build"
        }
        return value
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Group {
                    Text("How to use Signeur")
                        .font(.title2.bold())
                    Text("1. In Keys, create a key or import an nsec.\n2. In your Nostr app, choose Nostr Connect or remote signer, then paste its connection link.\n3. Approve only requests you expect.")
                }

                Group {
                    Text("Nostr and your keys")
                        .font(.headline)
                    Text("Nostr is an open network where apps exchange messages through relays. Your npub is your public, shareable identity. Your nsec is the private key that controls it: never share it or paste it into a website.")
                    Text("Signeur keeps your private key on this device and uses it only when you approve a request.")
                }

                Divider()

                Link("Open the Signeur guide and NIP-46 tester", destination: URL(string: "https://guaka.github.io/signeur/")!)
                Link("View Signeur on GitHub", destination: URL(string: "https://github.com/guaka/signeur")!)
                Text("Build time: \(buildTime)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .accessibilityIdentifier("signeur-help")
    }
}
