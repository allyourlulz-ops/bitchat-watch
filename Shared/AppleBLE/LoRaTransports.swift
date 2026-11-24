//
// LoRaTransports.swift — bitchat-watch
//
// MeshtasticTransport and MeshCoreTransport: BLE central adapters for the
// user's chosen LoRa radio. Only one LoRa radio is connected at a time (the
// one picked on the Radios screen; ConnectionPlanner reserves it a slot).
//
// Pairing: both firmwares normally require BLE bonding with a PIN (Meshtastic
// shows a random PIN or uses 123456; MeshCore companion default 123456). Core
// Bluetooth triggers the system pairing sheet when an encrypted characteristic
// is first accessed. Whether watchOS presents that sheet for third-party apps
// on every watch model is UNVERIFIED — see README "Known gaps".
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

// MARK: - Meshtastic

@MainActor
final class MeshtasticTransport: NSObject, ChatTransport, BLELinkHandler {
    let radioKind: RadioKind = .meshtastic
    let network: NetworkKind = .meshtastic
    weak var sink: TransportSink?
    let session = MeshtasticSession()
    private var peripheral: CBPeripheral?
    private var toRadio: CBCharacteristic?
    private var fromRadio: CBCharacteristic?
    private var fromNum: CBCharacteristic?
    private var reading = false
    private var pendingRead = false
    private var pendingIDs: [UInt32: String] = [:]
    private var radioName = "radio"

    override init() {
        super.init()
        session.write = { [weak self] data in
            guard let self = self, let p = self.peripheral, let ch = self.toRadio else { return }
            p.writeValue(data, for: ch, type: .withResponse)
        }
        session.requestRead = { [weak self] in self?.readNext() }
        session.onEvent = { [weak self] e in self?.handle(e) }
    }

    var statusText: String {
        guard peripheral != nil else { return "not connected" }
        return session.configured ? "\(radioName) · \(session.nodes.count) nodes" : "\(radioName) · syncing…"
    }
    var isActive: Bool { session.configured }

    func canSend(in c: ConversationID) -> Bool { c.network == .meshtastic && isActive }

    func send(_ text: String, in c: ConversationID) -> UnifiedMessage? {
        guard canSend(in: c) else { return nil }
        let id: UInt32
        switch c.scope {
        case .room: id = session.sendText(text, to: MeshtasticBLE.broadcastNum, channel: UInt32(c.key) ?? 0)
        case .direct:
            guard let num = UInt32(c.key.dropFirst(), radix: 16) else { return nil }
            id = session.sendText(text, to: num, channel: 0)
        }
        let localID = "mt-\(id)"
        pendingIDs[id] = localID
        return UnifiedMessage(id: localID, conversation: c, senderName: session.displayName(session.myNodeNum),
                              senderKey: String(format: "!%08x", session.myNodeNum), text: text, timestamp: Date(),
                              outgoing: true, state: .sending)
    }

    private func readNext() {
        guard let p = peripheral, let ch = fromRadio else { return }
        if reading { pendingRead = true; return }
        reading = true
        p.readValue(for: ch)
    }

    private func handle(_ e: MeshtasticEvent) {
        guard let sink = sink else { return }
        switch e {
        case .node(let n):
            guard n.num != session.myNodeNum else { return }
            let key = String(format: "!%08x", n.num)
            var detail = n.user?.shortName ?? ""
            if let h = n.hopsAway { detail += " · \(h) hop\(h == 1 ? "" : "s")" }
            if n.snr != 0 { detail += String(format: " · SNR %.1f", n.snr) }
            let heard = n.lastHeard > 0 ? Date().timeIntervalSince1970 - Double(n.lastHeard) < 2 * 3600 : false
            sink.transport(self, didUpdate: UnifiedPerson(network: .meshtastic, key: key, displayName: session.displayName(n.num),
                                                          detail: detail, isOnline: heard, isFavorite: n.isFavorite, canMessage: true))
        case .channel(let c):
            guard c.role != .disabled else { return }
            sink.transport(self, didUpdate: RoomInfo(conversation: .room(.meshtastic, String(c.index)),
                                                     title: "\(c.name.isEmpty ? (c.index == 0 ? "Primary" : "Ch \(c.index)") : c.name) · MT"))
        case .text(let m):
            let conv: ConversationID = m.isDirect ? .direct(.meshtastic, String(format: "!%08x", m.from))
                                                  : .room(.meshtastic, String(m.channel))
            sink.transport(self, didReceive: UnifiedMessage(id: "mt-\(m.from)-\(m.packetID)", conversation: conv,
                senderName: session.displayName(m.from), senderKey: String(format: "!%08x", m.from), text: m.text,
                timestamp: m.time, outgoing: false, state: .received, via: m.snr != 0 ? String(format: "SNR %.1f", m.snr) : nil))
        case .ack(let pid, let ok, _):
            if let local = pendingIDs.removeValue(forKey: pid) { sink.transport(self, message: local, didChangeTo: ok ? .delivered : .failed) }
        case .configComplete, .myNode, .rebooted:
            sink.transportStatusDidChange(self)
        }
    }

