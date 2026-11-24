//
// ChannelSupport.swift — bitchat-watch
// Small helpers shared by the channel core and the bitchat leaf engine
// (kept dependency-free so the iPhone bridge package can compile it alone).
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

func unixMillis(_ d: Date) -> UInt64 { UInt64(max(0, d.timeIntervalSince1970) * 1000) }

/// FIFO-bounded set for dedup.
struct BoundedSeenSet {
    private var set = Set<String>()
    private var order: [String] = []
    let capacity: Int
    init(capacity: Int) { self.capacity = capacity }
    func contains(_ s: String) -> Bool { set.contains(s) }
    mutating func insert(_ s: String) {
        guard set.insert(s).inserted else { return }
        order.append(s)
        if order.count > capacity {
            let drop = order.count - capacity
            for old in order.prefix(drop) { set.remove(old) }
            order.removeFirst(drop)
        }
    }
}
