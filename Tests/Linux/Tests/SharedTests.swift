// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

func runWireTests() throws {
    let sender = Data(repeating: 0xAB, count: 8)
    let p = BitchatPacket(type: MessageType.message.rawValue, senderID: sender, recipientID: nil,
                          timestamp: 1_700_000_000_000, payload: Data("hello mesh".utf8), signature: nil, ttl: 7)
    let enc = p.toBinaryData(padding: false)!
    check(enc.count == 14 + 8 + 10, "v1 unpadded size")
    check(enc[0] == 1 && enc[1] == 0x02 && enc[2] == 7, "header bytes")
    let dec = BinaryProtocol.decode(enc)!
    check(dec.payload == p.payload && dec.senderID == sender && dec.timestamp == p.timestamp, "roundtrip")
    let padded = p.toBinaryData(padding: true)!
    check(padded.count == 256, "padded to 256 block")
    check(BinaryProtocol.decode(padded)?.payload == p.payload, "padded roundtrip")

    // Fragmentation round trip with a tight link limit.
    let big = BitchatPacket(type: MessageType.message.rawValue, senderID: sender, recipientID: nil,
                            timestamp: 1, payload: Data((0..<1500).map { UInt8($0 % 251) }), signature: Data(repeating: 9, count: 64), ttl: 7)
    let frags = BitchatFragmenter.fragmentsIfNeeded(big, pad: false, linkLimit: 182)!
    check(frags.count > 1, "fragmented")
    var r = BitchatFragmentReassembler()
    var out: BitchatPacket?
    for f in frags.reversed() {   // out of order
        let wire = f.toBinaryData(padding: false)!
        check(wire.count <= 182, "fragment fits link")
        if case .complete(let pk) = r.add(BinaryProtocol.decode(wire)!) { out = pk }
    }
    check(out?.payload == big.payload && out?.signature == big.signature, "reassembled")

    // Notification stream assembler: two frames split across arbitrary chunks.
    var asm = NotificationStreamAssembler()
    let stream = enc + padded
    var frames: [Data] = []
    var i = 0
    while i < stream.count {
        let n = min(20, stream.count - i)
        frames += asm.append(stream.subdata(in: i..<(i + n))).frames
        i += n
    }
    check(frames.count == 2, "assembler yields 2 frames")
}

