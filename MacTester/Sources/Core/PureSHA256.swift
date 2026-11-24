//
// PureSHA256.swift — bitchat Mac tester (Swift 5.0 compatible)
//
// Straightforward FIPS 180-4 SHA-256 and RFC 2104 HMAC-SHA256 / RFC 5869 HKDF.
// Used on Linux (test harness) and as a fallback; on macOS the tester uses
// CommonCrypto (see TesterCrypto.swift). Written for clarity, not speed.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

struct PureSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    @inline(__always) private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 {
        return (x >> n) | (x << (32 - n))
    }

    static func hash(_ input: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                           0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = input
        let bitLen = UInt64(input.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        var i = 7
        while i >= 0 { msg.append(UInt8((bitLen >> UInt64(i * 8)) & 0xff)); i -= 1 }

        var w = [UInt32](repeating: 0, count: 64)
        var chunk = 0
        while chunk < msg.count {
            for t in 0..<16 {
                let b = chunk + t * 4
                w[t] = (UInt32(msg[b]) << 24) | (UInt32(msg[b + 1]) << 16) | (UInt32(msg[b + 2]) << 8) | UInt32(msg[b + 3])
            }
            for t in 16..<64 {
                let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
            }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
            for t in 0..<64 {
                let S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ S1 &+ ch &+ k[t] &+ w[t]
                let S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = S0 &+ maj
                hh = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
            h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
            chunk += 64
        }
        var out = [UInt8]()
        out.reserveCapacity(32)
        for v in h {
            out.append(UInt8(v >> 24)); out.append(UInt8((v >> 16) & 0xff))
            out.append(UInt8((v >> 8) & 0xff)); out.append(UInt8(v & 0xff))
        }
        return out
    }

    static func hmac(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var k = key
        if k.count > 64 { k = hash(k) }
        if k.count < 64 { k += [UInt8](repeating: 0, count: 64 - k.count) }
        var ipad = [UInt8](repeating: 0, count: 64)
        var opad = [UInt8](repeating: 0, count: 64)
        for i in 0..<64 { ipad[i] = k[i] ^ 0x36; opad[i] = k[i] ^ 0x5c }
        return hash(opad + hash(ipad + message))
    }

    /// RFC 5869 HKDF-SHA256 (extract + expand).
    static func hkdf(ikm: [UInt8], salt: [UInt8], info: [UInt8], length: Int) -> [UInt8] {
        let prk = hmac(key: salt.isEmpty ? [UInt8](repeating: 0, count: 32) : salt, message: ikm)
        var okm = [UInt8]()
        var t = [UInt8]()
        var counter: UInt8 = 1
        while okm.count < length {
            t = hmac(key: prk, message: t + info + [counter])
            okm += t
            counter = counter &+ 1
        }
        return Array(okm.prefix(length))
    }
}
