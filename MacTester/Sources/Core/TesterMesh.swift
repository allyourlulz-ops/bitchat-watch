//
// TesterMesh.swift — bitchat Mac tester (Swift 5.0 compatible)
//
// A full (non-leaf) bitchat test node: it is reachable as a BLE peripheral
// (so the central-only watch can connect to it) and also scans as a central.
// It decodes and logs every frame, verifies announce/public-message
// signatures, keeps a peer table, sends announces and public messages, runs
// Noise XX DMs (BTNoise), and can optionally relay between its links with
// upstream-style TTL/dedup rules. The platform layer (CoreBluetooth) feeds raw
// chunks in and writes the frames this class emits.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

struct BTIdentity {
    let noisePrivate: [UInt8]
    let signingSeed: [UInt8]
    let noisePublic: [UInt8]
    let signingPublic: [UInt8]

    init(noisePrivate: [UInt8], signingSeed: [UInt8]) {
        self.noisePrivate = noisePrivate
        self.signingSeed = signingSeed
        self.noisePublic = BTCrypto.x25519Public(noisePrivate)
        self.signingPublic = BTCrypto.ed25519KeyPair(seed: signingSeed).publicKey
    }

    static func generate() -> BTIdentity {
        return BTIdentity(noisePrivate: BTCrypto.randomBytes(32), signingSeed: BTCrypto.randomBytes(32))
    }

    /// first 8 bytes of SHA-256(noise static public key) == upstream PeerID
    var peerID: [UInt8] { return Array(BTCrypto.sha256(noisePublic).prefix(8)) }
    var peerIDHex: String { return BTHex.encode(peerID) }
    var fingerprint: String { return BTHex.encode(BTCrypto.sha256(noisePublic)) }

    func serialize() -> [String: String] {
        return ["noise": BTHex.encode(noisePrivate), "sign": BTHex.encode(signingSeed)]
    }
    static func deserialize(_ d: [String: String]) -> BTIdentity? {
        guard let n = d["noise"].flatMap({ BTHex.decode($0) }), let s = d["sign"].flatMap({ BTHex.decode($0) }),
              n.count == 32, s.count == 32 else { return nil }
        return BTIdentity(noisePrivate: n, signingSeed: s)
    }
}

struct BTPeer {
    let peerIDHex: String
    var nickname: String
    var noisePublic: [UInt8]
    var signingPublic: [UInt8]
    var lastSeen: Date
    var link: String?
    var direct: Bool
    var hasSession: Bool
}

enum BTDirection: String { case rx = "RX", tx = "TX", relay = "RELAY" }

struct BTLogEntry {
    let time: Date
    let direction: BTDirection
    let link: String
    let raw: [UInt8]
    let summary: String

    func line() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return "\(f.string(from: time)) \(direction.rawValue) [\(link)] \(summary)\n    \(BTHex.encode(raw))"
    }
}

final class BTMeshNode {
    var nickname: String
    let identity: BTIdentity
    var relayEnabled = false
    let ttl: UInt8 = 7

    // outputs
    var sendFrame: (_ frame: [UInt8], _ link: String?, _ except: String?) -> Void = { _, _, _ in }
    var linkLimit: (_ link: String?) -> Int = { _ in return 182 }
    var onLog: (BTLogEntry) -> Void = { _ in }
    var onChat: (_ line: String) -> Void = { _ in }
    var onPeersChanged: () -> Void = {}
    var onChannelTunnel: (_ payload: [UInt8], _ ttl: UInt8, _ link: String) -> Void = { _, _, _ in }

    private(set) var peers = [String: BTPeer]()
    private(set) var links = Set<String>()
    private var assemblers = [String: BTStreamAssembler]()
    private let reassembler = BTReassembler()
    private var seen = Set<String>()
    private var seenOrder = [String]()
    private var sessions = [String: BTNoiseSession]()
    private var pending = [String: [[UInt8]]]()

    init(identity: BTIdentity, nickname: String) {
        self.identity = identity
        self.nickname = nickname
    }

    // MARK: links

