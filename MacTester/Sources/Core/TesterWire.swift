//
// TesterWire.swift — bitchat Mac tester (Swift 5.0 compatible)
//
// Independent Swift-5.0 implementation of the bitchat binary packet format
// (v1/v2 header, flags, optional recipient/route/signature, zlib compression,
// PKCS#7-style padding), announce TLVs, private-message TLVs, fragments and a
// BLE notification/write stream assembler. Mirrors upstream bitchat
// BinaryProtocol.swift / Packets.swift / BLEOutboundFragmentPlanner.swift
// (Unlicense) and is cross-checked against them in Tests/Linux.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
#if canImport(Compression)
import Compression
#endif

enum BTType: UInt8 {
    case announce = 0x01, message = 0x02, leave = 0x03, courierEnvelope = 0x04
    case noiseHandshake = 0x10, noiseEncrypted = 0x11
    case fragment = 0x20, requestSync = 0x21, fileTransfer = 0x22, boardPost = 0x23, prekeyBundle = 0x24
    case groupMessage = 0x25, ping = 0x26, pong = 0x27, nostrCarrier = 0x28, voiceFrame = 0x29
    case announceV2 = 0x2C
    case channelTunnel = 0x7E   // bitchat-watch channel chat bridge (see docs/wifi-channel.md)

    static func name(_ raw: UInt8) -> String {
        guard let t = BTType(rawValue: raw) else { return String(format: "unknown(0x%02x)", raw) }
        return "\(t)"
    }
}

struct BTPacket {
    var version: UInt8 = 1
    var type: UInt8
    var ttl: UInt8
    var timestamp: UInt64
    var senderID: [UInt8]          // 8
    var recipientID: [UInt8]?      // 8
    var route: [[UInt8]]? = nil
    var payload: [UInt8]
    var signature: [UInt8]?        // 64
    var isRSR: Bool = false

    static let flagRecipient: UInt8 = 0x01, flagSignature: UInt8 = 0x02, flagCompressed: UInt8 = 0x04
    static let flagRoute: UInt8 = 0x08, flagRSR: UInt8 = 0x10
    static let maxPayload = 1_200_000

    init(type: UInt8, ttl: UInt8, timestamp: UInt64, senderID: [UInt8], recipientID: [UInt8]?, payload: [UInt8], signature: [UInt8]?) {
        self.type = type; self.ttl = ttl; self.timestamp = timestamp; self.senderID = senderID
        self.recipientID = recipientID; self.payload = payload; self.signature = signature
    }

    var isBroadcast: Bool {
        guard let r = recipientID else { return true }
        return r.count == 8 && r.allSatisfy { $0 == 0xFF }
    }

    // MARK: encode

    func encode(pad: Bool, compress: Bool = true) -> [UInt8]? {
        guard version == 1 || version == 2 else { return nil }
        var body = payload
        var compressedOriginal: Int? = nil
        if compress, let c = BTCompression.compressIfUseful(payload) {
            body = c; compressedOriginal = payload.count
        }
        let lenBytes = version == 2 ? 4 : 2
        let hops = version >= 2 ? (route ?? []) : []
        let payloadLen = body.count + (compressedOriginal == nil ? 0 : lenBytes)
        if version == 1 && payloadLen > 0xFFFF { return nil }
        var out = [UInt8]()
        out.append(version); out.append(type); out.append(ttl)
        var s = 56
        while s >= 0 { out.append(UInt8((timestamp >> UInt64(s)) & 0xff)); s -= 8 }
        var flags: UInt8 = 0
        if recipientID != nil { flags |= BTPacket.flagRecipient }
        if signature != nil { flags |= BTPacket.flagSignature }
        if compressedOriginal != nil { flags |= BTPacket.flagCompressed }
        if !hops.isEmpty { flags |= BTPacket.flagRoute }
        if isRSR { flags |= BTPacket.flagRSR }
        out.append(flags)
        BTPacket.appendLength(&out, payloadLen, bytes: lenBytes)
        out += BTPacket.fixed8(senderID)
        if let r = recipientID { out += BTPacket.fixed8(r) }
        if !hops.isEmpty {
            out.append(UInt8(hops.count))
            for h in hops { out += BTPacket.fixed8(h) }
        }
        if let orig = compressedOriginal { BTPacket.appendLength(&out, orig, bytes: lenBytes) }
        out += body
        if let sig = signature { out += Array(sig.prefix(64)) }
        if pad { return BTPadding.pad(out) }
        return out
    }

