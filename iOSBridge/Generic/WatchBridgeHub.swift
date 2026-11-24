//
// WatchBridgeHub.swift — bitchat-watch iPhone companion bridge
//
// The phone side of companion mode. A WCSessionDelegate that:
//   * forwards the phone's bitchat chat (any CompanionChatSource — the patched
//     upstream ChatViewModel adapter, or the standalone host's leaf engine) to
//     the watch as NetworkKind.bitchatPhone,
//   * runs ChannelChatService (LAN + MPC + optional bitchat bridge) and shows
//     it on the watch as NetworkKind.channel,
//   * executes watch requests (send, join/leave channel, bridge toggle, favorite).
// It is additive: the host app only has to create it and keep a reference.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import WatchConnectivity

/// What the bridge needs from the phone's bitchat stack.
@MainActor
protocol CompanionChatSource: AnyObject {
    var nickname: String { get }
    var people: [UnifiedPerson] { get }            // network = .bitchatPhone
    var recentMessages: [UnifiedMessage] { get }   // network = .bitchatPhone
    /// Called by the source when something changed (bridge then pushes a delta / snapshot).
    var onMessage: ((UnifiedMessage) -> Void)? { get set }
    var onPeopleChanged: (() -> Void)? { get set }
    func sendPublic(_ text: String) -> UnifiedMessage?
    func sendPrivate(_ text: String, peerKey: String) -> UnifiedMessage?
    func toggleFavorite(peerKey: String)
    /// Opaque channel-tunnel support (nil if the bitchat stack can't send/receive type 0x7E).
    var tunnelSend: ((Data, UInt8) -> Void)? { get }
    var onTunnelReceive: ((Data, String) -> Void)? { get set }
}

@MainActor
final class WatchBridgeHub: NSObject {
    let source: CompanionChatSource
    let channels: ChannelChatService
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }
    private var contextTimer: Timer?

    init(source: CompanionChatSource) {
        self.source = source
        self.channels = ChannelChatService(nickname: source.nickname)
        super.init()
        channels.bitchatTunnelSend = source.tunnelSend
        source.onTunnelReceive = { [weak self] env, peer in self?.channels.ingestFromBitchat(env, from: peer) }
        source.onMessage = { [weak self] m in self?.push(.message(m)) }
        source.onPeopleChanged = { [weak self] in
            guard let self = self else { return }
            self.push(.people(self.source.people)); self.scheduleContextUpdate()
        }
        channels.onMessage = { [weak self] m in self?.push(.message(m)) }
        channels.onChange = { [weak self] in
            guard let self = self else { return }
            self.push(.rooms(self.channels.rooms)); self.scheduleContextUpdate()
        }
    }

    func start() {
        guard let s = session else { return }
        s.delegate = self
        s.activate()
    }

    func snapshot() -> CompanionSnapshot {
        let publicRoom = RoomInfo(conversation: .room(.bitchatPhone, "public"), title: "Mesh · via iPhone")
        return CompanionSnapshot(phoneNickname: source.nickname, people: source.people,
                                 rooms: [publicRoom] + channels.rooms,
                                 recent: Array(source.recentMessages.suffix(40)),
                                 bridgeAvailable: source.tunnelSend != nil)
    }

    private func push(_ m: CompanionMessage) {
        guard let s = session, s.activationState == .activated, s.isPaired, s.isWatchAppInstalled else { return }
        if s.isReachable { s.sendMessage(m.encodeToDictionary(), replyHandler: nil, errorHandler: nil) }
        scheduleContextUpdate()
    }

    /// applicationContext is coalesced by the system; update at most every 5 s.
    private func scheduleContextUpdate() {
        guard contextTimer == nil else { return }
        contextTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.contextTimer = nil
                try? self.session?.updateApplicationContext(CompanionMessage.snapshot(self.snapshot()).encodeToDictionary())
            }
        }
    }

    private func handle(_ m: CompanionMessage) {
        switch m {
        case .requestSnapshot:
            push(.snapshot(snapshot()))
        case .sendRoom(let c, let text, let clientID):
            let sent: UnifiedMessage? = c.network == .channel ? channels.send(text, idHex: c.key) : source.sendPublic(text)
            push(.delivery(messageID: clientID, state: sent == nil ? .failed : .sent))
        case .sendDirect(let peer, let text, let clientID):
            let sent = source.sendPrivate(text, peerKey: peer)
            push(.delivery(messageID: clientID, state: sent == nil ? .failed : .sent))
        case .joinChannel(let code, let bridge):
            if channels.join(code: code, bridge: bridge) == nil { push(.error("channel code too short")) }
        case .leaveChannel(let id): channels.leave(idHex: id)
        case .setChannelBridge(let id, let on): channels.setBridge(idHex: id, enabled: on)
        case .toggleFavorite(let peer): source.toggleFavorite(peerKey: peer)
        default: break
        }
    }
}

extension WatchBridgeHub: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.scheduleContextUpdate() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() } // watch switched
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in self.push(.snapshot(self.snapshot())) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let m = CompanionMessage.decode(fromDictionary: message) else { return }
        Task { @MainActor in self.handle(m) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let m = CompanionMessage.decode(fromDictionary: userInfo) else { return }
        Task { @MainActor in self.handle(m) }
    }
}
