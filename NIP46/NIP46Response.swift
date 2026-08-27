import Foundation

public struct NIP46Response: Codable, Equatable, Sendable {
    public let id: String
    public let result: String?
    public let error: NIP46ResponseError?

    public init(id: String, result: String?, error: NIP46ResponseError?) {
        self.id = id
        self.result = result
        self.error = error
    }
}

public struct NIP46ResponseError: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}