/// Two leaf engines wired back-to-back exercise announce, signatures, public
/// chat, Noise XX (upstream NoiseSession) and private messages + delivery acks.
func runMeshEngineTests() throws {
    let a = BitchatLeafEngine(identity: .generate(), nickname: "alice")
    let b = BitchatLeafEngine(identity: .generate(), nickname: "bob")
    var aEvents: [BitchatEngineEvent] = [], bEvents: [BitchatEngineEvent] = []
    var queue: [(Data, Bool)] = []  // (frame, toB)
    a.sendFrame = { f, _ in queue.append((f, true)) }
    b.sendFrame = { f, _ in queue.append((f, false)) }
    a.onEvent = { aEvents.append($0) }
    b.onEvent = { bEvents.append($0) }
    func pump() {
        var guardCount = 0
        while !queue.isEmpty && guardCount < 1000 {
            let (f, toB) = queue.removeFirst()
            if toB { b.receive(frame: f, from: "link-a") } else { a.receive(frame: f, from: "link-b") }
            guardCount += 1
        }
    }
    a.linkUp("link-b"); b.linkUp("link-a"); pump()
    check(a.peers[b.myPeerID]?.nickname == "bob", "a learned bob via signed announce")
    check(b.peers[a.myPeerID]?.isDirect == true, "b sees alice as direct")

    a.sendPublic("hi all"); pump()
    let gotPublic = bEvents.contains { if case .publicMessage(_, let from, _, let text, _) = $0 { return from == a.myPeerID && text == "hi all" }; return false }
    check(gotPublic, "public message delivered + signature verified")

    let mid = a.sendPrivate("secret", to: b.myPeerID); pump()
    check(a.hasSession(with: b.myPeerID) && b.hasSession(with: a.myPeerID), "noise session established both ways")
    let gotDM = bEvents.contains { if case .privateMessage(let id, _, _, let text, _) = $0 { return id == mid && text == "secret" }; return false }
    check(gotDM, "private message decrypted")
    let gotAck = aEvents.contains { if case .delivered(let id, _) = $0 { return id == mid }; return false }
    check(gotAck, "delivery ack returned")

    // Tampered signature must be dropped.
    let before = bEvents.count
    var forged = BitchatPacket(type: MessageType.message.rawValue, senderID: a.identity.peerIDData, recipientID: nil,
                               timestamp: BitchatLeafEngine.ms(Date()), payload: Data("forged".utf8),
                               signature: Data(repeating: 1, count: 64), ttl: 7)
    forged.ttl = 7
    b.receive(frame: forged.toBinaryData(padding: false)!, from: "link-a")
    let forgedDelivered = bEvents[before...].contains { if case .publicMessage(_, _, _, let t, _) = $0 { return t == "forged" }; return false }
    check(!forgedDelivered, "forged public message rejected")

    // Duplicate (relayed copy) is suppressed.
    let n0 = bEvents.filter { if case .publicMessage = $0 { return true }; return false }.count
    var captured: Data?
    a.sendFrame = { f, _ in captured = f }
    a.sendPublic("once")
    b.receive(frame: captured!, from: "link-a"); b.receive(frame: captured!, from: "link-a")
    let n1 = bEvents.filter { if case .publicMessage = $0 { return true }; return false }.count
    check(n1 == n0 + 1, "dedup")

    // Leaf never relays: receiving a packet from a third party produces no outbound frame.
    var bOut = 0
    b.sendFrame = { _, _ in bOut += 1 }
    let c = BitchatLeafEngine(identity: .generate(), nickname: "carol")
    var cFrame: Data?
    c.sendFrame = { f, _ in cFrame = f }
    c.linkUp("x")
    b.receive(frame: cFrame!, from: "link-a")
    check(bOut == 0, "leaf does not relay")

    // Channel tunnel type is surfaced, not relayed.
    var tunnelSeen = false
    b.onEvent = { if case .channelTunnel = $0 { tunnelSeen = true } }
    c.sendChannelTunnel(Data([1, 2, 3]), ttl: 5)
    b.receive(frame: cFrame!, from: "link-a")
    check(tunnelSeen && bOut == 0, "tunnel surfaced, not relayed")
}

