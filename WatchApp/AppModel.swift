//
// AppModel.swift — bitchat-watch
//
// Wires the transports to the shared ChatStore and exposes it to SwiftUI.
// Mode selection is automatic and simultaneous:
//   * Leaf mesh: BLECentralHub connects to up to 2 peripherals (user's LoRa
//     radio first, then bitchat peers) — BitchatTransport / MeshtasticTransport
//     / MeshCoreTransport.
//   * Companion: CompanionTransport is always activated; when the iPhone bridge
//     answers, its bitchat mesh (.bitchatPhone) and channel chats (.channel)
//     appear as separately labelled networks.
// Sending picks the transport by the conversation's NetworkKind.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import SwiftUI
import CoreBluetooth

@MainActor
final class AppModel: ObservableObject, TransportSink {
    @Published private(set) var revision = 0
    @Published var needsNickname: Bool

    let store: ChatStore
    let settings = WatchSettings()
    let hub = BLECentralHub()
    let bitchat: BitchatTransport
    let meshtastic = MeshtasticTransport()
    let meshcore = MeshCoreTransport()
    let companion = CompanionTransport()
    let notifier = Notifier()
    private var transports: [ChatTransport] { [bitchat, meshtastic, meshcore, companion] }

    init() {
        let identity = KeychainStore.loadOrCreateIdentity()
        let nick = settings.nickname
        needsNickname = nick.isEmpty
        store = ChatStore(favorites: settings.favorites)
        bitchat = BitchatTransport(identity: identity, nickname: nick.isEmpty ? "watch\(identity.peerID.id.prefix(4))" : nick)
        for t in transports { t.sink = self }
        hub.register(bitchat); hub.register(meshtastic); hub.register(meshcore)
        hub.onChange = { [weak self] in self?.bump() }
        store.onChange = { [weak self] in self?.bump() }
        store.onIncoming = { [weak self] m in
            guard let self = self else { return }
            let fav = self.store.favorites.contains("\(m.conversation.network.rawValue):\(m.senderKey)")
            self.notifier.incoming(m, title: self.store.title(for: m.conversation), isFavorite: fav)
        }
        store.upsert(room: RoomInfo(conversation: .room(.bitchat, "public"), title: "Mesh · bitchat"))
        notifier.enabled = settings.notifications
        applyPolicy()
    }

    func start() {
        notifier.requestAuthorization()
        companion.start()
        hub.start()
    }

    func scenePhaseChanged(active: Bool) {
        notifier.appIsActive = active
        if active { hub.start(); companion.requestSnapshot() }
        // When inactive we keep running until watchOS suspends us; links then drop
        // and are re-established by the planner on the next activation.
    }

    private func bump() { revision &+= 1 }

    // MARK: settings

    func setNickname(_ n: String) {
        let trimmed = String(n.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        guard !trimmed.isEmpty else { return }
        settings.nickname = trimmed
        bitchat.engine.nickname = trimmed
        bitchat.engine.sendAnnounce(force: true)
        needsNickname = false
    }

    func choose(radio: RadioCandidate?) {
        settings.preferredRadioID = radio?.id
        settings.preferredRadioName = radio?.name ?? ""
        if radio == nil {
            store.removeRooms(network: .meshtastic); store.removeRooms(network: .meshcore)
        }
        applyPolicy()
    }

    func setDirectBitchat(_ on: Bool) { settings.directBitchat = on; applyPolicy() }
    func setNotifications(_ on: Bool) { settings.notifications = on; notifier.enabled = on; bump() }

    private func applyPolicy() {
        var p = ConnectionPolicy()
        p.preferredRadioID = settings.preferredRadioID
        p.directBitchatEnabled = settings.directBitchat
        hub.policy = p
        bump()
    }

    // MARK: actions

    func transport(for c: ConversationID) -> ChatTransport? {
        switch c.network {
        case .bitchat: return bitchat
        case .meshtastic: return meshtastic
        case .meshcore: return meshcore
        case .bitchatPhone, .channel: return companion
        }
    }

    func canSend(in c: ConversationID) -> Bool { transport(for: c)?.canSend(in: c) ?? false }

    func send(_ text: String, in c: ConversationID) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let tr = transport(for: c), let local = tr.send(t, in: c) else { return }
        store.append(local, notify: false)
    }

    func open(_ c: ConversationID) {
        store.activeConversation = c
        store.markRead(c)
        if c.network == .bitchat, c.scope == .direct,
           let last = store.messages[c]?.last(where: { !$0.outgoing }) {
            bitchat.sendReadReceipt(messageID: last.id, peerKey: c.key)
        }
    }

    func close(_ c: ConversationID) { if store.activeConversation == c { store.activeConversation = nil } }

    func toggleFavorite(_ person: UnifiedPerson) {
        store.toggleFavorite(personID: person.id)
        settings.favorites = store.favorites
        if person.network == .bitchatPhone { companion.toggleFavorite(peerKey: person.key) }
    }

    func startDM(with person: UnifiedPerson) -> ConversationID {
        let c = ConversationID.direct(person.network, person.key)
        if person.network == .bitchat { bitchat.engine.initiateHandshake(with: PeerID(str: person.key)) }
        return c
    }

    // MARK: TransportSink

    func transport(_ t: ChatTransport, didReceive message: UnifiedMessage) { store.append(message) }
    func transport(_ t: ChatTransport, didUpdate person: UnifiedPerson) { store.upsert(person) }
    func transport(_ t: ChatTransport, didUpdate room: RoomInfo) { store.upsert(room: room) }
    func transport(_ t: ChatTransport, message id: String, didChangeTo state: DeliveryState) {
        store.updateState(messageID: id, in: nil, to: state)
    }
    func transportStatusDidChange(_ t: ChatTransport) {
        if !t.isActive && t.network != .bitchatPhone { store.setOffline(network: t.network) }
        bump()
    }

    struct StatusLine: Identifiable { let network: NetworkKind; let text: String; var id: NetworkKind { network } }

    var statusLines: [StatusLine] {
        [StatusLine(network: .bitchat, text: settings.directBitchat ? bitchat.statusText : "direct mesh off"),
         StatusLine(network: .meshtastic, text: meshtastic.statusText),
         StatusLine(network: .meshcore, text: meshcore.statusText),
         StatusLine(network: .bitchatPhone, text: companion.statusText)]
    }

    var bluetoothOff: Bool { hub.bluetoothState == .poweredOff || hub.bluetoothState == .unauthorized }
}
