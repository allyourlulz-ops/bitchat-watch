//
// MeshCoreSession.swift — bitchat-watch
//
// Independent implementation of the MeshCore *companion radio* protocol over
// BLE (Nordic UART service; one protocol frame per write / notification), as
// documented in meshcore-dev/MeshCore docs/companion_protocol.md (MIT). Scope:
// self info, contacts, contact (DM) messages, channel messages, channel list.
// All multi-byte integers little-endian.
//
// Flow: APP_START → DEVICE_QUERY(app ver 3) → SET_DEVICE_TIME → GET_CONTACTS →
//       GET_CHANNEL 0..max-1 → SYNC_NEXT_MESSAGE until NO_MORE_MSGS;
//       on PUSH 0x83 (MSG_WAITING) sync again. One command in flight at a time.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum MeshCoreBLE {
    static let service = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    static let rx = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"   // app → radio (write)
    static let tx = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"   // radio → app (notify)
}

enum MCCmd: UInt8 {
    case appStart = 1, sendTxtMsg = 2, sendChannelTxtMsg = 3, getContacts = 4, getDeviceTime = 5,
         setDeviceTime = 6, sendSelfAdvert = 7, syncNextMessage = 10, deviceQuery = 22, getChannel = 31
}

enum MCResp: UInt8 {
    case ok = 0, err = 1, contactsStart = 2, contact = 3, endOfContacts = 4, selfInfo = 5, sent = 6,
         contactMsgRecv = 7, channelMsgRecv = 8, currTime = 9, noMoreMessages = 10, deviceInfo = 13,
         contactMsgRecvV3 = 16, channelMsgRecvV3 = 17, channelInfo = 18
    // pushes
    case pushAdvert = 0x80, pushPathUpdated = 0x81, pushSendConfirmed = 0x82, pushMsgWaiting = 0x83,
         pushLogRxData = 0x88, pushNewAdvert = 0x8A
}

struct MCContact: Equatable {
    let publicKey: Data       // 32 bytes
    var type: UInt8
    var flags: UInt8
    var outPathLen: Int8
    var name: String
    var lastAdvert: UInt32
    var prefixHex: String { publicKey.prefix(6).hexEncodedString() }
}

struct MCChannelInfo: Equatable {
    let index: UInt8
    let name: String
}

struct MCSelfInfo: Equatable {
    let publicKey: Data
    let name: String
}

struct MCTextMessage: Equatable {
    enum Origin: Equatable { case contact(prefix: Data), channel(index: UInt8) }
    let origin: Origin
    let pathLen: UInt8
    let txtType: UInt8
    let timestamp: UInt32
    let text: String
    let snr: Double?
}

enum MCEvent: Equatable {
    case selfInfo(MCSelfInfo)
    case contact(MCContact)
    case contactsDone
    case channel(MCChannelInfo)
    case message(MCTextMessage)
    case sent(expectedAck: UInt32, timeoutMs: UInt32)
    case sendConfirmed(ack: UInt32, roundTripMs: UInt32)
    case error(code: UInt8)
    case advert(publicKey: Data)
    case ready
}

