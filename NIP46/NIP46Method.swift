import Foundation

public enum NIP46Method: String, CaseIterable, Codable, Sendable {
    case connect
    case getPublicKey = "get_public_key"
    case signEvent = "sign_event"
    case ping
    case nip04Encrypt = "nip04_encrypt"
    case nip04Decrypt = "nip04_decrypt"
    case nip44Encrypt = "nip44_encrypt"
    case nip44Decrypt = "nip44_decrypt"
    case switchRelays = "switch_relays"
    case logout
}
