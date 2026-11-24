//
// TesterNoise.swift — bitchat Mac tester (Swift 5.0 compatible)
//
// Noise_XX_25519_ChaChaPoly_SHA256 written from the Noise spec (rev 34), with
// bitchat's transport framing: every transport ciphertext is prefixed with the
// 4-byte big-endian nonce counter, and the receiver uses that explicit nonce
// with a 1024-entry sliding replay window (upstream NoiseCipherState,
// useExtractedNonce = true). Handshake messages use the implicit counter.
// Cross-checked against the vendored upstream implementation in Tests/Linux.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum BTNoiseError: Error { case badMessage, decryptFailed, wrongState, replay, badKey }

final class BTCipherState {
    var key: [UInt8]? = nil
    var n: UInt64 = 0
    let explicitNonce: Bool
    private var highest: UInt64 = 0
    private var window = Set<UInt64>()
    private var anyReceived = false

    init(key: [UInt8]?, explicitNonce: Bool) { self.key = key; self.explicitNonce = explicitNonce }

    private static func nonce(_ n: UInt64) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 12)
        for i in 0..<8 { out[4 + i] = UInt8((n >> UInt64(8 * i)) & 0xff) } // little-endian at [4..12)
        return out
    }

    func encrypt(_ ad: [UInt8], _ pt: [UInt8]) throws -> [UInt8] {
        guard let k = key else { return pt }
        guard n < 0xFFFF_FFFF else { throw BTNoiseError.wrongState }
        let ct = BTCrypto.chachaSeal(key: k, nonce: BTCipherState.nonce(n), aad: ad, plaintext: pt)
        let used = n
        n += 1
        if explicitNonce {
            return [UInt8((used >> 24) & 0xff), UInt8((used >> 16) & 0xff), UInt8((used >> 8) & 0xff), UInt8(used & 0xff)] + ct
        }
        return ct
    }

    func decrypt(_ ad: [UInt8], _ ct: [UInt8]) throws -> [UInt8] {
        guard let k = key else { return ct }
        if explicitNonce {
            guard ct.count >= 4 + 16 else { throw BTNoiseError.badMessage }
            let rn = UInt64(ct[0]) << 24 | UInt64(ct[1]) << 16 | UInt64(ct[2]) << 8 | UInt64(ct[3])
            if anyReceived {
                if rn + 1024 <= highest { throw BTNoiseError.replay }
                if window.contains(rn) { throw BTNoiseError.replay }
            }
            guard let pt = BTCrypto.chachaOpen(key: k, nonce: BTCipherState.nonce(rn), aad: ad, sealed: Array(ct[4...])) else {
                throw BTNoiseError.decryptFailed
            }
            anyReceived = true
            window.insert(rn)
            if rn > highest { highest = rn }
            window = window.filter { $0 + 1024 > highest }
            return pt
        }
        guard let pt = BTCrypto.chachaOpen(key: k, nonce: BTCipherState.nonce(n), aad: ad, sealed: ct) else { throw BTNoiseError.decryptFailed }
        n += 1
        return pt
    }
}

final class BTSymmetricState {
    var ck: [UInt8]
    var h: [UInt8]
    let cipher = BTCipherState(key: nil, explicitNonce: false)

    init(protocolName: String) {
        let name = Array(protocolName.utf8)
        h = name.count <= 32 ? name + [UInt8](repeating: 0, count: 32 - name.count) : BTCrypto.sha256(name)
        ck = h
    }

    func mixHash(_ d: [UInt8]) { h = BTCrypto.sha256(h + d) }

    func hkdf(_ ikm: [UInt8], _ outputs: Int) -> [[UInt8]] {
        let temp = BTCrypto.hmacSHA256(key: ck, data: ikm)
        let o1 = BTCrypto.hmacSHA256(key: temp, data: [1])
        let o2 = BTCrypto.hmacSHA256(key: temp, data: o1 + [2])
        if outputs == 2 { return [o1, o2] }
        return [o1, o2, BTCrypto.hmacSHA256(key: temp, data: o2 + [3])]
    }

    func mixKey(_ ikm: [UInt8]) {
        let o = hkdf(ikm, 2)
        ck = o[0]
        cipher.key = Array(o[1].prefix(32)); cipher.n = 0
    }

    func encryptAndHash(_ pt: [UInt8]) throws -> [UInt8] {
        let ct = try cipher.encrypt(h, pt); mixHash(ct); return ct
    }

    func decryptAndHash(_ ct: [UInt8]) throws -> [UInt8] {
        let pt = try cipher.decrypt(h, ct); mixHash(ct); return pt
    }

    func split() -> (BTCipherState, BTCipherState) {
        let o = hkdf([], 2)
        return (BTCipherState(key: o[0], explicitNonce: true), BTCipherState(key: o[1], explicitNonce: true))
    }
}

