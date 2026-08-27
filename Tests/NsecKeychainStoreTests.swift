import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import SignstrCore

final class NsecKeychainStoreTests: XCTestCase {
    func testNsecStoreErrorMessagesCoverLessCommonVariants() {
        XCTAssertEqual(
            NsecStoreError.invalidInput.errorDescription,
            "The key could not be read as a valid nsec."
        )
        XCTAssertEqual(
            NsecStoreError.protectionUnavailable.errorDescription,
            "This device could not create biometric Keychain protection."
        )
        XCTAssertEqual(
            NsecStoreError.authenticationFailed.errorDescription,
            "Face ID or device authentication did not succeed. Please try again."
        )
        XCTAssertEqual(
            NsecStoreError.authenticationCanceled.errorDescription,
            "Authentication was canceled."
        )
        let unknownStatus: OSStatus = -1
        let detail = SecCopyErrorMessageString(unknownStatus, nil) as String? ?? "unknown error"
        XCTAssertEqual(
            NsecStoreError.unexpectedStatus(unknownStatus).errorDescription,
            "Keychain error \(unknownStatus): \(detail)"
        )
    }

    func testSaveNsecRejectsInvalidInput() async {
        let store = NsecKeychainStore(unlockDuration: 0, keychain: FakeNsecKeychainBackend())
        let invalidIdentity = "bad\nid"

        do {
            try await store.saveNsec(TestVectors.nsec, for: invalidIdentity)
            XCTFail("invalid identity must be rejected")
        } catch {
            XCTAssertEqual(error as? NsecStoreError, .invalidInput)
        }

        let invalidSecret = try! Bech32.encode(hrp: "nsec", bytes: [UInt8](repeating: 0, count: 32))
        do {
            try await store.saveNsec(invalidSecret, for: "identity")
            XCTFail("invalid secret material must be rejected")
        } catch {
            XCTAssertEqual(error as? NsecStoreError, .invalidInput)
        }
    }

    func testSaveNsecWritesTrimmedLowercasedValueAndReplacesExistingValue() async {
        let backend = FakeNsecKeychainBackend()
        let store = NsecKeychainStore(unlockDuration: 0, keychain: backend)
        let rawNsec = "  \(TestVectors.nsec.uppercased())\n"

        try? await store.saveNsec(rawNsec, for: "identity-1")

        XCTAssertEqual(backend.deleteCount(), 1)
        XCTAssertEqual(backend.addCount(), 1)
        let query = backend.lastAddQuery()
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.k.signstr.nsec")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "identity-1")
        XCTAssertNotNil(query[kSecAttrAccessControl as String])

        let trimmed = rawNsec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        XCTAssertEqual(backend.lastAddedData(), trimmed.data(using: .utf8))
    }

    func testHasNsecForMultipleKeychainStatuses() async {
        let statusCases: [(OSStatus, Bool)] = [
            (errSecSuccess, true),
            (errSecInteractionNotAllowed, true),
            (errSecAuthFailed, true),
            (errSecMissingEntitlement, false),
            (errSecItemNotFound, false)
        ]
        for (status, expected) in statusCases {
            let backend = FakeNsecKeychainBackend(copyStatuses: [status])
            let store = NsecKeychainStore(unlockDuration: 0, keychain: backend)
            let hasNsec = await store.hasNsec(for: "identity")
            XCTAssertEqual(hasNsec, expected)
        }
    }

    func testLoadNsecReturnsCachedValueAndSkipsSecondLookup() async throws {
        let backend = FakeNsecKeychainBackend(copyStatuses: [errSecSuccess], copyData: TestVectors.nsec.data(using: .utf8))
        let store = NsecKeychainStore(unlockDuration: 300, keychain: backend)

        let first = try await store.loadNsec(for: "identity")
        XCTAssertEqual(first, TestVectors.nsec)

        backend.setCopyStatuses([errSecItemNotFound])
        let second = try await store.loadNsec(for: "identity")
        XCTAssertEqual(second, TestVectors.nsec)
        XCTAssertEqual(backend.copyMatchingCount(), 1)
    }

    func testLoadNsecReturnsNilForMissingKey() async throws {
        let backend = FakeNsecKeychainBackend(copyStatuses: [errSecItemNotFound])
        let store = NsecKeychainStore(unlockDuration: 0, keychain: backend)

        let missing = try await store.loadNsec(for: "missing")
        XCTAssertNil(missing)
    }

    func testLoadNsecRetriesAuthFailureWithFreshContext() async throws {
        let backend = FakeNsecKeychainBackend(
            copyStatuses: [errSecAuthFailed, errSecSuccess],
            copyData: TestVectors.nsec.data(using: .utf8)
        )
        let store = NsecKeychainStore(unlockDuration: 0, keychain: backend)

        let nsec = try await store.loadNsec(for: "identity")

        XCTAssertEqual(nsec, TestVectors.nsec)
        XCTAssertEqual(backend.copyMatchingCount(), 2)
        let contexts = backend.authenticationContexts()
        XCTAssertEqual(contexts.count, 2)
        XCTAssertFalse(contexts[0] === contexts[1])
    }

