//
// ChannelLinks.swift — bitchat Mac tester (macOS 10.14+, Swift 5.0)
//
// Channel chat links, wire-compatible with iOSBridge/Generic:
//   * TesterMPCLink — MultipeerConnectivity, service "hk-chan", discoveryInfo
//     v=1 / c=<channel-ID csv>; only the smaller displayName invites; one MPC
//     message = one envelope; encryptionPreference .required.
//   * TesterLANLink — Bonjour "_hkchan._tcp", TXT v=1 / c=<csv>, TCP frames of
//     4-byte BE length + envelope; the smaller instance name dials.
//     NWBrowser and NWTXTRecord are macOS 10.15+, so on 10.14 discovery uses
//     NetServiceBrowser + NetService TXT resolution, while the listener and the
//     TCP connections use Network.framework (NWListener/NWConnection, 10.14).
// Both feed BTChannelRouter (Sources/Core/TesterChannel.swift).
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import MultipeerConnectivity
import Network

// MARK: - MultipeerConnectivity

final class TesterMPCLink: NSObject, MCSessionDelegate, MCNearbyServiceBrowserDelegate, MCNearbyServiceAdvertiserDelegate {
    static let serviceType = "hk-chan"
    let me = MCPeerID(displayName: "hk-" + String(UUID().uuidString.prefix(8)).lowercased())
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var channelIDs = [String]()

    var onEnvelope: (_ envelope: [UInt8], _ link: String) -> Void = { _, _ in }
    var onPeersChanged: (_ names: [String]) -> Void = { _ in }

    override init() {
        super.init()
        session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
    }

    var peerNames: [String] { return session.connectedPeers.map { $0.displayName }.sorted() }

    func update(channelIDs ids: [String]) {
        guard ids != channelIDs else { return }
        channelIDs = ids
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers(); browser = nil
        guard !ids.isEmpty else { session.disconnect(); return }
        let a = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: BTChannelAdvert.info(ids), serviceType: TesterMPCLink.serviceType)
        a.delegate = self
        a.startAdvertisingPeer()
        advertiser = a
        let b = MCNearbyServiceBrowser(peer: me, serviceType: TesterMPCLink.serviceType)
        b.delegate = self
        b.startBrowsingForPeers()
        browser = b
    }

    func send(_ envelope: [UInt8], except: String?) {
        let targets = session.connectedPeers.filter { $0.displayName != except }
        guard !targets.isEmpty else { return }
        try? session.send(Data(envelope), toPeers: targets, with: .reliable)
    }

    // browser
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            guard BTChannelAdvert.shares(info, with: self.channelIDs),
                  BTChannelAdvert.shouldDial(me: self.me.displayName, them: peerID.displayName),
                  !self.session.connectedPeers.contains(peerID) else { return }
            let ctx = self.channelIDs.joined(separator: ",").data(using: .utf8)
            browser.invitePeer(peerID, to: self.session, withContext: ctx, timeout: 15)
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    // advertiser
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        let csv = context.flatMap { String(data: $0, encoding: .utf8) }
        DispatchQueue.main.async {
            let ok = BTChannelAdvert.shares(["v": "1", "c": csv ?? ""], with: self.channelIDs)
            invitationHandler(ok, ok ? self.session : nil)
        }
    }

    // session
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let names = session.connectedPeers.map { $0.displayName }.sorted()
        DispatchQueue.main.async { self.onPeersChanged(names) }
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let name = peerID.displayName
        DispatchQueue.main.async { self.onEnvelope([UInt8](data), name) }
    }
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - LAN (Bonjour + TCP)