    /// Canonical bytes for Ed25519: signature removed, TTL = 0, RSR cleared, padded (upstream toBinaryDataForSigning).
    func signingBytes() -> [UInt8]? {
        var p = self
        p.signature = nil; p.ttl = 0; p.isRSR = false
        return p.encode(pad: true)
    }

    // MARK: decode

    static func decode(_ raw: [UInt8]) -> BTPacket? {
        if let p = decodeCore(raw) { return p }
        let unpadded = BTPadding.unpad(raw)
        if unpadded.count == raw.count { return nil }
        return decodeCore(unpadded)
    }

    private static func decodeCore(_ b: [UInt8]) -> BTPacket? {
        guard b.count >= 22 else { return nil }
        let version = b[0]
        guard version == 1 || version == 2 else { return nil }
        let headerSize = version == 2 ? 16 : 14
        guard b.count >= headerSize + 8 else { return nil }
        var i = 0
        func take(_ n: Int) -> [UInt8]? {
            guard i + n <= b.count else { return nil }
            let r = Array(b[i..<(i + n)]); i += n; return r
        }
        i = 1
        let type = b[1], ttl = b[2]
        i = 3
        var ts: UInt64 = 0
        for _ in 0..<8 { ts = (ts << 8) | UInt64(b[i]); i += 1 }
        let flags = b[i]; i += 1
        var plen = 0
        if version == 2 {
            guard let l = take(4) else { return nil }
            plen = Int(l[0]) << 24 | Int(l[1]) << 16 | Int(l[2]) << 8 | Int(l[3])
        } else {
            guard let l = take(2) else { return nil }
            plen = Int(l[0]) << 8 | Int(l[1])
        }
        guard plen <= maxPayload, let sender = take(8) else { return nil }
        var recipient: [UInt8]? = nil
        if flags & flagRecipient != 0 { guard let r = take(8) else { return nil }; recipient = r }
        var route: [[UInt8]]? = nil
        if version >= 2 && flags & flagRoute != 0 {
            guard let c = take(1) else { return nil }
            var hops = [[UInt8]]()
            for _ in 0..<Int(c[0]) { guard let h = take(8) else { return nil }; hops.append(h) }
            if !hops.isEmpty { route = hops }
        }
        var payload: [UInt8]
        if flags & flagCompressed != 0 {
            let lb = version == 2 ? 4 : 2
            guard plen >= lb, let o = take(lb) else { return nil }
            var orig = 0
            for x in o { orig = (orig << 8) | Int(x) }
            guard orig <= maxPayload, let c = take(plen - lb), !c.isEmpty,
                  orig <= c.count * 1032,
                  let d = BTCompression.decompress(c, originalSize: orig), d.count == orig else { return nil }
            payload = d
        } else {
            guard let p = take(plen) else { return nil }
            payload = p
        }
        var sig: [UInt8]? = nil
        if flags & flagSignature != 0 { guard let s = take(64) else { return nil }; sig = s }
        var p = BTPacket(type: type, ttl: ttl, timestamp: ts, senderID: sender, recipientID: recipient, payload: payload, signature: sig)
        p.version = version; p.route = route; p.isRSR = flags & flagRSR != 0
        return p
    }

    private static func appendLength(_ out: inout [UInt8], _ v: Int, bytes: Int) {
        var s = (bytes - 1) * 8
        while s >= 0 { out.append(UInt8((v >> s) & 0xff)); s -= 8 }
    }

    static func fixed8(_ b: [UInt8]) -> [UInt8] {
        if b.count >= 8 { return Array(b.prefix(8)) }
        return b + [UInt8](repeating: 0, count: 8 - b.count)
    }

    /// Upstream dedup ID: senderHex-timestamp-type-sha256(payload)[0..4]hex
    var messageID: String {
        return "\(BTHex.encode(senderID))-\(timestamp)-\(type)-\(BTHex.encode(Array(BTCrypto.sha256(payload).prefix(4))))"
    }
}

