//
// ConnectionBudget.swift — bitchat-watch
//
// watchOS lets an app hold only a couple of simultaneous BLE peripheral
// connections (Apple documents a limit of 2 for watchOS Core Bluetooth). This
// planner decides which discovered peripherals get those slots:
//
//   * the user's chosen LoRa radio (Meshtastic or MeshCore) always gets one
//     slot when it is visible — that radio is the user's explicit choice;
//   * remaining slot(s) go to bitchat peers (phones/Macs advertising the
//     bitchat service), strongest RSSI first, with hysteresis so the watch
//     doesn't churn between two similar peers;
//   * LoRa radios other than the chosen one are never auto-connected;
//   * a peer that failed recently is backed off.
//
// Pure value logic, unit-tested on Linux.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum RadioKind: String, Codable, Hashable {
    case bitchat, meshtastic, meshcore
}

struct RadioCandidate: Hashable {
    let id: String              // CBPeripheral.identifier.uuidString
    let kind: RadioKind
    var name: String
    var rssi: Int
    var lastSeen: Date
}

struct ConnectionPolicy: Equatable {
    var maxConnections = 2
    /// The user's chosen LoRa radio (peripheral UUID). nil = no LoRa radio.
    var preferredRadioID: String? = nil
    /// Allow direct bitchat BLE (leaf mesh). Can be turned off to save battery.
    var directBitchatEnabled = true
    /// Ignore bitchat candidates not heard for this long.
    var staleAfter: TimeInterval = 20
    /// A new bitchat peer must beat a connected one by this many dB to replace it...
    var switchMarginDB = 12
    /// ...and the connected one must have been up at least this long.
    var minDwell: TimeInterval = 60
    var failureBackoff: TimeInterval = 30
    var minRSSI = -95
}

struct ConnectionPlan: Equatable {
    var connect: [String] = []
    var disconnect: [String] = []
}

enum ConnectionPlanner {
    static func plan(policy: ConnectionPolicy,
                     candidates: [RadioCandidate],
                     connected: [String: Date],          // id -> connectedSince
                     connecting: Set<String> = [],
                     failures: [String: Date] = [:],
                     now: Date = Date()) -> ConnectionPlan {
        var plan = ConnectionPlan()
        let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let busy = Set(connected.keys).union(connecting)

        // 1. Drop anything that's no longer allowed (wrong LoRa radio, bitchat disabled).
        for id in connected.keys {
            guard let c = byID[id] else { continue }        // unknown: keep (may be mid-discovery)
            switch c.kind {
            case .meshtastic, .meshcore:
                if id != policy.preferredRadioID { plan.disconnect.append(id) }
            case .bitchat:
                if !policy.directBitchatEnabled { plan.disconnect.append(id) }
            }
        }
        var occupied = busy.subtracting(plan.disconnect)

        // 2. Preferred radio first.
        if let pref = policy.preferredRadioID, !occupied.contains(pref), byID[pref] != nil,
           !recentlyFailed(pref, failures, policy, now) {
            if occupied.count >= policy.maxConnections {
                // evict the weakest bitchat link to make room for the user's radio
                if let victim = occupied.compactMap({ byID[$0] }).filter({ $0.kind == .bitchat }).min(by: { $0.rssi < $1.rssi }) {
                    plan.disconnect.append(victim.id)
                    occupied.remove(victim.id)
                }
            }
            if occupied.count < policy.maxConnections {
                plan.connect.append(pref)
                occupied.insert(pref)
            }
        }

        // 3. bitchat peers into the remaining slots.
        guard policy.directBitchatEnabled else { return plan }
        let reserved = (policy.preferredRadioID != nil && byID[policy.preferredRadioID!] == nil) ? 1 : 0 // keep a slot for the radio when it reappears
        let pool = candidates
            .filter { $0.kind == .bitchat && !occupied.contains($0.id) && $0.rssi >= policy.minRSSI
                      && now.timeIntervalSince($0.lastSeen) <= policy.staleAfter
                      && !recentlyFailed($0.id, failures, policy, now) }
            .sorted { $0.rssi > $1.rssi }
        var free = policy.maxConnections - reserved - occupied.count
        var poolIter = pool.makeIterator()
        while free > 0, let next = poolIter.next() {
            plan.connect.append(next.id); occupied.insert(next.id); free -= 1
        }
        // 4. Hysteresis swap: a much stronger peer may replace a weak, long-lived bitchat link.
        if free <= 0, let best = poolIter.next() {
            let swappable = connected.compactMap { (id, since) -> RadioCandidate? in
                guard let c = byID[id], c.kind == .bitchat, !plan.disconnect.contains(id),
                      now.timeIntervalSince(since) >= policy.minDwell else { return nil }
                return c
            }.min(by: { $0.rssi < $1.rssi })
            if let weak = swappable, best.rssi - weak.rssi >= policy.switchMarginDB {
                plan.disconnect.append(weak.id)
                plan.connect.append(best.id)
            }
        }
        return plan
    }

    private static func recentlyFailed(_ id: String, _ f: [String: Date], _ p: ConnectionPolicy, _ now: Date) -> Bool {
        guard let t = f[id] else { return false }
        return now.timeIntervalSince(t) < p.failureBackoff
    }
}
