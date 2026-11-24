//
// BitchatLeafEngine.swift — bitchat-watch
//
// Platform-independent bitchat protocol engine for a *leaf* node: a device
// that connects to bitchat peers as a BLE central only (Apple Watch), sends
// its own packets and receives others', but never relays (it has no
// peripheral role to relay through and, with at most ~2 links, relaying would
// add nothing but duplicate airtime). It speaks the stock wire protocol:
//
//  * announce (0x01): TLV nickname / Noise static key / Ed25519 key, signed,
//    TTL 7 (= "direct" from a neighbour's point of view, upstream semantics)
//  * public message (0x02): UTF-8 payload, Ed25519-signed, TTL 7
//  * Noise XX handshake (0x10) / encrypted (0x11) for private messages,
//    payload = NoisePayloadType byte + TLV, using the vendored upstream
//    NoiseSession (Noise_XX_25519_ChaChaPoly_SHA256, 4-byte nonce prefix)
//  * fragments (0x20) in both directions
//  * an opaque "channel tunnel" type (see ChannelTunnelWire) handed to the app
//
// Dedup follows upstream's message ID (sender-timestamp-type-sha256(payload)[0..4]).
// Freshness: announces older than 900 s and public messages older than 6 h are
// ignored (upstream BLEPacketFreshnessPolicy / syncPublicMessageMaxAgeSeconds).
//
// Threading: not thread-safe. The platform layer calls every method on one
// serial queue and delivers outputs from the same queue.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CryptoKit

/// Long-term bitchat identity. Persist both raw keys (Keychain on Apple platforms).
struct BitchatIdentity {
    let noiseStatic: Curve25519.KeyAgreement.PrivateKey
    let signing: Curve25519.Signing.PrivateKey

    static func generate() -> BitchatIdentity {
        BitchatIdentity(noiseStatic: .init(), signing: .init())
    }

    var noisePublicKey: Data { noiseStatic.publicKey.rawRepresentation }
    var signingPublicKey: Data { signing.publicKey.rawRepresentation }
    /// Upstream: PeerID = first 16 hex chars of SHA-256(noise static public key).
    var peerID: PeerID { PeerID(publicKey: noisePublicKey) }
    var peerIDData: Data { Data(hexString: peerID.id) ?? Data() }
    /// Full SHA-256 fingerprint of the Noise static key (what bitchat shows for verification).
    var fingerprint: String { noisePublicKey.sha256Fingerprint() }
}

/// Opaque identifier for one BLE link (e.g. CBPeripheral.identifier.uuidString).
typealias BitchatLinkID = String

struct BitchatPeerInfo: Equatable {
    let peerID: PeerID
    var nickname: String
    var noisePublicKey: Data
    var signingPublicKey: Data
    var lastSeen: Date
    /// Heard directly on one of our links (announce with full TTL) vs relayed.
    var isDirect: Bool
    var link: BitchatLinkID?
    var sessionEstablished: Bool
    var fingerprint: String { noisePublicKey.sha256Fingerprint() }
}

enum BitchatEngineEvent {
    case peerUpdated(BitchatPeerInfo)
    case peerLost(PeerID)
    case publicMessage(id: String, from: PeerID, nickname: String, text: String, timestamp: Date)
    case privateMessage(id: String, from: PeerID, nickname: String, text: String, timestamp: Date)
    case delivered(messageID: String, by: PeerID)
    case read(messageID: String, by: PeerID)
    case sessionEstablished(PeerID)
    case sessionFailed(PeerID, String)
    case channelTunnel(payload: Data, from: PeerID, ttl: UInt8)
    case log(String)
}

final class BitchatLeafEngine {
    // MARK: configuration
    var nickname: String
    let identity: BitchatIdentity
    let ttl: UInt8 = TransportConfig.messageTTLDefault
    var announceInterval: TimeInterval = 30
    var peerTimeout: TimeInterval = 180

    // MARK: outputs (set by the platform layer)
    /// Write one encoded frame. `link == nil` means "every connected link".
    var sendFrame: (_ frame: Data, _ link: BitchatLinkID?) -> Void = { _, _ in }
    /// Max bytes per write for a link (CBPeripheral.maximumWriteValueLength(for: .withoutResponse)).
    var linkWriteLimit: (_ link: BitchatLinkID?) -> Int = { _ in 182 }
    var onEvent: (BitchatEngineEvent) -> Void = { _ in }
    var now: () -> Date = { Date() }

