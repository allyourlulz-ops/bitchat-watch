//
// ChannelProtocol.swift — bitchat-watch "channel chat" (our own protocol, v1)
//
// Local channel chat keyed by a short shared channel code. Carried over LAN
// (Bonjour/TCP), MultipeerConnectivity and — opt-in per channel — tunnelled
// through the bitchat BLE mesh. See docs/wifi-channel.md for the full spec and
// the security caveats (a short code is a WEAK secret: anyone who can guess or
// brute-force it can read and post; not for sensitive use).
//
// Envelope (all integers big-endian):
//   0   4  magic "HKC1"
//   4   1  version = 1
//   5   1  ttl (hops remaining, default 5, clamped to 7) — NOT authenticated
//   6   8  channelID = HKDF(code, info "hkchan/v1/id")[0..8]
//   14 16  msgID (random)
//   30 12  nonce (random)
//   42  n  ChaCha20-Poly1305(key, nonce, aad = bytes[0..5) ‖ bytes[6..30)) ciphertext ‖ 16-byte tag
// Inner plaintext:
//   originID(8) ‖ timestampMs(8) ‖ kind(1) ‖ nickLen(1) ‖ nick ‖ body
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CryptoKit

enum ChannelTunnelWire {
    /// bitchat MessageType value used to tunnel channel envelopes through the BLE
    /// mesh. Unassigned upstream as of bitchat iOS 04995f68 / Android cc1fb178;
    /// both stock clients relay unknown broadcast types (see docs/wifi-channel.md).
    static let bitchatPacketType: UInt8 = 0x7E
    /// Keep tunnelled envelopes inside one BLE write on typical phone links so
    /// stock relays don't have to fragment an unknown type.
    static let maxTunnelledEnvelopeBytes = 400
}

enum ChannelMessageKind: UInt8, Codable {
    case text = 1
    case hello = 2   // presence: nickname only, not bridged, ttl 1
    case leave = 3
}

struct ChannelKeys: Equatable {
    let code: String           // normalized
    let key: SymmetricKey
    let channelID: Data        // 8 bytes
    var channelIDHex: String { channelID.hexEncodedString() }

    static let minimumCodeLength = 4

    /// Normalization: NFKC, trim, lowercase, collapse internal whitespace.
    static func normalize(_ raw: String) -> String {
        let nfkc = raw.precomposedStringWithCompatibilityMapping
        return nfkc.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    init?(code raw: String) {
        let code = ChannelKeys.normalize(raw)
        guard code.count >= ChannelKeys.minimumCodeLength else { return nil }
        let ikm = SymmetricKey(data: Data(code.utf8))
        let salt = Data("hkchan/v1/salt".utf8)
        self.code = code
        self.key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("hkchan/v1/key".utf8), outputByteCount: 32)
        self.channelID = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("hkchan/v1/id".utf8), outputByteCount: 8)
            .withUnsafeBytes { Data($0) }
    }

    static func == (a: ChannelKeys, b: ChannelKeys) -> Bool { a.code == b.code }
}

struct ChannelEnvelopeHeader: Equatable {
    static let magic: [UInt8] = [0x48, 0x4B, 0x43, 0x31] // "HKC1"
    static let version: UInt8 = 1
    static let length = 42
    static let defaultTTL: UInt8 = 5
    static let maxTTL: UInt8 = 7
    static let maxEnvelopeBytes = 4096

    var ttl: UInt8
    let channelID: Data
    let msgID: Data
    let nonce: Data

    var msgIDHex: String { msgID.hexEncodedString() }

    static func parse(_ d: Data) -> ChannelEnvelopeHeader? {
        guard d.count >= length + 16, d.count <= maxEnvelopeBytes else { return nil }
        let b = [UInt8](d)
        guard Array(b[0..<4]) == magic, b[4] == version else { return nil }
        return ChannelEnvelopeHeader(ttl: min(b[5], maxTTL), channelID: Data(b[6..<14]),
                                     msgID: Data(b[14..<30]), nonce: Data(b[30..<42]))
    }