    func linkUp(_ link: String) {
        links.insert(link)
        assemblers[link] = BTStreamAssembler()
        sendAnnounce()
    }

    func linkDown(_ link: String) {
        links.remove(link)
        assemblers[link] = nil
        for (k, var p) in peers where p.link == link { p.link = nil; p.direct = false; peers[k] = p }
        onPeersChanged()
    }

    /// Raw bytes from a BLE write (peripheral side) or notification (central side).
    func receiveChunk(_ chunk: [UInt8], from link: String) {
        let asm = assemblers[link] ?? BTStreamAssembler()
        assemblers[link] = asm
        for frame in asm.append(chunk) { receiveFrame(frame, from: link) }
    }

    // MARK: outbound

    func sendAnnounce() {
        let neighbors = peers.values.filter { $0.direct }.compactMap { BTHex.decode($0.peerIDHex) }
        guard let payload = BTAnnounce(nickname: nickname, noisePublicKey: identity.noisePublic,
                                       signingPublicKey: identity.signingPublic, neighbors: neighbors).encode() else { return }
        var p = BTPacket(type: BTType.announce.rawValue, ttl: ttl, timestamp: BTMeshNode.nowMs(), senderID: identity.peerID,
                         recipientID: nil, payload: payload, signature: nil)
        sign(&p)
        emit(p, link: nil, except: nil, direction: .tx)
    }

    func sendPublic(_ text: String) {
        var p = BTPacket(type: BTType.message.rawValue, ttl: ttl, timestamp: BTMeshNode.nowMs(), senderID: identity.peerID,
                         recipientID: nil, payload: Array(text.utf8), signature: nil)
        sign(&p)
        markSeen(p.messageID)
        emit(p, link: nil, except: nil, direction: .tx)
        onChat("<\(nickname)> \(text)")
    }

    func sendPrivate(_ text: String, toPeerHex peer: String) {
        guard let pm = BTPrivateMessage.encode(messageID: UUID().uuidString, content: String(text.prefix(200))) else { return }
        let typed = [UInt8(0x01)] + pm
        if let s = sessions[peer], s.established { encryptAndSend(typed, to: peer, session: s) }
        else {
            pending[peer, default: []].append(typed)
            startHandshake(peer)
        }
        onChat("-> [\(peers[peer]?.nickname ?? peer)] \(text)")
    }

    func sendChannelTunnel(_ envelope: [UInt8], ttl requested: UInt8) {
        let p = BTPacket(type: BTType.channelTunnel.rawValue, ttl: min(requested, ttl), timestamp: BTMeshNode.nowMs(),
                         senderID: identity.peerID, recipientID: nil, payload: envelope, signature: nil)
        markSeen(p.messageID)
        emit(p, link: nil, except: nil, direction: .tx)
    }

    func startHandshake(_ peer: String) {
        if let s = sessions[peer], !s.established, Date().timeIntervalSince(s.started) < 10 { return }
        let s = BTNoiseSession(initiator: true, staticPrivate: identity.noisePrivate)
        sessions[peer] = s
        if let m1 = try? s.start() { emitDirected(BTType.noiseHandshake.rawValue, m1, to: peer) }
    }

    // MARK: inbound

    func receiveFrame(_ frame: [UInt8], from link: String) {
        guard let p = BTPacket.decode(frame) else {
            onLog(BTLogEntry(time: Date(), direction: .rx, link: link, raw: frame, summary: "UNDECODABLE len=\(frame.count)"))
            return
        }
        onLog(BTLogEntry(time: Date(), direction: .rx, link: link, raw: frame, summary: describe(p)))
        handle(p, from: link)
    }