    // MARK: state
    private(set) var peers: [PeerID: BitchatPeerInfo] = [:]
    private var links: Set<BitchatLinkID> = []
    private var linkPeer: [BitchatLinkID: PeerID] = [:]
    private var seen = BoundedSeenSet(capacity: 2048)
    private var reassembler = BitchatFragmentReassembler()
    private var sessions: [PeerID: NoiseSession] = [:]
    private var pendingPrivate: [PeerID: [(id: String, payload: Data)]] = [:]
    private var lastAnnounce: Date = .distantPast
    private var handshakeStarted: [PeerID: Date] = [:]

    init(identity: BitchatIdentity, nickname: String) {
        self.identity = identity
        self.nickname = nickname
    }

    var myPeerID: PeerID { identity.peerID }

    // MARK: - Link lifecycle

    func linkUp(_ link: BitchatLinkID) {
        links.insert(link)
        sendAnnounce(force: true)
    }

    func linkDown(_ link: BitchatLinkID) {
        links.remove(link)
        if let pid = linkPeer.removeValue(forKey: link), var info = peers[pid] {
            info.isDirect = false
            info.link = nil
            peers[pid] = info
            onEvent(.peerUpdated(info))
        }
    }

    var connectedLinkCount: Int { links.count }

    // MARK: - Periodic

    func tick() {
        let t = now()
        if t.timeIntervalSince(lastAnnounce) >= announceInterval { sendAnnounce(force: false) }
        reassembler.expire(now: t)
        for (pid, info) in peers where t.timeIntervalSince(info.lastSeen) > peerTimeout {
            peers.removeValue(forKey: pid)
            onEvent(.peerLost(pid))
        }
        for (pid, started) in handshakeStarted where t.timeIntervalSince(started) > 20 {
            handshakeStarted.removeValue(forKey: pid)
            if sessions[pid]?.isEstablished() != true {
                sessions.removeValue(forKey: pid)
                onEvent(.sessionFailed(pid, "handshake timed out"))
            }
        }
    }

    // MARK: - Outbound

    func sendAnnounce(force: Bool) {
        guard !links.isEmpty else { return }
        let t = now()
        if !force && t.timeIntervalSince(lastAnnounce) < 2 { return }
        lastAnnounce = t
        let ann = AnnouncementPacket(nickname: nickname, noisePublicKey: identity.noisePublicKey,
                                     signingPublicKey: identity.signingPublicKey,
                                     directNeighbors: linkPeer.values.compactMap { $0.routingData },
                                     capabilities: nil, bridgeGeohash: nil)
        guard let payload = ann.encode() else { return }
        let packet = BitchatPacket(type: MessageType.announce.rawValue, senderID: identity.peerIDData,
                                   recipientID: nil, timestamp: Self.ms(t), payload: payload,
                                   signature: nil, ttl: ttl)
        emit(sign(packet), to: nil)
    }

    /// Broadcast a signed public message. Returns the local message ID.
    @discardableResult
    func sendPublic(_ text: String) -> String? {
        let content = String(text.prefix(2000))
        let t = now()
        let packet = sign(BitchatPacket(type: MessageType.message.rawValue, senderID: identity.peerIDData,
                                        recipientID: nil, timestamp: Self.ms(t), payload: Data(content.utf8),
                                        signature: nil, ttl: ttl))
        seen.insert(Self.messageID(for: packet))
        emit(packet, to: nil)
        return "\(myPeerID.id)-\(packet.timestamp)"
    }

    /// Send a private message over Noise; initiates a handshake if needed.
    @discardableResult
    func sendPrivate(_ text: String, to peer: PeerID, messageID: String = UUID().uuidString) -> String {
        guard let payload = PrivateMessagePacket(messageID: messageID, content: String(text.prefix(255))).encode() else {
            return messageID
        }
        sendNoisePayload(NoisePayload(type: .privateMessage, data: payload).encode(), to: peer, queueID: messageID)
        return messageID
    }

