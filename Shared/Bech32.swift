import Foundation

enum Bech32Error: Error, Equatable {
    case invalidCharacter
    case invalidChecksum
    case invalidFormat
    case invalidData
}

enum Bech32 {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
    private static let charsetRev: [Character: UInt8] = {
        var table: [Character: UInt8] = [:]
        for (i, c) in charset.enumerated() {
            table[c] = UInt8(i)
        }
        return table
    }()

    static func decode(_ bech: String, expectedHRP: String) throws -> [UInt8] {
        let lower = bech.lowercased()
        guard let sep = lower.lastIndex(of: "1"), sep != lower.startIndex else {
            throw Bech32Error.invalidFormat
        }
        let hrp = String(lower[..<sep])
        guard hrp == expectedHRP else { throw Bech32Error.invalidFormat }

        let dataPart = lower[lower.index(after: sep)...]
        guard dataPart.count >= 6 else { throw Bech32Error.invalidFormat }
        var values: [UInt8] = []
        values.reserveCapacity(dataPart.count)
        for ch in dataPart {
            guard let v = charsetRev[ch] else { throw Bech32Error.invalidCharacter }
            values.append(v)
        }

        guard verifyChecksum(hrp: hrp, data: values) else {
            throw Bech32Error.invalidChecksum
        }
        let payload = Array(values.dropLast(6))
        guard let bytes = convertBits(payload, from: 5, to: 8, pad: false) else {
            throw Bech32Error.invalidData
        }
        return bytes
    }

    static func encode(hrp: String, bytes: [UInt8]) throws -> String {
        // Every UInt8 is valid input when converting from 8 bits with padding enabled.
        let data5 = convertBits(bytes, from: 8, to: 5, pad: true)!
        let checksum = createChecksum(hrp: hrp, data: data5)
        let combined = data5 + checksum
        let encoded = combined.map { String(charset[Int($0)]) }.joined()
        return "\(hrp)1\(encoded)"
    }

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let generators: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        var chk: UInt32 = 1
        for v in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(v)
            for i in 0..<5 where ((top >> i) & 1) == 1 {
                chk ^= generators[i]
            }
        }
        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        var result: [UInt8] = []
        for scalar in hrp.unicodeScalars {
            result.append(UInt8(scalar.value >> 5))
        }
        result.append(0)
        for scalar in hrp.unicodeScalars {
            result.append(UInt8(scalar.value & 31))
        }
        return result
    }

    private static func verifyChecksum(hrp: String, data: [UInt8]) -> Bool {
        polymod(hrpExpand(hrp) + data) == 1
    }

    static func createChecksum(hrp: String, data: [UInt8]) -> [UInt8] {
        let values = hrpExpand(hrp) + data + [0, 0, 0, 0, 0, 0]
        let mod = polymod(values) ^ 1
        return (0..<6).map { i in
            UInt8((mod >> (5 * (5 - i))) & 31)
        }
    }

    private static func convertBits(_ data: [UInt8], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var acc = 0
        var bits = 0
        let maxv = (1 << to) - 1
        var ret: [UInt8] = []
        for value in data {
            if (value >> from) != 0 { return nil } // coverage:ignore-region Private callers constrain every value to the declared source bit width.
            acc = (acc << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                ret.append(UInt8((acc >> bits) & maxv))
            }
        }
        if pad {
            if bits > 0 {
                ret.append(UInt8((acc << (to - bits)) & maxv))
            }
        } else if bits >= from || ((acc << (to - bits)) & maxv) != 0 {
            return nil
        }
        return ret
    }
}