func runMeshtasticTests() throws {
    // Encode text packet and decode it back through the same field numbers.
    var sent: [Data] = []
    let s = MeshtasticSession()
    s.write = { sent.append($0) }
    s.start(nonce: 42)
    check(sent.first == Data([0x18, 42]), "want_config_id = field 3 varint")
    let id = s.sendText("hola", to: 0x1234_5678, channel: 1)
    let toRadio = try ProtoReader.fields(sent.last!)
    check(toRadio.first?.number == 1, "ToRadio.packet field 1")
    let pkt = try MTMeshPacket.decode(toRadio.first!.bytes)
    check(pkt.to == 0x1234_5678 && pkt.channel == 1 && pkt.id == id && pkt.wantAck, "MeshPacket fields")
    check(pkt.decoded?.portnum == 1 && pkt.decoded?.payload == Data("hola".utf8), "Data TEXT_MESSAGE_APP")

    // Build FromRadio frames by hand (as firmware would) and feed them.
    var events: [MeshtasticEvent] = []
    s.onEvent = { events.append($0) }
    var w = ProtoWriter(); var mi = ProtoWriter(); mi.uint(1, 0xAABB)
    w.message(3, mi.data)
    s.handleFromRadio(w.data)
    var user = ProtoWriter(); user.string(1, "!00001111"); user.string(2, "Base Camp"); user.string(3, "BC")
    var node = ProtoWriter(); node.uint(1, 0x1111); node.message(2, user.data); node.bool(10, true)
    var fr = ProtoWriter(); fr.message(4, node.data)
    s.handleFromRadio(fr.data)
    var cs = ProtoWriter(); cs.string(3, "LongFast")
    var ch = ProtoWriter(); ch.int32(1, 0); ch.message(2, cs.data); ch.uint(3, 1)
    var fr2 = ProtoWriter(); fr2.message(10, ch.data)
    s.handleFromRadio(fr2.data)
    var done = ProtoWriter(); done.uint(7, 42)
    s.handleFromRadio(done.data)
    check(s.myNodeNum == 0xAABB && s.displayName(0x1111) == "Base Camp" && s.channelName(0) == "LongFast", "node db + channel")
    check(s.configured, "config complete with matching nonce")
    var data = MTData(portnum: 1, payload: Data("ping".utf8))
    var mp = MTMeshPacket(); mp.from = 0x1111; mp.to = 0xAABB; mp.id = 7; mp.decoded = data
    var fr3 = ProtoWriter(); fr3.message(2, mp.encode())
    s.handleFromRadio(fr3.data)
    s.handleFromRadio(fr3.data) // duplicate
    let texts = events.compactMap { e -> MeshtasticTextMessage? in if case .text(let t) = e { return t }; return nil }
    check(texts.count == 1 && texts[0].text == "ping" && texts[0].isDirect, "incoming DM decoded once")
    data = MTData(portnum: 5, payload: { var r = ProtoWriter(); r.uint(3, 0, omitZero: false); return r.data }(), requestID: id)
    mp = MTMeshPacket(); mp.from = 0x1234_5678; mp.decoded = data
    var fr4 = ProtoWriter(); fr4.message(2, mp.encode())
    s.handleFromRadio(fr4.data)
    check(events.contains(.ack(packetID: id, ok: true, reason: 0)), "routing ack")
    check(s.handleFromRadio(Data()) == false, "empty read ends drain")
    // Negative int32 & malformed input don't crash.
    var neg = ProtoWriter(); neg.int32(12, -90)
    let negVal = try ProtoReader.fields(neg.data).first?.int32
    check(negVal == -90, "negative int32")
    check((try? ProtoReader.fields(Data([0x0A, 0x05, 0x01]))) == nil, "truncated rejected")
}

