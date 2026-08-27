import SwiftUI
import XCTest
@testable import SignstrCore

@MainActor
final class ConnectedAppsViewTests: XCTestCase {
    func testViewModelRefreshLoadsConnectedAppsFromProvider() async {
        let provider = StubConnectedAppsProvider(items: [
            ConnectedAppItem(
                appName: "Amethyst",
                appPubkey: TestVectors.otherPubkeyHex,
                methods: ["sign_event", "logout"],
                requestedPermissions: ["nip44_encrypt"]
            )
        ])
        let viewModel = ConnectedAppsViewModel(provider: provider)

        await viewModel.refresh()

        XCTAssertEqual(viewModel.apps.map(\.appPubkey), [TestVectors.otherPubkeyHex])
        XCTAssertEqual(viewModel.apps.first?.appName, "Amethyst")
    }

    func testViewModelRevokeForwardsRequestAndRefreshes() async {
        let provider = StubConnectedAppsProvider(items: [
            ConnectedAppItem(
                appName: "Legacy",
                appPubkey: TestVectors.otherPubkeyHex,
                methods: ["sign_event"],
                requestedPermissions: ["nip04_encrypt", "nip04_decrypt"]
            )
        ])
        let viewModel = ConnectedAppsViewModel(provider: provider)

        await viewModel.refresh()
        guard let app = viewModel.apps.first else {
            XCTFail("expected an initial app")
            return
        }
        await viewModel.revoke(app)
        let revoked = await provider.hasRevoked(appPubkey: app.appPubkey)

        XCTAssertTrue(revoked)
        XCTAssertTrue(viewModel.apps.isEmpty)
    }

    func testConnectedAppsViewBuildsEmptyAndPopulatedBodies() async {
        let emptyProvider = StubConnectedAppsProvider(items: [])
        let emptyViewModel = ConnectedAppsViewModel(provider: emptyProvider)
        await emptyViewModel.refresh()
        await MainActor.run { _ = ConnectedAppsView(viewModel: emptyViewModel).body }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let populatedProvider = StubConnectedAppsProvider(items: [
            ConnectedAppItem(
                appName: "Amethyst",
                appPubkey: TestVectors.otherPubkeyHex,
                methods: ["sign_event", "ping"],
                requestedPermissions: [],
                appURL: "https://example.com",
                relays: ["wss://relay.one"],
                identityName: "Main",
                createdAt: now,
                lastUsedAt: now,
                usesLegacyEncryption: true
            ),
            ConnectedAppItem(
                appName: "Nostrudel",
                appPubkey: TestVectors.pubkeyHex,
                methods: ["asks you every time"],
                requestedPermissions: ["sign_event", "nip44_decrypt"],
                relays: ["wss://relay.two", "wss://relay.three"]
            )
        ])
        let populatedViewModel = ConnectedAppsViewModel(provider: populatedProvider)
        await populatedViewModel.refresh()
        await MainActor.run { _ = ConnectedAppsView(viewModel: populatedViewModel).body }
    }