enum BTPadding {
    static let blocks = [256, 512, 1024, 2048]
    static func pad(_ d: [UInt8]) -> [UInt8] {
        var target = d.count
        for b in blocks where d.count + 16 <= b { target = b; break }
        let need = target - d.count
        guard need > 0 && need <= 255 else { return d }
        return d + [UInt8](repeating: UInt8(need), count: need)
    }
    static func unpad(_ d: [UInt8]) -> [UInt8] {
        guard let last = d.last else { return d }
        let n = Int(last)
        guard n > 0 && n <= d.count else { return d }
        for x in d[(d.count - n)...] where x != last { return d }
        return Array(d[0..<(d.count - n)])
    }
}

enum BTCompression {
    static func compressIfUseful(_ d: [UInt8]) -> [UInt8]? {
        guard d.count >= 100 else { return nil }
        let unique = Set(d).count
        guard Double(unique) / Double(min(d.count, 256)) < 0.9 else { return nil }
        #if canImport(Compression)
        let cap = d.count + d.count / 255 + 16
        var dst = [UInt8](repeating: 0, count: cap)
        let n = compression_encode_buffer(&dst, cap, d, d.count, nil, COMPRESSION_ZLIB)
        guard n > 0 && n < d.count else { return nil }
        return Array(dst[0..<n])
        #else
        return nil
        #endif
    }
    static func decompress(_ c: [UInt8], originalSize: Int) -> [UInt8]? {
        #if canImport(Compression)
        var dst = [UInt8](repeating: 0, count: max(1, originalSize))
        let n = compression_decode_buffer(&dst, originalSize, c, c.count, nil, COMPRESSION_ZLIB)
        guard n > 0 else { return nil }
        return Array(dst[0..<n])
        #else
        return nil
        #endif
    }
}

// MARK: - TLVs

struct BTAnnounce {
    var nickname: String
    var noisePublicKey: [UInt8]
    var signingPublicKey: [UInt8]
    var neighbors: [[UInt8]] = []

    func encode() -> [UInt8]? {
        let nick = Array(nickname.utf8)
        guard nick.count <= 255 else { return nil }
        var out: [UInt8] = [0x01, UInt8(nick.count)] + nick
        out += [0x02, UInt8(noisePublicKey.count)] + noisePublicKey
        out += [0x03, UInt8(signingPublicKey.count)] + signingPublicKey
        let n = neighbors.prefix(10).filter { $0.count == 8 }
        if !n.isEmpty { out += [0x04, UInt8(n.count * 8)] + n.flatMap { $0 } }
        return out
    }

    static func decode(_ b: [UInt8]) -> BTAnnounce? {
        var i = 0
        var nick: String? = nil, noise: [UInt8]? = nil, sign: [UInt8]? = nil
        var neigh = [[UInt8]]()
        while i + 2 <= b.count {
            let t = b[i], l = Int(b[i + 1]); i += 2
            guard i + l <= b.count else { return nil }
            let v = Array(b[i..<(i + l)]); i += l
            switch t {
            case 0x01: nick = String(bytes: v, encoding: .utf8)
            case 0x02: noise = v
            case 0x03: sign = v
            case 0x04:
                if l % 8 == 0 { var k = 0; while k < l { neigh.append(Array(v[k..<(k + 8)])); k += 8 } }
            default: break
            }
        }
        guard let n = nick, let nk = noise, let sk = sign else { return nil }
        return BTAnnounce(nickname: n, noisePublicKey: nk, signingPublicKey: sk, neighbors: neigh)
    }
}

enum BTPrivateMessage {
    static func encode(messageID: String, content: String) -> [UInt8]? {
        let id = Array(messageID.utf8), c = Array(content.utf8)
        guard id.count <= 255, c.count <= 255 else { return nil }
        return [0x00, UInt8(id.count)] + id + [0x01, UInt8(c.count)] + c
    }
    static func decode(_ b: [UInt8]) -> (id: String, content: String)? {
        var i = 0
        var id: String? = nil, content: String? = nil
        while i + 2 <= b.count {
            let t = b[i], l = Int(b[i + 1]); i += 2
            guard i + l <= b.count else { return nil }
            let v = Array(b[i..<(i + l)]); i += l
            if t == 0x00 { id = String(bytes: v, encoding: .utf8) } else if t == 0x01 { content = String(bytes: v, encoding: .utf8) } else { return nil }
        }
        guard let a = id, let c = content else { return nil }
        return (a, c)
    }
}

