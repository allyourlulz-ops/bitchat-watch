//
// TesterChannel.swift — bitchat Mac tester (Swift 5.0 compatible)
//
// Port of Shared/ChannelCore (channel chat v1) without CryptoKit: HKDF via
// CommonCrypto HMAC, ChaCha20-Poly1305 via Monocypher. Same envelope, same
// TTL/dedup/bridge rules, so the tester can sit on MultipeerConnectivity, the
// LAN (Bonjour/TCP) and the bitchat BLE tunnel and forward between them.
// Cross-checked against the shared implementation in Tests/Linux.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

struct BTChannelKeys {
    let code: String
    let key: [UInt8]
    let channelID: [UInt8]
    var channelIDHex: String { return BTHex.encode(channelID) }

    init?(code raw: String) {
        let code = raw.precomposedStringWithCompatibilityMapping
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        guard code.count >= 4 else { return nil }
        let ikm = Array(code.utf8), salt = Array("hkchan/v1/salt".utf8)
        self.code = code
        self.key = BTCrypto.hkdfSHA256(ikm: ikm, salt: salt, info: Array("hkchan/v1/key".utf8), length: 32)
        self.channelID = BTCrypto.hkdfSHA256(ikm: ikm, salt: salt, info: Array("hkchan/v1/id".utf8), length: 8)
    }
}

struct BTChannelMessage {
    let channelID: [UInt8]
    let msgID: [UInt8]
    let originID: [UInt8]
    let timestampMs: UInt64
    let kind: UInt8
    let nickname: String
    let body: String
    let ttl: UInt8
}

enum BTChannelCodec {
    static let magic: [UInt8] = [0x48, 0x4B, 0x43, 0x31]

    static func aad(_ e: [UInt8]) -> [UInt8] { return Array(e[0..<5]) + Array(e[6..<30]) }

    static func seal(_ k: BTChannelKeys, origin: [UInt8], nick: String, body: String, kind: UInt8, ttl: UInt8,
                     timestampMs: UInt64, msgID: [UInt8]? = nil, nonce: [UInt8]? = nil) -> [UInt8] {
        let mid = msgID ?? BTCrypto.randomBytes(16)
        let n = nonce ?? BTCrypto.randomBytes(12)
        var header = magic + [1, min(ttl, 7)] + k.channelID + mid + n
        var plain = origin
        var s = 56
        while s >= 0 { plain.append(UInt8((timestampMs >> UInt64(s)) & 0xff)); s -= 8 }
        let nb = Array(Array(nick.utf8).prefix(32))
        var text = [UInt8]()
        for ch in body { let c = Array(String(ch).utf8); if text.count + c.count > 280 { break }; text += c }
        plain += [kind, UInt8(nb.count)] + nb + text
        header += BTCrypto.chachaSeal(key: k.key, nonce: n, aad: aad(header), plaintext: plain)
        return header
    }

    static func header(_ e: [UInt8]) -> (ttl: UInt8, channelID: [UInt8], msgID: [UInt8], nonce: [UInt8])? {
        guard e.count >= 58, e.count <= 4096, Array(e[0..<4]) == magic, e[4] == 1 else { return nil }
        return (min(e[5], 7), Array(e[6..<14]), Array(e[14..<30]), Array(e[30..<42]))
    }

    static func open(_ e: [UInt8], _ k: BTChannelKeys) -> BTChannelMessage? {
        guard let h = header(e), h.channelID == k.channelID,
              let p = BTCrypto.chachaOpen(key: k.key, nonce: h.nonce, aad: aad(e), sealed: Array(e[42...])),
              p.count >= 18 else { return nil }
        var ts: UInt64 = 0
        for i in 8..<16 { ts = (ts << 8) | UInt64(p[i]) }
        let nl = Int(p[17])
        guard p.count >= 18 + nl else { return nil }
        return BTChannelMessage(channelID: h.channelID, msgID: h.msgID, originID: Array(p[0..<8]), timestampMs: ts,
                                kind: p[16], nickname: String(decoding: p[18..<(18 + nl)], as: UTF8.self),
                                body: String(decoding: p[(18 + nl)...], as: UTF8.self), ttl: h.ttl)
    }
}

/// Paths: "lan", "mpc", "bitchat". Same rules as Shared/ChannelCore/ChannelRouter.swift.
final class BTChannelRouter {
    struct Membership { let keys: BTChannelKeys; var bridge: Bool }

    let origin: [UInt8]
    var nickname: String
    private(set) var memberships = [String: Membership]()   // channelIDHex -> membership
    private var seen = Set<String>()
    private var seenOrder = [String]()
    private var tokens: Double = 3
    private var lastRefill = Date()
    var bridgePerMinute: Double = 6

    var transmit: (_ envelope: [UInt8], _ path: String, _ exceptLink: String?) -> Void = { _, _, _ in }
    var onMessage: (_ msg: BTChannelMessage, _ via: String) -> Void = { _, _ in }
    var onNote: (String) -> Void = { _ in }

    init(origin: [UInt8], nickname: String) { self.origin = origin; self.nickname = nickname }

    @discardableResult
    func join(_ code: String, bridge: Bool) -> BTChannelKeys? {
        guard let k = BTChannelKeys(code: code) else { return nil }
        memberships[k.channelIDHex] = Membership(keys: k, bridge: bridge)
        return k
    }

    func leave(_ idHex: String) { memberships[idHex] = nil }
    func setBridge(_ idHex: String, _ on: Bool) { memberships[idHex]?.bridge = on }
    var advertisedIDs: [String] { return memberships.keys.sorted() }

    func send(_ text: String, channelHex: String, ttl: UInt8 = 5) {
        guard let m = memberships[channelHex] else { return }
        let e = BTChannelCodec.seal(m.keys, origin: origin, nick: nickname, body: text, kind: 1, ttl: ttl,
                                    timestampMs: BTMeshNode.nowMs())
        markSeen(BTHex.encode(Array(e[14..<30])))
        transmit(e, "lan", nil)
        transmit(e, "mpc", nil)
        if m.bridge { bridgeOut(e) }
    }

    func ingest(_ e: [UInt8], path: String, link: String) {
        guard let h = BTChannelCodec.header(e), let m = memberships[BTHex.encode(h.channelID)] else { return }
        let mid = BTHex.encode(h.msgID)
        if seen.contains(mid) { return }
        guard let msg = BTChannelCodec.open(e, m.keys) else { onNote("channel auth failed on \(path)"); return }
        markSeen(mid)
        if msg.originID == origin { return }
        onMessage(msg, path)
        guard msg.kind != 2, h.ttl > 1 else { return }
        var fwd = e
        fwd[5] = h.ttl - 1
        transmit(fwd, "lan", path == "lan" ? link : nil)
        transmit(fwd, "mpc", path == "mpc" ? link : nil)
        if m.bridge && path != "bitchat" { bridgeOut(fwd) }
    }

    private func bridgeOut(_ e: [UInt8]) {
        guard e.count <= 400 else { onNote("envelope too large to bridge"); return }
        let now = Date()
        tokens = min(3, tokens + now.timeIntervalSince(lastRefill) * bridgePerMinute / 60)
        lastRefill = now
        guard tokens >= 1 else { onNote("bitchat bridge rate limited"); return }
        tokens -= 1
        transmit(e, "bitchat", nil)
    }

    private func markSeen(_ id: String) {
        if seen.insert(id).inserted { seenOrder.append(id) }
        if seenOrder.count > 4096 { seen.remove(seenOrder.removeFirst()) }
    }
}