    func testConnectedAppsViewCoversPermissionEdgeBranches() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let provider = StubConnectedAppsProvider(items: [
            ConnectedAppItem(
                appName: "Legacy",
                appPubkey: TestVectors.pubkeyHex,
                methods: ["asks you every time"],
                requestedPermissions: [],
                createdAt: now
            ),
            ConnectedAppItem(
                appName: "Unknown Method",
                appPubkey: TestVectors.otherPubkeyHex,
                methods: ["custom_permission"],
                requestedPermissions: ["sign_event"],
                relays: ["wss://relay.one"]
            )
        ])
        let viewModel = ConnectedAppsViewModel(provider: provider)
        await viewModel.refresh()
        await MainActor.run { _ = ConnectedAppsView(viewModel: viewModel).body }
    }

    func testConnectedAppPermissionHelpersCoverKnownUnknownAndQualifiedInputs() {
        XCTAssertEqual(permissionDisplayName("get_public_key"), "Read public key")
        XCTAssertEqual(permissionDisplayName("sign_event"), "Sign events")
        XCTAssertEqual(permissionDisplayName("sign_event:22"), "Sign events (kind 22)")
        XCTAssertEqual(permissionDisplayName("nip04_encrypt"), "NIP-04 encryption")
        XCTAssertEqual(permissionDisplayName("nip04_decrypt"), "NIP-04 decryption")
        XCTAssertEqual(permissionDisplayName("nip44_encrypt"), "NIP-44 encryption")
        XCTAssertEqual(permissionDisplayName("nip44_decrypt"), "NIP-44 decryption")
        XCTAssertEqual(permissionDisplayName("switch_relays"), "Change relays")
        XCTAssertEqual(permissionDisplayName("ping"), "Signer availability")
        XCTAssertEqual(permissionDisplayName("logout"), "Disconnect signer")
        XCTAssertEqual(permissionDisplayName("mystery_permission"), "Mystery Permission")

        XCTAssertEqual(permissionDisplayIcon("sign_event"), "signature")
        XCTAssertEqual(permissionDisplayIcon("nip04_encrypt"), "lock.fill")
        XCTAssertEqual(permissionDisplayIcon("nip44_encrypt"), "lock.fill")
        XCTAssertEqual(permissionDisplayIcon("nip04_decrypt"), "lock.open.fill")
        XCTAssertEqual(permissionDisplayIcon("nip44_decrypt"), "lock.open.fill")
        XCTAssertEqual(permissionDisplayIcon("get_public_key"), "person.text.rectangle")
        XCTAssertEqual(permissionDisplayIcon("switch_relays"), "network")
        XCTAssertEqual(permissionDisplayIcon("sign_event:22"), "signature")
        XCTAssertEqual(permissionDisplayIcon("mystery_permission"), "checkmark.circle")
    }

    func testConnectedAppRowAndDetailViewsExercisePermissionAndStatusBranches() async {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let requested = ConnectedAppItem(
            appName: "Nostrudel",
            appPubkey: TestVectors.otherPubkeyHex,
            methods: ["sign_event", "logout"],
            requestedPermissions: ["nip44_encrypt"],
            appURL: "https://nostrudel.io",
            relays: [],
            identityName: "Main",
            createdAt: now,
            lastUsedAt: now.addingTimeInterval(120),
            usesLegacyEncryption: true
        )

        let remembered = ConnectedAppItem(
            appName: "Legacy App",
            appPubkey: TestVectors.pubkeyHex,
            methods: ["asks you every time"],
            requestedPermissions: [],
            appURL: nil,
            relays: ["wss://relay.one", "wss://relay.two"],
            identityName: nil,
            createdAt: nil,
            lastUsedAt: nil,
            usesLegacyEncryption: false
        )

        await MainActor.run {
            _ = ConnectedAppRow(app: requested).body
            _ = ConnectedAppRow(app: remembered).body
            _ = ConnectedAppDetailView(app: requested) {}
                .body
            _ = ConnectedAppDetailView(app: remembered) {}
                .body
        }
    }

    func testLoadingSigningViewBuildsBody() {
        _ = LoadingSigningView().body
    }

    func testApprovalActionsViewBuildsBodyWithAndWithoutRememberChoice() {
        var rememberChoice = false
        _ = ApprovalActionsView(
            approve: {},
            reject: {},
            rememberChoice: Binding(
                get: { rememberChoice },
                set: { rememberChoice = $0 }
            ),
            approveTitle: "Approve",
            rejectTitle: "Reject",
            showsRememberChoice: true
        ).body

        _ = ApprovalActionsView(
            approve: {},
            reject: {},
            rememberChoice: Binding(
                get: { rememberChoice },
                set: { rememberChoice = $0 }
            ),
            showsRememberChoice: false
        ).body
    }
}

private actor StubConnectedAppsProvider: ConnectedAppsProviding {
    private(set) var items: [ConnectedAppItem]
    private(set) var revoked: [String] = []

    init(items: [ConnectedAppItem]) {
        self.items = items
    }

    func listConnectedApps() async -> [ConnectedAppItem] { items }

    func revoke(appPubkey: String) async {
        revoked.append(appPubkey)
        items.removeAll { $0.appPubkey == appPubkey }
    }

    func hasRevoked(appPubkey: String) async -> Bool { revoked.contains(appPubkey) }
}
