//
// WatchBridgePublic.swift — public façade of the WatchBridgeKit package
//
// Only this file is public. It lets the upstream bitchat iOS app (which has
// its own ConversationID, TransportConfig, SecureLogger, … types) use the
// bridge without any symbol collisions: everything else in the package is
// internal. Used only when building the upstream patch (scripts/make-upstream-patch.sh);
// the standalone host target compiles the generic files directly.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

public struct WBPerson: Equatable {
    public let key: String          // bitchat peer ID hex
    public let name: String
    public let detail: String
    public let online: Bool
    public let favorite: Bool
    public let secure: Bool
    public init(key: String, name: String, detail: String, online: Bool, favorite: Bool, secure: Bool) {
        self.key = key; self.name = name; self.detail = detail; self.online = online; self.favorite = favorite; self.secure = secure
    }
}

public struct WBMessage: Equatable {
    public enum State: String { case sending, sent, delivered, read, failed, received }
    public let id: String
    /// nil = public mesh room, otherwise the DM peer's ID hex.
    public let directPeerKey: String?
    public let senderName: String
    public let senderKey: String
    public let text: String
    public let timestamp: Date
    public let outgoing: Bool
    public let state: State
    public init(id: String, directPeerKey: String?, senderName: String, senderKey: String, text: String,
                timestamp: Date, outgoing: Bool, state: State) {
        self.id = id; self.directPeerKey = directPeerKey; self.senderName = senderName; self.senderKey = senderKey
        self.text = text; self.timestamp = timestamp; self.outgoing = outgoing; self.state = state
    }
}

@MainActor
public protocol WatchBridgeChatSource: AnyObject {
    var bridgeNickname: String { get }
    var bridgePeople: [WBPerson] { get }
    var bridgeRecentMessages: [WBMessage] { get }
    func bridgeSendPublic(_ text: String) -> WBMessage?
    func bridgeSendPrivate(_ text: String, peerKey: String) -> WBMessage?
    func bridgeToggleFavorite(peerKey: String)
    /// Broadcast an opaque channel-tunnel payload into the mesh (nil = unsupported).
    var bridgeTunnelSend: ((Data, UInt8) -> Void)? { get }
}

@MainActor
public final class WatchBridge {
    private let adapter: SourceAdapter
    private let hub: WatchBridgeHub

    public init(source: WatchBridgeChatSource) {
        adapter = SourceAdapter(source)
        hub = WatchBridgeHub(source: adapter)
    }

    public func start() { hub.start() }
    /// Call for every new mesh/DM message the phone sees (incoming or local echo).
    public func didReceive(_ m: WBMessage) { adapter.onMessage?(SourceAdapter.convert(m)) }
    public func peopleDidChange() { adapter.onPeopleChanged?() }
    /// Call with the payload of every received bitchat packet of type 0x7E.
    public func didReceiveTunnel(_ payload: Data, fromPeer peer: String) { adapter.onTunnelReceive?(payload, peer) }
    public static let tunnelPacketType: UInt8 = ChannelTunnelWire.bitchatPacketType
}

@MainActor
final class SourceAdapter: CompanionChatSource {
    let src: WatchBridgeChatSource
    var onMessage: ((UnifiedMessage) -> Void)?
    var onPeopleChanged: (() -> Void)?
    var onTunnelReceive: ((Data, String) -> Void)?
    init(_ s: WatchBridgeChatSource) { src = s }

    var nickname: String { src.bridgeNickname }
    var people: [UnifiedPerson] {
        src.bridgePeople.map { UnifiedPerson(network: .bitchatPhone, key: $0.key, displayName: $0.name, detail: $0.detail,
                                             isOnline: $0.online, isFavorite: $0.favorite, canMessage: true, secureSession: $0.secure) }
    }
    var recentMessages: [UnifiedMessage] { src.bridgeRecentMessages.map(SourceAdapter.convert) }
    func sendPublic(_ text: String) -> UnifiedMessage? { src.bridgeSendPublic(text).map(SourceAdapter.convert) }
    func sendPrivate(_ text: String, peerKey: String) -> UnifiedMessage? { src.bridgeSendPrivate(text, peerKey: peerKey).map(SourceAdapter.convert) }
    func toggleFavorite(peerKey: String) { src.bridgeToggleFavorite(peerKey: peerKey) }
    var tunnelSend: ((Data, UInt8) -> Void)? { src.bridgeTunnelSend }

    static func convert(_ m: WBMessage) -> UnifiedMessage {
        UnifiedMessage(id: m.id, conversation: m.directPeerKey.map { .direct(.bitchatPhone, $0) } ?? .room(.bitchatPhone, "public"),
                       senderName: m.senderName, senderKey: m.senderKey, text: m.text, timestamp: m.timestamp,
                       outgoing: m.outgoing, state: DeliveryState(rawValue: m.state.rawValue) ?? .received)
    }
}
