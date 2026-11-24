//
// ChannelChatService.swift — bitchat-watch iPhone companion
//
// Local "channel chat" peer + bridge. Owns one ChannelRouter and three paths:
//   LAN (Bonjour/TCP), MultipeerConnectivity, and — opt-in per channel — the
//   bitchat BLE mesh, via an opaque tunnel packet (type 0x7E) that stock
//   bitchat iOS/Android relay without understanding (docs/wifi-channel.md §6).
// Joined channels are persisted (code + bridge flag) in UserDefaults: the
// code is a weak shared secret by design, see the doc.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

@MainActor
final class ChannelChatService {
    let router: ChannelRouter
    let lan = LANChannelTransport()
    let mpc = MPCChannelTransport()
    /// Set by the bitchat side when it can carry tunnel packets (patched upstream
    /// BLEService or the host app's leaf engine). nil = bridging unavailable.
    var bitchatTunnelSend: ((Data, UInt8) -> Void)? { didSet { onChange() } }

    var onMessage: (UnifiedMessage) -> Void = { _ in }
    var onChange: () -> Void = {}
    private(set) var lanPeers = 0
    private(set) var mpcPeers = 0
    private let defaultsKey = "hk.channels.v1"

    init(nickname: String) {
        var g = SystemRandomNumberGenerator()
        let origin = Data((0..<8).map { _ in UInt8.random(in: 0...255, using: &g) })
        router = ChannelRouter(originID: origin, nickname: nickname)
        router.transmit = { [weak self] env, path, except in
            guard let self = self else { return }
            switch path {
            case .lan: self.lan.send(env, except: except?.path == .lan ? except?.id : nil)
            case .mpc: self.mpc.send(env, except: except?.path == .mpc ? except?.id : nil)
            case .bitchat:
                if let h = ChannelEnvelopeHeader.parse(env) { self.bitchatTunnelSend?(env, h.ttl) }
            }
        }
        router.onEvent = { [weak self] e in
            guard let self = self, case .message(let m, _, let via, let bridged) = e else { return }
            switch m.kind {
            case .text:
                self.onMessage(UnifiedMessage(id: m.msgID.hexEncodedString(), conversation: .room(.channel, m.channelID.hexEncodedString()),
                    senderName: m.nickname, senderKey: m.originID.hexEncodedString(), text: m.body,
                    timestamp: Date(timeIntervalSince1970: Double(m.timestampMs) / 1000), outgoing: false, state: .received,
                    bridged: bridged, via: via.rawValue.uppercased()))
            case .hello, .leave:
                self.onChange()
            }
        }
        lan.onEnvelope = { [weak self] env, link in self?.router.ingest(env, from: ChannelLinkRef(path: .lan, id: link)) }
        mpc.onEnvelope = { [weak self] env, link in self?.router.ingest(env, from: ChannelLinkRef(path: .mpc, id: link)) }
        lan.onPeersChanged = { [weak self] n in self?.lanPeers = n; self?.onChange() }
        mpc.onPeersChanged = { [weak self] n in self?.mpcPeers = n; self?.onChange() }
        restore()
    }

    /// Envelope that arrived inside a bitchat tunnel packet.
    func ingestFromBitchat(_ envelope: Data, from peer: String) {
        router.ingest(envelope, from: ChannelLinkRef(path: .bitchat, id: peer))
    }

    @discardableResult
    func join(code: String, bridge: Bool) -> RoomInfo? {
        guard let keys = router.join(code: code, bridge: bridge && bitchatTunnelSend != nil) else { return nil }
        persist()
        refreshAdvertising()
        router.sendHello(channelID: keys.channelID)
        return room(for: keys.channelID)
    }

    func leave(idHex: String) {
        guard let id = Data(hexString: idHex) else { return }
        router.leave(channelID: id)
        persist(); refreshAdvertising()
    }

    func setBridge(idHex: String, enabled: Bool) {
        guard let id = Data(hexString: idHex) else { return }
        router.setBridge(enabled && bitchatTunnelSend != nil, channelID: id)
        persist(); onChange()
    }

    func send(_ text: String, idHex: String) -> UnifiedMessage? {
        guard let id = Data(hexString: idHex), let m = router.send(text: text, channelID: id) else { return nil }
        return UnifiedMessage(id: m.msgID.hexEncodedString(), conversation: .room(.channel, idHex), senderName: router.nickname,
                              senderKey: router.originID.hexEncodedString(), text: text, timestamp: Date(), outgoing: true,
                              state: .sent, bridged: router.memberships[id]?.bridgeToBitchat ?? false)
    }

    var rooms: [RoomInfo] { router.memberships.keys.compactMap { room(for: $0) } }

    private func room(for id: Data) -> RoomInfo? {
        guard let m = router.memberships[id] else { return nil }
        return RoomInfo(conversation: .room(.channel, id.hexEncodedString()), title: m.displayName,
                        bridged: m.bridgeToBitchat, memberCount: lanPeers + mpcPeers)
    }

    private func refreshAdvertising() {
        let ids = router.advertisedChannelIDs
        lan.update(channelIDs: ids)
        mpc.update(channelIDs: ids)
        onChange()
    }

    private func persist() {
        let list = router.memberships.values.map { ["code": $0.keys.code, "bridge": $0.bridgeToBitchat ? "1" : "0"] }
        UserDefaults.standard.set(list, forKey: defaultsKey)
    }

    private func restore() {
        let list = UserDefaults.standard.array(forKey: defaultsKey) as? [[String: String]] ?? []
        for e in list { if let c = e["code"] { router.join(code: c, bridge: e["bridge"] == "1") } }
        refreshAdvertising()
    }
}