    func sendReadReceipt(for messageID: String, to peer: PeerID) {
        sendNoisePayload(NoisePayload(type: .readReceipt, data: Data(messageID.utf8)).encode(), to: peer, queueID: nil)
    }

    /// Broadcast an opaque channel-tunnel payload (Wi-Fi channel bridge). Unsigned,
    /// like other opaque types; stock iOS/Android relay unknown broadcast types.
    func sendChannelTunnel(_ payload: Data, ttl requested: UInt8) {
        let packet = BitchatPacket(type: ChannelTunnelWire.bitchatPacketType, senderID: identity.peerIDData,
                                   recipientID: nil, timestamp: Self.ms(now()), payload: payload,
                                   signature: nil, ttl: min(requested, ttl))
        seen.insert(Self.messageID(for: packet))
        emit(packet, to: nil)
    }

    func initiateHandshake(with peer: PeerID) {
        if let s = sessions[peer], s.isEstablished() || s.getState() == .handshaking { return }
        let session = NoiseSession(peerID: peer, role: .initiator, keychain: MemoryZeroizer.shared,
                                   localStaticKey: identity.noiseStatic)
        sessions[peer] = session
        handshakeStarted[peer] = now()
        do {
            let msg1 = try session.startHandshake()
            emitDirected(type: .noiseHandshake, payload: msg1, to: peer)
        } catch {
            sessions.removeValue(forKey: peer)
            onEvent(.sessionFailed(peer, "\(error)"))
        }
    }

    func hasSession(with peer: PeerID) -> Bool { sessions[peer]?.isEstablished() == true }

    // MARK: - Inbound

    /// Feed one complete frame (as produced by NotificationStreamAssembler).
    func receive(frame: Data, from link: BitchatLinkID) {
        guard let packet = BinaryProtocol.decode(frame) else {
            onEvent(.log("undecodable frame len=\(frame.count)"))
            return
        }
        receive(packet: packet, from: link)
    }

    func receive(packet: BitchatPacket, from link: BitchatLinkID) {
        let sender = PeerID(hexData: packet.senderID)
        if sender == myPeerID { return }               // own echo relayed back
        if packet.type == MessageType.fragment.rawValue {
            if let r = packet.recipientID, !isBroadcastOrMe(r) { return }
            switch reassembler.add(packet, now: now()) {
            case .complete(let original): receive(packet: original, from: link)
            case .rejected(let why): onEvent(.log("fragment rejected: \(why)"))
            case .incomplete: break
            }
            return
        }
        let id = Self.messageID(for: packet)
        if seen.contains(id) { return }
        seen.insert(id)
        // NOTE: leaf node — never relays. TTL is only read, never decremented.
        switch MessageType(rawValue: packet.type) {
        case .announce?: handleAnnounce(packet, sender: sender, link: link)
        case .message?: handlePublic(packet, sender: sender)
        case .noiseHandshake?: handleHandshake(packet, sender: sender)
        case .noiseEncrypted?: handleEncrypted(packet, sender: sender)
        case .leave?: break  // presence is timed out instead (leave is signed upstream; not needed)
        default:
            if packet.type == ChannelTunnelWire.bitchatPacketType {
                onEvent(.channelTunnel(payload: packet.payload, from: sender, ttl: packet.ttl))
            }
        }
    }

    private func handleAnnounce(_ packet: BitchatPacket, sender: PeerID, link: BitchatLinkID) {
        guard let ann = AnnouncementPacket.decode(from: packet.payload) else { return }
        guard PeerID(publicKey: ann.noisePublicKey) == sender else { onEvent(.log("announce sender mismatch")); return }
        guard !isStale(packet.timestamp, maxAge: 900) else { return }
        guard verify(packet, signingKey: ann.signingPublicKey) else { onEvent(.log("announce bad signature")); return }
        // TOFU pin: reject a changed signing/noise key for a known peer id.
        if let known = peers[sender], known.signingPublicKey != ann.signingPublicKey { onEvent(.log("announce signing key changed; ignored")); return }
        let direct = packet.ttl == ttl
        var info = peers[sender] ?? BitchatPeerInfo(peerID: sender, nickname: ann.nickname,
                                                     noisePublicKey: ann.noisePublicKey,
                                                     signingPublicKey: ann.signingPublicKey,
                                                     lastSeen: now(), isDirect: direct, link: nil,
                                                     sessionEstablished: hasSession(with: sender))
        info.nickname = ann.nickname
        info.lastSeen = now()
        if direct {
            info.isDirect = true
            info.link = link
            linkPeer[link] = sender
        }
        peers[sender] = info
        onEvent(.peerUpdated(info))
    }

