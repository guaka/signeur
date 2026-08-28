import SwiftUI
import SignstrCore

enum RootSection: String, CaseIterable, Identifiable {
    case requests
    case connected
    case keys
    case help

    var id: String { rawValue }

    var title: String {
        switch self {
        case .requests: return "Requests"
        case .connected: return "Connected"
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

struct RootView: View {
    @StateObject private var sessionVM = AppBootstrap.makeSessionViewModel()
    @StateObject private var connectedAppsVM = AppBootstrap.makeConnectedAppsViewModel()
    @StateObject private var keysVM = AppBootstrap.makeKeysViewModel()
    @StateObject private var pairingVM = AppBootstrap.makePairingViewModel()

    @State private var section: RootSection = .requests
    @State private var didPickInitialSection = false
    @State private var isScanning = false
    @State private var pairingErrorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Section", selection: $section) {
                    ForEach(RootSection.allCases) { item in
                        Label(item.title, systemImage: item.icon)
                            .tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isScanning = true
                    } label: {
                        Label("Scan", systemImage: "qrcode.viewfinder")
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 7) {
                        if let icon = appIcon {
                            Image(uiImage: icon)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 30, height: 30)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        }
                        Text("Signstr")
                            .font(.headline)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Signstr")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        pasteConnectionLink()
                    } label: {
                        Label("Paste link", systemImage: "doc.on.clipboard")
                    }
                }
            }
        }
        .sheet(isPresented: $isScanning) {
            ScanPairingSheet(viewModel: pairingVM, onPaired: showPairedRequest)
        }
        .alert("Could not connect", isPresented: pairingErrorBinding) {
            Button("OK") { pairingErrorMessage = nil }
        } message: {
            Text(pairingErrorMessage ?? "")
        }
        .task {
            guard !didPickInitialSection else { return }
            didPickInitialSection = true
            await keysVM.refresh()
            if keysVM.identities.isEmpty {
                section = .keys
            }
            // Reconnects to the relays of apps that were already approved.
            await AppBootstrap.startListening()
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
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            Task { await AppBootstrap.lockKeySession() }
        }
    }

    private var pairingErrorBinding: Binding<Bool> {
        Binding(
            get: { pairingErrorMessage != nil },
            set: { if !$0 { pairingErrorMessage = nil } }
        )
    }

    /// App icons are emitted as bundle resources under the primary icon filename.
    private var appIcon: UIImage? {
        guard
            let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
            let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let files = primary["CFBundleIconFiles"] as? [String],
            let filename = files.last
        else {
            return UIImage(named: "AppIcon")
        }
        return UIImage(named: filename) ?? UIImage(named: "AppIcon")
    }

    private func pasteConnectionLink() {
        Task {
            if await pairingVM.handlePastedText(UIPasteboard.general.string) {
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
                    .init(title: "Scan a code", systemImage: "qrcode.viewfinder") { isScanning = true },
                    .init(title: "Paste a link", systemImage: "doc.on.clipboard") { pasteConnectionLink() }
                ],
                onConnectionApproved: showApprovedConnection
            )
        case .connected:
            ConnectedAppsView(viewModel: connectedAppsVM)
        case .keys:
            KeysView(viewModel: keysVM)
        case .help:
            SignstrHelpView()
        }
    }

    private func showApprovedConnection() {
        section = .connected
        Task { await connectedAppsVM.refresh() }
    }
}

private struct SignstrHelpView: View {
    private let buildTime: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SignstrBuildTime") as? String,
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
                    Text("How to use Signstr")
                        .font(.title2.bold())
                    Text("1. In Keys, create a key or import an nsec.\n2. In your Nostr app, choose Nostr Connect or remote signer, then scan its code or paste its link.\n3. Approve only requests you expect.")
                }

                Group {
                    Text("Nostr and your keys")
                        .font(.headline)
                    Text("Nostr is an open network where apps exchange messages through relays. Your npub is your public, shareable identity. Your nsec is the private key that controls it: never share it or paste it into a website.")
                    Text("Signstr keeps your private key on this device and uses it only when you approve a request.")
                }

                Divider()

                Link("Open the Signstr guide and NIP-46 tester", destination: URL(string: "https://guaka.github.io/signstr/")!)
                Link("View Signstr on GitHub", destination: URL(string: "https://github.com/guaka/signstr")!)
                Text("Build time: \(buildTime)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .accessibilityIdentifier("signstr-help")
    }
}
