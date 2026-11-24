//
// MeshtasticMessages.swift — bitchat-watch
//
// The subset of the Meshtastic client API the watch uses, encoded/decoded with
// ProtobufWire. Field numbers are those of meshtastic/protobufs
// (meshtastic/mesh.proto, channel.proto, portnums.proto; GPL-3.0). This file
// is an independent hand implementation of that interface, not generated code.
// To switch to generated SwiftProtobuf types instead, see docs/meshtastic.md.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum MeshtasticBLE {
    static let service = "6BA1B218-15A8-461F-9FA8-5DCAE273EAFD"
    static let toRadio = "F75C76D2-129E-4DAD-A1DD-7866124401E7"
    static let fromRadio = "2C55E69E-4993-11ED-B878-0242AC120002"
    static let fromNum = "ED9DA18C-A800-4F66-A670-AA7547E34453"
    static let broadcastNum: UInt32 = 0xFFFF_FFFF
}

enum MeshtasticPort: UInt64 {
    case textMessage = 1   // TEXT_MESSAGE_APP
    case nodeInfo = 4      // NODEINFO_APP
    case routing = 5       // ROUTING_APP
}

struct MTUser: Equatable {
    var id = ""            // "!a1b2c3d4"
    var longName = ""
    var shortName = ""

    static func decode(_ d: Data) throws -> MTUser {
        var u = MTUser()
        for f in try ProtoReader.fields(d) {
            switch f.number {
            case 1: u.id = f.string
            case 2: u.longName = f.string
            case 3: u.shortName = f.string
            default: break
            }
        }
        return u
    }
}

struct MTNodeInfo: Equatable {
    var num: UInt32 = 0
    var user: MTUser? = nil
    var snr: Float = 0
    var lastHeard: UInt32 = 0
    var hopsAway: UInt32? = nil
    var isFavorite = false

    static func decode(_ d: Data) throws -> MTNodeInfo {
        var n = MTNodeInfo()
        for f in try ProtoReader.fields(d) {
            switch f.number {
            case 1: n.num = f.uint32
            case 2: n.user = try MTUser.decode(f.bytes)
            case 4: n.snr = f.float
            case 5: n.lastHeard = f.uint32
            case 9: n.hopsAway = f.uint32
            case 10: n.isFavorite = f.bool
            default: break
            }
        }
        return n
    }
}

struct MTChannel: Equatable {
    enum Role: UInt64 { case disabled = 0, primary = 1, secondary = 2 }
    var index: Int32 = 0
    var name = ""
    var role: Role = .disabled

    static func decode(_ d: Data) throws -> MTChannel {
        var c = MTChannel()
        for f in try ProtoReader.fields(d) {
            switch f.number {
            case 1: c.index = f.int32
            case 2:
                for s in try ProtoReader.fields(f.bytes) where s.number == 3 { c.name = s.string }
            case 3: c.role = Role(rawValue: f.varint) ?? .disabled
            default: break
            }
        }
        return c
    }
}

struct MTData: Equatable {
    var portnum: UInt64 = 0
    var payload = Data()
    var requestID: UInt32 = 0
    var replyID: UInt32 = 0
    var emoji: UInt32 = 0

    func encode() -> Data {
        var w = ProtoWriter()
        w.uint(1, portnum)
        w.bytes(2, payload)
        w.fixed32(6, requestID)
        w.fixed32(7, replyID)
        w.fixed32(8, emoji)
        return w.data
    }

    static func decode(_ d: Data) throws -> MTData {
        var m = MTData()
        for f in try ProtoReader.fields(d) {
            switch f.number {
            case 1: m.portnum = f.varint
            case 2: m.payload = f.bytes
            case 6: m.requestID = f.uint32
            case 7: m.replyID = f.uint32
            case 8: m.emoji = f.uint32
            default: break
            }
        }
        return m
    }
}

struct MTMeshPacket: Equatable {
    var from: UInt32 = 0
    var to: UInt32 = MeshtasticBLE.broadcastNum
    var channel: UInt32 = 0
    var decoded: MTData? = nil
    var encrypted = false
    var id: UInt32 = 0
    var rxTime: UInt32 = 0
    var rxSnr: Float = 0
    var hopLimit: UInt32 = 0
    var wantAck = false
    var rxRssi: Int32 = 0
    var hopStart: UInt32 = 0
    var pkiEncrypted = false

    func encode() -> Data {
        var w = ProtoWriter()
        w.fixed32(1, from)
        w.fixed32(2, to, omitZero: false)
        w.uint(3, UInt64(channel))
        if let d = decoded { w.message(4, d.encode()) }
        w.fixed32(6, id)
        w.uint(9, UInt64(hopLimit))
        w.bool(10, wantAck)
        return w.data
    }

    static func decode(_ d: Data) throws -> MTMeshPacket {
        var p = MTMeshPacket()
        p.to = 0
        for f in try ProtoReader.fields(d) {
            switch f.number {
            case 1: p.from = f.uint32
            case 2: p.to = f.uint32
            case 3: p.channel = f.uint32
            case 4: p.decoded = try MTData.decode(f.bytes)
            case 5: p.encrypted = true
            case 6: p.id = f.uint32
            case 7: p.rxTime = f.uint32
            case 8: p.rxSnr = f.float
            case 9: p.hopLimit = f.uint32
            case 10: p.wantAck = f.bool
            case 12: p.rxRssi = f.int32
            case 15: p.hopStart = f.uint32
            case 17: p.pkiEncrypted = f.bool
            default: break
            }
        }
        return p
    }
}

enum MTToRadio {
    static func wantConfig(_ nonce: UInt32) -> Data {
        var w = ProtoWriter(); w.uint(3, UInt64(nonce), omitZero: false); return w.data
    }
    static func packet(_ p: MTMeshPacket) -> Data {
        var w = ProtoWriter(); w.message(1, p.encode()); return w.data
    }
    static func heartbeat() -> Data {
        var w = ProtoWriter(); w.message(7, Data()); return w.data
    }
    static func disconnect() -> Data {
        var w = ProtoWriter(); w.bool(4, true); return w.data
    }
}

enum MTFromRadio: Equatable {
    case packet(MTMeshPacket)
    case myInfo(myNodeNum: UInt32)
    case nodeInfo(MTNodeInfo)
    case channel(MTChannel)
    case configComplete(UInt32)
    case rebooted
    case other(field: Int)
    case empty

    static func decode(_ d: Data) throws -> MTFromRadio {
        if d.isEmpty { return .empty }
        var result: MTFromRadio = .empty
        for f in try ProtoReader.fields(d) {
            switch f.number {
            case 1: continue // FromRadio.id
            case 2: result = .packet(try MTMeshPacket.decode(f.bytes))
            case 3:
                var num: UInt32 = 0
                for s in try ProtoReader.fields(f.bytes) where s.number == 1 { num = s.uint32 }
                result = .myInfo(myNodeNum: num)
            case 4: result = .nodeInfo(try MTNodeInfo.decode(f.bytes))
            case 7: result = .configComplete(f.uint32)
            case 8: result = .rebooted
            case 10: result = .channel(try MTChannel.decode(f.bytes))
            default: result = .other(field: f.number)
            }
        }
        return result
    }
}

/// Routing.error_reason (field 3); 0 = NONE (delivered/acked).
enum MTRouting {
    static func errorReason(_ payload: Data) -> UInt64? {
        guard let fields = try? ProtoReader.fields(payload) else { return nil }
        for f in fields where f.number == 3 { return f.varint }
        return nil
    }
}
