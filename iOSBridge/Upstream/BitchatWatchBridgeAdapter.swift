//
// BitchatWatchBridgeAdapter.swift — goes INTO the upstream bitchat iOS app
// (bitchat/WatchBridge/), added by upstream-patches/0001-watch-companion-bridge.patch.
//
// Adapts upstream ChatViewModel / ConversationStore / BLEService to the
// WatchBridgeKit package's public façade. Depends on three small additive
// upstream changes made by the same patch:
//   * ChatViewModel.sendMeshText(_:)          (mesh public send regardless of active channel)
//   * BLEService.broadcastOpaque(type:payload:ttl:)
//   * BLEService.opaquePacketObserver          (called for unknown packet types, before relay)
//
// Written against upstream commit 04995f68 (2026-10-25). UNCOMPILED in this
// repo (needs the upstream tree + Xcode); see README.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

#if os(iOS)
import BitFoundation
import Combine
import Foundation
import WatchBridgeKit

@MainActor
final class BitchatWatchBridgeAdapter: WatchBridgeChatSource {
    private let vm: ChatViewModel
    private var bridge: WatchBridge?
    private var bag = Set<AnyCancellable>()

    init(chatViewModel: ChatViewModel) {
        vm = chatViewModel
    }

    func start() {
        let b = WatchBridge(source: self)
        bridge = b
        vm.conversations.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self = self, case .appended(let cid, let msg) = change, let wb = self.convert(msg, in: cid) else { return }
                self.bridge?.didReceive(wb)
            }
            .store(in: &bag)
        vm.$allPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.bridge?.peopleDidChange() }
            .store(in: &bag)
        if let ble = vm.meshService as? BLEService {
            ble.opaquePacketObserver = { [weak self] type, payload, sender in
                guard type == WatchBridge.tunnelPacketType else { return }
                Task { @MainActor in self?.bridge?.didReceiveTunnel(payload, fromPeer: sender.id) }
            }
        }
        b.start()
    }

    // MARK: WatchBridgeChatSource

    var bridgeNickname: String { vm.nickname }

    var bridgePeople: [WBPerson] {
        vm.allPeers.map {
            WBPerson(key: $0.peerID.id, name: $0.displayName, detail: $0.isConnected ? "connected" : ($0.isReachable ? "reachable" : "offline"),
                     online: $0.isConnected || $0.isReachable, favorite: $0.isFavorite, secure: false)
        }
    }

    var bridgeRecentMessages: [WBMessage] {
        let mesh = vm.conversations.conversationsByID[.mesh]?.messages.suffix(30) ?? []
        return mesh.compactMap { convert($0, in: .mesh) }
    }

    func bridgeSendPublic(_ text: String) -> WBMessage? {
        vm.sendMeshText(text)
        return WBMessage(id: UUID().uuidString, directPeerKey: nil, senderName: vm.nickname, senderKey: vm.meshService.myPeerID.id,
                         text: text, timestamp: Date(), outgoing: true, state: .sent)
    }

    func bridgeSendPrivate(_ text: String, peerKey: String) -> WBMessage? {
        vm.privateConversationCoordinator.sendPrivateMessage(text, to: PeerID(str: peerKey))
        return WBMessage(id: UUID().uuidString, directPeerKey: peerKey, senderName: vm.nickname, senderKey: vm.meshService.myPeerID.id,
                         text: text, timestamp: Date(), outgoing: true, state: .sending)
    }

    func bridgeToggleFavorite(peerKey: String) { vm.toggleFavorite(peerID: PeerID(str: peerKey)) }

    var bridgeTunnelSend: ((Data, UInt8) -> Void)? {
        guard let ble = vm.meshService as? BLEService else { return nil }
        return { payload, ttl in ble.broadcastOpaque(type: WatchBridge.tunnelPacketType, payload: payload, ttl: ttl) }
    }

    // MARK: helpers

    private func convert(_ m: BitchatMessage, in cid: ConversationID) -> WBMessage? {
        let directKey: String?
        switch cid {
        case .mesh: directKey = nil
        case .direct(let handle): directKey = handle.routingPeerID.id
        case .geohash: return nil   // location channels are internet (Nostr); out of watch scope
        }
        let mine = m.senderPeerID == vm.meshService.myPeerID
        let state: WBMessage.State
        switch m.deliveryStatus {
        case .delivered: state = .delivered
        case .read: state = .read
        case .failed: state = .failed
        case .sending: state = .sending
        default: state = mine ? .sent : .received
        }
        return WBMessage(id: m.id, directPeerKey: directKey, senderName: m.sender, senderKey: m.senderPeerID?.id ?? "",
                         text: m.content, timestamp: m.timestamp, outgoing: mine, state: state)
    }
}
#endif