func runMeshCoreTests() throws {
    var writes: [Data] = []
    var events: [MCEvent] = []
    let s = MeshCoreSession()
    s.write = { writes.append($0) }
    s.onEvent = { events.append($0) }
    s.now = { Date(timeIntervalSince1970: 1_234_567_890) }
    s.start()
    check(writes.count == 1 && writes[0].first == 0x01, "APP_START first, one command in flight")
    // SELF_INFO reply
    var selfInfo = [UInt8](repeating: 0, count: 58); selfInfo[0] = 5
    for i in 4..<36 { selfInfo[i] = UInt8(i) }
    s.handleNotification(Data(selfInfo + Array("Pocket".utf8)))
    check(s.selfInfo?.name == "Pocket", "self info parsed")
    check(writes.last == Data([0x16, 0x03]), "DEVICE_QUERY next")
    var dev = [UInt8](repeating: 0, count: 82); dev[0] = 13; dev[1] = 9; dev[3] = 2
    s.handleNotification(Data(dev))
    check(writes.last == Data([0x06, 0xD2, 0x02, 0x96, 0x49]), "SET_DEVICE_TIME LE")
    s.handleNotification(Data([0x00]))
    check(writes.last == Data([0x04]), "GET_CONTACTS")
    var contact = [UInt8](repeating: 0, count: 1 + 32 + 3 + 64 + 32 + 16); contact[0] = 3
    for i in 1...32 { contact[i] = 0xC0 &+ UInt8(i) }
    let nameStart = 1 + 32 + 3 + 64
    for (k, ch) in "Ridge".utf8.enumerated() { contact[nameStart + k] = ch }
    s.handleNotification(Data(contact))
    s.handleNotification(Data([0x04]))
    check(s.contacts.count == 1 && s.contacts.values.first?.name == "Ridge", "contact parsed")
    check(writes.last == Data([0x1F, 0x00]), "GET_CHANNEL 0 (max_channels from DEVICE_INFO = 2)")
    var chInfo = [UInt8](repeating: 0, count: 50); chInfo[0] = 0x12; chInfo[1] = 0
    for (k, ch) in "Public".utf8.enumerated() { chInfo[2 + k] = ch }
    s.handleNotification(Data(chInfo))
    chInfo[1] = 1; for k in 2..<34 { chInfo[k] = 0 }
    s.handleNotification(Data(chInfo))
    check(events.contains(.ready), "ready after last channel")
    check(writes.last == Data([0x0A]), "SYNC_NEXT_MESSAGE after setup")
    // channel message V3: 0x11 snr r r idx path type ts(4) text
    s.handleNotification(Data([0x11, 0x18, 0, 0, 0, 0xFF, 0] + [0xD2, 0x02, 0x96, 0x49] + Array("Ridge: hi".utf8)))
    let chMsg = events.compactMap { e -> MCTextMessage? in if case .message(let m) = e { return m }; return nil }.last
    check(chMsg?.origin == .channel(index: 0) && chMsg?.text == "Ridge: hi" && chMsg?.snr == 6.0, "channel msg v3")
    check(writes.last == Data([0x0A]), "keeps draining after a message")
    // contact message V3
    let prefix = Array(Data(contact[1...6]))
    s.handleNotification(Data([0x10, 0xF8, 0, 0] + prefix + [2, 0] + [0xD2, 0x02, 0x96, 0x49] + Array("yo".utf8)))
    let dm = events.compactMap { e -> MCTextMessage? in if case .message(let m) = e { return m }; return nil }.last
    check(dm?.origin == .contact(prefix: Data(prefix)) && dm?.text == "yo" && dm?.snr == -2.0, "contact msg v3")
    s.handleNotification(Data([0x0A]))
    // send DM
    s.sendDirect("on my way", toPrefix: Data(prefix))
    check(writes.last!.prefix(7) == Data([0x02, 0x00, 0x00, 0xD2, 0x02, 0x96, 0x49]) && writes.last!.subdata(in: 7..<13) == Data(prefix), "SEND_TXT_MSG layout")
    s.handleNotification(Data([0x06, 0x01, 0x78, 0x56, 0x34, 0x12, 0x10, 0x27, 0, 0]))
    check(events.contains(.sent(expectedAck: 0x1234_5678, timeoutMs: 10000)), "MSG_SENT parsed")
    s.handleNotification(Data([0x82, 0x78, 0x56, 0x34, 0x12, 0x2C, 0x01, 0, 0]))
    check(events.contains(.sendConfirmed(ack: 0x1234_5678, roundTripMs: 300)), "SEND_CONFIRMED parsed")
    s.sendChannel("hello", channel: 0)
    check(writes.last == Data([0x03, 0x00, 0x00, 0xD2, 0x02, 0x96, 0x49] + Array("hello".utf8)), "SEND_CHANNEL_TXT_MSG matches doc example layout")
    check(MeshCoreCodec.decode(Data([0x07])) == nil && MeshCoreCodec.decode(Data([0x10, 1])) == nil, "short frames rejected")
}