enum MeshCoreCodec {
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)] }
    static func readLE32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24
    }
    static func cString(_ b: ArraySlice<UInt8>) -> String {
        let bytes = b.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func appStart(appName: String) -> Data { Data([MCCmd.appStart.rawValue, 0, 0, 0, 0, 0, 0, 0] + Array(appName.utf8.prefix(32))) }
    static func deviceQuery(appTargetVersion: UInt8 = 3) -> Data { Data([MCCmd.deviceQuery.rawValue, appTargetVersion]) }
    static func setDeviceTime(_ t: UInt32) -> Data { Data([MCCmd.setDeviceTime.rawValue] + le32(t)) }
    static func getContacts() -> Data { Data([MCCmd.getContacts.rawValue]) }
    static func getChannel(_ i: UInt8) -> Data { Data([MCCmd.getChannel.rawValue, i]) }
    static func syncNext() -> Data { Data([MCCmd.syncNextMessage.rawValue]) }

    /// CMD_SEND_TXT_MSG: txt_type(0 plain), attempt, timestamp(4), pubkey prefix(6), text
    static func sendText(toPrefix prefix: Data, text: String, timestamp: UInt32, attempt: UInt8 = 0) -> Data {
        Data([MCCmd.sendTxtMsg.rawValue, 0, attempt] + le32(timestamp) + Array(prefix.prefix(6)) + Array(ChannelCodec.truncatedUTF8(text, maxBytes: 133)))
    }

    /// CMD_SEND_CHANNEL_TXT_MSG: txt_type(0), channel index, timestamp(4), text
    static func sendChannelText(channel: UInt8, text: String, timestamp: UInt32) -> Data {
        Data([MCCmd.sendChannelTxtMsg.rawValue, 0, channel] + le32(timestamp) + Array(ChannelCodec.truncatedUTF8(text, maxBytes: 133)))
    }

    static func decode(_ frame: Data) -> MCEvent? {
        let b = [UInt8](frame)
        guard let code = b.first else { return nil }
        switch MCResp(rawValue: code) {
        case .selfInfo?:
            guard b.count >= 58 else { return nil }
            return .selfInfo(MCSelfInfo(publicKey: Data(b[4..<36]), name: cString(b[58...])))
        case .contact?:
            // code, pubkey(32), type, flags, out_path_len, out_path(64), name(32), last_advert(4), lat(4), lon(4), lastmod(4)
            guard b.count >= 1 + 32 + 3 + 64 + 32 + 4 else { return nil }
            let nameStart = 1 + 32 + 3 + 64
            return .contact(MCContact(publicKey: Data(b[1..<33]), type: b[33], flags: b[34],
                                      outPathLen: Int8(bitPattern: b[35]),
                                      name: cString(b[nameStart ..< nameStart + 32]),
                                      lastAdvert: readLE32(b, nameStart + 32)))
        case .endOfContacts?:
            return .contactsDone
        case .channelInfo?:
            guard b.count >= 34 else { return nil }
            return .channel(MCChannelInfo(index: b[1], name: cString(b[2..<34])))
        case .contactMsgRecv?, .contactMsgRecvV3?:
            var i = 1
            var snr: Double? = nil
            if code == MCResp.contactMsgRecvV3.rawValue { guard b.count > 4 else { return nil }; snr = Double(Int8(bitPattern: b[1])) / 4; i = 4 }
            guard b.count >= i + 12 else { return nil }
            let prefix = Data(b[i ..< i + 6]); i += 6
            let pathLen = b[i], txtType = b[i + 1]; i += 2
            let ts = readLE32(b, i); i += 4
            if txtType == 2 { i += 4 } // signed: 4-byte signature prefix
            guard i <= b.count else { return nil }
            return .message(MCTextMessage(origin: .contact(prefix: prefix), pathLen: pathLen, txtType: txtType,
                                          timestamp: ts, text: String(decoding: b[i...], as: UTF8.self), snr: snr))
        case .channelMsgRecv?, .channelMsgRecvV3?:
            var i = 1
            var snr: Double? = nil
            if code == MCResp.channelMsgRecvV3.rawValue { guard b.count > 4 else { return nil }; snr = Double(Int8(bitPattern: b[1])) / 4; i = 4 }
            guard b.count >= i + 7 else { return nil }
            let ch = b[i], pathLen = b[i + 1], txtType = b[i + 2]
            let ts = readLE32(b, i + 3)
            return .message(MCTextMessage(origin: .channel(index: ch), pathLen: pathLen, txtType: txtType,
                                          timestamp: ts, text: String(decoding: b[(i + 7)...], as: UTF8.self), snr: snr))
        case .sent?:
            guard b.count >= 10 else { return nil }
            return .sent(expectedAck: readLE32(b, 2), timeoutMs: readLE32(b, 6))
        case .pushSendConfirmed?:
            guard b.count >= 9 else { return nil }
            return .sendConfirmed(ack: readLE32(b, 1), roundTripMs: readLE32(b, 5))
        case .err?:
            return .error(code: b.count > 1 ? b[1] : 0)
        case .pushAdvert?, .pushNewAdvert?:
            guard b.count >= 33 else { return nil }
            return .advert(publicKey: Data(b[1..<33]))
        default:
            return nil
        }
    }
}

/// Command queue + state. The BLE layer calls `write`-closure and feeds notifications.
final class MeshCoreSession {
    var write: (Data) -> Void = { _ in }
    var onEvent: (MCEvent) -> Void = { _ in }
    var now: () -> Date = { Date() }
    var appName = "bitchat-watch"

    private(set) var selfInfo: MCSelfInfo?
    private(set) var contacts: [Data: MCContact] = [:]   // keyed by 6-byte prefix
    private(set) var channels: [UInt8: MCChannelInfo] = [:]
    private(set) var maxChannels: UInt8 = 8

