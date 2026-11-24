//
// CompanionProtocol.swift — bitchat-watch
//
// Messages exchanged between the watch app and the iPhone companion bridge over
// WatchConnectivity. Shared verbatim by both sides. Each message is JSON in a
// WCSession message dictionary under key "hk" (sendMessage when reachable,
// transferUserInfo as a queued fallback for watch→phone sends). The phone also
// keeps an applicationContext snapshot so the watch has something to show the
// moment it launches.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum CompanionWire {
    static let key = "hk"
    static let version = 1
    static let contextKey = "hkSnapshot"
}

struct CompanionSnapshot: Codable, Equatable {
    var phoneNickname: String
    var people: [UnifiedPerson]          // network == .bitchatPhone
    var rooms: [RoomInfo]                // bitchat public + joined channel-chat channels
    var recent: [UnifiedMessage]         // last N messages across rooms/DMs
    var bridgeAvailable: Bool            // phone can tunnel channel chat into bitchat
}

enum CompanionMessage: Codable, Equatable {
    // phone -> watch
    case snapshot(CompanionSnapshot)
    case message(UnifiedMessage)
    case people([UnifiedPerson])
    case rooms([RoomInfo])
    case delivery(messageID: String, state: DeliveryState)
    case error(String)

    // watch -> phone
    case requestSnapshot
    case sendRoom(conversation: ConversationID, text: String, clientID: String)
    case sendDirect(peerKey: String, text: String, clientID: String)
    case joinChannel(code: String, bridge: Bool)
    case leaveChannel(channelIDHex: String)
    case setChannelBridge(channelIDHex: String, enabled: Bool)
    case toggleFavorite(peerKey: String)

    func encodeToDictionary() -> [String: Any] {
        let data = (try? JSONEncoder().encode(CompanionEnvelope(v: CompanionWire.version, m: self))) ?? Data()
        return [CompanionWire.key: data]
    }

    static func decode(fromDictionary d: [String: Any]) -> CompanionMessage? {
        guard let data = d[CompanionWire.key] as? Data,
              let env = try? JSONDecoder().decode(CompanionEnvelope.self, from: data),
              env.v == CompanionWire.version else { return nil }
        return env.m
    }
}

struct CompanionEnvelope: Codable, Equatable {
    let v: Int
    let m: CompanionMessage
}
