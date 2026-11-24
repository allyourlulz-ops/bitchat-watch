//
// MPCChannelTransport.swift — bitchat-watch iPhone companion
//
// Channel chat over MultipeerConnectivity (router-free peer-to-peer Wi-Fi /
// Bluetooth between Apple devices). Service type "hk-chan". discoveryInfo
// carries `v=1` and `c=<comma-separated channel-ID hex>` — HKDF-derived IDs,
// never the channel code. Devices sharing a channel invite each other (only
// the smaller displayName invites, to avoid crossed invitations); sessions use
// encryptionPreference .required. Each MPC message is exactly one envelope.
//
// Limits: Apple-only; iOS suspends MPC when the app is backgrounded (links
// drop and come back on foreground); discoveryInfo should stay small (≤ ~400
// bytes), so at most 16 channel IDs are advertised.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import MultipeerConnectivity

@MainActor
final class MPCChannelTransport: NSObject {
    static let serviceType = "hk-chan"   // ≤15 chars, lowercase letters/digits/hyphen
    private let me = MCPeerID(displayName: "hk-" + UUID().uuidString.prefix(8).lowercased())
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var channelIDs: [String] = []

    var onEnvelope: (Data, String) -> Void = { _, _ in }
    var onPeersChanged: (Int) -> Void = { _ in }

    override init() {
        super.init()
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
    }

    func update(channelIDs ids: [String]) {
        guard ids != channelIDs else { return }
        channelIDs = ids
        restart()
    }

    func stop() {
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers(); browser = nil
        session.disconnect()
        onPeersChanged(0)
    }

    var peerCount: Int { session.connectedPeers.count }

    func send(_ envelope: Data, except: String?) {
        let targets = session.connectedPeers.filter { $0.displayName != except }
        guard !targets.isEmpty else { return }
        try? session.send(envelope, toPeers: targets, with: .reliable)
    }

    private var info: [String: String] { ["v": "1", "c": channelIDs.prefix(16).joined(separator: ",")] }

    private func restart() {
        advertiser?.stopAdvertisingPeer(); browser?.stopBrowsingForPeers()
        guard !channelIDs.isEmpty else { stop(); return }
        let a = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: info, serviceType: Self.serviceType)
        a.delegate = self
        a.startAdvertisingPeer()
        advertiser = a
        let b = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
    }

    private func sharesChannel(_ csv: String?) -> Bool {
        let theirs = Set((csv ?? "").split(separator: ",").map(String.init))
        return !theirs.isDisjoint(with: channelIDs)
    }
}

extension MPCChannelTransport: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let csv = info?["c"], v = info?["v"]
        Task { @MainActor in
            guard v == "1", self.sharesChannel(csv), self.me.displayName < peerID.displayName,
                  !self.session.connectedPeers.contains(peerID) else { return }
            let ctx = self.channelIDs.joined(separator: ",").data(using: .utf8)
            browser.invitePeer(peerID, to: self.session, withContext: ctx, timeout: 15)
        }
    }
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}

extension MPCChannelTransport: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let csv = context.flatMap { String(data: $0, encoding: .utf8) }
        nonisolated(unsafe) let handler = invitationHandler
        Task { @MainActor in
            let ok = self.sharesChannel(csv)
            handler(ok, ok ? self.session : nil)
        }
    }
}

extension MPCChannelTransport: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let n = session.connectedPeers.count
        Task { @MainActor in self.onPeersChanged(n) }
    }
    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let name = peerID.displayName
        Task { @MainActor in self.onEnvelope(data, name) }
    }
    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
