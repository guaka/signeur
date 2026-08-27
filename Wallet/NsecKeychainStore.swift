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
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Keychain error \(status): \(detail)"
        }
    }
}

public actor NsecKeychainStore: NsecStoring {
    private let service = "com.k.signstr.nsec"
    private var authenticationContext = NsecKeychainStore.makeAuthenticationContext()
    private var unlockCache: NsecUnlockCache

    public init(unlockDuration: TimeInterval = 120) {
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identityID
        ]
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identityID,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    public func loadNsec(for identityID: String) throws -> String? {
        if let cached = unlockCache.value(for: identityID, now: Date()) {
            return cached
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identityID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authenticationContext
        ]
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identityID
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Ends the short in-memory unlock window, such as when the app backgrounds.
    public func lock() {
        unlockCache.removeAll()
        authenticationContext.invalidate()
        authenticationContext = Self.makeAuthenticationContext()
    }

    private static func makeAuthenticationContext() -> LAContext {
        let context = LAContext()
        context.localizedReason = "Unlock your Nostr key to sign or decrypt a request."
        context.touchIDAuthenticationAllowableReuseDuration = 120
        return context
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
