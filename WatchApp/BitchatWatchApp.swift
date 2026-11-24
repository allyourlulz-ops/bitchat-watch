//
// BitchatWatchApp.swift — bitchat-watch (watchOS 26)
// SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

@main
struct BitchatWatchApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onAppear { model.start() }
                .onChange(of: phase) { _, p in model.scenePhaseChanged(active: p == .active) }
        }
    }
}