/// XX:  -> e  /  <- e, ee, s, es  /  -> s, se
final class BTNoiseHandshake {
    let initiator: Bool
    let ss = BTSymmetricState(protocolName: "Noise_XX_25519_ChaChaPoly_SHA256")
    let sPriv: [UInt8]
    var ePriv: [UInt8]? = nil
    var rs: [UInt8]? = nil
    var re: [UInt8]? = nil
    private(set) var step = 0
    var fixedEphemeral: [UInt8]? = nil   // tests only

    init(initiator: Bool, staticPrivate: [UInt8], prologue: [UInt8] = []) {
        self.initiator = initiator
        self.sPriv = staticPrivate
        ss.mixHash(prologue)
    }

    var isComplete: Bool { return step >= 3 }

    private func dh(_ priv: [UInt8], _ pub: [UInt8]) throws -> [UInt8] {
        let out = BTCrypto.x25519(priv, pub)
        if out.allSatisfy({ $0 == 0 }) { throw BTNoiseError.badKey }
        return out
    }

    func write(payload: [UInt8] = []) throws -> [UInt8] {
        var out = [UInt8]()
        switch (step, initiator) {
        case (0, true):
            let e = fixedEphemeral ?? BTCrypto.randomBytes(32); ePriv = e
            let ePub = BTCrypto.x25519Public(e); out += ePub; ss.mixHash(ePub)
        case (1, false):
            let e = fixedEphemeral ?? BTCrypto.randomBytes(32); ePriv = e
            let ePub = BTCrypto.x25519Public(e); out += ePub; ss.mixHash(ePub)
            guard let rE = re else { throw BTNoiseError.wrongState }
            ss.mixKey(try dh(e, rE))
            out += try ss.encryptAndHash(BTCrypto.x25519Public(sPriv))
            ss.mixKey(try dh(sPriv, rE))
        case (2, true):
            out += try ss.encryptAndHash(BTCrypto.x25519Public(sPriv))
            guard let rE = re else { throw BTNoiseError.wrongState }
            ss.mixKey(try dh(sPriv, rE))
        default:
            throw BTNoiseError.wrongState
        }
        out += try ss.encryptAndHash(payload)
        step += 1
        return out
    }

    func read(_ m: [UInt8]) throws -> [UInt8] {
        var i = 0
        func take(_ n: Int) throws -> [UInt8] {
            guard i + n <= m.count else { throw BTNoiseError.badMessage }
            let r = Array(m[i..<(i + n)]); i += n; return r
        }
        switch (step, initiator) {
        case (0, false):
            let e = try take(32); re = e; ss.mixHash(e)
        case (1, true):
            let e = try take(32); re = e; ss.mixHash(e)
            guard let myE = ePriv else { throw BTNoiseError.wrongState }
            ss.mixKey(try dh(myE, e))
            let s = try ss.decryptAndHash(try take(48)); rs = s
            ss.mixKey(try dh(myE, s))
        case (2, false):
            let s = try ss.decryptAndHash(try take(48)); rs = s
            guard let myE = ePriv else { throw BTNoiseError.wrongState }
            ss.mixKey(try dh(myE, s))
        default:
            throw BTNoiseError.wrongState
        }
        let payload = try ss.decryptAndHash(Array(m[i...]))
        step += 1
        return payload
    }

    /// (send, receive) transport ciphers.
    func transport() -> (BTCipherState, BTCipherState) {
        let (c1, c2) = ss.split()
        return initiator ? (c1, c2) : (c2, c1)
    }
}

final class BTNoiseSession {
    let handshake: BTNoiseHandshake
    var send: BTCipherState? = nil
    var recv: BTCipherState? = nil
    var established: Bool { return send != nil }
    var remoteStatic: [UInt8]? { return handshake.rs }
    let started = Date()

    init(initiator: Bool, staticPrivate: [UInt8]) {
        handshake = BTNoiseHandshake(initiator: initiator, staticPrivate: staticPrivate)
    }

    /// Feeds a handshake message, returns the reply (if any).
    func process(_ m: [UInt8]) throws -> [UInt8]? {
        _ = try handshake.read(m)
        var reply: [UInt8]? = nil
        if !handshake.isComplete { reply = try handshake.write() }
        if handshake.isComplete { let t = handshake.transport(); send = t.0; recv = t.1 }
        return reply
    }

    func start() throws -> [UInt8] { return try handshake.write() }
    func encrypt(_ pt: [UInt8]) throws -> [UInt8] { guard let s = send else { throw BTNoiseError.wrongState }; return try s.encrypt([], pt) }
    func decrypt(_ ct: [UInt8]) throws -> [UInt8] { guard let r = recv else { throw BTNoiseError.wrongState }; return try r.decrypt([], ct) }
}
