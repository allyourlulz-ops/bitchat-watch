//
// Checks for the Mac tester shell's non-UI logic (MacTester/Sources/Core/TesterLinks.swift).
// SPDX-License-Identifier: GPL-3.0-or-later
//
import Foundation

func runTesterShellTests() throws {
    // link table
    let t = BTLinkTable()
    check(t.limit(for: nil) == BTLinkTable.defaultLimit, "empty table uses default limit")
    t.add("p:watch", writeLimit: 244)
    t.add("c:phone", writeLimit: 512)
    t.add("c:tiny", writeLimit: 5)
    check(t.limit(for: "c:tiny") == 20, "limit clamped to ATT minimum")
    check(t.limit(for: nil) == 20 && t.limit(for: "c:phone") == 512, "broadcast uses smallest link limit")
    check(t.targets(link: nil, except: "p:watch") == ["c:phone", "c:tiny"], "broadcast skips ingress link")
    check(t.targets(link: "c:phone", except: nil) == ["c:phone"] && t.targets(link: "gone", except: nil).isEmpty, "directed targets")
    check(t.remove("c:tiny") && !t.remove("c:tiny") && t.limit(for: nil) == 244, "remove link")
    check(BTLinkTable.isPeripheralSide("p:x") && BTLinkTable.isCentralSide("c:x"), "link side prefixes")

    // chunker + stream assembler round trip with a real signed frame
    let id = BTIdentity.generate()
    let node = BTMeshNode(identity: id, nickname: "mac")
    var frames = [[UInt8]]()
    node.sendFrame = { f, _, _ in frames.append(f) }
    node.linkLimit = { _ in return 512 }
    node.sendPublic("tester shell chunking check")
    check(frames.count == 1 && frames[0].count > 100, "public frame emitted")
    let pieces = BTWriteChunker.chunks(frames[0], limit: 40)
    check(pieces.count == (frames[0].count + 39) / 40 && pieces.allSatisfy { $0.count <= 40 }, "chunk sizes")
    check(Array(pieces.joined()) == frames[0], "chunks rejoin")
    check(BTWriteChunker.chunks([1, 2, 3], limit: 1).count == 1, "chunker clamps limit to 20")
    let asm = BTStreamAssembler()
    var got = [[UInt8]]()
    for p in pieces { got += asm.append(p) }
    check(got == [frames[0]], "assembler rebuilds chunked frame")

    // LAN length framer
    let e1 = [UInt8](repeating: 0xAB, count: 70), e2 = [UInt8](repeating: 0xCD, count: 3)
    let stream = BTLengthFramer.frame(e1)! + BTLengthFramer.frame(e2)!
    let fr = BTLengthFramer()
    var envs = [[UInt8]]()
    for b in stream { envs += fr.append([b]) }
    check(envs == [e1, e2], "framer byte-by-byte")
    check(BTLengthFramer.frame([]) == nil && BTLengthFramer.frame([UInt8](repeating: 0, count: 4097)) == nil, "framer rejects empty/oversize")
    let bad = BTLengthFramer()
    _ = bad.append([0, 0, 0x20, 0x00, 1])
    check(bad.broken && bad.append(stream).isEmpty, "framer breaks on oversize length")

    // channel advertisement
    let ka = BTChannelKeys(code: "Pizza Night")!, kb = BTChannelKeys(code: "other channel")!
    let info = BTChannelAdvert.info([kb.channelIDHex, ka.channelIDHex])
    check(info["v"] == "1" && info["c"] == [ka.channelIDHex, kb.channelIDHex].sorted().joined(separator: ","), "advert info")
    check(!(info["c"] ?? "").contains("pizza"), "advert never carries code")
    check(BTChannelAdvert.shares(info, with: [ka.channelIDHex]), "shares channel")
    check(!BTChannelAdvert.shares(info, with: ["0011223344556677"]) && !BTChannelAdvert.shares(["c": info["c"]!], with: [ka.channelIDHex]), "no share / wrong version")
    let many = (0..<20).map { String(format: "%016x", $0) }
    check(BTChannelAdvert.parse(BTChannelAdvert.info(many)["c"]).count == 16, "advert capped at 16 IDs")
    check(BTChannelAdvert.shouldDial(me: "hk-a", them: "hk-b") != BTChannelAdvert.shouldDial(me: "hk-b", them: "hk-a"), "exactly one side dials")

    // LAN path end to end: tester router -> framer -> tester router
    let ra = BTChannelRouter(origin: [1, 1, 1, 1, 1, 1, 1, 1], nickname: "a")
    let rb = BTChannelRouter(origin: [2, 2, 2, 2, 2, 2, 2, 2], nickname: "b")
    ra.join("pizza night", bridge: false); rb.join("Pizza  Night", bridge: false)
    let wire = BTLengthFramer()
    var received = [String]()
    ra.transmit = { e, path, _ in if path == "lan" { for env in wire.append(BTLengthFramer.frame(e)!) { rb.ingest(env, path: "lan", link: "in-1") } } }
    rb.onMessage = { m, via in received.append("\(m.nickname)@\(via):\(m.body)") }
    ra.send("hello lan", channelHex: ka.channelIDHex)
    check(received == ["a@lan:hello lan"], "LAN framing carries channel message")

    // log export
    let entry = BTLogEntry(time: Date(timeIntervalSince1970: 0), direction: .rx, link: "p:w", raw: [0xde, 0xad], summary: "announce")
    let text = BTLogExport.render([entry], node: id.peerIDHex)
    check(text.contains("# entries 1") && text.contains("RX [p:w] announce") && text.contains("dead"), "log export")
}
