#!/usr/bin/env python3
"""Generates reference values for the Swift tests, independently of the Swift code.

Run:  python3 Tools/derive_reference_vectors.py

Prints NIP-01 event ids and a NIP-04 payload. The secp256k1 arithmetic here is a
deliberately plain implementation so the Swift side is checked against the spec
rather than against another copy of the same library.
"""

import base64
import hashlib
import json

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

P = 2**256 - 2**32 - 977
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (
    0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
    0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8,
)


def point_add(p, q):
    if p is None:
        return q
    if q is None:
        return p
    if p[0] == q[0] and (p[1] + q[1]) % P == 0:
        return None
    if p == q:
        lam = 3 * p[0] * p[0] * pow(2 * p[1], P - 2, P) % P
    else:
        lam = (q[1] - p[1]) * pow(q[0] - p[0], P - 2, P) % P
    x = (lam * lam - p[0] - q[0]) % P
    return (x, (lam * (p[0] - x) - p[1]) % P)


def point_mul(k, point=G):
    result = None
    addend = point
    while k:
        if k & 1:
            result = point_add(result, addend)
        addend = point_add(addend, addend)
        k >>= 1
    return result


def lift_x(x):
    """The even-Y point with the given x coordinate, as Nostr keys are x-only."""
    y_sq = (pow(x, 3, P) + 7) % P
    y = pow(y_sq, (P + 1) // 4, P)
    if pow(y, 2, P) != y_sq:
        raise ValueError("x is not on the curve")
    return (x, y if y % 2 == 0 else P - y)


def xonly_pubkey(secret_hex):
    return f"{point_mul(int(secret_hex, 16))[0]:064x}"


def event_id(pubkey, created_at, kind, tags, content):
    serialized = json.dumps(
        [0, pubkey, created_at, kind, tags, content],
        separators=(",", ":"),
        ensure_ascii=False,
    )
    return hashlib.sha256(serialized.encode()).hexdigest()


def nip04_encrypt(secret_hex, peer_xonly_hex, plaintext, iv):
    shared_x = point_mul(int(secret_hex, 16), lift_x(int(peer_xonly_hex, 16)))[0]
    key = shared_x.to_bytes(32, "big")
    padding = 16 - len(plaintext.encode()) % 16
    padded = plaintext.encode() + bytes([padding]) * padding
    encryptor = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    ciphertext = encryptor.update(padded) + encryptor.finalize()
    return (
        base64.b64encode(ciphertext).decode()
        + "?iv="
        + base64.b64encode(iv).decode()
    )


if __name__ == "__main__":
    sec1 = "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"
    sec2 = "0000000000000000000000000000000000000000000000000000000000000002"
    pub1, pub2 = xonly_pubkey(sec1), xonly_pubkey(sec2)

    print("pub1:", pub1)
    print("pub2:", pub2)

    print("\nNIP-01 event ids")
    for case in [
        (pub1, 1700000000, 1, [], "hello world"),
        (
            pub1,
            1700000000,
            1,
            [["e", "abc"], ["p", "def", "wss://relay.one"]],
            'quote " backslash \\ newline \n tab \t emoji 🔑 unicode ñ',
        ),
        (pub1, 0, 24133, [["p", pub1]], ""),
    ]:
        print(" ", event_id(*case))

    print("\nNIP-04 payload (sec1 -> pub2, iv = 16 zero bytes)")
    print(" ", nip04_encrypt(sec1, pub2, "hello from python", bytes(16)))