final class TesterLANLink: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let serviceType = "_hkchan._tcp"
    let instanceName = "hk-" + String(UUID().uuidString.prefix(12)).lowercased()

    var onEnvelope: (_ envelope: [UInt8], _ link: String) -> Void = { _, _ in }
    var onPeersChanged: (_ names: [String]) -> Void = { _ in }
    var onNote: (String) -> Void = { _ in }

    private var listener: NWListener?
    private var serviceBrowser: NetServiceBrowser?
    private var resolving = [String: NetService]()
    private var connections = [String: NWConnection]()
    private var framers = [String: BTLengthFramer]()
    private var dialed = Set<String>()
    private var channelIDs = [String]()

    var peerNames: [String] { return connections.keys.sorted() }

    func update(channelIDs ids: [String]) {
        guard ids != channelIDs else { return }
        channelIDs = ids
        stop()
        guard !ids.isEmpty else { return }
        do {
            let l = try NWListener(using: .tcp)
            let info = BTChannelAdvert.info(ids)
            var txt = [String: Data]()
            for (k, v) in info { txt[k] = v.data(using: .utf8) }
            l.service = NWListener.Service(name: instanceName, type: TesterLANLink.serviceType, domain: nil,
                                           txtRecord: NetService.data(fromTXTRecord: txt))
            l.newConnectionHandler = { [weak self] c in self?.adopt(c, id: "in-" + String(UUID().uuidString.prefix(8))) }
            l.stateUpdateHandler = { [weak self] s in
                if case .failed(let e) = s { self?.onNote("LAN listener failed: \(e)") }
            }
            l.start(queue: DispatchQueue.main)
            listener = l
        } catch {
            onNote("LAN listener failed: \(error)")
        }
        let b = NetServiceBrowser()
        b.delegate = self
        b.searchForServices(ofType: TesterLANLink.serviceType + ".", inDomain: "local.")
        serviceBrowser = b
    }

    func stop() {
        listener?.cancel(); listener = nil
        serviceBrowser?.stop(); serviceBrowser = nil
        for s in resolving.values { s.stop() }
        resolving.removeAll()
        for c in connections.values { c.cancel() }
        connections.removeAll(); framers.removeAll(); dialed.removeAll()
        onPeersChanged([])
    }

    func send(_ envelope: [UInt8], except: String?) {
        guard let framed = BTLengthFramer.frame(envelope) else { return }
        let d = Data(framed)
        for (id, c) in connections where id != except {
            c.send(content: d, completion: .contentProcessed({ _ in }))
        }
    }

    // NetServiceBrowser: resolve each service to read its TXT record.
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard service.name != instanceName, !dialed.contains(service.name),
              BTChannelAdvert.shouldDial(me: instanceName, them: service.name) else { return }
        resolving[service.name] = service
        service.delegate = self
        service.resolve(withTimeout: 10)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        defer { resolving[sender.name] = nil }
        guard !dialed.contains(sender.name), let data = sender.txtRecordData() else { return }
        var info = [String: String]()
        for (k, v) in NetService.dictionary(fromTXTRecord: data) { info[k] = String(data: v, encoding: .utf8) }
        guard BTChannelAdvert.shares(info, with: channelIDs) else { return }
        dialed.insert(sender.name)
        let ep = NWEndpoint.service(name: sender.name, type: TesterLANLink.serviceType, domain: sender.domain, interface: nil)
        adopt(NWConnection(to: ep, using: .tcp), id: "out-" + sender.name)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) { resolving[sender.name] = nil }

    private func adopt(_ c: NWConnection, id: String) {
        connections[id] = c
        framers[id] = BTLengthFramer()
        c.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready: self.onPeersChanged(self.peerNames)
            case .failed, .cancelled: self.drop(id)
            default: break
            }
        }
        c.start(queue: DispatchQueue.main)
        receive(c, id: id)
    }

    private func drop(_ id: String) {
        guard let c = connections.removeValue(forKey: id) else { return }
        c.cancel()
        framers[id] = nil
        if id.hasPrefix("out-") { dialed.remove(String(id.dropFirst(4))) }
        onPeersChanged(peerNames)
    }

    private func receive(_ c: NWConnection, id: String) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self = self, let framer = self.framers[id] else { return }
            if let d = data, !d.isEmpty {
                for env in framer.append([UInt8](d)) { self.onEnvelope(env, id) }
                if framer.broken { self.onNote("LAN \(id): bad frame, dropping"); self.drop(id); return }
            }
            if done || error != nil { self.drop(id); return }
            self.receive(c, id: id)
        }
    }
}
