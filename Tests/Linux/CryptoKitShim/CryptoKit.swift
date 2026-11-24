//
// CryptoKit.swift — LINUX TEST HARNESS ONLY.
//
// A tiny API-compatible subset of Apple's CryptoKit, backed by Monocypher
// (X25519, Ed25519, ChaCha20-Poly1305 IETF) and a pure-Swift SHA-256, so the
// vendored bitchat Noise/protocol files and our shared code can be compiled
// and exercised on Linux. It is never shipped in any Apple target: watchOS and
// iOS link the real CryptoKit. Only the API surface used by this repo exists.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CMonocypher

public enum CryptoKitError: Error {
    case incorrectKeySize
    case incorrectParameterSize
    case authenticationFailure
    case underlyingCoreCryptoError(error: Int32)
}

// MARK: - Hashing

public protocol HashFunction {
    static var byteCount: Int { get }
    static func digest(_ bytes: [UInt8]) -> [UInt8]
}

public struct SHA256: HashFunction {
    public static var byteCount: Int { return 32 }
    public static func digest(_ bytes: [UInt8]) -> [UInt8] { return PureSHA256.hash(bytes) }

    public struct Digest: Sequence, ContiguousBytes {
        let bytes: [UInt8]
        public func makeIterator() -> IndexingIterator<[UInt8]> { return bytes.makeIterator() }
        public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
            return try bytes.withUnsafeBytes(body)
        }
    }

    public static func hash<D: DataProtocol>(data: D) -> Digest {
        return Digest(bytes: PureSHA256.hash(Array(data)))
    }
}

// MARK: - Symmetric keys / HMAC / HKDF

public struct SymmetricKeySize {
    public let bitCount: Int
    public static let bits128 = SymmetricKeySize(bitCount: 128)
    public static let bits256 = SymmetricKeySize(bitCount: 256)
}

public struct SymmetricKey: ContiguousBytes {
    let bytes: [UInt8]
    public init<D: ContiguousBytes>(data: D) {
        bytes = data.withUnsafeBytes { Array($0) }
    }
    public init(size: SymmetricKeySize) {
        var g = SystemRandomNumberGenerator()
        bytes = (0..<(size.bitCount / 8)).map { _ in UInt8.random(in: 0...255, using: &g) }
    }
    public var bitCount: Int { return bytes.count * 8 }
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try bytes.withUnsafeBytes(body)
    }
}

public struct HashedAuthenticationCode<H: HashFunction>: Sequence, ContiguousBytes {
    let bytes: [UInt8]
    public func makeIterator() -> IndexingIterator<[UInt8]> { return bytes.makeIterator() }
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try bytes.withUnsafeBytes(body)
    }
}

public struct HMAC<H: HashFunction> {
    public static func authenticationCode<D: DataProtocol>(for data: D, using key: SymmetricKey) -> HashedAuthenticationCode<H> {
        precondition(H.self == SHA256.self, "shim implements HMAC-SHA256 only")
        return HashedAuthenticationCode(bytes: PureSHA256.hmac(key: key.bytes, message: Array(data)))
    }
    public static func isValidAuthenticationCode<D: DataProtocol>(_ mac: HashedAuthenticationCode<H>, authenticating data: D, using key: SymmetricKey) -> Bool {
        return authenticationCode(for: data, using: key).bytes == mac.bytes
    }
}

public struct HKDF<H: HashFunction> {
    public static func deriveKey<Salt: DataProtocol, Info: DataProtocol>(
        inputKeyMaterial: SymmetricKey, salt: Salt, info: Info, outputByteCount: Int) -> SymmetricKey {
        precondition(H.self == SHA256.self, "shim implements HKDF-SHA256 only")
        let out = PureSHA256.hkdf(ikm: inputKeyMaterial.bytes, salt: Array(salt), info: Array(info), length: outputByteCount)
        return SymmetricKey(data: out)
    }
}

// MARK: - ChaChaPoly (RFC 8439 IETF variant)

