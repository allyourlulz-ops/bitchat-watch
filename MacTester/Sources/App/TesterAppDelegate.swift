//
// TesterAppDelegate.swift — bitchat Mac tester (AppKit, macOS 10.14+, Swift 5.0)
//
// Loads (or creates) the tester identity from UserDefaults, builds the menu and
// the main window. Launch arguments / defaults:
//   -nickname <name>      nickname announced on the mesh (default "mac-tester")
//   -testnet YES          use the upstream Debug ("testnet") service UUID …4B5A
//   -freshIdentity YES    generate a new identity instead of the stored one
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
import AppKit

final class TesterAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: TesterWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        let d = UserDefaults.standard
        var identity: BTIdentity
        if !d.bool(forKey: "freshIdentity"), let stored = d.dictionary(forKey: "identity") as? [String: String],
           let id = BTIdentity.deserialize(stored) {
            identity = id
        } else {
            identity = BTIdentity.generate()
            d.set(identity.serialize(), forKey: "identity")
        }
        let nick = d.string(forKey: "nickname") ?? "mac-tester"
        let c = TesterWindowController(identity: identity, nickname: nick, testnet: d.bool(forKey: "testnet"))
        controller = c
        c.showWindow(nil)
        c.start()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { return true }

    @objc private func exportLog() { controller?.exportLog() }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit bitchat tester", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let export = NSMenuItem(title: "Export Log…", action: #selector(exportLog), keyEquivalent: "e")
        export.target = self
        fileMenu.addItem(export)
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        NSApp.mainMenu = main
    }
}
