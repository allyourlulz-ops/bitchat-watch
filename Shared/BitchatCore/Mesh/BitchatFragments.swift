//
// BitchatFragments.swift — bitchat-watch
//
// Fragmentation compatible with upstream bitchat (BLEOutboundFragmentPlanner /
// BLEFragmentAssemblyBuffer @ 04995f68):
//   fragment payload = fragmentID(8) | index(UInt16 BE) | total(UInt16 BE) | originalType(1) | chunk
//   the chunks concatenate to the full *encoded* original packet (BinaryProtocol bytes).
// Fragment packets carry the original sender, timestamp, TTL and (for directed
// traffic) recipient, are unsigned, and use MessageType.fragment (0x20).
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum BitchatFragmenter {
    static let fragmentIDLength = 8
    static let headerLength = 8 + 2 + 2 + 1
    /// Android receivers reject fragment sets above 256 (see upstream planner).
    static let maxFragments = 256
    static let minimumChunk = 64

    /// Splits `packet` into fragment packets when its encoded size exceeds `linkLimit`.
    /// Returns `nil` when no fragmentation is needed. `linkLimit` is the per-write
    /// size (CBPeripheral.maximumWriteValueLength(for: .withoutResponse)).
    static func fragmentsIfNeeded(_ packet: BitchatPacket, pad: Bool, linkLimit: Int,
                                  fragmentID: Data = randomFragmentID()) -> [BitchatPacket]? {
        guard let full = packet.toBinaryData(padding: pad) else { return nil }
        guard full.count > linkLimit else { return nil }
        // upstream: fragmentChunkSize(forLinkLimit:) = max(64, limit - (13+8+8+13))
        let chunk = max(minimumChunk, min(TransportConfig.bleDefaultFragmentSize, linkLimit - (13 + 8 + 8 + 13)))
        return makeFragments(full: full, original: packet, chunk: chunk, fragmentID: fragmentID)
    }

    static func makeFragments(full: Data, original packet: BitchatPacket, chunk: Int,
                              fragmentID: Data = randomFragmentID()) -> [BitchatPacket]? {
        precondition(fragmentID.count == fragmentIDLength)
        var chunks: [Data] = []
        var offset = 0
        while offset < full.count {
            let end = min(offset + chunk, full.count)
            chunks.append(Data(full[full.startIndex + offset ..< full.startIndex + end]))
            offset = end
        }
        guard !chunks.isEmpty, chunks.count <= maxFragments else { return nil }
        return chunks.enumerated().map { index, data in
            var payload = Data()
            payload.append(fragmentID)
            payload.append(UInt8(index >> 8)); payload.append(UInt8(index & 0xff))
            payload.append(UInt8(chunks.count >> 8)); payload.append(UInt8(chunks.count & 0xff))
            payload.append(packet.type)
            payload.append(data)
            return BitchatPacket(type: MessageType.fragment.rawValue, senderID: packet.senderID,
                                 recipientID: packet.recipientID, timestamp: packet.timestamp,
                                 payload: payload, signature: nil, ttl: packet.ttl,
                                 version: packet.route?.isEmpty == false ? 2 : 1,
                                 route: packet.route, isRSR: packet.isRSR)
        }
    }

    static func randomFragmentID() -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<fragmentIDLength).map { _ in UInt8.random(in: 0...255, using: &g) })
    }
}

/// Bounded reassembly buffer. Not thread-safe: drive it from one queue.
struct BitchatFragmentReassembler {
    struct Key: Hashable { let sender: Data; let fragmentID: Data }
    private struct Assembly {
        var total: Int
        var originalType: UInt8
        var parts: [Int: Data]
        var bytes: Int
        var started: Date
    }
    private var assemblies: [Key: Assembly] = [:]
    var maxInFlight = 32
    var maxBytesPerAssembly = 256 * 1024
    var lifetime: TimeInterval = TransportConfig.bleFragmentLifetimeSeconds

    enum Result {
        case incomplete
        case complete(BitchatPacket)
        case rejected(String)
    }

    mutating func add(_ fragment: BitchatPacket, now: Date = Date()) -> Result {
        expire(now: now)
        let p = fragment.payload
        guard p.count > BitchatFragmenter.headerLength else { return .rejected("short fragment") }
        let b = [UInt8](p)
        let fid = Data(b[0..<8])
        let index = Int(b[8]) << 8 | Int(b[9])
        let total = Int(b[10]) << 8 | Int(b[11])
        let type = b[12]
        guard total > 0, total <= BitchatFragmenter.maxFragments, index < total else { return .rejected("bad index") }
        let chunk = Data(b[13...])
        let key = Key(sender: fragment.senderID, fragmentID: fid)
        var a = assemblies[key] ?? {
            Assembly(total: total, originalType: type, parts: [:], bytes: 0, started: now)
        }()
        if assemblies[key] == nil && assemblies.count >= maxInFlight {
            // drop the oldest assembly to bound memory
            if let oldest = assemblies.min(by: { $0.value.started < $1.value.started })?.key {
                assemblies.removeValue(forKey: oldest)
            }
        }
        guard a.total == total, a.originalType == type else { return .rejected("inconsistent set") }
        if a.parts[index] == nil {
            a.parts[index] = chunk
            a.bytes += chunk.count
        }
        guard a.bytes <= maxBytesPerAssembly else {
            assemblies.removeValue(forKey: key)
            return .rejected("assembly too large")
        }
        if a.parts.count == a.total {
            assemblies.removeValue(forKey: key)
            var full = Data(capacity: a.bytes)
            for i in 0..<a.total { full.append(a.parts[i]!) }
            guard let packet = BinaryProtocol.decode(full) else { return .rejected("reassembled frame failed to decode") }
            return .complete(packet)
        }
        assemblies[key] = a
        return .incomplete
    }

    mutating func expire(now: Date) {
        assemblies = assemblies.filter { now.timeIntervalSince($0.value.started) < lifetime }
    }

    var inFlightCount: Int { assemblies.count }
}
