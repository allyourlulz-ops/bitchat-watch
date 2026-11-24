//
// Notifier.swift — bitchat-watch
// Haptic + local notification for incoming messages. While the app is
// frontmost we only play a haptic; local notifications cover the short window
// after the wrist drops while the app is still running (watchOS suspends the
// app soon after, and BLE links drop with it — see README).
// Notification text never includes message bodies for DMs (privacy), only
// "New private message · <network>".
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import UserNotifications
#if os(watchOS)
import WatchKit
#endif

@MainActor
final class Notifier {
    var enabled = true
    var appIsActive = true
    private var lastBuzz = Date.distantPast

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func incoming(_ m: UnifiedMessage, title: String, isFavorite: Bool) {
        guard enabled else { return }
        let isDM = m.conversation.scope == .direct
        // Rate-limit haptics so a busy public room doesn't buzz constantly.
        let now = Date()
        if isDM || isFavorite || now.timeIntervalSince(lastBuzz) > 30 {
            lastBuzz = now
            #if os(watchOS)
            WKInterfaceDevice.current().play(isDM ? .notification : .click)
            #endif
        }
        guard !appIsActive, isDM || isFavorite else { return }
        let content = UNMutableNotificationContent()
        content.title = isDM ? "\(m.senderName) · \(m.conversation.network.shortLabel)" : title
        content.body = isDM ? "New private message" : "\(m.senderName): \(m.text.prefix(80))"
        content.threadIdentifier = m.conversation.description
        content.userInfo = ["conversation": m.conversation.description]
        let req = UNNotificationRequest(identifier: m.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