    private func handle(_ p: BTPacket, from link: String) {
        let sender = BTHex.encode(p.senderID)
        if sender == identity.peerIDHex { return }
        if p.type == BTType.fragment.rawValue {
            if let whole = reassembler.add(p) {
                onLog(BTLogEntry(time: Date(), direction: .rx, link: link, raw: [], summary: "REASSEMBLED " + describe(whole)))
                handle(whole, from: link)
            }
            maybeRelay(p, from: link)   // fragments relay as fragments (upstream behaviour)
            return
        }
        let id = p.messageID
        if seen.contains(id) { return }
        markSeen(id)
        let forMe = p.recipientID.map { BTHex.encode($0) == identity.peerIDHex } ?? false
        switch BTType(rawValue: p.type) {
        case .some(.announce): handleAnnounce(p, sender: sender, link: link)
        case .some(.message):
            if let peer = peers[sender], let sb = p.signingBytes(), let sig = p.signature,
               BTCrypto.ed25519Verify(publicKey: peer.signingPublic, signature: sig, message: sb) {
                onChat("<\(peer.nickname)> \(String(decoding: p.payload, as: UTF8.self))")
            } else {
                onChat("<?\(sender.prefix(8))> (unverified) \(String(decoding: p.payload, as: UTF8.self))")
            }
        case .some(.noiseHandshake): if forMe { handleHandshake(p, sender: sender) }
        case .some(.noiseEncrypted): if forMe { handleEncrypted(p, sender: sender) }
        case .some(.channelTunnel): onChannelTunnel(p.payload, p.ttl, link)
        default: break
        }
        if !forMe { maybeRelay(p, from: link) }
    }

    private func handleAnnounce(_ p: BTPacket, sender: String, link: String) {
        guard let a = BTAnnounce.decode(p.payload) else { return }
        guard BTHex.encode(Array(BTCrypto.sha256(a.noisePublicKey).prefix(8))) == sender,
              let sb = p.signingBytes(), let sig = p.signature,
              BTCrypto.ed25519Verify(publicKey: a.signingPublicKey, signature: sig, message: sb) else {
            onChat("! announce from \(sender.prefix(8)) failed verification")
            return
        }
        let direct = p.ttl == ttl
        var peer = peers[sender] ?? BTPeer(peerIDHex: sender, nickname: a.nickname, noisePublic: a.noisePublicKey,
                                           signingPublic: a.signingPublicKey, lastSeen: Date(), link: nil, direct: false,
                                           hasSession: false)
        let isNew = peers[sender] == nil
        peer.nickname = a.nickname
        peer.lastSeen = Date()
        if direct { peer.direct = true; peer.link = link }
        peers[sender] = peer
        if isNew { onChat("* \(a.nickname) (\(sender.prefix(8))) joined\(direct ? " directly" : " via relay")"); sendAnnounce() }
        onPeersChanged()
    }

    private func handleHandshake(_ p: BTPacket, sender: String) {
        if p.payload.count == 32 {
            if let s = sessions[sender], !s.established, s.handshake.initiator, identity.peerIDHex < sender { return }
            sessions[sender] = BTNoiseSession(initiator: false, staticPrivate: identity.noisePrivate)
        }
        guard let s = sessions[sender] else { return }
        do {
            if let reply = try s.process(p.payload) { emitDirected(BTType.noiseHandshake.rawValue, reply, to: sender) }
            if s.established {
                if var peer = peers[sender] { peer.hasSession = true; peers[sender] = peer }
                onChat("* Noise session with \(peers[sender]?.nickname ?? sender) established")
                // authenticated peer state: version 1, caps TLV (0x00), signing key TLV
                let state: [UInt8] = [0x01, 0x01, 0x01, 0x00, 0x02, 32] + identity.signingPublic
                encryptAndSend([0x21] + state, to: sender, session: s)
                for typed in pending[sender] ?? [] { encryptAndSend(typed, to: sender, session: s) }
                pending[sender] = nil
                onPeersChanged()
            }
        } catch {
            sessions[sender] = nil
            onChat("! handshake with \(sender.prefix(8)) failed: \(error)")
        }
    }