    private func handlePublic(_ packet: BitchatPacket, sender: PeerID) {
        if let r = packet.recipientID, !BitchatLeafEngine.isBroadcast(r) { return }
        guard !isStale(packet.timestamp, maxAge: TransportConfig.syncPublicMessageMaxAgeSeconds) else { return }
        guard let info = peers[sender], verify(packet, signingKey: info.signingPublicKey) else {
            onEvent(.log("public message from unverified sender \(sender.id.prefix(8)) dropped"))
            return
        }
        guard let text = String(data: packet.payload, encoding: .utf8) else { return }
        onEvent(.publicMessage(id: "\(sender.id)-\(packet.timestamp)", from: sender, nickname: info.nickname,
                               text: text, timestamp: Date(timeIntervalSince1970: Double(packet.timestamp) / 1000)))
    }

    private func handleHandshake(_ packet: BitchatPacket, sender: PeerID) {
        guard let r = packet.recipientID, PeerID(hexData: r) == myPeerID else { return }
        var session = sessions[sender]
        let isMessage1 = packet.payload.count == 32
        if isMessage1 {
            if let s = session, s.getState() == .handshaking, s.role == .initiator {
                // Crossed initiation: upstream keeps the lower peer ID as initiator.
                if myPeerID.id < sender.id { return }
            }
            session = NoiseSession(peerID: sender, role: .responder, keychain: MemoryZeroizer.shared,
                                   localStaticKey: identity.noiseStatic)
            sessions[sender] = session
            handshakeStarted[sender] = now()
        }
        guard let s = session else { return }
        do {
            if let response = try s.processHandshakeMessage(packet.payload) {
                emitDirected(type: .noiseHandshake, payload: response, to: sender)
            }
            if s.isEstablished() { sessionDidEstablish(sender, session: s) }
        } catch {
            sessions.removeValue(forKey: sender)
            handshakeStarted.removeValue(forKey: sender)
            onEvent(.sessionFailed(sender, "\(error)"))
        }
    }

    private func sessionDidEstablish(_ peer: PeerID, session: NoiseSession) {
        handshakeStarted.removeValue(forKey: peer)
        // Bind the session to the announced identity when we have one.
        if let remote = session.getRemoteStaticPublicKey()?.rawRepresentation,
           PeerID(publicKey: remote) != peer {
            sessions.removeValue(forKey: peer)
            onEvent(.sessionFailed(peer, "remote static key does not match peer ID"))
            return
        }
        if var info = peers[peer] { info.sessionEstablished = true; peers[peer] = info; onEvent(.peerUpdated(info)) }
        onEvent(.sessionEstablished(peer))
        // Authenticated peer state (upstream sends this right after auth). No capabilities.
        let state = AuthenticatedPeerStatePacket(capabilities: PeerCapabilities(rawValue: 0),
                                                 signingPublicKey: identity.signingPublicKey)
        if let p = state.encode() { encryptAndSend(NoisePayload(type: .authenticatedPeerState, data: p).encode(), to: peer) }
        for item in pendingPrivate.removeValue(forKey: peer) ?? [] { encryptAndSend(item.payload, to: peer) }
    }

