//
// main.swift — bitchat Mac tester entry point (no @main / NSApplicationMain nib; Swift 5.0)
// SPDX-License-Identifier: GPL-3.0-or-later
//
import AppKit

let app = NSApplication.shared
let delegate = TesterAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
