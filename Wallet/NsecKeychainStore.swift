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

    public init() {}

    public func saveNsec(_ nsec: String, for identityID: String) throws {
        let trimmed = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("nsec"), !identityID.isEmpty else {
            throw NsecStoreError.invalidInput
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw NsecStoreError.invalidInput
        }

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
            if status == errSecAuthFailed || status == errSecUserCanceled {
                authenticationContext = Self.makeAuthenticationContext()
            }
            throw NsecStoreError.unexpectedStatus(status)
        }
        guard
            let data = result as? Data,
            let nsec = String(data: data, encoding: .utf8)
        else {
            throw NsecStoreError.invalidInput
        }
        return nsec
    }

    public func deleteNsec(for identityID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identityID
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func makeAuthenticationContext() -> LAContext {
        let context = LAContext()
        context.localizedReason = "Unlock your Nostr key to sign or decrypt a request."
        context.touchIDAuthenticationAllowableReuseDuration = 60
        return context
    }
}