    private func handleEncrypted(_ packet: BitchatPacket, sender: PeerID) {
        guard let r = packet.recipientID, PeerID(hexData: r) == myPeerID else { return }
        guard let s = sessions[sender], s.isEstablished() else {
            initiateHandshake(with: sender)
            return
        }
        guard let plain = try? s.decrypt(packet.payload), let payload = NoisePayload.decode(plain) else {
            onEvent(.log("decrypt failed from \(sender.id.prefix(8))"))
            return
        }
        let nick = peers[sender]?.nickname ?? sender.id.prefix(8).description
        switch payload.type {
        case .privateMessage:
            guard let pm = PrivateMessagePacket.decode(from: payload.data) else { return }
            onEvent(.privateMessage(id: pm.messageID, from: sender, nickname: nick, text: pm.content,
                                    timestamp: Date(timeIntervalSince1970: Double(packet.timestamp) / 1000)))
            encryptAndSend(NoisePayload(type: .delivered, data: Data(pm.messageID.utf8)).encode(), to: sender)
        case .delivered:
            onEvent(.delivered(messageID: String(decoding: payload.data, as: UTF8.self), by: sender))
        case .readReceipt:
            onEvent(.read(messageID: String(decoding: payload.data, as: UTF8.self), by: sender))
        default:
            break // groups, media, verification, vouch: out of watch scope
        }
    }

    // MARK: - Helpers

    private func sendNoisePayload(_ typed: Data, to peer: PeerID, queueID: String?) {
        if hasSession(with: peer) {
            encryptAndSend(typed, to: peer)
        } else {
            pendingPrivate[peer, default: []].append((queueID ?? UUID().uuidString, typed))
            if (pendingPrivate[peer]?.count ?? 0) > 20 { pendingPrivate[peer]?.removeFirst() }
            initiateHandshake(with: peer)
        }
    }

    private func encryptAndSend(_ typed: Data, to peer: PeerID) {
        guard let s = sessions[peer], let ct = try? s.encrypt(typed) else { return }
        emitDirected(type: .noiseEncrypted, payload: ct, to: peer)
    }

    private func emitDirected(type: MessageType, payload: Data, to peer: PeerID) {
        let packet = BitchatPacket(type: type.rawValue, senderID: identity.peerIDData,
                                   recipientID: Data(hexString: peer.id), timestamp: Self.ms(now()),
                                   payload: payload, signature: nil, ttl: ttl)
        // Prefer the peer's own link; otherwise flood to all links (phones relay directed traffic).
        let link = peers[peer]?.isDirect == true ? peers[peer]?.link : nil
        emit(packet, to: link)
    }

    private func emit(_ packet: BitchatPacket, to link: BitchatLinkID?) {
        // Upstream pads only Noise frames (BLEOutboundPacketPolicy.padsBLEFrame).
        let pad = packet.type == MessageType.noiseEncrypted.rawValue || packet.type == MessageType.noiseHandshake.rawValue
        let limit = linkWriteLimit(link)
        if let frags = BitchatFragmenter.fragmentsIfNeeded(packet, pad: pad, linkLimit: limit) {
            for f in frags { if let d = f.toBinaryData(padding: false) { sendFrame(d, link) } }
        } else if let d = packet.toBinaryData(padding: pad) {
            sendFrame(d, link)
        }
    }

    private func sign(_ packet: BitchatPacket) -> BitchatPacket {
        guard let bytes = packet.toBinaryDataForSigning(),
              let sig = try? identity.signing.signature(for: bytes) else { return packet }
        var p = packet
        p.signature = sig
        return p
    }

    private func verify(_ packet: BitchatPacket, signingKey: Data) -> Bool {
        guard let sig = packet.signature, let bytes = packet.toBinaryDataForSigning(),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: signingKey) else { return false }
        return key.isValidSignature(sig, for: bytes)
    }

    private func isStale(_ ts: UInt64, maxAge: TimeInterval) -> Bool {
        let n = Self.ms(now())
        let maxMs = UInt64(maxAge * 1000)
        return n > maxMs && ts < n - maxMs
    }

    private func isBroadcastOrMe(_ r: Data) -> Bool {
        BitchatLeafEngine.isBroadcast(r) || PeerID(hexData: r) == myPeerID
    }

    static func isBroadcast(_ r: Data) -> Bool { r.count == 8 && r.allSatisfy { $0 == 0xFF } }

    static func ms(_ d: Date) -> UInt64 { UInt64(max(0, d.timeIntervalSince1970) * 1000) }

    /// Upstream BLEReceivePipeline message ID.
    static func messageID(for packet: BitchatPacket) -> String {
        "\(packet.senderID.hexEncodedString())-\(packet.timestamp)-\(packet.type)-\(packet.payload.sha256Hash().prefix(4).hexEncodedString())"
    }
}
