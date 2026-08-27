import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import SignstrCore

final class NsecUnlockCacheTests: XCTestCase {
    func testProtectedStorageFailureHasAnActionableMessage() {
        XCTAssertEqual(
            NsecStoreError.unexpectedStatus(-34010).errorDescription,
            "Keychain could not create protected storage. Please try again. (error -34010)"
        )
    }

    func testMissingEntitlementHasAnActionableMessage() {
        XCTAssertEqual(
            NsecStoreError.unexpectedStatus(errSecMissingEntitlement).errorDescription,
            "This build of Signstr is missing Keychain permission. (error -34018)"
        )
    }

    func testBaseQueryUsesDataProtectionKeychainForProtectedMacItems() {
        let query = NsecKeychainStore.makeItemQuery(service: "test.service", identityID: "key-1")

        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "test.service")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "key-1")
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertNil(query[kSecAttrAccessGroup as String], "the app should use its default access group")
    }

    func testLockedKeychainItemsStillCountAsPresent() {
        XCTAssertTrue(NsecKeychainStore.indicatesPresence(errSecSuccess))
        XCTAssertTrue(NsecKeychainStore.indicatesPresence(errSecInteractionNotAllowed))
        XCTAssertTrue(NsecKeychainStore.indicatesPresence(errSecAuthFailed))
        XCTAssertFalse(NsecKeychainStore.indicatesPresence(errSecItemNotFound))
        XCTAssertFalse(NsecKeychainStore.indicatesPresence(errSecMissingEntitlement))
    }

    func testPresenceQueryCannotDisplayAuthenticationUI() throws {
        let query = NsecKeychainStore.makePresenceQuery(service: "test.service", identityID: "key-1")
        let context = try XCTUnwrap(query[kSecUseAuthenticationContext as String] as? LAContext)

        XCTAssertTrue(context.interactionNotAllowed)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, false)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "test.service")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "key-1")
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
    }

    func testLoadQueryCanAuthenticateAndRequestsSecretData() throws {
        let context = NsecKeychainStore.makeAuthenticationContext()
        let query = NsecKeychainStore.makeLoadQuery(
            service: "test.service",
            identityID: "key-1",
            context: context
        )
        let queryContext = try XCTUnwrap(query[kSecUseAuthenticationContext as String] as? LAContext)

        XCTAssertTrue(queryContext === context)
        XCTAssertFalse(queryContext.interactionNotAllowed)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
    }

    func testAuthenticationContextUsesFiveMinuteSystemReuseWindow() {
        let context = NsecKeychainStore.makeAuthenticationContext()

        XCTAssertEqual(NsecKeychainStore.defaultUnlockDuration, 300)
        XCTAssertEqual(context.touchIDAuthenticationAllowableReuseDuration, 300)
        XCTAssertFalse(context.localizedReason.isEmpty)
    }

    func testReturnsKeyDuringUnlockWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        var cache = NsecUnlockCache(duration: 120)
        cache.insert("nsec", for: "identity", now: start)

        XCTAssertEqual(
            cache.value(for: "identity", now: start.addingTimeInterval(119)),
            "nsec"
        )
    }

    func testExpiresKeyAtEndOfUnlockWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        var cache = NsecUnlockCache(duration: 120)
        cache.insert("nsec", for: "identity", now: start)

        XCTAssertNil(cache.value(for: "identity", now: start.addingTimeInterval(120)))
    }

    func testUsingAKeyExtendsTheIdleWindow() {
        let start = Date(timeIntervalSince1970: 1_000)
        var cache = NsecUnlockCache(duration: 120)
        cache.insert("nsec", for: "identity", now: start)

        XCTAssertEqual(
            cache.value(for: "identity", now: start.addingTimeInterval(119)),
            "nsec"
        )
        XCTAssertEqual(
            cache.value(for: "identity", now: start.addingTimeInterval(238)),
            "nsec"
        )
        XCTAssertNil(
            cache.value(for: "identity", now: start.addingTimeInterval(358))
        )
    }

    func testLockClearsAllCachedKeys() {
        let start = Date(timeIntervalSince1970: 1_000)
        var cache = NsecUnlockCache(duration: 120)
        cache.insert("first", for: "one", now: start)
        cache.insert("second", for: "two", now: start)

        cache.removeAll()

        XCTAssertNil(cache.value(for: "one", now: start))
        XCTAssertNil(cache.value(for: "two", now: start))
    }

    func testRemovingOneKeyDoesNotLockAnotherKey() {
        let start = Date(timeIntervalSince1970: 1_000)
        var cache = NsecUnlockCache(duration: 120)
        cache.insert("first", for: "one", now: start)
        cache.insert("second", for: "two", now: start)

        cache.removeValue(for: "one")

        XCTAssertNil(cache.value(for: "one", now: start))
        XCTAssertEqual(cache.value(for: "two", now: start), "second")
    }

    func testKeysAreIsolatedByIdentity() {
        let start = Date(timeIntervalSince1970: 1_000)
        var cache = NsecUnlockCache(duration: 120)
        cache.insert("first", for: "one", now: start)

        XCTAssertNil(cache.value(for: "two", now: start))
        XCTAssertEqual(cache.value(for: "one", now: start), "first")
    }

    func testZeroDurationNeverCachesAKey() {
        let start = Date(timeIntervalSince1970: 1_000)
        var cache = NsecUnlockCache(duration: 0)
        cache.insert("nsec", for: "identity", now: start)

        XCTAssertNil(cache.value(for: "identity", now: start))
    }

    func testReinsertingAKeyReplacesItsValueAndRestartsExpiry() {
        let start = Date(timeIntervalSince1970: 1_000)
        var cache = NsecUnlockCache(duration: 120)
        cache.insert("old", for: "identity", now: start)
        cache.insert("new", for: "identity", now: start.addingTimeInterval(100))

        XCTAssertEqual(
            cache.value(for: "identity", now: start.addingTimeInterval(219)),
            "new"
        )
    }
}