func runChannelTests() throws {
    check(ChannelKeys(code: "  Hello   World ") == ChannelKeys(code: "hello world"), "code normalization")
    check(ChannelKeys(code: "abc") == nil, "min length")
    let k = ChannelKeys(code: "camp42")!
    let env = try ChannelCodec.seal(keys: k, originID: Data(repeating: 1, count: 8), nickname: "ann", body: "meet at 6",
                                    kind: .text, timestampMs: 123)
    let m = ChannelCodec.open(env, keys: k)
    check(m?.body == "meet at 6" && m?.nickname == "ann" && m?.ttl == 5, "seal/open")
    check(ChannelCodec.open(env, keys: ChannelKeys(code: "camp43")!) == nil, "wrong code rejected")
    var tampered = env; tampered[tampered.count - 20] ^= 1
    check(ChannelCodec.open(tampered, keys: k) == nil, "tamper rejected")
    check(ChannelCodec.open(ChannelEnvelopeHeader.withTTL(env, 2), keys: k)?.ttl == 2, "ttl is mutable, outside AAD")

    // Three routers: phoneA (LAN) <-> phoneB (LAN + bitchat bridge) <-> phoneC (bitchat only).
    let A = ChannelRouter(originID: Data(repeating: 0xA, count: 8), nickname: "A")
    let B = ChannelRouter(originID: Data(repeating: 0xB, count: 8), nickname: "B")
    let C = ChannelRouter(originID: Data(repeating: 0xC, count: 8), nickname: "C")
    var inbox: [String: [String]] = [:]
    for (r, name) in [(A, "A"), (B, "B"), (C, "C")] {
        r.onEvent = { if case .message(let msg, _, _, _) = $0, msg.kind == .text { inbox[name, default: []].append(msg.body) } }
    }
    A.join(code: "camp42"); B.join(code: "camp42", bridge: true); C.join(code: "camp42", bridge: true)
    var wire: [(Data, ChannelPath, String)] = []  // envelope, path, from
    A.transmit = { e, p, _ in if p == .lan { wire.append((e, p, "A")) } }
    B.transmit = { e, p, _ in wire.append((e, p, "B")) }
    C.transmit = { e, p, _ in if p == .bitchat { wire.append((e, p, "C")) } }
    func deliver() {
        var n = 0
        while !wire.isEmpty && n < 100 {
            let (e, p, from) = wire.removeFirst(); n += 1
            switch (p, from) {
            case (.lan, "A"): B.ingest(e, from: ChannelLinkRef(path: .lan, id: "A"))
            case (.lan, "B"): A.ingest(e, from: ChannelLinkRef(path: .lan, id: "B"))
            case (.bitchat, "B"): C.ingest(e, from: ChannelLinkRef(path: .bitchat, id: "mesh"))
            case (.bitchat, "C"): B.ingest(e, from: ChannelLinkRef(path: .bitchat, id: "mesh"))
            default: break
            }
        }
    }
    A.send(text: "from A", channelID: k.channelID); deliver()
    check(inbox["B"] == ["from A"] && inbox["C"] == ["from A"], "LAN -> bitchat bridge hop")
    C.send(text: "from C", channelID: k.channelID); deliver()
    check(inbox["A"] == ["from C"], "bitchat -> LAN hop")
    check(inbox["C"] == ["from A"], "no echo to origin")
    // TTL exhaustion: ttl 1 is delivered but not forwarded.
    A.send(text: "one hop", channelID: k.channelID, ttl: 1); deliver()
    check(inbox["B"]?.last == "one hop" && inbox["C"]?.last != "one hop", "ttl stops forwarding")
    // Rate limit: burst 3 then drops.
    B.bridgeBucket = TokenBucket(capacity: 3, perMinute: 6)
    var bridged = 0
    B.transmit = { _, p, _ in if p == .bitchat { bridged += 1 } }
    for i in 0..<10 { B.send(text: "spam \(i)", channelID: k.channelID) }
    check(bridged == 3 && B.bridgeDropsRateLimited == 7, "bridge rate limit")
    // Not bridged when opt-in is off.
    B.setBridge(false, channelID: k.channelID)
    B.bridgeBucket = TokenBucket(capacity: 3, perMinute: 6)
    bridged = 0
    B.send(text: "local only", channelID: k.channelID)
    check(bridged == 0, "bridge is opt-in")
}

