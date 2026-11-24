//
// ChatTransport.swift — bitchat-watch
//
// The transport abstraction behind the unified inbox. Each network adapter
// (BitchatTransport, MeshtasticTransport, MeshCoreTransport, CompanionTransport)
// converts its protocol into UnifiedMessage / UnifiedPerson / RoomInfo and
// reports to a TransportSink (the app model). All on the main actor.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

@MainActor
protocol TransportSink: AnyObject {
    func transport(_ t: ChatTransport, didReceive message: UnifiedMessage)
    func transport(_ t: ChatTransport, didUpdate person: UnifiedPerson)
    func transport(_ t: ChatTransport, didUpdate room: RoomInfo)
    func transport(_ t: ChatTransport, message id: String, didChangeTo state: DeliveryState)
    func transportStatusDidChange(_ t: ChatTransport)
}

@MainActor
protocol ChatTransport: AnyObject {
    /// Primary network label for this transport (Companion reports two: .bitchatPhone and .channel).
    var network: NetworkKind { get }
    var sink: TransportSink? { get set }
    /// One-line human status for the Radios screen ("2 peers", "T-Echo · config ok", "iPhone reachable").
    var statusText: String { get }
    var isActive: Bool { get }
    func canSend(in conversation: ConversationID) -> Bool
    /// Sends and returns the optimistic local copy (state .sending/.sent), or nil if not possible.
    func send(_ text: String, in conversation: ConversationID) -> UnifiedMessage?
    func markRead(_ conversation: ConversationID)
}

extension ChatTransport {
    func markRead(_ conversation: ConversationID) {}
}