    func testLoadNsecReportsFriendlyAuthenticationErrorsAfterRetry() async {
        let backend = FakeNsecKeychainBackend(copyStatuses: [errSecAuthFailed, errSecAuthFailed])
        let store = NsecKeychainStore(unlockDuration: 0, keychain: backend)

        do {
            _ = try await store.loadNsec(for: "identity")
            XCTFail("authentication failure should throw")
        } catch {
            XCTAssertEqual(error as? NsecStoreError, .authenticationFailed)
        }

        XCTAssertEqual(NsecKeychainStore.error(for: errSecUserCanceled), .authenticationCanceled)
    }

    func testLoadNsecThrowsOnInvalidPayloadEncodingAndUnexpectedStatus() async throws {
        let malformedData = Data([0xF4, 0x28, 0x8F, 0xBF])
        let malformed = FakeNsecKeychainBackend(copyStatuses: [errSecSuccess], copyData: malformedData)
        let malformedStore = NsecKeychainStore(unlockDuration: 0, keychain: malformed)

        do {
            _ = try await malformedStore.loadNsec(for: "identity")
            XCTFail("nsec payload must be UTF-8 text")
        } catch {
            XCTAssertEqual(error as? NsecStoreError, .invalidInput)
        }

        let failingStore = NsecKeychainStore(
            unlockDuration: 0,
            keychain: FakeNsecKeychainBackend(copyStatuses: [errSecMissingEntitlement], copyData: nil)
        )
        do {
            _ = try await failingStore.loadNsec(for: "identity")
            XCTFail("unexpected keychain status should throw")
        } catch {
            XCTAssertEqual(error as? NsecStoreError, .unexpectedStatus(errSecMissingEntitlement))
        }
    }

    func testDeleteNsecAndLockClearCachedSecrets() async throws {
        let backend = FakeNsecKeychainBackend(copyStatuses: [errSecSuccess], copyData: TestVectors.nsec.data(using: .utf8))
        let store = NsecKeychainStore(unlockDuration: 0, keychain: backend)

        let deletedValue = try await store.loadNsec(for: "identity")
        XCTAssertEqual(deletedValue, TestVectors.nsec)
        await store.deleteNsec(for: "identity")
        XCTAssertEqual(backend.deleteCount(), 1)

        backend.setCopyStatuses([errSecItemNotFound])
        let missingAfterDelete = try await store.loadNsec(for: "identity")
        XCTAssertNil(missingAfterDelete)

        backend.setCopyStatuses([errSecSuccess])
        backend.setCopyData(TestVectors.nsec.data(using: .utf8))
        await store.lock()
        let finalValue = try await store.loadNsec(for: "identity")
        XCTAssertEqual(finalValue, TestVectors.nsec)
    }
}

private final class FakeNsecKeychainBackend: NsecKeychainBackend, @unchecked Sendable {
    private var addStatuses: [OSStatus]
    private var copyStatuses: [OSStatus]
    private var deleteStatuses: [OSStatus]
    private var copyData: Data?

    private var addQueries: [[String: Any]] = []
    private var copyQueries: [[String: Any]] = []
    private var deleteQueries: [[String: Any]] = []

    init(
        addStatus: OSStatus = errSecSuccess,
        copyStatuses: [OSStatus] = [],
        copyData: Data? = nil,
        deleteStatus: OSStatus = errSecSuccess
    ) {
        self.addStatuses = [addStatus]
        self.copyStatuses = copyStatuses
        self.copyData = copyData
        self.deleteStatuses = [deleteStatus]
    }

    private func pop(_ queue: inout [OSStatus], default fallback: OSStatus) -> OSStatus {
        guard let first = queue.first else { return fallback }
        queue.removeFirst()
        return first
    }

    func add(query: [String: Any]) -> OSStatus {
        addQueries.append(query)
        return pop(&addStatuses, default: errSecSuccess)
    }

    func delete(query: [String: Any]) -> OSStatus {
        deleteQueries.append(query)
        return pop(&deleteStatuses, default: errSecSuccess)
    }

    func copyMatching(query: [String: Any], result: inout CFTypeRef?) -> OSStatus {
        copyQueries.append(query)
        let status = pop(&copyStatuses, default: errSecSuccess)
        if status == errSecSuccess, let copyData {
            result = copyData as CFTypeRef
        }
        return status
    }

    func addCount() -> Int { addQueries.count }
    func copyMatchingCount() -> Int { copyQueries.count }
    func deleteCount() -> Int { deleteQueries.count }
    func lastAddQuery() -> [String: Any] { addQueries.last ?? [:] }
    func lastAddedData() -> Data? { lastAddQuery()[kSecValueData as String] as? Data }
    func authenticationContexts() -> [LAContext] {
        copyQueries.compactMap { $0[kSecUseAuthenticationContext as String] as? LAContext }
    }

    func setCopyStatuses(_ statuses: [OSStatus]) {
        copyStatuses = statuses
    }

    func setCopyData(_ data: Data?) {
        copyData = data
    }
}
