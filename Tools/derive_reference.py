"""Independent reference for the Bech32 + secp256k1 test vectors used by NostrKeyDeriverTests.

Pure Python so it shares no code with the app: pairs an nsec with the npub/x-only
pubkey that Swift must produce.

Usage: python3 Tools/derive_reference.py <nsec>
"""

import sys

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
P = 2**256 - 2**32 - 977
G = (
    0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
    0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8,
)


def bech32_polymod(values):
    generators = [0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3]
    chk = 1
    for value in values:
        top = chk >> 25
        chk = (chk & 0x1FFFFFF) << 5 ^ value
        for i in range(5):
            chk ^= generators[i] if ((top >> i) & 1) else 0
    return chk


def hrp_expand(hrp):
    return [ord(c) >> 5 for c in hrp] + [0] + [ord(c) & 31 for c in hrp]


def convert_bits(data, frombits, tobits, pad):
    acc = 0
    bits = 0
    ret = []
    maxv = (1 << tobits) - 1
    for value in data:
        acc = (acc << frombits) | value
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad and bits:
        ret.append((acc << (tobits - bits)) & maxv)
    return ret


def bech32_decode(bech, expected_hrp):
    pos = bech.rfind("1")
    hrp, data = bech[:pos], bech[pos + 1 :]
    assert hrp == expected_hrp, f"unexpected hrp {hrp}"
    values = [CHARSET.index(c) for c in data]
    assert bech32_polymod(hrp_expand(hrp) + values) == 1, "bad checksum"
    return bytes(convert_bits(values[:-6], 5, 8, False))


def bech32_encode(hrp, payload):
    data = convert_bits(payload, 8, 5, True)
    checksum_input = hrp_expand(hrp) + data + [0] * 6
    mod = bech32_polymod(checksum_input) ^ 1
    checksum = [(mod >> 5 * (5 - i)) & 31 for i in range(6)]
    return hrp + "1" + "".join(CHARSET[d] for d in data + checksum)


def point_add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0] and (a[1] + b[1]) % P == 0:
        return None
    if a == b:
        lam = 3 * a[0] * a[0] * pow(2 * a[1], P - 2, P) % P
    else:
        lam = (b[1] - a[1]) * pow(b[0] - a[0], P - 2, P) % P
    x = (lam * lam - a[0] - b[0]) % P
    return (x, (lam * (a[0] - x) - a[1]) % P)


def point_mul(scalar, point=G):
    result = None
    addend = point
    while scalar:
        if scalar & 1:
            result = point_add(result, addend)
        addend = point_add(addend, addend)
        scalar >>= 1
    return result


def main():
    nsec = sys.argv[1]
    secret = bech32_decode(nsec, "nsec")
    pubkey = point_mul(int.from_bytes(secret, "big"))
    xonly = pubkey[0].to_bytes(32, "big")
    print(f"seckey_hex {secret.hex()}")
    print(f"xonly_hex  {xonly.hex()}")
    print(f"npub       {bech32_encode('npub', xonly)}")


if __name__ == "__main__":
    main()
