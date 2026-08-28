import Foundation
import LocalAuthentication
import Security

public enum NsecStoreError: Error, Equatable, LocalizedError {
    case invalidInput
    case protectionUnavailable
    case authenticationFailed
    case authenticationCanceled
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidInput:
            return "The key could not be read as a valid nsec."
        case .protectionUnavailable:
            return "This device could not create biometric Keychain protection."
        case .authenticationFailed:
            return "Face ID or device authentication did not succeed. Please try again."
        case .authenticationCanceled:
            return "Authentication was canceled."
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

protocol NsecKeychainBackend: Sendable {
    func delete(query: [String: Any]) -> OSStatus
    func add(query: [String: Any]) -> OSStatus
    func copyMatching(query: [String: Any], result: inout CFTypeRef?) -> OSStatus
    func makeAccessControl() -> SecAccessControl?
}

extension NsecKeychainBackend {
    func makeAccessControl() -> SecAccessControl? {
        var error: Unmanaged<CFError>?
        return SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        )
    }
}

struct DefaultNsecKeychainBackend: NsecKeychainBackend {
    func delete(query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }

    func add(query: [String: Any]) -> OSStatus {
        SecItemAdd(query as CFDictionary, nil)
    }

    func copyMatching(query: [String: Any], result: inout CFTypeRef?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, &result)
    }
}

public actor NsecKeychainStore: NsecStoring {
    public static let defaultUnlockDuration: TimeInterval = 5 * 60
    private let service = "com.k.signstr.nsec"
    private let keychain: NsecKeychainBackend
    private var unlockCache: NsecUnlockCache

    public init(unlockDuration: TimeInterval = NsecKeychainStore.defaultUnlockDuration) {
        unlockCache = NsecUnlockCache(duration: unlockDuration)
        keychain = DefaultNsecKeychainBackend()
    }

    init(unlockDuration: TimeInterval, keychain: NsecKeychainBackend) {
        unlockCache = NsecUnlockCache(duration: unlockDuration)
        self.keychain = keychain
    }

    public func saveNsec(_ nsec: String, for identityID: String) throws {
        let trimmed = nsec.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard SecurityPolicy.validateIdentifier(identityID),
              (try? NostrKeyDeriver.derivePublicKeyHex(fromNsec: trimmed)) != nil
        else {
            throw NsecStoreError.invalidInput
        }
        let data = Data(trimmed.utf8)

        unlockCache.removeValue(for: identityID)
        let query = Self.makeItemQuery(service: service, identityID: identityID)
        _ = keychain.delete(query: query)

        guard let accessControl = keychain.makeAccessControl() else {
            throw NsecStoreError.protectionUnavailable
        }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessControl as String] = accessControl
        let status = keychain.add(query: addQuery)
        guard status == errSecSuccess else {
            throw NsecStoreError.unexpectedStatus(status)
        }
    }

    public func hasNsec(for identityID: String) -> Bool {
        let query = Self.makePresenceQuery(service: service, identityID: identityID)
        var ignoredResult: CFTypeRef? = nil
        let status = keychain.copyMatching(query: query, result: &ignoredResult)
        return Self.indicatesPresence(status)
    }

    public func loadNsec(for identityID: String) throws -> String? {
        if let cached = unlockCache.value(for: identityID, now: Date()) {
            return cached
        }

        var response = loadNsec(identityID: identityID, context: Self.makeAuthenticationContext())
        if response.status == errSecAuthFailed {
            // App state and biometric changes can leave an LAContext unusable.
            // Retry once with a new context so Keychain can present Face ID.
            response = loadNsec(identityID: identityID, context: Self.makeAuthenticationContext())
        }
        let status = response.status
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw Self.error(for: status)
        }
        guard
            let data = response.result as? Data,
            let nsec = String(data: data, encoding: .utf8)
        else {
            throw NsecStoreError.invalidInput
        }
        unlockCache.insert(nsec, for: identityID, now: Date())
        return nsec
    }

    public func deleteNsec(for identityID: String) {
        unlockCache.removeValue(for: identityID)
        let query = Self.makeItemQuery(service: service, identityID: identityID)
        _ = keychain.delete(query: query)
    }

    /// Ends the short in-memory unlock window, such as when the app backgrounds.
    public func lock() {
        unlockCache.removeAll()
    }

    private func loadNsec(identityID: String, context: LAContext) -> (status: OSStatus, result: CFTypeRef?) {
        let query = Self.makeLoadQuery(service: service, identityID: identityID, context: context)
        var result: CFTypeRef?
        let status = keychain.copyMatching(query: query, result: &result)
        return (status, result)
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

    static func error(for status: OSStatus) -> NsecStoreError {
        switch status {
        case errSecAuthFailed:
            return .authenticationFailed
        case errSecUserCanceled:
            return .authenticationCanceled
        default:
            return .unexpectedStatus(status)
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
