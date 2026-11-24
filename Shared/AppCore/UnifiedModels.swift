//
// UnifiedModels.swift — bitchat-watch
//
// Network-neutral models behind the watch's single inbox. Every conversation,
// person and message carries its NetworkKind so the UI can always label which
// network (and which radio / phone path) it belongs to. Nothing is merged
// across networks: the same human on bitchat and Meshtastic is two people.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum NetworkKind: String, Codable, CaseIterable, Hashable {
    case bitchat          // direct BLE mesh from the watch (leaf)
    case bitchatPhone     // bitchat via the paired iPhone (WatchConnectivity)
    case meshtastic       // Meshtastic LoRa radio over BLE
    case meshcore         // MeshCore LoRa companion radio over BLE
    case channel          // local channel chat (LAN/MPC/bridge) via the iPhone

    var shortLabel: String {
        switch self {
        case .bitchat: return "bitchat"
        case .bitchatPhone: return "bitchat·📱"
        case .meshtastic: return "Meshtastic"
        case .meshcore: return "MeshCore"
        case .channel: return "Wi-Fi ch"
        }
    }
    var badge: String {
        switch self {
        case .bitchat: return "BC"
        case .bitchatPhone: return "BC📱"
        case .meshtastic: return "MT"
        case .meshcore: return "MC"
        case .channel: return "CH"
        }
    }
}

struct ConversationID: Hashable, Codable, CustomStringConvertible {
    enum Scope: String, Codable { case room, direct }
    let network: NetworkKind
    let scope: Scope
    /// room: channel key ("public", Meshtastic channel index, MeshCore channel index, channel-chat ID hex)
    /// direct: peer key (bitchat peerID hex, "!nodenum", MeshCore pubkey prefix hex)
    let key: String

    static func room(_ n: NetworkKind, _ key: String) -> ConversationID { .init(network: n, scope: .room, key: key) }
    static func direct(_ n: NetworkKind, _ key: String) -> ConversationID { .init(network: n, scope: .direct, key: key) }
    var description: String { "\(network.rawValue)/\(scope.rawValue)/\(key)" }
}

enum DeliveryState: String, Codable {
    case sending, sent, delivered, read, failed, received
}

struct UnifiedMessage: Codable, Identifiable, Equatable {
    let id: String
    let conversation: ConversationID
    let senderName: String
    let senderKey: String
    let text: String
    let timestamp: Date
    let outgoing: Bool
    var state: DeliveryState
    /// Arrived (or left) through a bridge hop, e.g. a channel message tunnelled via bitchat.
    var bridged: Bool = false
    /// Free-form path note for the detail view ("LAN", "MPC", "bitchat bridge", "SNR 6.5").
    var via: String? = nil
}

struct UnifiedPerson: Codable, Identifiable, Hashable {
    var id: String { "\(network.rawValue):\(key)" }
    let network: NetworkKind
    let key: String
    var displayName: String
    var detail: String           // fingerprint prefix, node id, RSSI/SNR, hops
    var isOnline: Bool
    var isFavorite: Bool
    var canMessage: Bool
    var secureSession: Bool = false
}

struct RoomInfo: Codable, Hashable, Identifiable {
    var id: ConversationID { conversation }
    let conversation: ConversationID
    var title: String
    var bridged: Bool = false     // channel chat: bridged into bitchat (opt-in)
    var memberCount: Int? = nil
}
