//
// TesterLinks.swift — bitchat Mac tester (Swift 5.0 compatible)
//
// Platform-independent helpers used by the AppKit shell (Sources/App) so the
// logic behind the UI can be checked on Linux (Tests/Linux):
//   * BTLinkTable       — BLE link bookkeeping (per-link write limit, broadcast
//                         targets, the "all links" limit used for fragmenting)
//   * BTWriteChunker    — split a frame into ATT-sized writes/notifications
//   * BTLengthFramer    — LAN stream framing: 4-byte big-endian length + envelope
//   * BTChannelAdvert   — channel-ID list for Bonjour TXT / MPC discoveryInfo and
//                         the "do we share a channel / who dials" rules
//   * BTLogExport       — text rendering of the packet log for "Export log…"
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Known BLE links. Link IDs: "p:<central UUID>" (a central — e.g. the watch —
/// subscribed to our peripheral) and "c:<peripheral UUID>" (a peripheral we
/// connected to as a central).
final class BTLinkTable {
    static let defaultLimit = 182   // safe BLE 4.2 DLE payload; upstream default
    static let minLimit = 20        // ATT_MTU 23 - 3

    private(set) var limits = [String: Int]()

    var ids: [String] { return limits.keys.sorted() }
    var isEmpty: Bool { return limits.isEmpty }

    func add(_ id: String, writeLimit: Int) { limits[id] = max(BTLinkTable.minLimit, writeLimit) }
    @discardableResult func remove(_ id: String) -> Bool { return limits.removeValue(forKey: id) != nil }
    func contains(_ id: String) -> Bool { return limits[id] != nil }

    /// Fragment threshold: the link's own limit, or the smallest across all links for a broadcast.
    func limit(for link: String?) -> Int {
        if let l = link, let v = limits[l] { return v }
        return limits.values.min() ?? BTLinkTable.defaultLimit
    }

    /// Where a frame goes: one link, or every link except the one it came in on.
    func targets(link: String?, except: String?) -> [String] {
        if let l = link { return limits[l] != nil ? [l] : [] }
        return ids.filter { $0 != except }
    }

    static func isPeripheralSide(_ id: String) -> Bool { return id.hasPrefix("p:") }
    static func isCentralSide(_ id: String) -> Bool { return id.hasPrefix("c:") }
}

enum BTWriteChunker {
    /// Splits `frame` into pieces no longer than `limit` (≥ 20). The receiver's
    /// BTStreamAssembler / upstream NotificationStreamAssembler joins them back.
    static func chunks(_ frame: [UInt8], limit: Int) -> [[UInt8]] {
        let n = max(BTLinkTable.minLimit, limit)
        if frame.count <= n { return [frame] }
        var out = [[UInt8]]()
        var o = 0
        while o < frame.count {
            out.append(Array(frame[o..<min(o + n, frame.count)]))
            o += n
        }
        return out
    }
}

/// 4-byte big-endian length prefix + one channel envelope (same as iOSBridge LANChannelTransport).
final class BTLengthFramer {
    static let maxFrame = 4096
    private var buf = [UInt8]()
    private(set) var broken = false

    static func frame(_ envelope: [UInt8]) -> [UInt8]? {
        guard !envelope.isEmpty, envelope.count <= maxFrame else { return nil }
        let n = envelope.count
        return [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)] + envelope
    }

    /// Feeds received bytes; returns complete envelopes. A bad length marks the stream broken (caller drops it).
    func append(_ chunk: [UInt8]) -> [[UInt8]] {
        if broken { return [] }
        buf += chunk
        var out = [[UInt8]]()
        while buf.count >= 4 {
            let len = Int(buf[0]) << 24 | Int(buf[1]) << 16 | Int(buf[2]) << 8 | Int(buf[3])
            guard len > 0, len <= BTLengthFramer.maxFrame else { broken = true; buf.removeAll(); return out }
            guard buf.count >= 4 + len else { break }
            out.append(Array(buf[4..<(4 + len)]))
            buf.removeFirst(4 + len)
        }
        return out
    }
}

enum BTChannelAdvert {
    static let maxAdvertised = 16

    /// "v=1", "c=<csv>" — HKDF-derived channel IDs only, never the codes.
    static func info(_ channelIDs: [String]) -> [String: String] {
        return ["v": "1", "c": channelIDs.sorted().prefix(maxAdvertised).joined(separator: ",")]
    }

    static func parse(_ csv: String?) -> Set<String> {
        guard let c = csv else { return [] }
        return Set(c.split(separator: ",").map { String($0).lowercased() }.filter { $0.count == 16 })
    }

    static func shares(_ info: [String: String]?, with mine: [String]) -> Bool {
        guard let i = info, i["v"] == "1" else { return false }
        return !parse(i["c"]).isDisjoint(with: mine.map { $0.lowercased() })
    }

    /// Only the lexicographically smaller name dials/invites, so a pair connects once.
    static func shouldDial(me: String, them: String) -> Bool { return me < them }
}

enum BTLogExport {
    static func render(_ entries: [BTLogEntry], node: String, generated: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        var s = "# bitchat Mac tester packet log\n# node \(node)\n# exported \(f.string(from: generated))\n# entries \(entries.count)\n"
        for e in entries { s += e.line() + "\n" }
        return s
    }
}