    private var queue: [(cmd: Data, expect: Set<UInt8>)] = []
    private var inFlight: (cmd: Data, expect: Set<UInt8>, sentAt: Date)?
    private var syncing = false
    var commandTimeout: TimeInterval = 5

    func start() {
        queue.removeAll(); inFlight = nil
        enqueue(MeshCoreCodec.appStart(appName: appName), expect: [MCResp.selfInfo.rawValue])
        enqueue(MeshCoreCodec.deviceQuery(), expect: [MCResp.deviceInfo.rawValue, MCResp.err.rawValue])
        enqueue(MeshCoreCodec.setDeviceTime(UInt32(now().timeIntervalSince1970)), expect: [MCResp.ok.rawValue, MCResp.err.rawValue])
        enqueue(MeshCoreCodec.getContacts(), expect: [MCResp.endOfContacts.rawValue, MCResp.err.rawValue])
        // channels are fetched after contacts (max_channels comes from DEVICE_INFO);
        // the first SYNC_NEXT_MESSAGE runs once setup is complete (.ready).
    }

    func sendDirect(_ text: String, toPrefix prefix: Data) {
        enqueue(MeshCoreCodec.sendText(toPrefix: prefix, text: text, timestamp: UInt32(now().timeIntervalSince1970)),
                expect: [MCResp.sent.rawValue, MCResp.err.rawValue])
    }

    func sendChannel(_ text: String, channel: UInt8) {
        enqueue(MeshCoreCodec.sendChannelText(channel: channel, text: text, timestamp: UInt32(now().timeIntervalSince1970)),
                expect: [MCResp.sent.rawValue, MCResp.ok.rawValue, MCResp.err.rawValue])
    }

    func syncMessages() {
        guard !syncing else { return }
        syncing = true
        enqueue(MeshCoreCodec.syncNext(), expect: Set([MCResp.noMoreMessages, .contactMsgRecv, .contactMsgRecvV3,
                                                      .channelMsgRecv, .channelMsgRecvV3, .err].map { $0.rawValue }))
    }

    /// Periodic: time out a stuck command.
    func tick() {
        if let f = inFlight, now().timeIntervalSince(f.sentAt) > commandTimeout {
            if f.cmd.first == MCCmd.syncNextMessage.rawValue { syncing = false }
            inFlight = nil
            pump()
        }
    }

    func handleNotification(_ frame: Data) {
        guard let code = frame.first else { return }
        if code == MCResp.deviceInfo.rawValue, frame.count >= 4 {
            maxChannels = max(1, min(40, frame[frame.startIndex + 3]))
        }
        let event = MeshCoreCodec.decode(frame)
        if let event = event {
            switch event {
            case .selfInfo(let s): selfInfo = s
            case .contact(let c): contacts[c.publicKey.prefix(6)] = c
            case .channel(let ch): if !ch.name.isEmpty { channels[ch.index] = ch }
            default: break
            }
            onEvent(event)
        }
        if code == MCResp.pushMsgWaiting.rawValue { syncMessages() }
        // command completion
        if let f = inFlight, f.expect.contains(code) {
            let cmd = f.cmd.first
            inFlight = nil
            if cmd == MCCmd.syncNextMessage.rawValue {
                syncing = false
                if code != MCResp.noMoreMessages.rawValue && code != MCResp.err.rawValue { syncMessages() } // keep draining
            }
            if cmd == MCCmd.getContacts.rawValue {
                syncing = false
                for i in 0..<maxChannels { enqueue(MeshCoreCodec.getChannel(i), expect: [MCResp.channelInfo.rawValue, MCResp.err.rawValue]) }
            }
            if cmd == MCCmd.getChannel.rawValue, f.cmd.count > 1, f.cmd[f.cmd.startIndex + 1] == maxChannels - 1 {
                onEvent(.ready)
                syncMessages()
            }
            pump()
        }
    }

    private func enqueue(_ cmd: Data, expect: Set<UInt8>) {
        queue.append((cmd, expect))
        pump()
    }

    private func pump() {
        guard inFlight == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        inFlight = (next.cmd, next.expect, now())
        write(next.cmd)
    }

    func contactName(prefix: Data) -> String {
        contacts[prefix.prefix(6)]?.name ?? prefix.prefix(6).hexEncodedString()
    }
}
