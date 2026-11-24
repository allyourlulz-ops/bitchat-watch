//
// MeshtasticSession.swift — bitchat-watch
//
// Platform-independent Meshtastic client state machine for the official BLE
// API (docs: meshtastic.org/docs/development/device/client-api):
//   1. write ToRadio{want_config_id = nonce} to ToRadio
//   2. read FromRadio repeatedly until it returns an empty value
//      (my_info, node_info*, channel*, config..., config_complete_id == nonce)
//   3. subscribe to FromNum notifications; on each notify, drain FromRadio again
//   4. send text with ToRadio{packet: MeshPacket{to, channel, decoded: Data{TEXT_MESSAGE_APP, utf8}}}
// The BLE layer owns characteristics and calls `handleFromRadio` / `write`.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

struct MeshtasticTextMessage: Equatable {
    let packetID: UInt32
    let from: UInt32
    let to: UInt32
    let channel: UInt32
    let text: String
    let time: Date
    let isDirect: Bool
    let snr: Float
}

enum MeshtasticEvent: Equatable {
    case myNode(UInt32)
    case node(MTNodeInfo)
    case channel(MTChannel)
    case configComplete
    case text(MeshtasticTextMessage)
    case ack(packetID: UInt32, ok: Bool, reason: UInt64)
    case rebooted
}

final class MeshtasticSession {
    var write: (Data) -> Void = { _ in }          // write to ToRadio (with response)
    var requestRead: () -> Void = {}               // schedule a FromRadio read
    var onEvent: (MeshtasticEvent) -> Void = { _ in }
    var now: () -> Date = { Date() }

    private(set) var myNodeNum: UInt32 = 0
    private(set) var nodes: [UInt32: MTNodeInfo] = [:]
    private(set) var channels: [Int32: MTChannel] = [:]
    private(set) var configured = false
    private var configNonce: UInt32 = 0
    private var seenPacketIDs = BoundedSeenSet(capacity: 512)

    func start(nonce: UInt32 = UInt32.random(in: 1...UInt32.max)) {
        configured = false
        configNonce = nonce
        write(MTToRadio.wantConfig(nonce))
        requestRead()
    }

    /// Called after every FromRadio read. Returns true if the caller should keep reading.
    @discardableResult
    func handleFromRadio(_ data: Data) -> Bool {
        guard let msg = try? MTFromRadio.decode(data) else { return true } // skip garbage, keep draining
        switch msg {
        case .empty:
            return false
        case .myInfo(let num):
            myNodeNum = num
            onEvent(.myNode(num))
        case .nodeInfo(let n):
            nodes[n.num] = n
            onEvent(.node(n))
        case .channel(let c):
            channels[c.index] = c
            onEvent(.channel(c))
        case .configComplete(let id):
            if id == configNonce { configured = true; onEvent(.configComplete) }
        case .rebooted:
            onEvent(.rebooted)
            start()
        case .packet(let p):
            handlePacket(p)
        case .other:
            break
        }
        return true
    }

    /// FromNum notified: there is data waiting.
    func fromNumNotified() { requestRead() }

    private func handlePacket(_ p: MTMeshPacket) {
        guard let d = p.decoded else { return } // still encrypted for us: not decodable on this channel
        switch MeshtasticPort(rawValue: d.portnum) {
        case .textMessage?:
            if p.id != 0 {
                let key = "\(p.from)-\(p.id)"
                if seenPacketIDs.contains(key) { return }
                seenPacketIDs.insert(key)
            }
            let t = p.rxTime != 0 ? Date(timeIntervalSince1970: TimeInterval(p.rxTime)) : now()
            let msg = MeshtasticTextMessage(packetID: p.id, from: p.from, to: p.to, channel: p.channel,
                                            text: String(decoding: d.payload, as: UTF8.self), time: t,
                                            isDirect: p.to != MeshtasticBLE.broadcastNum && p.to == myNodeNum,
                                            snr: p.rxSnr)
            onEvent(.text(msg))
        case .routing?:
            if d.requestID != 0, let reason = MTRouting.errorReason(d.payload) {
                onEvent(.ack(packetID: d.requestID, ok: reason == 0, reason: reason))
            }
        case .nodeInfo?:
            if let u = try? MTUser.decode(d.payload) {
                var n = nodes[p.from] ?? MTNodeInfo()
                n.num = p.from
                n.user = u
                n.lastHeard = UInt32(now().timeIntervalSince1970)
                nodes[p.from] = n
                onEvent(.node(n))
            }
        default:
            break
        }
    }

    /// Send a text. `to` = node number for a DM, broadcast for a channel message.
    @discardableResult
    func sendText(_ text: String, to: UInt32 = MeshtasticBLE.broadcastNum, channel: UInt32 = 0) -> UInt32 {
        let id = UInt32.random(in: 1...UInt32.max)
        // Meshtastic payload limit is ~233 bytes for DATA_PAYLOAD_LEN; truncate on a character boundary.
        let payload = ChannelCodec.truncatedUTF8(text, maxBytes: 200)
        var pkt = MTMeshPacket()
        pkt.to = to
        pkt.channel = channel
        pkt.id = id
        pkt.wantAck = true
        pkt.decoded = MTData(portnum: MeshtasticPort.textMessage.rawValue, payload: payload)
        write(MTToRadio.packet(pkt))
        return id
    }

    func displayName(_ num: UInt32) -> String {
        if let u = nodes[num]?.user, !u.longName.isEmpty { return u.longName }
        return String(format: "!%08x", num)
    }

    func channelName(_ index: UInt32) -> String {
        if let c = channels[Int32(index)], !c.name.isEmpty { return c.name }
        return index == 0 ? "Primary" : "Ch \(index)"
    }
}