    func linkConnected(_ p: CBPeripheral) {
        peripheral = p
        radioName = p.name ?? "Meshtastic"
        p.discoverServices([BLEServiceIDs.meshtastic])
        sink?.transportStatusDidChange(self)
    }

    func linkDisconnected(_ p: CBPeripheral) {
        guard p == peripheral else { return }
        peripheral = nil; toRadio = nil; fromRadio = nil; fromNum = nil; reading = false
        sink?.transportStatusDidChange(self)
    }
}

extension MeshtasticTransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let s = p.services?.first(where: { $0.uuid == BLEServiceIDs.meshtastic }) else { return }
            p.discoverCharacteristics([CBUUID(string: MeshtasticBLE.toRadio), CBUUID(string: MeshtasticBLE.fromRadio),
                                       CBUUID(string: MeshtasticBLE.fromNum)], for: s)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for ch in service.characteristics ?? [] {
                switch ch.uuid {
                case CBUUID(string: MeshtasticBLE.toRadio): toRadio = ch
                case CBUUID(string: MeshtasticBLE.fromRadio): fromRadio = ch
                case CBUUID(string: MeshtasticBLE.fromNum): fromNum = ch
                default: break
                }
            }
            guard toRadio != nil, fromRadio != nil else { return }
            if let fn = fromNum { p.setNotifyValue(true, for: fn) }   // may trigger pairing
            session.start()
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if ch.uuid == CBUUID(string: MeshtasticBLE.fromNum) { session.fromNumNotified(); return }
            guard ch.uuid == CBUUID(string: MeshtasticBLE.fromRadio) else { return }
            reading = false
            if error != nil { return }
            let more = session.handleFromRadio(ch.value ?? Data())
            if more || pendingRead { pendingRead = false; readNext() }
        }
    }
}

// MARK: - MeshCore

@MainActor
final class MeshCoreTransport: NSObject, ChatTransport, BLELinkHandler {
    let radioKind: RadioKind = .meshcore
    let network: NetworkKind = .meshcore
    weak var sink: TransportSink?
    let session = MeshCoreSession()
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tick: Timer?
    private var ready = false
    private var pendingSends: [String] = []      // local IDs awaiting RESP_CODE_SENT, FIFO
    private var ackToLocal: [UInt32: String] = [:]