    /// Returns the envelope with a new TTL byte (only unauthenticated field).
    static func withTTL(_ envelope: Data, _ ttl: UInt8) -> Data {
        var e = envelope
        e[e.startIndex + 5] = ttl
        return e
    }

    static func aad(_ envelope: Data) -> Data {
        let b = [UInt8](envelope)
        return Data(b[0..<5] + b[6..<30])
    }
}

struct ChannelMessage: Equatable {
    let channelID: Data
    let msgID: Data
    let originID: Data
    let timestampMs: UInt64
    let kind: ChannelMessageKind
    let nickname: String
    let body: String
    var ttl: UInt8
}

enum ChannelCodec {
    static let maxBodyBytes = 280
    static let maxNickBytes = 32

    static func seal(keys: ChannelKeys, originID: Data, nickname: String, body: String, kind: ChannelMessageKind,
                     ttl: UInt8 = ChannelEnvelopeHeader.defaultTTL, timestampMs: UInt64,
                     msgID: Data? = nil, nonce: Data? = nil) throws -> Data {
        precondition(originID.count == 8)
        let nick = Data(nickname.utf8.prefix(maxNickBytes))
        let text = truncatedUTF8(body, maxBytes: maxBodyBytes)
        var g = SystemRandomNumberGenerator()
        let mid = msgID ?? Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &g) })
        let n = nonce ?? Data((0..<12).map { _ in UInt8.random(in: 0...255, using: &g) })
        var header = Data(ChannelEnvelopeHeader.magic)
        header.append(ChannelEnvelopeHeader.version)
        header.append(min(ttl, ChannelEnvelopeHeader.maxTTL))
        header.append(keys.channelID)
        header.append(mid)
        header.append(n)
        var plain = Data(originID)
        for s in stride(from: 56, through: 0, by: -8) { plain.append(UInt8((timestampMs >> UInt64(s)) & 0xff)) }
        plain.append(kind.rawValue)
        plain.append(UInt8(nick.count))
        plain.append(nick)
        plain.append(text)
        let box = try ChaChaPoly.seal(plain, using: keys.key, nonce: try ChaChaPoly.Nonce(data: n),
                                      authenticating: ChannelEnvelopeHeader.aad(header))
        return header + box.ciphertext + box.tag
    }

    static func open(_ envelope: Data, keys: ChannelKeys) -> ChannelMessage? {
        guard let h = ChannelEnvelopeHeader.parse(envelope), h.channelID == keys.channelID else { return nil }
        let b = [UInt8](envelope)
        let ct = Data(b[ChannelEnvelopeHeader.length ..< (b.count - 16)])
        let tag = Data(b[(b.count - 16)...])
        guard let nonce = try? ChaChaPoly.Nonce(data: h.nonce),
              let box = try? ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag),
              let plain = try? ChaChaPoly.open(box, using: keys.key, authenticating: ChannelEnvelopeHeader.aad(envelope)) else { return nil }
        let p = [UInt8](plain)
        guard p.count >= 18 else { return nil }
        var ts: UInt64 = 0
        for i in 8..<16 { ts = (ts << 8) | UInt64(p[i]) }
        guard let kind = ChannelMessageKind(rawValue: p[16]) else { return nil }
        let nl = Int(p[17])
        guard p.count >= 18 + nl else { return nil }
        let nick = String(decoding: p[18 ..< 18 + nl], as: UTF8.self)
        let body = String(decoding: p[(18 + nl)...], as: UTF8.self)
        return ChannelMessage(channelID: h.channelID, msgID: h.msgID, originID: Data(p[0..<8]),
                              timestampMs: ts, kind: kind, nickname: nick, body: body, ttl: h.ttl)
    }

    static func truncatedUTF8(_ s: String, maxBytes: Int) -> Data {
        var out = Data()
        for ch in s {
            let d = Data(String(ch).utf8)
            if out.count + d.count > maxBytes { break }
            out.append(d)
        }
        return out
    }
}
