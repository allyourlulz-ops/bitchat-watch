//
// LANChannelTransport.swift — bitchat-watch iPhone companion
//
// Channel chat over the local network (no internet): Bonjour `_hkchan._tcp`
// via Network.framework. Each device advertises one service whose TXT record
// carries `v=1` and `c=<comma-separated channel-ID hex>` (8-byte HKDF-derived
// IDs, never the codes). Devices sharing at least one channel connect over TCP;
// to avoid duplicate pairs only the side with the lexicographically smaller
// instance name dials. Frames: 4-byte big-endian length + channel envelope
// (≤ 4096 bytes). Envelopes are already ChaCha20-Poly1305 sealed with the
// channel key, so TCP carries no extra TLS.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Network

@MainActor
final class LANChannelTransport {
    static let serviceType = "_hkchan._tcp"
    let instanceName = "hk-" + UUID().uuidString.prefix(12).lowercased()

    var onEnvelope: (Data, String) -> Void = { _, _ in }     // (envelope, linkID)
    var onPeersChanged: (Int) -> Void = { _ in }

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [String: NWConnection] = [:]
    private var buffers: [String: Data] = [:]
    private var dialed: Set<String> = []
    private var channelIDs: [String] = []
    private let queue = DispatchQueue.main

    func update(channelIDs ids: [String]) {
        guard ids != channelIDs else { return }
        channelIDs = ids
        restart()
    }

    func stop() {
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll(); buffers.removeAll(); dialed.removeAll()
        onPeersChanged(0)
    }

    func send(_ envelope: Data, except: String?) {
        guard envelope.count <= ChannelEnvelopeHeader.maxEnvelopeBytes else { return }
        var framed = Data([UInt8(envelope.count >> 24 & 0xff), UInt8(envelope.count >> 16 & 0xff),
                           UInt8(envelope.count >> 8 & 0xff), UInt8(envelope.count & 0xff)])
        framed.append(envelope)
        for (id, c) in connections where id != except {
            c.send(content: framed, completion: .contentProcessed { _ in })
        }
    }

    var peerCount: Int { connections.count }

    private func restart() {
        stop()
        guard !channelIDs.isEmpty else { return }
        do {
            let l = try NWListener(using: .tcp)
            var txt = NWTXTRecord()
            txt["v"] = "1"
            txt["c"] = channelIDs.prefix(16).joined(separator: ",")
            l.service = NWListener.Service(name: instanceName, type: Self.serviceType, domain: nil, txtRecord: txt)
            l.newConnectionHandler = { [weak self] conn in
                MainActor.assumeIsolated { self?.adopt(conn, id: "in-\(UUID().uuidString.prefix(8))") }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            SecureLogger.error("LAN listener failed: \(error)")
        }
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.handle(results) }
        }
        b.start(queue: queue)
        browser = b
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint, name != instanceName, !dialed.contains(name) else { continue }
            guard case .bonjour(let txt) = r.metadata, txt["v"] == "1" else { continue }
            let theirs = Set((txt["c"] ?? "").split(separator: ",").map(String.init))
            guard !theirs.isDisjoint(with: channelIDs), instanceName < name else { continue }
            dialed.insert(name)
            adopt(NWConnection(to: r.endpoint, using: .tcp), id: "out-\(name)")
        }
    }

    private func adopt(_ c: NWConnection, id: String) {
        connections[id] = c
        c.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .ready: self?.onPeersChanged(self?.connections.count ?? 0)
                case .failed, .cancelled: self?.drop(id)
                default: break
                }
            }
        }
        c.start(queue: queue)
        receive(c, id: id)
    }

    private func drop(_ id: String) {
        connections.removeValue(forKey: id)?.cancel()
        buffers.removeValue(forKey: id)
        if id.hasPrefix("out-") { dialed.remove(String(id.dropFirst(4))) }
        onPeersChanged(connections.count)
    }

    private func receive(_ c: NWConnection, id: String) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if let d = data, !d.isEmpty { self.consume(d, id: id) }
                if done || error != nil { self.drop(id); return }
                self.receive(c, id: id)
            }
        }
    }

    private func consume(_ d: Data, id: String) {
        var buf = (buffers[id] ?? Data()) + d
        while buf.count >= 4 {
            let b = [UInt8](buf.prefix(4))
            let len = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            guard len > 0, len <= ChannelEnvelopeHeader.maxEnvelopeBytes else { drop(id); return }
            guard buf.count >= 4 + len else { break }
            onEnvelope(Data(buf.subdata(in: buf.startIndex + 4 ..< buf.startIndex + 4 + len)), id)
            buf = Data(buf.dropFirst(4 + len))
        }
        buffers[id] = buf
    }
}