    override init() {
        super.init()
        session.write = { [weak self] d in
            guard let self = self, let p = self.peripheral, let ch = self.rx else { return }
            p.writeValue(d, for: ch, type: .withResponse)
        }
        session.onEvent = { [weak self] e in self?.handle(e) }
        tick = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.tick() }
        }
    }

    var statusText: String {
        guard peripheral != nil else { return "not connected" }
        let name = session.selfInfo?.name ?? peripheral?.name ?? "MeshCore"
        return ready ? "\(name) · \(session.contacts.count) contacts" : "\(name) · syncing…"
    }
    var isActive: Bool { ready }

    func canSend(in c: ConversationID) -> Bool { c.network == .meshcore && ready }

    func send(_ text: String, in c: ConversationID) -> UnifiedMessage? {
        guard canSend(in: c) else { return nil }
        switch c.scope {
        case .room: session.sendChannel(text, channel: UInt8(c.key) ?? 0)
        case .direct:
            guard let prefix = Data(hexString: c.key) else { return nil }
            session.sendDirect(text, toPrefix: prefix)
        }
        let local = "mc-\(UUID().uuidString)"
        pendingSends.append(local)
        return UnifiedMessage(id: local, conversation: c, senderName: session.selfInfo?.name ?? "me", senderKey: "me",
                              text: text, timestamp: Date(), outgoing: true, state: .sending)
    }

    private func handle(_ e: MCEvent) {
        guard let sink = sink else { return }
        switch e {
        case .contact(let c):
            sink.transport(self, didUpdate: UnifiedPerson(network: .meshcore, key: c.prefixHex, displayName: c.name,
                detail: c.outPathLen < 0 ? "flood" : "\(c.outPathLen) hop\(c.outPathLen == 1 ? "" : "s")",
                isOnline: Date().timeIntervalSince1970 - Double(c.lastAdvert) < 6 * 3600, isFavorite: false,
                canMessage: c.type == 1 /* ADV_TYPE_CHAT */))
        case .channel(let ch):
            sink.transport(self, didUpdate: RoomInfo(conversation: .room(.meshcore, String(ch.index)), title: "\(ch.name) · MC"))
        case .message(let m):
            let conv: ConversationID
            var sender: String
            var text = m.text
            switch m.origin {
            case .contact(let prefix):
                conv = .direct(.meshcore, prefix.hexEncodedString()); sender = session.contactName(prefix: prefix)
            case .channel(let idx):
                conv = .room(.meshcore, String(idx))
                // MeshCore channel text is "<name>: <message>" by convention
                if let r = text.range(of: ": ") { sender = String(text[..<r.lowerBound]); text = String(text[r.upperBound...]) } else { sender = "?" }
            }
            sink.transport(self, didReceive: UnifiedMessage(id: "mc-\(conv.key)-\(m.timestamp)-\(Data(m.text.utf8).sha256Hash().prefix(4).hexEncodedString())", conversation: conv,
                senderName: sender, senderKey: sender, text: text, timestamp: Date(timeIntervalSince1970: TimeInterval(m.timestamp)),
                outgoing: false, state: .received, via: m.snr.map { String(format: "SNR %.1f", $0) }))
        case .sent(let ack, _):
            if !pendingSends.isEmpty {
                let local = pendingSends.removeFirst()
                sink.transport(self, message: local, didChangeTo: .sent)
                if ack != 0 { ackToLocal[ack] = local }
            }
        case .sendConfirmed(let ack, _):
            if let local = ackToLocal.removeValue(forKey: ack) { sink.transport(self, message: local, didChangeTo: .delivered) }
        case .error:
            if !pendingSends.isEmpty { sink.transport(self, message: pendingSends.removeFirst(), didChangeTo: .failed) }
        case .ready:
            ready = true
            sink.transportStatusDidChange(self)
        case .selfInfo, .contactsDone, .advert:
            sink.transportStatusDidChange(self)
        }
    }

    func linkConnected(_ p: CBPeripheral) {
        peripheral = p
        p.discoverServices([BLEServiceIDs.meshcore])
    }

    func linkDisconnected(_ p: CBPeripheral) {
        guard p == peripheral else { return }
        peripheral = nil; rx = nil; ready = false
        sink?.transportStatusDidChange(self)
    }
}

extension MeshCoreTransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let s = p.services?.first(where: { $0.uuid == BLEServiceIDs.meshcore }) else { return }
            p.discoverCharacteristics([CBUUID(string: MeshCoreBLE.rx), CBUUID(string: MeshCoreBLE.tx)], for: s)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for ch in service.characteristics ?? [] {
                if ch.uuid == CBUUID(string: MeshCoreBLE.rx) { rx = ch }
                if ch.uuid == CBUUID(string: MeshCoreBLE.tx) { p.setNotifyValue(true, for: ch) }
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if ch.isNotifying && rx != nil { session.start() }   // docs: send APP_START only after notify is on
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil, ch.uuid == CBUUID(string: MeshCoreBLE.tx), let v = ch.value else { return }
            session.handleNotification(v)
        }
    }
}
#endif
