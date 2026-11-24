//
// BitchatTransport.swift — bitchat-watch
//
// Leaf-mode bitchat over Core Bluetooth (central only). Owns a
// BitchatLeafEngine and the GATT plumbing for each connected bitchat
// peripheral (phone/Mac running stock bitchat, or the Mac tester):
//   discover service F47B5E2D-…  → characteristic A1B2C3D4-… → subscribe notify
//   inbound notifications → NotificationStreamAssembler → engine.receive(frame:)
//   engine.sendFrame → writeValue(.withoutResponse) with a small backlog drained
//                      in peripheralIsReady(toSendWriteWithoutResponse:)
// The engine never relays; we only originate packets (see BitchatLeafEngine).
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

@MainActor
final class BitchatTransport: NSObject, ChatTransport, BLELinkHandler {
    let radioKind: RadioKind = .bitchat
    let network: NetworkKind = .bitchat
    weak var sink: TransportSink?
    let engine: BitchatLeafEngine

    private struct Link {
        let peripheral: CBPeripheral
        var characteristic: CBCharacteristic?
        var assembler = NotificationStreamAssembler()
        var backlog: [Data] = []
    }
    private var links: [String: Link] = [:]
    private var tick: Timer?
    /// Opaque channel-chat tunnel payloads (type 0x7E) — only the iPhone host bridges them.
    var onChannelTunnel: ((Data, UInt8) -> Void)?

