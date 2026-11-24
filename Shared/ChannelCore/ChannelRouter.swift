//
// ChannelRouter.swift — bitchat-watch channel chat forwarding core
//
// One router per device (iPhone companion, Mac tester). It owns channel
// memberships, the msgID dedup cache, TTL handling and the bitchat-bridge rate
// limit. Transports (LAN, MultipeerConnectivity, bitchat BLE tunnel) are dumb
// pipes: they hand raw envelopes to `ingest` and send what `send` asks for.
//
// Forwarding rules (docs/wifi-channel.md §5):
//  * only channels this device has joined are forwarded (others are opaque and dropped)
//  * every msgID is delivered/forwarded at most once (bounded cache)
//  * TTL: decremented by 1 per channel hop; not forwarded when it reaches 0/1
//  * LAN/MPC: forwarded to every other link of both kinds except the arrival link
//  * bitchat: only if the channel is bridged (opt-in), never back into bitchat,
//    only `.text`/`.leave`, only envelopes <= ChannelTunnelWire.maxTunnelledEnvelopeBytes,
//    and through a token bucket (default 6/min, burst 3) shared by all channels
//
// Threading: not thread-safe; call from one serial queue.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum ChannelPath: String, Codable, CaseIterable {
    case lan, mpc, bitchat
}

struct ChannelLinkRef: Hashable {
    let path: ChannelPath
    let id: String
}

struct ChannelMembership {
    let keys: ChannelKeys
    var displayName: String
    var bridgeToBitchat: Bool
}

struct TokenBucket {
    var capacity: Double
    var refillPerSecond: Double
    private(set) var tokens: Double
    private var last: Date

    init(capacity: Double, perMinute: Double, now: Date = Date()) {
        self.capacity = capacity
        self.refillPerSecond = perMinute / 60
        self.tokens = capacity
        self.last = now
    }

    mutating func take(now: Date = Date()) -> Bool {
        tokens = min(capacity, tokens + now.timeIntervalSince(last) * refillPerSecond)
        last = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

final class ChannelRouter {
    enum Event {
        case message(ChannelMessage, channelName: String, via: ChannelPath, bridged: Bool)
        case dropped(reason: String)
    }

    // identity
    let originID: Data
    var nickname: String

    // outputs
    /// Send `envelope` on `path`. `except` = arrival link to skip (nil = all links of that path).
    var transmit: (_ envelope: Data, _ path: ChannelPath, _ except: ChannelLinkRef?) -> Void = { _, _, _ in }
    var onEvent: (Event) -> Void = { _ in }
    var now: () -> Date = { Date() }

    // state
    private(set) var memberships: [Data: ChannelMembership] = [:]
    private var seen = BoundedSeenSet(capacity: 4096)
    var bridgeBucket = TokenBucket(capacity: 3, perMinute: 6)
    private(set) var bridgedOut = 0
    private(set) var bridgeDropsRateLimited = 0

    init(originID: Data, nickname: String) {
        precondition(originID.count == 8)
        self.originID = originID
        self.nickname = nickname
    }

    // MARK: membership

    @discardableResult
    func join(code: String, displayName: String? = nil, bridge: Bool = false) -> ChannelKeys? {
        guard let keys = ChannelKeys(code: code) else { return nil }
        memberships[keys.channelID] = ChannelMembership(keys: keys, displayName: displayName ?? "#\(keys.code)", bridgeToBitchat: bridge)
        return keys
    }

    func leave(channelID: Data) {
        if let m = memberships[channelID] { _ = try? sendRaw(m, kind: .leave, body: "", ttl: 1) }
        memberships.removeValue(forKey: channelID)
    }

    func setBridge(_ on: Bool, channelID: Data) { memberships[channelID]?.bridgeToBitchat = on }

    /// Hex channel IDs advertised in Bonjour TXT / MPC discoveryInfo.
    var advertisedChannelIDs: [String] { memberships.keys.map { $0.hexEncodedString() }.sorted() }

    // MARK: outbound

    @discardableResult
    func send(text: String, channelID: Data, ttl: UInt8 = ChannelEnvelopeHeader.defaultTTL) -> ChannelMessage? {
        guard let m = memberships[channelID] else { return nil }
        return try? sendRaw(m, kind: .text, body: text, ttl: ttl)
    }

    func sendHello(channelID: Data) {
        guard let m = memberships[channelID] else { return }
        _ = try? sendRaw(m, kind: .hello, body: "", ttl: 1)
    }

    private func sendRaw(_ m: ChannelMembership, kind: ChannelMessageKind, body: String, ttl: UInt8) throws -> ChannelMessage? {
        let env = try ChannelCodec.seal(keys: m.keys, originID: originID, nickname: nickname, body: body, kind: kind,
                                        ttl: ttl, timestampMs: unixMillis(now()))
        guard let h = ChannelEnvelopeHeader.parse(env) else { return nil }
        seen.insert(h.msgIDHex)
        transmit(env, .lan, nil)
        transmit(env, .mpc, nil)
        if m.bridgeToBitchat && kind != .hello { bridgeOut(env) }
        return ChannelCodec.open(env, keys: m.keys)
    }

    // MARK: inbound

    func ingest(_ envelope: Data, from link: ChannelLinkRef) {
        guard let h = ChannelEnvelopeHeader.parse(envelope) else { onEvent(.dropped(reason: "not a channel envelope")); return }
        guard let m = memberships[h.channelID] else { return } // not our channel: opaque, ignore
        guard !seen.contains(h.msgIDHex) else { return }
        guard let msg = ChannelCodec.open(envelope, keys: m.keys) else {
            onEvent(.dropped(reason: "auth failed (wrong code or tampered)"))
            return
        }
        seen.insert(h.msgIDHex)
        if msg.originID == originID { return } // our own message looped back
        onEvent(.message(msg, channelName: m.displayName, via: link.path, bridged: link.path == .bitchat))

        // forward
        guard msg.kind != .hello, h.ttl > 1 else { return }
        let fwd = ChannelEnvelopeHeader.withTTL(envelope, h.ttl - 1)
        for path in [ChannelPath.lan, .mpc] {
            transmit(fwd, path, link.path == path ? link : nil)
        }
        if m.bridgeToBitchat && link.path != .bitchat { bridgeOut(fwd) }
    }

    private func bridgeOut(_ envelope: Data) {
        guard envelope.count <= ChannelTunnelWire.maxTunnelledEnvelopeBytes else {
            onEvent(.dropped(reason: "too large to bridge into bitchat"))
            return
        }
        guard bridgeBucket.take(now: now()) else {
            bridgeDropsRateLimited += 1
            onEvent(.dropped(reason: "bitchat bridge rate limit"))
            return
        }
        bridgedOut += 1
        transmit(envelope, .bitchat, nil)
    }
}
