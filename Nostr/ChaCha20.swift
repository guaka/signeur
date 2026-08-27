import Foundation

/// RFC 8439 ChaCha20 stream cipher.
///
/// CryptoKit only exposes the AEAD construction (ChaChaPoly), but NIP-44 v2 uses the
/// raw stream cipher with a separate HMAC, so the block function is implemented here.
enum ChaCha20 {
    static let keyByteCount = 32
    static let nonceByteCount = 12

    static func apply(key: [UInt8], nonce: [UInt8], counter: UInt32 = 0, to input: [UInt8]) -> [UInt8] {
        precondition(key.count == keyByteCount, "ChaCha20 needs a 32-byte key")
        precondition(nonce.count == nonceByteCount, "ChaCha20 needs a 12-byte nonce")

        var output = [UInt8]()
        output.reserveCapacity(input.count)

        var blockCounter = counter
        var offset = 0
        while offset < input.count {
            let keyStream = block(key: key, nonce: nonce, counter: blockCounter)
            let chunk = min(64, input.count - offset)
            for i in 0..<chunk {
                output.append(input[offset + i] ^ keyStream[i])
            }
            offset += chunk
            blockCounter &+= 1
        }
        return output
    }

    private static func block(key: [UInt8], nonce: [UInt8], counter: UInt32) -> [UInt8] {
        var state = [UInt32](repeating: 0, count: 16)
        state[0] = 0x6170_7865
        state[1] = 0x3320_646e
        state[2] = 0x7962_2d32
        state[3] = 0x6b20_6574
        for i in 0..<8 {
            state[4 + i] = word(key, at: i * 4)
        }
        state[12] = counter
        for i in 0..<3 {
            state[13 + i] = word(nonce, at: i * 4)
        }

        var working = state
        for _ in 0..<10 {
            quarterRound(&working, 0, 4, 8, 12)
            quarterRound(&working, 1, 5, 9, 13)
            quarterRound(&working, 2, 6, 10, 14)
            quarterRound(&working, 3, 7, 11, 15)
            quarterRound(&working, 0, 5, 10, 15)
            quarterRound(&working, 1, 6, 11, 12)
            quarterRound(&working, 2, 7, 8, 13)
            quarterRound(&working, 3, 4, 9, 14)
        }

        var result = [UInt8]()
        result.reserveCapacity(64)
        for i in 0..<16 {
            let value = working[i] &+ state[i]
            result.append(UInt8(truncatingIfNeeded: value))
            result.append(UInt8(truncatingIfNeeded: value >> 8))
            result.append(UInt8(truncatingIfNeeded: value >> 16))
            result.append(UInt8(truncatingIfNeeded: value >> 24))
        }
        return result
    }

    private static func quarterRound(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        state[a] = state[a] &+ state[b]
        state[d] = rotateLeft(state[d] ^ state[a], 16)
        state[c] = state[c] &+ state[d]
        state[b] = rotateLeft(state[b] ^ state[c], 12)
        state[a] = state[a] &+ state[b]
        state[d] = rotateLeft(state[d] ^ state[a], 8)
        state[c] = state[c] &+ state[d]
        state[b] = rotateLeft(state[b] ^ state[c], 7)
    }

    private static func rotateLeft(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }

    private static func word(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index])
            | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16
            | UInt32(bytes[index + 3]) << 24
    }
}
