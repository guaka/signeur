import Foundation
import XCTest
@testable import SignstrCore

final class NsecUnlockCacheTests: XCTestCase {
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

    func testLockClearsAllCachedKeys() {
        let start = Date(timeIntervalSince1970: 1_000)
        var cache = NsecUnlockCache(duration: 120)
        cache.insert("first", for: "one", now: start)
        cache.insert("second", for: "two", now: start)

        cache.removeAll()

        XCTAssertNil(cache.value(for: "one", now: start))
        XCTAssertNil(cache.value(for: "two", now: start))
    }
}