    init(identity: BitchatIdentity, nickname: String) {
        engine = BitchatLeafEngine(identity: identity, nickname: nickname)
        super.init()
        engine.sendFrame = { [weak self] frame, link in self?.write(frame, link: link) }
        engine.linkWriteLimit = { [weak self] link in self?.writeLimit(link) ?? 182 }
        engine.onEvent = { [weak self] e in self?.handle(e) }
        tick = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.engine.tick() }
        }
    }

    var statusText: String {
        let n = links.values.filter { $0.characteristic != nil }.count
        let peers = engine.peers.count
        return n == 0 ? "no bitchat phone in range" : "\(n) link\(n == 1 ? "" : "s") · \(peers) peer\(peers == 1 ? "" : "s")"
    }
    var isActive: Bool { links.values.contains { $0.characteristic != nil } }

    func canSend(in c: ConversationID) -> Bool { c.network == .bitchat && isActive }

    func send(_ text: String, in c: ConversationID) -> UnifiedMessage? {
        guard canSend(in: c) else { return nil }
        let me = engine.myPeerID.id
        switch c.scope {
        case .room:
            guard let id = engine.sendPublic(text) else { return nil }
            return UnifiedMessage(id: id, conversation: c, senderName: engine.nickname, senderKey: me, text: text,
                                  timestamp: Date(), outgoing: true, state: .sent)
        case .direct:
            let id = engine.sendPrivate(text, to: PeerID(str: c.key))
            return UnifiedMessage(id: id, conversation: c, senderName: engine.nickname, senderKey: me, text: text,
                                  timestamp: Date(), outgoing: true, state: .sending)
        }
    }

    func markRead(_ c: ConversationID) {
        guard c.network == .bitchat, c.scope == .direct else { return }
        // Read receipts are sent for the last received message only (cheap on a watch).
        // The app model passes the message ID via sendReadReceipt when the thread opens.
    }

    func sendReadReceipt(messageID: String, peerKey: String) {
        engine.sendReadReceipt(for: messageID, to: PeerID(str: peerKey))
    }

    func sendChannelTunnel(_ envelope: Data, ttl: UInt8) { engine.sendChannelTunnel(envelope, ttl: ttl) }

    // MARK: engine events → unified model

    private func handle(_ e: BitchatEngineEvent) {
        guard let sink = sink else { return }
        switch e {
        case .peerUpdated(let p):
            sink.transport(self, didUpdate: UnifiedPerson(network: .bitchat, key: p.peerID.id, displayName: p.nickname,
                detail: "\(p.isDirect ? "direct" : "via mesh") · \(p.fingerprint.prefix(8))",
                isOnline: true, isFavorite: false, canMessage: true, secureSession: p.sessionEstablished))
        case .peerLost(let pid):
            sink.transport(self, didUpdate: UnifiedPerson(network: .bitchat, key: pid.id, displayName: pid.id.prefix(8).description,
                detail: "offline", isOnline: false, isFavorite: false, canMessage: false))
        case .publicMessage(let id, let from, let nick, let text, let ts):
            sink.transport(self, didReceive: UnifiedMessage(id: id, conversation: .room(.bitchat, "public"), senderName: nick,
                senderKey: from.id, text: text, timestamp: ts, outgoing: false, state: .received))
        case .privateMessage(let id, let from, let nick, let text, let ts):
            sink.transport(self, didReceive: UnifiedMessage(id: id, conversation: .direct(.bitchat, from.id), senderName: nick,
                senderKey: from.id, text: text, timestamp: ts, outgoing: false, state: .received, via: "Noise"))
        case .delivered(let id, _): sink.transport(self, message: id, didChangeTo: .delivered)
        case .read(let id, _): sink.transport(self, message: id, didChangeTo: .read)
        case .sessionEstablished, .sessionFailed: sink.transportStatusDidChange(self)
        case .channelTunnel(let payload, _, let ttl): onChannelTunnel?(payload, ttl)
        case .log(let s): SecureLogger.debug("bitchat: \(s)", category: .session)
        }
    }

    // MARK: writes

    private func writeLimit(_ link: String?) -> Int {
        let ls = link.flatMap { links[$0] }.map { [$0] } ?? Array(links.values)
        let limits = ls.map { $0.peripheral.maximumWriteValueLength(for: .withoutResponse) }
        return max(20, limits.min() ?? 182)
    }

    private func write(_ frame: Data, link: String?) {
        let targets = link.map { [$0] } ?? Array(links.keys)
        for id in targets {
            guard var l = links[id], let ch = l.characteristic else { continue }
            if ch.properties.contains(.writeWithoutResponse) {
                if l.backlog.isEmpty && l.peripheral.canSendWriteWithoutResponse {
                    l.peripheral.writeValue(frame, for: ch, type: .withoutResponse)
                } else {
                    l.backlog.append(frame)
                    if l.backlog.count > 64 { l.backlog.removeFirst() } // bounded; announces are periodic anyway
                }
            } else {
                l.peripheral.writeValue(frame, for: ch, type: .withResponse)
            }
            links[id] = l
        }
    }

    // MARK: BLELinkHandler

    func linkConnected(_ peripheral: CBPeripheral) {
        links[peripheral.identifier.uuidString] = Link(peripheral: peripheral)
        peripheral.discoverServices([BLEServiceIDs.bitchat])
        sink?.transportStatusDidChange(self)
    }

    func linkDisconnected(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier.uuidString
        links.removeValue(forKey: id)
        engine.linkDown(id)
        sink?.transportStatusDidChange(self)
    }
}

extension BitchatTransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let s = peripheral.services?.first(where: { $0.uuid == BLEServiceIDs.bitchat }) else { return }
            peripheral.discoverCharacteristics([BLEServiceIDs.bitchatCharacteristic], for: s)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier.uuidString
            guard let ch = service.characteristics?.first(where: { $0.uuid == BLEServiceIDs.bitchatCharacteristic }) else { return }
            links[id]?.characteristic = ch
            if ch.properties.contains(.notify) { peripheral.setNotifyValue(true, for: ch) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.isNotifying else { return }
            engine.linkUp(peripheral.identifier.uuidString)   // sends our announce on this link
            sink?.transportStatusDidChange(self)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier.uuidString
            guard error == nil, let chunk = characteristic.value, !chunk.isEmpty, var l = links[id] else { return }
            let result = l.assembler.append(chunk)
            links[id] = l
            for frame in result.frames { engine.receive(frame: frame, from: id) }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier.uuidString
            guard var l = links[id], let ch = l.characteristic else { return }
            while !l.backlog.isEmpty && peripheral.canSendWriteWithoutResponse {
                peripheral.writeValue(l.backlog.removeFirst(), for: ch, type: .withoutResponse)
            }
            links[id] = l
        }
    }
}
#endif
