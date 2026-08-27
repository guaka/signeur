import Foundation
import LocalAuthentication
import Security

public enum NsecStoreError: Error, Equatable, LocalizedError {
    case invalidInput
    case protectionUnavailable
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "The key could not be read as a valid nsec."
        case .protectionUnavailable:
            return "This device could not create biometric Keychain protection."
        case .unexpectedStatus(let status):
            if status == -34010 {
                return "Keychain could not create protected storage. Please try again. (error -34010)"
            }
            if status == errSecMissingEntitlement {
                return "This build of Signstr is missing Keychain permission. (error \(status))"
            }
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(detail)"
        }
    }
}

public actor NsecKeychainStore: NsecStoring {
    public static let defaultUnlockDuration: TimeInterval = 5 * 60
    private let service = "com.k.signstr.nsec"
    private var authenticationContext = NsecKeychainStore.makeAuthenticationContext()
    private var unlockCache: NsecUnlockCache

    public init(unlockDuration: TimeInterval = NsecKeychainStore.defaultUnlockDuration) {
        unlockCache = NsecUnlockCache(duration: unlockDuration)
    }

    public func saveNsec(_ nsec: String, for identityID: String) throws {
        let trimmed = nsec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard SecurityPolicy.validateIdentifier(identityID),
              (try? NostrKeyDeriver.derivePublicKeyHex(fromNsec: trimmed)) != nil
        else {
            throw NsecStoreError.invalidInput
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw NsecStoreError.invalidInput
        }

        unlockCache.removeValue(for: identityID)
        let query = Self.makeItemQuery(service: service, identityID: identityID)
        SecItemDelete(query as CFDictionary)

        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &accessControlError
        ) else {
            throw NsecStoreError.protectionUnavailable
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessControl as String] = accessControl
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NsecStoreError.unexpectedStatus(status)
        }
    }

    public func hasNsec(for identityID: String) -> Bool {
        let query = Self.makePresenceQuery(service: service, identityID: identityID)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return Self.indicatesPresence(status)
    }

    public func loadNsec(for identityID: String) throws -> String? {
        if let cached = unlockCache.value(for: identityID, now: Date()) {
            return cached
        }

        let query = Self.makeLoadQuery(
            service: service,
            identityID: identityID,
            context: authenticationContext
        )
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            authenticationContext = Self.makeAuthenticationContext()
            throw NsecStoreError.unexpectedStatus(status)
        }
        guard
            let data = result as? Data,
            let nsec = String(data: data, encoding: .utf8)
        else {
            authenticationContext = Self.makeAuthenticationContext()
            throw NsecStoreError.invalidInput
        }
        unlockCache.insert(nsec, for: identityID, now: Date())
        return nsec
    }

    public func deleteNsec(for identityID: String) {
        unlockCache.removeValue(for: identityID)
        let query = Self.makeItemQuery(service: service, identityID: identityID)
        SecItemDelete(query as CFDictionary)
    }

    /// Ends the short in-memory unlock window, such as when the app backgrounds.
    public func lock() {
        unlockCache.removeAll()
        authenticationContext.invalidate()
        authenticationContext = Self.makeAuthenticationContext()
    }

    static func makeAuthenticationContext() -> LAContext {
        let context = LAContext()
        context.localizedReason = "Unlock your Nostr key to sign or decrypt a request."
        context.touchIDAuthenticationAllowableReuseDuration = defaultUnlockDuration
        return context
    }

    static func makeItemQuery(service: String, identityID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identityID,
            // macOS otherwise uses its legacy file-based Keychain, which does
            // not support the iOS-style accessibility and user-presence policy
            // attached to Signstr's private keys. iOS ignores this key.
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    static func makePresenceQuery(service: String, identityID: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        var query = makeItemQuery(service: service, identityID: identityID)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    static func makeLoadQuery(service: String, identityID: String, context: LAContext) -> [String: Any] {
        var query = makeItemQuery(service: service, identityID: identityID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    static func indicatesPresence(_ status: OSStatus) -> Bool {
        switch status {
        case errSecSuccess, errSecInteractionNotAllowed, errSecAuthFailed:
            return true
        default:
            return false
        }
    }
}

struct NsecUnlockCache {
    private struct Entry {
        let nsec: String
        let expiresAt: Date
    }

    private let duration: TimeInterval
    private var entries: [String: Entry] = [:]

    init(duration: TimeInterval) {
        self.duration = max(0, duration)
    }

    mutating func value(for identityID: String, now: Date) -> String? {
        guard let entry = entries[identityID] else { return nil }
        guard entry.expiresAt > now else {
            entries.removeValue(forKey: identityID)
            return nil
        }
        entries[identityID] = Entry(
            nsec: entry.nsec,
            expiresAt: now.addingTimeInterval(duration)
        )
        return entry.nsec
    }

    mutating func insert(_ nsec: String, for identityID: String, now: Date) {
        entries[identityID] = Entry(
            nsec: nsec,
            expiresAt: now.addingTimeInterval(duration)
        )
    }

    mutating func removeValue(for identityID: String) {
        entries.removeValue(forKey: identityID)
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
    }
}