public enum ChaChaPoly {
    public struct Nonce: ContiguousBytes, Sequence {
        let bytes: [UInt8]
        public init() {
            bytes = (0..<12).map { _ in UInt8.random(in: 0...255) }
        }
        public init<D: DataProtocol>(data: D) throws {
            guard data.count == 12 else { throw CryptoKitError.incorrectParameterSize }
            bytes = Array(data)
        }
        public func makeIterator() -> IndexingIterator<[UInt8]> { return bytes.makeIterator() }
        public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
            return try bytes.withUnsafeBytes(body)
        }
    }

    public struct SealedBox {
        public let nonce: Nonce
        public let ciphertext: Data
        public let tag: Data
        public var combined: Data { return Data(nonce.bytes) + ciphertext + tag }

        public init<C: DataProtocol, T: DataProtocol>(nonce: Nonce, ciphertext: C, tag: T) throws {
            guard tag.count == 16 else { throw CryptoKitError.incorrectParameterSize }
            self.nonce = nonce
            self.ciphertext = Data(ciphertext)
            self.tag = Data(tag)
        }
        public init<D: DataProtocol>(combined: D) throws {
            let all = Array(combined)
            guard all.count >= 28 else { throw CryptoKitError.incorrectParameterSize }
            nonce = try Nonce(data: all[0..<12])
            ciphertext = Data(all[12..<(all.count - 16)])
            tag = Data(all[(all.count - 16)...])
        }
    }

    public static func seal<P: DataProtocol, A: DataProtocol>(_ plaintext: P, using key: SymmetricKey, nonce: Nonce = Nonce(), authenticating ad: A) throws -> SealedBox {
        guard key.bytes.count == 32 else { throw CryptoKitError.incorrectKeySize }
        let pt = Array(plaintext), aad = Array(ad)
        var ct = [UInt8](repeating: 0, count: pt.count)
        var mac = [UInt8](repeating: 0, count: 16)
        var ctx = crypto_aead_ctx()
        crypto_aead_init_ietf(&ctx, key.bytes, nonce.bytes)
        crypto_aead_write(&ctx, &ct, &mac, aad, aad.count, pt, pt.count)
        crypto_wipe(&ctx, MemoryLayout<crypto_aead_ctx>.size)
        return try SealedBox(nonce: nonce, ciphertext: ct, tag: mac)
    }

    public static func seal<P: DataProtocol>(_ plaintext: P, using key: SymmetricKey, nonce: Nonce = Nonce()) throws -> SealedBox {
        return try seal(plaintext, using: key, nonce: nonce, authenticating: Data())
    }

    public static func open<A: DataProtocol>(_ box: SealedBox, using key: SymmetricKey, authenticating ad: A) throws -> Data {
        guard key.bytes.count == 32 else { throw CryptoKitError.incorrectKeySize }
        let ct = Array(box.ciphertext), aad = Array(ad), mac = Array(box.tag)
        var pt = [UInt8](repeating: 0, count: ct.count)
        var ctx = crypto_aead_ctx()
        crypto_aead_init_ietf(&ctx, key.bytes, box.nonce.bytes)
        let rc = crypto_aead_read(&ctx, &pt, mac, aad, aad.count, ct, ct.count)
        crypto_wipe(&ctx, MemoryLayout<crypto_aead_ctx>.size)
        guard rc == 0 else { throw CryptoKitError.authenticationFailure }
        return Data(pt)
    }

    public static func open(_ box: SealedBox, using key: SymmetricKey) throws -> Data {
        return try open(box, using: key, authenticating: Data())
    }
}

// MARK: - Curve25519

public struct SharedSecret: ContiguousBytes {
    let bytes: [UInt8]
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        return try bytes.withUnsafeBytes(body)
    }
    public func hkdfDerivedSymmetricKey<H: HashFunction, Salt: DataProtocol, Info: DataProtocol>(
        using: H.Type, salt: Salt, sharedInfo: Info, outputByteCount: Int) -> SymmetricKey {
        return HKDF<H>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes), salt: salt, info: sharedInfo, outputByteCount: outputByteCount)
    }
}

private func randomBytes(_ n: Int) -> [UInt8] {
    var g = SystemRandomNumberGenerator()
    return (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
}

public enum Curve25519 {
    public enum KeyAgreement {
        public struct PublicKey {
            let bytes: [UInt8]
            public init<D: ContiguousBytes>(rawRepresentation: D) throws {
                let b = rawRepresentation.withUnsafeBytes { Array($0) }
                guard b.count == 32 else { throw CryptoKitError.incorrectKeySize }
                bytes = b
            }
            public var rawRepresentation: Data { return Data(bytes) }
        }
        public struct PrivateKey {
            let bytes: [UInt8]
            public init() { bytes = randomBytes(32) }
            public init<D: ContiguousBytes>(rawRepresentation: D) throws {
                let b = rawRepresentation.withUnsafeBytes { Array($0) }
                guard b.count == 32 else { throw CryptoKitError.incorrectKeySize }
                bytes = b
            }
            public var rawRepresentation: Data { return Data(bytes) }
            public var publicKey: PublicKey {
                var pub = [UInt8](repeating: 0, count: 32)
                crypto_x25519_public_key(&pub, bytes)
                return try! PublicKey(rawRepresentation: pub)
            }
            public func sharedSecretFromKeyAgreement(with other: PublicKey) throws -> SharedSecret {
                var out = [UInt8](repeating: 0, count: 32)
                crypto_x25519(&out, bytes, other.bytes)
                return SharedSecret(bytes: out)
            }
        }
    }

    public enum Signing {
        public struct PublicKey {
            let bytes: [UInt8]
            public init<D: ContiguousBytes>(rawRepresentation: D) throws {
                let b = rawRepresentation.withUnsafeBytes { Array($0) }
                guard b.count == 32 else { throw CryptoKitError.incorrectKeySize }
                bytes = b
            }
            public var rawRepresentation: Data { return Data(bytes) }
            public func isValidSignature<S: DataProtocol, D: DataProtocol>(_ signature: S, for data: D) -> Bool {
                let sig = Array(signature), msg = Array(data)
                guard sig.count == 64 else { return false }
                return crypto_ed25519_check(sig, bytes, msg, msg.count) == 0
            }
        }
        public struct PrivateKey {
            let seed: [UInt8]
            public init() { seed = randomBytes(32) }
            public init<D: ContiguousBytes>(rawRepresentation: D) throws {
                let b = rawRepresentation.withUnsafeBytes { Array($0) }
                guard b.count == 32 else { throw CryptoKitError.incorrectKeySize }
                seed = b
            }
            public var rawRepresentation: Data { return Data(seed) }
            private func expanded() -> (sk: [UInt8], pk: [UInt8]) {
                var s = seed  // crypto_ed25519_key_pair wipes its seed argument
                var sk = [UInt8](repeating: 0, count: 64)
                var pk = [UInt8](repeating: 0, count: 32)
                crypto_ed25519_key_pair(&sk, &pk, &s)
                return (sk, pk)
            }
            public var publicKey: PublicKey { return try! PublicKey(rawRepresentation: expanded().pk) }
            public func signature<D: DataProtocol>(for data: D) throws -> Data {
                let msg = Array(data)
                var sig = [UInt8](repeating: 0, count: 64)
                crypto_ed25519_sign(&sig, expanded().sk, msg, msg.count)
                return Data(sig)
            }
        }
    }
}
