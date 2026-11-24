// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

func runCryptoVectorTests() throws {
    // FIPS 180-2 SHA-256 "abc"
    check(Data(SHA256.hash(data: Data("abc".utf8))).hexEncodedString()
          == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256 abc")
    // RFC 4231 test case 2 HMAC-SHA256
    let mac = HMAC<SHA256>.authenticationCode(for: Data("what do ya want for nothing?".utf8), using: SymmetricKey(data: Data("Jefe".utf8)))
    check(Data(mac).hexEncodedString() == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "hmac rfc4231 #2")
    // RFC 5869 test case 1
    let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: hex("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")),
                                     salt: hex("000102030405060708090a0b0c"), info: hex("f0f1f2f3f4f5f6f7f8f9"), outputByteCount: 42)
    check(okm.withUnsafeBytes { Data($0) }.hexEncodedString()
          == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", "hkdf rfc5869 #1")
    // RFC 8439 2.8.2 AEAD vector
    let key = SymmetricKey(data: hex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f"))
    let nonce = try ChaChaPoly.Nonce(data: hex("070000004041424344454647"))
    let aad = hex("50515253c0c1c2c3c4c5c6c7")
    let pt = Data("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
    let box = try ChaChaPoly.seal(pt, using: key, nonce: nonce, authenticating: aad)
    check(box.tag.hexEncodedString() == "1ae10b594f09e26a7e902ecbd0600691", "chachapoly rfc8439 tag")
    check(box.ciphertext.prefix(16).hexEncodedString() == "d31a8d34648e60db7b86afbc53ef7ec2", "chachapoly rfc8439 ct prefix")
    check((try? ChaChaPoly.open(box, using: key, authenticating: aad)) == pt, "chachapoly open")
    // RFC 7748 6.1 X25519
    let a = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))
    check(a.publicKey.rawRepresentation.hexEncodedString() == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a", "x25519 pub")
    let bPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"))
    let shared = try a.sharedSecretFromKeyAgreement(with: bPub).withUnsafeBytes { Data($0) }.hexEncodedString()
    check(shared == "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742", "x25519 shared")
    // RFC 8032 7.1 test 1 Ed25519
    let ed = try Curve25519.Signing.PrivateKey(rawRepresentation: hex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
    check(ed.publicKey.rawRepresentation.hexEncodedString() == "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "ed25519 pub")
    let sig = try ed.signature(for: Data())
    check(sig.hexEncodedString() == "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b", "ed25519 sig")
    check(ed.publicKey.isValidSignature(sig, for: Data()), "ed25519 verify")
    check(!ed.publicKey.isValidSignature(sig, for: Data([1])), "ed25519 reject")
}

func runNoiseVectorTests() throws {
    let url = URL(fileURLWithPath: repoRoot).appendingPathComponent("upstream/bitchatTests/Noise/NoiseTestVectors.json")
    guard let raw = try? Data(contentsOf: url),
          let vectors = try JSONSerialization.jsonObject(with: raw) as? [[String: Any]] else {
        print("  (skipped: upstream/ not present; vectors come from the upstream clone)")
        return
    }
    var ran = 0
    for v in vectors {
        guard (v["protocol_name"] as? String) == "Noise_XX_25519_ChaChaPoly_SHA256" else { continue }
        let s = { (k: String) in hex(v[k] as! String) }
        let initiator = NoiseHandshakeState(role: .initiator, pattern: .XX, keychain: MemoryZeroizer.shared,
            localStaticKey: try .init(rawRepresentation: s("init_static")), prologue: s("init_prologue"),
            predeterminedEphemeralKey: try .init(rawRepresentation: s("init_ephemeral")))
        let responder = NoiseHandshakeState(role: .responder, pattern: .XX, keychain: MemoryZeroizer.shared,
            localStaticKey: try .init(rawRepresentation: s("resp_static")), prologue: s("resp_prologue"),
            predeterminedEphemeralKey: try .init(rawRepresentation: s("resp_ephemeral")))
        let msgs = v["messages"] as! [[String: String]]
        // XX: -> e ; <- e, ee, s, es ; -> s, se
        let order: [(NoiseHandshakeState, NoiseHandshakeState)] = [(initiator, responder), (responder, initiator), (initiator, responder)]
        for (i, pair) in order.enumerated() {
            let ct = try pair.0.writeMessage(payload: hex(msgs[i]["payload"]!))
            check(ct.hexEncodedString() == msgs[i]["ciphertext"]!, "noise vector hs msg \(i)")
            let p = try pair.1.readMessage(ct)
            check(p == hex(msgs[i]["payload"]!), "noise vector hs payload \(i)")
        }
        if let hh = v["handshake_hash"] as? String { check(initiator.getHandshakeHash().hexEncodedString() == hh, "noise handshake hash") }
        // Standard (counter-nonce) transport vectors.
        let ic = try initiator.getTransportCiphers(useExtractedNonce: false)
        let rc = try responder.getTransportCiphers(useExtractedNonce: false)
        for i in 3..<msgs.count {
            let fromInit = (i % 2 == 0)
            let ct = try (fromInit ? ic.send : rc.send).encrypt(plaintext: hex(msgs[i]["payload"]!))
            check(ct.hexEncodedString() == msgs[i]["ciphertext"]!, "noise vector transport msg \(i)")
        }
        ran += 1
    }
    check(ran > 0, "ran at least one XX vector")
}
