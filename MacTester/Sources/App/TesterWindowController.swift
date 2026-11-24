//
// TesterWindowController.swift — bitchat Mac tester UI (AppKit, macOS 10.14+, Swift 5.0)
//
// One window, built in code (no nib/storyboard, no SwiftUI):
//   left   — connected peers table (bitchat peers + BLE links + MPC/LAN channel peers)
//   right  — packet log table (time, dir, link, decoded type/summary, hex)
//   bottom — chat transcript, public chat send box (+ DM to selected peer),
//            channel code / join / bridge toggle / channel send, relay toggle,
//            Export log… button.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import AppKit

final class TesterWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let node: BTMeshNode
    let ble: BLEController
    let router: BTChannelRouter
    let mpc = TesterMPCLink()
    let lan = TesterLANLink()

    private var log = [BTLogEntry]()
    private let maxLog = 20000
    private var peerRows = [[String]]()     // [name, id, via]
    private var activeChannel: String?

    private let peersTable = NSTableView()
    private let logTable = NSTableView()
    private let chatView = NSTextView()
    private let sendField = NSTextField()
    private let channelCodeField = NSTextField()
    private let channelSendField = NSTextField()
    private let bridgeBox = NSButton(checkboxWithTitle: "Bridge channel over bitchat (0x7E)", target: nil, action: nil)
    private let relayBox = NSButton(checkboxWithTitle: "Relay between BLE links", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "starting…")

    init(identity: BTIdentity, nickname: String, testnet: Bool) {
        node = BTMeshNode(identity: identity, nickname: nickname)
        ble = BLEController(node: node, testnet: testnet)
        router = BTChannelRouter(origin: identity.peerID, nickname: nickname)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "bitchat tester — \(nickname) (\(identity.peerIDHex))"
        w.minSize = NSSize(width: 900, height: 600)
        super.init(window: w)
        w.delegate = self
        buildUI(in: w.contentView!)
        wire()
        w.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: wiring

    private func wire() {
        node.onLog = { [weak self] e in self?.append(e) }
        node.onChat = { [weak self] line in self?.chat(line) }
        node.onPeersChanged = { [weak self] in self?.refreshPeers() }
        node.onChannelTunnel = { [weak self] payload, _, link in self?.router.ingest(payload, path: "bitchat", link: link) }
        ble.onStatus = { [weak self] s in self?.status(s) }
        ble.onLinksChanged = { [weak self] in self?.refreshPeers() }

        router.transmit = { [weak self] env, path, except in
            guard let self = self else { return }
            switch path {
            case "lan": self.lan.send(env, except: except)
            case "mpc": self.mpc.send(env, except: except)
            case "bitchat": self.node.sendChannelTunnel(env, ttl: env.count > 5 ? env[5] : 1)
            default: break
            }
        }
        router.onMessage = { [weak self] m, via in self?.chat("#\(BTHex.encode(m.channelID).prefix(6)) <\(m.nickname)> \(m.body)  [via \(via)]") }
        router.onNote = { [weak self] n in self?.status(n) }
        mpc.onEnvelope = { [weak self] e, link in self?.router.ingest(e, path: "mpc", link: link) }
        mpc.onPeersChanged = { [weak self] _ in self?.refreshPeers() }
        lan.onEnvelope = { [weak self] e, link in self?.router.ingest(e, path: "lan", link: link) }
        lan.onPeersChanged = { [weak self] _ in self?.refreshPeers() }
        lan.onNote = { [weak self] n in self?.status(n) }
    }

    func start() { ble.start() }

    // MARK: layout

    private func buildUI(in root: NSView) {
        let W = root.bounds.width, H = root.bounds.height

        // bottom controls (fixed height 200)
        let controls = NSView(frame: NSRect(x: 0, y: 0, width: W, height: 200))
        controls.autoresizingMask = [.width, .maxYMargin]
        root.addSubview(controls)

        let chatScroll = NSScrollView(frame: NSRect(x: 10, y: 100, width: W - 20, height: 95))
        chatScroll.autoresizingMask = [.width]
        chatScroll.hasVerticalScroller = true
        chatView.frame = chatScroll.bounds
        chatView.isEditable = false
        chatView.font = NSFont.userFixedPitchFont(ofSize: 11)
        chatView.autoresizingMask = [.width]
        chatScroll.documentView = chatView
        controls.addSubview(chatScroll)

        sendField.frame = NSRect(x: 10, y: 68, width: W - 330, height: 24)
        sendField.autoresizingMask = [.width]
        sendField.placeholderString = "Public chat message"
        sendField.target = self; sendField.action = #selector(sendPublic)
        controls.addSubview(sendField)
        controls.addSubview(button("Send public", x: W - 312, y: 66, w: 110, #selector(sendPublic)))
        controls.addSubview(button("DM selected", x: W - 196, y: 66, w: 110, #selector(sendDM)))
        controls.addSubview(button("Announce", x: W - 82, y: 66, w: 72, #selector(announce)))

        channelCodeField.frame = NSRect(x: 10, y: 38, width: 180, height: 24)
        channelCodeField.placeholderString = "Channel code"
        controls.addSubview(channelCodeField)
        controls.addSubview(button("Join", x: 196, y: 36, w: 60, #selector(joinChannel)))
        bridgeBox.frame = NSRect(x: 262, y: 40, width: 250, height: 20)
        bridgeBox.target = self; bridgeBox.action = #selector(toggleBridge)
        controls.addSubview(bridgeBox)
        channelSendField.frame = NSRect(x: 516, y: 38, width: W - 640, height: 24)
        channelSendField.autoresizingMask = [.width]
        channelSendField.placeholderString = "Channel message"
        channelSendField.target = self; channelSendField.action = #selector(sendChannel)
        controls.addSubview(channelSendField)
        controls.addSubview(button("Send channel", x: W - 118, y: 36, w: 108, #selector(sendChannel)))

        relayBox.frame = NSRect(x: 10, y: 10, width: 200, height: 20)
        relayBox.target = self; relayBox.action = #selector(toggleRelay)
        controls.addSubview(relayBox)
        controls.addSubview(button("Export log…", x: 216, y: 6, w: 110, #selector(exportLog)))
        controls.addSubview(button("Clear log", x: 330, y: 6, w: 90, #selector(clearLog)))
        statusLabel.frame = NSRect(x: 430, y: 10, width: W - 440, height: 18)
        statusLabel.autoresizingMask = [.width]
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.textColor = NSColor.secondaryLabelColor
        controls.addSubview(statusLabel)

        // top: peers (left) + packet log (right)
        let split = NSSplitView(frame: NSRect(x: 10, y: 205, width: W - 20, height: H - 215))
        split.isVertical = true
        split.dividerStyle = .thin
        split.autoresizingMask = [.width, .height]
        root.addSubview(split)
        split.addSubview(table(peersTable, columns: [("name", "Peer / link", 120), ("id", "ID", 140), ("via", "Via", 70)],
                               frame: NSRect(x: 0, y: 0, width: 340, height: split.bounds.height)))
        split.addSubview(table(logTable, columns: [("time", "Time", 90), ("dir", "Dir", 50), ("link", "Link", 90),
                                                   ("summary", "Decoded", 330), ("hex", "Hex", 600)],
                               frame: NSRect(x: 0, y: 0, width: split.bounds.width - 341, height: split.bounds.height)))
        split.adjustSubviews()
        split.setPosition(340, ofDividerAt: 0)
    }

    private func button(_ title: String, x: CGFloat, y: CGFloat, w: CGFloat, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.frame = NSRect(x: x, y: y, width: w, height: 28)
        let mask: NSView.AutoresizingMask = x > 300 ? [.minXMargin] : []
        b.autoresizingMask = mask
        return b
    }

    private func table(_ t: NSTableView, columns: [(String, String, CGFloat)], frame: NSRect) -> NSScrollView {
        let s = NSScrollView(frame: frame)
        s.hasVerticalScroller = true
        s.hasHorizontalScroller = true
        s.autoresizingMask = [.width, .height]
        for c in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.0))
            col.title = c.1
            col.width = c.2
            (col.dataCell as? NSTextFieldCell)?.font = NSFont.userFixedPitchFont(ofSize: 10)
            (col.dataCell as? NSTextFieldCell)?.lineBreakMode = .byTruncatingTail
            t.addTableColumn(col)
        }
        t.usesAlternatingRowBackgroundColors = true
        t.columnAutoresizingStyle = .noColumnAutoresizing
        t.dataSource = self
        t.delegate = self
        s.documentView = t
        return s
    }

    // MARK: table data (cell-based)

    func numberOfRows(in tableView: NSTableView) -> Int { return tableView === peersTable ? peerRows.count : log.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let key = tableColumn?.identifier.rawValue ?? ""
        if tableView === peersTable {
            guard row < peerRows.count else { return nil }
            switch key {
            case "name": return peerRows[row][0]
            case "id": return peerRows[row][1]
            default: return peerRows[row][2]
            }
        }
        guard row < log.count else { return nil }
        let e = log[row]
        switch key {
        case "time": return TesterWindowController.timeFormatter.string(from: e.time)
        case "dir": return e.direction.rawValue
        case "link": return e.link
        case "summary": return e.summary
        default: return BTHex.encode(Array(e.raw.prefix(512))) + (e.raw.count > 512 ? "…" : "")
        }
    }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool { return false }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    // MARK: updates

    private func append(_ e: BTLogEntry) {
        log.append(e)
        if log.count > maxLog { log.removeFirst(log.count - maxLog) }
        let atBottom = (logTable.enclosingScrollView?.verticalScroller?.doubleValue ?? 1) > 0.98
        logTable.reloadData()
        if atBottom { logTable.scrollRowToVisible(log.count - 1) }
    }

    private func chat(_ line: String) {
        let s = TesterWindowController.timeFormatter.string(from: Date()) + "  " + line + "\n"
        chatView.textStorage?.append(NSAttributedString(string: s, attributes: [.font: NSFont.userFixedPitchFont(ofSize: 11) ?? NSFont.systemFont(ofSize: 11),
                                                                               .foregroundColor: NSColor.textColor]))
        chatView.scrollToEndOfDocument(nil)
    }

    private func status(_ s: String) { statusLabel.stringValue = s }

    private func refreshPeers() {
        var rows = [[String]]()
        for p in node.peers.values.sorted(by: { $0.nickname < $1.nickname }) {
            rows.append([p.nickname + (p.hasSession ? " 🔒" : ""), p.peerIDHex, p.direct ? (p.link ?? "direct") : "relayed"])
        }
        for l in ble.links.ids { rows.append(["BLE link", l, BTLinkTable.isPeripheralSide(l) ? "peripheral" : "central"]) }
        for n in mpc.peerNames { rows.append(["channel peer", n, "mpc"]) }
        for n in lan.peerNames { rows.append(["channel peer", n, "lan"]) }
        peerRows = rows
        peersTable.reloadData()
    }

    // MARK: actions

    @objc private func sendPublic() {
        let t = sendField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        node.sendPublic(t)
        sendField.stringValue = ""
    }

    @objc private func sendDM() {
        let row = peersTable.selectedRow
        let t = sendField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard row >= 0, row < peerRows.count, node.peers[peerRows[row][1]] != nil, !t.isEmpty else {
            status("select a bitchat peer and type a message"); return
        }
        node.sendPrivate(t, toPeerHex: peerRows[row][1])
        sendField.stringValue = ""
    }

    @objc private func announce() { node.sendAnnounce() }

    @objc private func joinChannel() {
        guard let k = router.join(channelCodeField.stringValue, bridge: bridgeBox.state == .on) else {
            status("channel code must be at least 4 characters"); return
        }
        activeChannel = k.channelIDHex
        mpc.update(channelIDs: router.advertisedIDs)
        lan.update(channelIDs: router.advertisedIDs)
        chat("* joined channel \(k.channelIDHex.prefix(6)) (short codes are weak secrets — testing only)")
    }

    @objc private func toggleBridge() {
        if let c = activeChannel { router.setBridge(c, bridgeBox.state == .on) }
    }

    @objc private func sendChannel() {
        let t = channelSendField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = activeChannel, !t.isEmpty else { status("join a channel first"); return }
        router.send(t, channelHex: c)
        chat("#\(c.prefix(6)) <\(router.nickname)> \(t)")
        channelSendField.stringValue = ""
    }

    @objc private func toggleRelay() {
        node.relayEnabled = relayBox.state == .on
        status(node.relayEnabled ? "relay ON (TTL-1, dedup, 10–60 ms jitter)" : "relay off")
    }

    @objc private func clearLog() { log.removeAll(); logTable.reloadData() }

    @objc func exportLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "bitchat-tester-\(Int(Date().timeIntervalSince1970)).log"
        panel.allowedFileTypes = ["log", "txt"]
        guard let w = window else { return }
        let text = BTLogExport.render(log, node: node.identity.peerIDHex)
        panel.beginSheetModal(for: w) { resp in
            guard resp == .OK, let url = panel.url else { return }
            do { try text.write(to: url, atomically: true, encoding: .utf8); self.status("exported \(url.lastPathComponent)") }
            catch { self.status("export failed: \(error.localizedDescription)") }
        }
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}
