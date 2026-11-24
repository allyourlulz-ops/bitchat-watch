//
// HostApp.swift — BitchatWatchHost (standalone iPhone companion for development)
//
// A minimal iPhone app that embeds the watch app and runs the same companion
// bridge as the upstream patch, without needing the upstream tree:
//   * bitchat side: a *leaf* BitchatLeafEngine over Core Bluetooth central
//     (connects to nearby bitchat phones/Macs; does not advertise or relay) —
//     production users should use the upstream patch instead, where the full
//     bitchat BLEService carries the mesh;
//   * channel chat: LAN (Bonjour) + MultipeerConnectivity + bitchat bridge.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import CryptoKit

@main
struct BitchatWatchHostApp: App {
    @StateObject private var host = HostModel()
    var body: some Scene {
        WindowGroup { HostView().environmentObject(host).onAppear { host.start() } }
    }
}

@MainActor
final class LeafChatSource: NSObject, CompanionChatSource, TransportSink {
    let hub = BLECentralHub()
    let transport: BitchatTransport
    var onMessage: ((UnifiedMessage) -> Void)?
    var onPeopleChanged: (() -> Void)?
    var onTunnelReceive: ((Data, String) -> Void)?
    private var peopleByKey: [String: UnifiedPerson] = [:]
    private var recent: [UnifiedMessage] = []
    var changed: () -> Void = {}

    init(nickname: String) {
        let key = "host.identity"
        var identity = BitchatIdentity.generate()
        if let d = UserDefaults.standard.dictionary(forKey: key) as? [String: Data],
           let n = d["n"], let s = d["s"],
           let nk = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: n),
           let sk = try? Curve25519.Signing.PrivateKey(rawRepresentation: s) {
            identity = BitchatIdentity(noiseStatic: nk, signing: sk)
        } else {
            // dev host only: production keys belong in the Keychain (see WatchApp/Support/KeychainStore.swift)
            UserDefaults.standard.set(["n": identity.noiseStatic.rawRepresentation, "s": identity.signing.rawRepresentation], forKey: key)
        }
        transport = BitchatTransport(identity: identity, nickname: nickname)
        super.init()
        transport.sink = self
        transport.onChannelTunnel = { [weak self] payload, _ in self?.onTunnelReceive?(payload, "mesh") }
        hub.register(transport)
        var p = ConnectionPolicy(); p.maxConnections = 4   // iOS allows more than watchOS
        hub.policy = p
        hub.onChange = { [weak self] in self?.changed() }
    }

    func start() { hub.start() }

    // CompanionChatSource
    var nickname: String { transport.engine.nickname }
    var people: [UnifiedPerson] { Array(peopleByKey.values) }
    var recentMessages: [UnifiedMessage] { recent }
    func sendPublic(_ text: String) -> UnifiedMessage? { relabel(transport.send(text, in: .room(.bitchat, "public"))) }
    func sendPrivate(_ text: String, peerKey: String) -> UnifiedMessage? { relabel(transport.send(text, in: .direct(.bitchat, peerKey))) }
    func toggleFavorite(peerKey: String) {}
    var tunnelSend: ((Data, UInt8) -> Void)? { { [weak self] env, ttl in self?.transport.sendChannelTunnel(env, ttl: ttl) } }

    /// The phone reports its leaf-mesh traffic to the watch as `.bitchatPhone`.
    private func relabel(_ m: UnifiedMessage?) -> UnifiedMessage? {
        guard let m = m else { return nil }
        let c = ConversationID(network: .bitchatPhone, scope: m.conversation.scope, key: m.conversation.key)
        return UnifiedMessage(id: m.id, conversation: c, senderName: m.senderName, senderKey: m.senderKey, text: m.text,
                              timestamp: m.timestamp, outgoing: m.outgoing, state: m.state, bridged: m.bridged, via: m.via)
    }

    // TransportSink
    func transport(_ t: ChatTransport, didReceive message: UnifiedMessage) {
        guard let m = relabel(message) else { return }
        recent.append(m); if recent.count > 100 { recent.removeFirst() }
        onMessage?(m); changed()
    }
    func transport(_ t: ChatTransport, didUpdate person: UnifiedPerson) {
        var p = person
        p = UnifiedPerson(network: .bitchatPhone, key: p.key, displayName: p.displayName, detail: p.detail,
                          isOnline: p.isOnline, isFavorite: p.isFavorite, canMessage: p.canMessage, secureSession: p.secureSession)
        peopleByKey[p.key] = p
        onPeopleChanged?(); changed()
    }
    func transport(_ t: ChatTransport, didUpdate room: RoomInfo) {}
    func transport(_ t: ChatTransport, message id: String, didChangeTo state: DeliveryState) {}
    func transportStatusDidChange(_ t: ChatTransport) { changed() }
}

@MainActor
final class HostModel: ObservableObject {
    @Published var revision = 0
    let source: LeafChatSource
    let bridge: WatchBridgeHub
    @Published var code = ""
    @Published var bridgeNew = false

    init() {
        let nick = UserDefaults.standard.string(forKey: "host.nick") ?? "phone\(Int.random(in: 100...999))"
        UserDefaults.standard.set(nick, forKey: "host.nick")
        source = LeafChatSource(nickname: nick)
        bridge = WatchBridgeHub(source: source)
        source.changed = { [weak self] in self?.revision &+= 1 }
        let previous = bridge.channels.onChange
        bridge.channels.onChange = { [weak self] in previous(); self?.revision &+= 1 }
    }

    func start() { source.start(); bridge.start() }
}

struct HostView: View {
    @EnvironmentObject var host: HostModel
    var body: some View {
        let _ = host.revision
        NavigationStack {
            Form {
                Section("bitchat (leaf, dev host)") {
                    Text(host.source.transport.statusText)
                    Text("ID \(host.source.transport.engine.myPeerID.id)").font(.caption.monospaced())
                }
                Section("Channel chat") {
                    Text("LAN peers \(host.bridge.channels.lanPeers) · MPC peers \(host.bridge.channels.mpcPeers)")
                    TextField("channel code", text: $host.code).textInputAutocapitalization(.never)
                    Toggle("Bridge into bitchat", isOn: $host.bridgeNew)
                    Button("Join") { host.bridge.channels.join(code: host.code, bridge: host.bridgeNew); host.code = "" }
                    ForEach(host.bridge.channels.rooms) { r in
                        HStack { Text(r.title); Spacer(); if r.bridged { Text("bridged").font(.caption).foregroundStyle(.blue) } }
                    }
                    Text("Channel codes are weak shared secrets. Not for sensitive use.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("bitchat watch host")
        }
    }
}
