//
// CompanionTransport.swift — bitchat-watch (watchOS side)
//
// Companion mode: when the paired iPhone runs bitchat with the WatchBridge
// patch (or the standalone BitchatWatchHost app), the watch shows the phone's
// bitchat mesh and the phone's local channel chats, and sends through the
// phone. Uses WCSession.sendMessage when reachable, transferUserInfo as a
// queued fallback, and the phone's applicationContext snapshot on launch.
// Reports two networks: .bitchatPhone and .channel.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity

@MainActor
final class CompanionTransport: NSObject, ChatTransport {
    let network: NetworkKind = .bitchatPhone
    weak var sink: TransportSink?
    private(set) var reachable = false
    private(set) var activated = false
    private(set) var bridgeAvailable = false
    private(set) var phoneNickname = ""
    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func start() {
        guard let s = session else { return }
        s.delegate = self
        s.activate()
    }

    var statusText: String {
        guard activated else { return "iPhone: not paired" }
        return reachable ? "iPhone reachable\(phoneNickname.isEmpty ? "" : " · \(phoneNickname)")" : "iPhone not reachable (queued)"
    }
    var isActive: Bool { reachable }

    func canSend(in c: ConversationID) -> Bool {
        (c.network == .bitchatPhone || c.network == .channel) && activated
    }

    func send(_ text: String, in c: ConversationID) -> UnifiedMessage? {
        guard canSend(in: c) else { return nil }
        let clientID = "w-\(UUID().uuidString)"
        let msg: CompanionMessage = c.scope == .direct
            ? .sendDirect(peerKey: c.key, text: text, clientID: clientID)
            : .sendRoom(conversation: c, text: text, clientID: clientID)
        deliver(msg, queueIfUnreachable: true)
        return UnifiedMessage(id: clientID, conversation: c, senderName: phoneNickname.isEmpty ? "me" : phoneNickname,
                              senderKey: "me", text: text, timestamp: Date(), outgoing: true, state: .sending,
                              via: reachable ? "via iPhone" : "queued for iPhone")
    }

    func joinChannel(code: String, bridge: Bool) { deliver(.joinChannel(code: code, bridge: bridge), queueIfUnreachable: true) }
    func leaveChannel(idHex: String) { deliver(.leaveChannel(channelIDHex: idHex), queueIfUnreachable: true) }
    func setBridge(idHex: String, enabled: Bool) { deliver(.setChannelBridge(channelIDHex: idHex, enabled: enabled), queueIfUnreachable: true) }
    func toggleFavorite(peerKey: String) { deliver(.toggleFavorite(peerKey: peerKey), queueIfUnreachable: true) }
    func requestSnapshot() { deliver(.requestSnapshot, queueIfUnreachable: false) }

    private func deliver(_ m: CompanionMessage, queueIfUnreachable: Bool) {
        guard let s = session, s.activationState == .activated else { return }
        let dict = m.encodeToDictionary()
        if s.isReachable {
            s.sendMessage(dict, replyHandler: nil) { [weak self] _ in
                // fall back to the queued channel if the live send failed
                if queueIfUnreachable { Task { @MainActor in self?.session?.transferUserInfo(dict) } }
            }
        } else if queueIfUnreachable {
            s.transferUserInfo(dict)
        }
    }

    private func apply(_ m: CompanionMessage) {
        guard let sink = sink else { return }
        switch m {
        case .snapshot(let snap):
            phoneNickname = snap.phoneNickname
            bridgeAvailable = snap.bridgeAvailable
            snap.people.forEach { sink.transport(self, didUpdate: $0) }
            snap.rooms.forEach { sink.transport(self, didUpdate: $0) }
            snap.recent.forEach { sink.transport(self, didReceive: $0) }
        case .message(let msg): sink.transport(self, didReceive: msg)
        case .people(let ps): ps.forEach { sink.transport(self, didUpdate: $0) }
        case .rooms(let rs): rs.forEach { sink.transport(self, didUpdate: $0) }
        case .delivery(let id, let state): sink.transport(self, message: id, didChangeTo: state)
        case .error(let text): SecureLogger.warning("companion: \(text)")
        default: break   // watch→phone kinds are never received here
        }
        sink.transportStatusDidChange(self)
    }
}

extension CompanionTransport: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        let ctx = session.receivedApplicationContext
        let reachable = session.isReachable
        Task { @MainActor in
            self.activated = state == .activated
            self.reachable = reachable
            if let snap = CompanionMessage.decode(fromDictionary: ctx) { self.apply(snap) }
            self.requestSnapshot()
            self.sink?.transportStatusDidChange(self)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let r = session.isReachable
        Task { @MainActor in
            self.reachable = r
            if r { self.requestSnapshot() }
            self.sink?.transportStatusDidChange(self)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let m = CompanionMessage.decode(fromDictionary: message) else { return }
        Task { @MainActor in self.apply(m) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let m = CompanionMessage.decode(fromDictionary: userInfo) else { return }
        Task { @MainActor in self.apply(m) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let m = CompanionMessage.decode(fromDictionary: applicationContext) else { return }
        Task { @MainActor in self.apply(m) }
    }
}
#endif
