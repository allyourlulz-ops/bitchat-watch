//
// ChatStore.swift — bitchat-watch
//
// Platform-independent inbox state (no SwiftUI/Combine so it can be tested on
// Linux). The watch wraps it in an ObservableObject (WatchApp/AppModel.swift).
// Not thread-safe: mutate on the main actor only.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

struct ConversationSummary: Equatable, Identifiable {
    var id: ConversationID { conversation }
    let conversation: ConversationID
    let title: String
    let lastText: String
    let lastDate: Date
    let unread: Int
    let bridged: Bool
    let isFavorite: Bool
}

final class ChatStore {
    var maxMessagesPerConversation = 200
    var onChange: () -> Void = {}
    /// Called for an incoming message the UI should notify about (not for history sync).
    var onIncoming: (UnifiedMessage) -> Void = { _ in }

    private(set) var messages: [ConversationID: [UnifiedMessage]] = [:]
    private(set) var unread: [ConversationID: Int] = [:]
    private(set) var people: [String: UnifiedPerson] = [:]
    private(set) var rooms: [ConversationID: RoomInfo] = [:]
    private(set) var favorites: Set<String>
    private var ids = Set<String>()
    var activeConversation: ConversationID?

    init(favorites: Set<String> = []) {
        self.favorites = favorites
    }

    // MARK: messages

    func append(_ m: UnifiedMessage, notify: Bool = true) {
        let key = "\(m.conversation)#\(m.id)"
        guard !ids.contains(key) else { return }
        ids.insert(key)
        var list = messages[m.conversation, default: []]
        // keep chronological; most arrive in order so append is the fast path
        if let last = list.last, last.timestamp > m.timestamp {
            let idx = list.firstIndex { $0.timestamp > m.timestamp } ?? list.count
            list.insert(m, at: idx)
        } else {
            list.append(m)
        }
        if list.count > maxMessagesPerConversation {
            for old in list.prefix(list.count - maxMessagesPerConversation) { ids.remove("\(old.conversation)#\(old.id)") }
            list.removeFirst(list.count - maxMessagesPerConversation)
        }
        messages[m.conversation] = list
        if !m.outgoing && activeConversation != m.conversation {
            unread[m.conversation, default: 0] += 1
        }
        if notify && !m.outgoing { onIncoming(m) }
        onChange()
    }

    func updateState(messageID: String, in conversation: ConversationID?, to state: DeliveryState) {
        let targets = conversation.map { [$0] } ?? Array(messages.keys)
        for c in targets {
            guard var list = messages[c], let i = list.firstIndex(where: { $0.id == messageID }) else { continue }
            // never downgrade read -> delivered etc.
            let rank: [DeliveryState: Int] = [.sending: 0, .failed: 0, .sent: 1, .delivered: 2, .read: 3, .received: 3]
            if (rank[state] ?? 0) >= (rank[list[i].state] ?? 0) || state == .failed {
                list[i].state = state
                messages[c] = list
                onChange()
            }
            return
        }
    }

    func markRead(_ c: ConversationID) {
        if unread.removeValue(forKey: c) != nil { onChange() }
    }

    // MARK: people / rooms

    func upsert(_ p: UnifiedPerson) {
        var p = p
        p.isFavorite = favorites.contains(p.id)
        if people[p.id] != p { people[p.id] = p; onChange() }
    }

    func setOffline(network: NetworkKind) {
        var changed = false
        for (k, var p) in people where p.network == network && p.isOnline {
            p.isOnline = false; p.secureSession = false; people[k] = p; changed = true
        }
        if changed { onChange() }
    }

    func removePerson(id: String) { if people.removeValue(forKey: id) != nil { onChange() } }

    func upsert(room: RoomInfo) {
        if rooms[room.conversation] != room { rooms[room.conversation] = room; onChange() }
    }

    func removeRooms(network: NetworkKind) {
        let before = rooms.count
        rooms = rooms.filter { $0.key.network != network }
        if rooms.count != before { onChange() }
    }

    @discardableResult
    func toggleFavorite(personID: String) -> Bool {
        let on = !favorites.contains(personID)
        if on { favorites.insert(personID) } else { favorites.remove(personID) }
        if var p = people[personID] { p.isFavorite = on; people[personID] = p }
        onChange()
        return on
    }

    // MARK: derived

    func title(for c: ConversationID) -> String {
        switch c.scope {
        case .room: return rooms[c]?.title ?? (c.key == "public" ? "Public" : "#\(c.key)")
        case .direct: return people["\(c.network.rawValue):\(c.key)"]?.displayName ?? String(c.key.prefix(8))
        }
    }

    func summaries() -> [ConversationSummary] {
        var keys = Set(messages.keys)
        keys.formUnion(rooms.keys)
        return keys.map { c in
            let last = messages[c]?.last
            let personID = "\(c.network.rawValue):\(c.key)"
            return ConversationSummary(conversation: c, title: title(for: c), lastText: last?.text ?? "",
                                       lastDate: last?.timestamp ?? .distantPast, unread: unread[c] ?? 0,
                                       bridged: rooms[c]?.bridged ?? false,
                                       isFavorite: c.scope == .direct && favorites.contains(personID))
        }.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            return $0.lastDate > $1.lastDate
        }
    }

    func sortedPeople(network: NetworkKind? = nil) -> [UnifiedPerson] {
        people.values.filter { network == nil || $0.network == network }.sorted {
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite }
            if $0.isOnline != $1.isOnline { return $0.isOnline }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    var totalUnread: Int { unread.values.reduce(0, +) }
}
