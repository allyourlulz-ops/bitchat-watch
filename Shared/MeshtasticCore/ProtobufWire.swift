//
// ProtobufWire.swift — bitchat-watch
//
// Minimal hand-written protobuf wire-format reader/writer (varint, fixed32,
// fixed64, length-delimited). Enough for the handful of Meshtastic messages
// the watch needs, without pulling SwiftProtobuf + generated code into a
// watch binary. Field numbers follow meshtastic/protobufs (GPL-3.0); see
// MeshtasticMessages.swift and NOTICE. Unknown fields are skipped, so newer
// firmware with extra fields still decodes.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum ProtoWireType: UInt8 {
    case varint = 0, fixed64 = 1, lengthDelimited = 2, startGroup = 3, endGroup = 4, fixed32 = 5
}

struct ProtoWriter {
    private(set) var data = Data()

    mutating func varint(_ v: UInt64) {
        var v = v
        while v >= 0x80 { data.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }
        data.append(UInt8(v))
    }
    mutating func tag(_ field: Int, _ type: ProtoWireType) { varint(UInt64(field << 3) | UInt64(type.rawValue)) }

    mutating func uint(_ field: Int, _ v: UInt64, omitZero: Bool = true) {
        if omitZero && v == 0 { return }
        tag(field, .varint); varint(v)
    }
    mutating func int32(_ field: Int, _ v: Int32) {
        if v == 0 { return }
        tag(field, .varint); varint(UInt64(bitPattern: Int64(v))) // negative int32 = 10-byte varint
    }
    mutating func bool(_ field: Int, _ v: Bool) { if v { uint(field, 1) } }
    mutating func fixed32(_ field: Int, _ v: UInt32, omitZero: Bool = true) {
        if omitZero && v == 0 { return }
        tag(field, .fixed32)
        var le = v.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    mutating func bytes(_ field: Int, _ d: Data, omitEmpty: Bool = true) {
        if omitEmpty && d.isEmpty { return }
        tag(field, .lengthDelimited); varint(UInt64(d.count)); data.append(d)
    }
    mutating func string(_ field: Int, _ s: String) { bytes(field, Data(s.utf8)) }
    mutating func message(_ field: Int, _ m: Data) { bytes(field, m, omitEmpty: false) }
}

struct ProtoField {
    let number: Int
    let type: ProtoWireType
    let varint: UInt64      // varint / fixed32 / fixed64 value
    let bytes: Data         // length-delimited payload

    var uint32: UInt32 { UInt32(truncatingIfNeeded: varint) }
    var int32: Int32 { Int32(truncatingIfNeeded: Int64(bitPattern: varint)) }
    var bool: Bool { varint != 0 }
    var float: Float { Float(bitPattern: UInt32(truncatingIfNeeded: varint)) }
    var string: String { String(decoding: bytes, as: UTF8.self) }
}

enum ProtoReader {
    struct Malformed: Error {}

    static func fields(_ data: Data) throws -> [ProtoField] {
        let b = [UInt8](data)
        var i = 0
        var out: [ProtoField] = []
        func readVarint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard i < b.count, shift < 64 else { throw Malformed() }
                let byte = b[i]; i += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }
        while i < b.count {
            let key = try readVarint()
            let number = Int(key >> 3)
            guard number > 0, let type = ProtoWireType(rawValue: UInt8(key & 7)) else { throw Malformed() }
            switch type {
            case .varint:
                out.append(ProtoField(number: number, type: type, varint: try readVarint(), bytes: Data()))
            case .fixed32:
                guard i + 4 <= b.count else { throw Malformed() }
                let v = UInt64(b[i]) | UInt64(b[i+1]) << 8 | UInt64(b[i+2]) << 16 | UInt64(b[i+3]) << 24
                i += 4
                out.append(ProtoField(number: number, type: type, varint: v, bytes: Data()))
            case .fixed64:
                guard i + 8 <= b.count else { throw Malformed() }
                var v: UInt64 = 0
                for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }
                i += 8
                out.append(ProtoField(number: number, type: type, varint: v, bytes: Data()))
            case .lengthDelimited:
                let len = Int(try readVarint())
                guard len >= 0, i + len <= b.count else { throw Malformed() }
                out.append(ProtoField(number: number, type: type, varint: 0, bytes: Data(b[i ..< i + len])))
                i += len
            case .startGroup, .endGroup:
                throw Malformed() // groups are not used by Meshtastic
            }
        }
        return out
    }
}