    private func handleEncrypted(_ p: BTPacket, sender: String) {
        guard let s = sessions[sender], s.established else { startHandshake(sender); return }
        guard let pt = try? s.decrypt(p.payload), let type = pt.first else { onChat("! decrypt failed from \(sender.prefix(8))"); return }
        let body = Array(pt.dropFirst())
        let nick = peers[sender]?.nickname ?? sender
        switch type {
        case 0x01:
            if let m = BTPrivateMessage.decode(body) {
                onChat("[DM \(nick)] \(m.content)")
                encryptAndSend([0x03] + Array(m.id.utf8), to: sender, session: s)   // delivered
            }
        case 0x02: onChat("* read receipt from \(nick)")
        case 0x03: onChat("* delivered to \(nick)")
        case 0x21: onChat("* authenticated peer state from \(nick)")
        default: onChat("* noise payload type 0x\(String(type, radix: 16)) from \(nick) (ignored)")
        }
    }

    private func maybeRelay(_ p: BTPacket, from link: String) {
        guard relayEnabled, p.ttl > 1, links.count > 1 else { return }
        var r = p
        r.ttl = min(p.ttl, ttl) - 1
        let delay = Double(Int.random(in: 10...60)) / 1000
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.emit(r, link: nil, except: link, direction: .relay)
        }
    }

    // MARK: helpers

    private func encryptAndSend(_ typed: [UInt8], to peer: String, session: BTNoiseSession) {
        guard let ct = try? session.encrypt(typed) else { return }
        emitDirected(BTType.noiseEncrypted.rawValue, ct, to: peer)
    }

    private func emitDirected(_ type: UInt8, _ payload: [UInt8], to peer: String) {
        let p = BTPacket(type: type, ttl: ttl, timestamp: BTMeshNode.nowMs(), senderID: identity.peerID,
                         recipientID: BTHex.decode(peer), payload: payload, signature: nil)
        emit(p, link: peers[peer]?.direct == true ? peers[peer]?.link : nil, except: nil, direction: .tx)
    }

    private func emit(_ p: BTPacket, link: String?, except: String?, direction: BTDirection) {
        let pad = p.type == BTType.noiseEncrypted.rawValue || p.type == BTType.noiseHandshake.rawValue
        if let frags = BTFragments.split(p, pad: pad, linkLimit: linkLimit(link)) {
            for f in frags {
                guard let d = f.encode(pad: false) else { continue }
                onLog(BTLogEntry(time: Date(), direction: direction, link: link ?? "all", raw: d, summary: describe(f)))
                sendFrame(d, link, except)
            }
        } else if let d = p.encode(pad: pad) {
            onLog(BTLogEntry(time: Date(), direction: direction, link: link ?? "all", raw: d, summary: describe(p)))
            sendFrame(d, link, except)
        }
    }

    private func sign(_ p: inout BTPacket) {
        guard let sb = p.signingBytes() else { return }
        p.signature = BTCrypto.ed25519Sign(seed: identity.signingSeed, message: sb)
    }

    private func markSeen(_ id: String) {
        if seen.insert(id).inserted { seenOrder.append(id) }
        if seenOrder.count > 4096 { seen.remove(seenOrder.removeFirst()) }
    }

    func describe(_ p: BTPacket) -> String {
        var s = "\(BTType.name(p.type)) v\(p.version) ttl=\(p.ttl) from=\(BTHex.encode(p.senderID).prefix(16))"
        if let r = p.recipientID { s += " to=\(BTHex.encode(r))" }
        s += " len=\(p.payload.count)\(p.signature != nil ? " signed" : "")"
        switch BTType(rawValue: p.type) {
        case .some(.announce): if let a = BTAnnounce.decode(p.payload) { s += " nick=\"\(a.nickname)\"" }
        case .some(.message): s += " text=\"\(String(decoding: p.payload.prefix(60), as: UTF8.self))\""
        case .some(.fragment):
            if p.payload.count >= 13 {
                s += " frag \(Int(p.payload[8]) << 8 | Int(p.payload[9]))/\(Int(p.payload[10]) << 8 | Int(p.payload[11])) of \(BTType.name(p.payload[12]))"
            }
        default: break
        }
        return s
    }

    static func nowMs() -> UInt64 { return UInt64(Date().timeIntervalSince1970 * 1000) }
}
