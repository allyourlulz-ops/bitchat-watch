//
// TesterCrypto.swift — bitchat Mac tester (Swift 5.0 compatible, macOS 10.14+)
//
// CryptoKit is macOS 10.15+, so the tester uses:
//   * Monocypher 4.0.2 (vendored C, BSD-2/CC0): X25519, Ed25519, ChaCha20-Poly1305 (IETF)
//   * CommonCrypto (macOS) for SHA-256/HMAC; PureSHA256 elsewhere (Linux harness)
// On macOS the Monocypher headers come in via the bridging header
// (Sources/App/Tester-Bridging-Header.h); on Linux via the CMonocypher module.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
#if canImport(CMonocypher)
import CMonocypher
#endif
#if canImport(CommonCrypto)
import CommonCrypto
#endif

enum BTCrypto {
    static func randomBytes(_ n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        #if canImport(Security) && os(macOS)
        if SecRandomCopyBytes(kSecRandomDefault, n, &out) == errSecSuccess { return out }
        #endif
        var g = SystemRandomNumberGenerator()
        for i in 0..<n { out[i] = UInt8.random(in: 0...255, using: &g) }
        return out
    }

    // MARK: hashing

    static func sha256(_ data: [UInt8]) -> [UInt8] {
        #if canImport(CommonCrypto)
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = CC_SHA256(data, CC_LONG(data.count), &out)
        return out
        #else
        return PureSHA256.hash(data)
        #endif
    }

    static func hmacSHA256(key: [UInt8], data: [UInt8]) -> [UInt8] {
        #if canImport(CommonCrypto)
        var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, data, data.count, &out)
        return out
        #else
        return PureSHA256.hmac(key: key, message: data)
        #endif
    }

    static func hkdfSHA256(ikm: [UInt8], salt: [UInt8], info: [UInt8], length: Int) -> [UInt8] {
        let prk = hmacSHA256(key: salt.isEmpty ? [UInt8](repeating: 0, count: 32) : salt, data: ikm)
        var okm = [UInt8]()
        var t = [UInt8]()
        var counter: UInt8 = 1
        while okm.count < length {
            t = hmacSHA256(key: prk, data: t + info + [counter])
            okm += t
            counter = counter &+ 1
        }
        return Array(okm.prefix(length))
    }

    // MARK: X25519

    static func x25519Public(_ secret: [UInt8]) -> [UInt8] {
        var pub = [UInt8](repeating: 0, count: 32)
        crypto_x25519_public_key(&pub, secret)
        return pub
    }

    static func x25519(_ secret: [UInt8], _ publicKey: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 32)
        crypto_x25519(&out, secret, publicKey)
        return out
    }

    // MARK: Ed25519 (seed = 32 bytes, same as CryptoKit rawRepresentation)

    static func ed25519KeyPair(seed: [UInt8]) -> (secret: [UInt8], publicKey: [UInt8]) {
        var s = seed  // wiped by Monocypher
        var sk = [UInt8](repeating: 0, count: 64)
        var pk = [UInt8](repeating: 0, count: 32)
        crypto_ed25519_key_pair(&sk, &pk, &s)
        return (sk, pk)
    }

    static func ed25519Sign(seed: [UInt8], message: [UInt8]) -> [UInt8] {
        let kp = ed25519KeyPair(seed: seed)
        var sig = [UInt8](repeating: 0, count: 64)
        crypto_ed25519_sign(&sig, kp.secret, message, message.count)
        return sig
    }

    static func ed25519Verify(publicKey: [UInt8], signature: [UInt8], message: [UInt8]) -> Bool {
        guard publicKey.count == 32, signature.count == 64 else { return false }
        return crypto_ed25519_check(signature, publicKey, message, message.count) == 0
    }

    // MARK: ChaCha20-Poly1305 (RFC 8439). Returns ciphertext || tag.

    static func chachaSeal(key: [UInt8], nonce: [UInt8], aad: [UInt8], plaintext: [UInt8]) -> [UInt8] {
        precondition(key.count == 32 && nonce.count == 12)
        var ct = [UInt8](repeating: 0, count: plaintext.count)
        var mac = [UInt8](repeating: 0, count: 16)
        var ctx = crypto_aead_ctx()
        crypto_aead_init_ietf(&ctx, key, nonce)
        crypto_aead_write(&ctx, &ct, &mac, aad, aad.count, plaintext, plaintext.count)
        crypto_wipe(&ctx, MemoryLayout<crypto_aead_ctx>.size)
        return ct + mac
    }

    static func chachaOpen(key: [UInt8], nonce: [UInt8], aad: [UInt8], sealed: [UInt8]) -> [UInt8]? {
        guard key.count == 32, nonce.count == 12, sealed.count >= 16 else { return nil }
        let ct = Array(sealed[0..<(sealed.count - 16)])
        let mac = Array(sealed[(sealed.count - 16)...])
        var pt = [UInt8](repeating: 0, count: ct.count)
        var ctx = crypto_aead_ctx()
        crypto_aead_init_ietf(&ctx, key, nonce)
        let rc = crypto_aead_read(&ctx, &pt, mac, aad, aad.count, ct, ct.count)
        crypto_wipe(&ctx, MemoryLayout<crypto_aead_ctx>.size)
        return rc == 0 ? pt : nil
    }
}

enum BTHex {
    static func encode(_ b: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var s = ""
        s.reserveCapacity(b.count * 2)
        for x in b { s.append(digits[Int(x >> 4)]); s.append(digits[Int(x & 0x0f)]) }
        return s
    }
    static func encode(_ d: Data) -> String { return encode([UInt8](d)) }

    static func decode(_ s: String) -> [UInt8]? {
        let chars = Array(s.lowercased())
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            out.append(UInt8(hi << 4 | lo))
            i += 2
        }
        return out
    }
}
