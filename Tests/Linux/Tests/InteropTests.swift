// SPDX-License-Identifier: GPL-3.0-or-later
// Cross-implementation tests: Mac tester core (Swift 5.0, Monocypher) vs the
// shared watch code (vendored upstream bitchat + CryptoKit API).
import Foundation
import CryptoKit

func runTesterInteropTests() throws {
    // 1. Wire format both ways.
    let sid = [UInt8](repeating: 0x42, count: 8)
    var bt = BTPacket(type: 0x11, ttl: 6, timestamp: 1_700_000_000_123, senderID: sid,
                      recipientID: [UInt8](repeating: 0x07, count: 8), payload: Array("ciphertext".utf8), signature: nil)
    for pad in [false, true] {
        let up = BinaryProtocol.decode(Data(bt.encode(pad: pad)!))
        check(up?.payload == Data("ciphertext".utf8) && up?.recipientID == Data(repeating: 7, count: 8) && up?.ttl == 6, "tester->upstream pad=\(pad)")
    }
    let upPkt = BitchatPacket(type: 0x02, senderID: Data(sid), recipientID: nil, timestamp: 99,
                              payload: Data(repeating: 0x61, count: 300), signature: Data(repeating: 5, count: 64), ttl: 7)
    let upBytes = upPkt.toBinaryData(padding: false)!
    let back = BTPacket.decode([UInt8](upBytes))
    check(back?.payload == [UInt8](repeating: 0x61, count: 300) && back?.signature == [UInt8](repeating: 5, count: 64), "upstream->tester")
    bt.type = 0x02; bt.recipientID = nil; bt.signature = Array(repeating: 1, count: 64)
    let upEquivalent = BitchatPacket(type: 0x02, senderID: Data(sid), recipientID: nil, timestamp: bt.timestamp,
                                     payload: Data(bt.payload), signature: Data(bt.signature!), ttl: 3)
    check(Data(bt.signingBytes()!) == upEquivalent.toBinaryDataForSigning()!, "identical signing bytes")

    // 2. Fragments both ways.
    let big = BTPacket(type: 0x02, ttl: 7, timestamp: 5, senderID: sid, recipientID: nil,
                       payload: BTCrypto.randomBytes(900), signature: nil)
    var r = BitchatFragmentReassembler()
    var whole: BitchatPacket?
    for f in BTFragments.split(big, pad: false, linkLimit: 182)! {
        if case .complete(let p) = r.add(BinaryProtocol.decode(Data(f.encode(pad: false)!))!) { whole = p }
    }
    check(whole?.payload == Data(big.payload), "tester fragments -> shared reassembler")
    let ra = BTReassembler()
    var whole2: BTPacket?
    for f in BitchatFragmenter.fragmentsIfNeeded(upPkt, pad: false, linkLimit: 100)! {
        if let p = ra.add(BTPacket.decode([UInt8](f.toBinaryData(padding: false)!))!) { whole2 = p }
    }
    check(whole2?.payload == [UInt8](upPkt.payload), "shared fragments -> tester reassembler")

    // 3. Noise: tester initiator <-> upstream responder, then reverse roles.
    for testerInitiates in [true, false] {
        let tPriv = BTCrypto.randomBytes(32)
        let uKey = Curve25519.KeyAgreement.PrivateKey()
        let t = BTNoiseSession(initiator: testerInitiates, staticPrivate: tPriv)
        let u = NoiseSession(peerID: PeerID(str: "0011223344556677"), role: testerInitiates ? .responder : .initiator,
                             keychain: MemoryZeroizer.shared, localStaticKey: uKey)
        if testerInitiates {
            let m1 = try t.start()
            let m2 = try u.processHandshakeMessage(Data(m1))!
            let m3 = try t.process([UInt8](m2))!
            check(try u.processHandshakeMessage(Data(m3)) == nil, "handshake done")
        } else {
            let m1 = try u.startHandshake()
            let m2 = try t.process([UInt8](m1))!
            let m3 = try u.processHandshakeMessage(Data(m2))!
            check(try t.process([UInt8](m3)) == nil, "handshake done (rev)")
        }
        check(t.established && u.isEstablished(), "both established (testerInitiates=\(testerInitiates))")
        check(t.remoteStatic == [UInt8](uKey.publicKey.rawRepresentation), "tester learned upstream static")
        for i in 0..<3 {
            let c1 = try u.encrypt(Data("u\(i)".utf8))
            check(try t.decrypt([UInt8](c1)) == Array("u\(i)".utf8), "upstream->tester transport \(i)")
            let c2 = try t.encrypt(Array("t\(i)".utf8))
            check(try u.decrypt(Data(c2)) == Data("t\(i)".utf8), "tester->upstream transport \(i)")
        }
        let replay = try t.encrypt([1])
        _ = try u.decrypt(Data(replay))
        check((try? u.decrypt(Data(replay))) == nil, "upstream rejects replay of tester frame")
    }

    // 4. Watch leaf engine <-> Mac tester node, end to end.
    let watch = BitchatLeafEngine(identity: .generate(), nickname: "watch")
    let mac = BTMeshNode(identity: .generate(), nickname: "mac")
    var macChat: [String] = []
    var watchEvents: [BitchatEngineEvent] = []
    var q: [([UInt8], Bool)] = []   // (frame, toMac)
    watch.sendFrame = { f, _ in q.append(([UInt8](f), true)) }
    mac.sendFrame = { f, _, _ in q.append((f, false)) }
    watch.onEvent = { watchEvents.append($0) }
    mac.onChat = { macChat.append($0) }
    func pump() {
        var n = 0
        while !q.isEmpty && n < 500 {
            let (f, toMac) = q.removeFirst(); n += 1
            if toMac { mac.receiveChunk(f, from: "watch") } else { watch.receive(frame: Data(f), from: "mac") }
        }
    }
    mac.linkUp("watch"); watch.linkUp("mac"); pump()
    check(mac.peers[watch.myPeerID.id]?.nickname == "watch", "mac verified watch announce")
    check(watch.peers[PeerID(str: mac.identity.peerIDHex)]?.nickname == "mac", "watch verified mac announce")
    watch.sendPublic("from wrist"); pump()
    check(macChat.contains("<watch> from wrist"), "mac got signed public msg")
    mac.sendPublic("from mac"); pump()
    check(watchEvents.contains { if case .publicMessage(_, _, _, let t, _) = $0 { return t == "from mac" }; return false }, "watch got mac public msg")
    let id = watch.sendPrivate("dm to mac", to: PeerID(str: mac.identity.peerIDHex)); pump()
    check(macChat.contains { $0.hasPrefix("[DM watch] dm to mac") }, "mac decrypted watch DM")
    check(watchEvents.contains { if case .delivered(let d, _) = $0 { return d == id }; return false }, "watch got delivered ack from mac")
    mac.sendPrivate("dm to watch", toPeerHex: watch.myPeerID.id); pump()
    check(watchEvents.contains { if case .privateMessage(_, _, _, let t, _) = $0 { return t == "dm to watch" }; return false }, "watch decrypted mac DM")

    // 5. Channel chat: shared <-> tester.
    let sk = ChannelKeys(code: "Trail Head 9")!
    let tk = BTChannelKeys(code: "trail head 9")!
    check(sk.channelID == Data(tk.channelID) && sk.key.withUnsafeBytes { Data($0) } == Data(tk.key), "same key derivation")
    let e1 = try ChannelCodec.seal(keys: sk, originID: Data(repeating: 3, count: 8), nickname: "phone", body: "a→b ✓", kind: .text, timestampMs: 77)
    check(BTChannelCodec.open([UInt8](e1), tk)?.body == "a→b ✓", "shared envelope opens on tester")
    let e2 = BTChannelCodec.seal(tk, origin: [UInt8](repeating: 4, count: 8), nick: "mac", body: "hi phone", kind: 1, ttl: 5, timestampMs: 78)
    check(ChannelCodec.open(Data(e2), keys: sk)?.body == "hi phone", "tester envelope opens on shared")
    // Tunnel through bitchat: tester -> watch engine surfaces 0x7E payload.
    var tunnel: Data?
    watch.onEvent = { if case .channelTunnel(let p, _, _) = $0 { tunnel = p } }
    mac.sendChannelTunnel(e2, ttl: 5); pump()
    check(tunnel == Data(e2), "0x7E tunnel tester -> watch engine")
}