// MARK: - Fragments

enum BTFragments {
    static func split(_ packet: BTPacket, pad: Bool, linkLimit: Int) -> [BTPacket]? {
        guard let full = packet.encode(pad: pad), full.count > linkLimit else { return nil }
        let chunk = max(64, min(469, linkLimit - 42))
        let fid = BTCrypto.randomBytes(8)
        var pieces = [[UInt8]]()
        var o = 0
        while o < full.count { pieces.append(Array(full[o..<min(o + chunk, full.count)])); o += chunk }
        guard pieces.count <= 256 else { return nil }
        var out = [BTPacket]()
        for (idx, piece) in pieces.enumerated() {
            let header: [UInt8] = fid + [UInt8(idx >> 8), UInt8(idx & 0xff), UInt8(pieces.count >> 8), UInt8(pieces.count & 0xff), packet.type]
            out.append(BTPacket(type: BTType.fragment.rawValue, ttl: packet.ttl, timestamp: packet.timestamp,
                                senderID: packet.senderID, recipientID: packet.recipientID, payload: header + piece, signature: nil))
        }
        return out
    }
}

final class BTReassembler {
    private struct Entry { var total: Int; var parts: [Int: [UInt8]]; var started: Date }
    private var entries = [String: Entry]()

    func add(_ f: BTPacket, now: Date = Date()) -> BTPacket? {
        entries = entries.filter { now.timeIntervalSince($0.value.started) < 30 }
        let p = f.payload
        guard p.count > 13 else { return nil }
        let key = BTHex.encode(f.senderID) + BTHex.encode(Array(p[0..<8]))
        let index = Int(p[8]) << 8 | Int(p[9]), total = Int(p[10]) << 8 | Int(p[11])
        guard total > 0, total <= 256, index < total else { return nil }
        var e = entries[key] ?? Entry(total: total, parts: [:], started: now)
        guard e.total == total else { return nil }
        e.parts[index] = Array(p[13...])
        if e.parts.count == total {
            entries[key] = nil
            var full = [UInt8]()
            for k in 0..<total { full += e.parts[k]! }
            return BTPacket.decode(full)
        }
        entries[key] = e
        return nil
    }
}

/// Splits a byte stream (BLE writes/notifications) into whole frames using the header length fields.
final class BTStreamAssembler {
    private var buf = [UInt8]()

    func append(_ chunk: [UInt8]) -> [[UInt8]] {
        buf += chunk
        var frames = [[UInt8]]()
        if buf.count > 2_000_000 { buf.removeAll(); return frames }
        while buf.count >= 22 {
            let v = buf[0]
            if v != 1 && v != 2 {
                // skip PKCS#7 padding runs or a stray byte
                let n = Int(v)
                if n > 0 && n <= buf.count && buf[0..<n].allSatisfy({ $0 == v }) { buf.removeFirst(n) } else { buf.removeFirst() }
                continue
            }
            let header = v == 2 ? 16 : 14
            guard buf.count >= header + 8 else { break }
            let flags = buf[11]
            var plen = 0
            if v == 2 { plen = Int(buf[12]) << 24 | Int(buf[13]) << 16 | Int(buf[14]) << 8 | Int(buf[15]) } else { plen = Int(buf[12]) << 8 | Int(buf[13]) }
            var len = header + 8 + plen
            if flags & BTPacket.flagRecipient != 0 { len += 8 }
            if flags & BTPacket.flagSignature != 0 { len += 64 }
            if v >= 2 && flags & BTPacket.flagRoute != 0 {
                let off = header + 8 + (flags & BTPacket.flagRecipient != 0 ? 8 : 0)
                guard buf.count > off else { break }
                len += 1 + Int(buf[off]) * 8
            }
            guard len <= 2_000_000 else { buf.removeAll(); break }
            guard buf.count >= len else { break }
            frames.append(Array(buf[0..<len]))
            buf.removeFirst(len)
        }
        return frames
    }
}