func runAppCoreTests() throws {
    let store = ChatStore()
    let room = ConversationID.room(.meshtastic, "0")
    var incoming = 0
    store.onIncoming = { _ in incoming += 1 }
    let t0 = Date(timeIntervalSince1970: 100)
    store.append(UnifiedMessage(id: "1", conversation: room, senderName: "x", senderKey: "!1", text: "a", timestamp: t0, outgoing: false, state: .received))
    store.append(UnifiedMessage(id: "1", conversation: room, senderName: "x", senderKey: "!1", text: "a", timestamp: t0, outgoing: false, state: .received))
    store.append(UnifiedMessage(id: "0", conversation: room, senderName: "x", senderKey: "!1", text: "earlier", timestamp: t0.addingTimeInterval(-5), outgoing: false, state: .received))
    check(store.messages[room]?.map { $0.id } == ["0", "1"] && incoming == 2, "dedup + ordering")
    check(store.unread[room] == 2, "unread count")
    store.markRead(room)
    check(store.totalUnread == 0, "mark read")
    let dm = ConversationID.direct(.bitchat, "abcd")
    store.append(UnifiedMessage(id: "m", conversation: dm, senderName: "me", senderKey: "me", text: "hi", timestamp: t0, outgoing: true, state: .sending))
    store.updateState(messageID: "m", in: dm, to: .delivered)
    store.updateState(messageID: "m", in: dm, to: .sent)
    check(store.messages[dm]?.first?.state == .delivered, "no state downgrade")
    store.upsert(UnifiedPerson(network: .bitchat, key: "abcd", displayName: "bob", detail: "", isOnline: true, isFavorite: false, canMessage: true))
    store.toggleFavorite(personID: "bitchat:abcd")
    check(store.summaries().first?.conversation == dm, "favorites sort first")

    // Connection budget
    let now = Date()
    let lora = RadioCandidate(id: "radio", kind: .meshtastic, name: "T-Echo", rssi: -80, lastSeen: now)
    let p1 = RadioCandidate(id: "p1", kind: .bitchat, name: "phone1", rssi: -60, lastSeen: now)
    let p2 = RadioCandidate(id: "p2", kind: .bitchat, name: "phone2", rssi: -70, lastSeen: now)
    let other = RadioCandidate(id: "other", kind: .meshcore, name: "x", rssi: -40, lastSeen: now)
    var pol = ConnectionPolicy(); pol.preferredRadioID = "radio"
    var plan = ConnectionPlanner.plan(policy: pol, candidates: [lora, p1, p2, other], connected: [:], now: now)
    check(Set(plan.connect) == ["radio", "p1"], "radio + best bitchat peer, never the unchosen LoRa")
    plan = ConnectionPlanner.plan(policy: pol, candidates: [lora, p1, p2], connected: ["p1": now, "p2": now], now: now)
    check(plan.connect == ["radio"] && plan.disconnect == ["p2"], "radio evicts weakest bitchat link")
    pol.preferredRadioID = nil
    plan = ConnectionPlanner.plan(policy: pol, candidates: [p1, p2], connected: [:], now: now)
    check(Set(plan.connect) == ["p1", "p2"], "two bitchat peers without a radio")
    let strong = RadioCandidate(id: "p3", kind: .bitchat, name: "p3", rssi: -45, lastSeen: now)
    plan = ConnectionPlanner.plan(policy: pol, candidates: [p1, p2, strong], connected: ["p1": now, "p2": now.addingTimeInterval(-120)], now: now)
    check(plan.connect == ["p3"] && plan.disconnect == ["p2"], "hysteresis swap of weak long-lived link")
    plan = ConnectionPlanner.plan(policy: pol, candidates: [p1, p2, strong], connected: ["p1": now, "p2": now], now: now)
    check(plan.connect.isEmpty && plan.disconnect.isEmpty, "no swap before min dwell")
    let total = ConnectionPlanner.plan(policy: ConnectionPolicy(maxConnections: 2, preferredRadioID: "radio"),
                                       candidates: [lora, p1, p2, strong], connected: [:], now: now)
    check(total.connect.count <= 2, "never exceeds 2")

    // Companion protocol round trip
    let msg = CompanionMessage.sendRoom(conversation: .room(.channel, "a1b2"), text: "yo", clientID: "c1")
    check(CompanionMessage.decode(fromDictionary: msg.encodeToDictionary()) == msg, "companion codec")
}
