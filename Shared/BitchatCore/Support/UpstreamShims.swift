//
// UpstreamShims.swift — bitchat-watch
//
// Minimal stand-ins for upstream bitchat dependencies (BitLogger.SecureLogger,
// BitFoundation.KeychainManagerProtocol, TransportConfig) so the vendored
// protocol/Noise files in ../Upstream and ../Noise compile unchanged inside the
// watch app target, the iOS bridge, and the Linux typecheck harness.
//
// SPDX-License-Identifier: GPL-3.0-or-later (this file); the vendored files keep
// their original Unlicense headers.
//

import Foundation
#if canImport(os)
import os
#endif

/// Log categories used by the vendored files.
enum LogCategory: String {
    case session, security, encryption, noise, general
}

/// Structured security events used by vendored NoiseSession / NoiseEncryptionService.
enum SecurityEvent {
    case handshakeStarted(peerID: String)
    case handshakeCompleted(peerID: String)
    case handshakeFailed(peerID: String, error: String)
    case sessionExpired(peerID: String)
    case authenticationFailed(peerID: String)

    var message: String {
        switch self {
        case .handshakeStarted(let p): return "Noise handshake started with \(p.prefix(8))…"
        case .handshakeCompleted(let p): return "Noise handshake completed with \(p.prefix(8))…"
        case .handshakeFailed(let p, let e): return "Noise handshake failed with \(p.prefix(8))…: \(e)"
        case .sessionExpired(let p): return "Noise session expired for \(p.prefix(8))…"
        case .authenticationFailed(let p): return "Authentication failed for \(p.prefix(8))…"
        }
    }
}

/// Tiny logger compatible with the call shapes used by the vendored files.
/// Never logs message contents or key material (the vendored callers don't pass any).
enum SecureLogger {
    nonisolated(unsafe) static var sink: ((String) -> Void)? = nil
    #if DEBUG
    nonisolated(unsafe) static var minimumLevel = 0
    #else
    nonisolated(unsafe) static var minimumLevel = 2
    #endif

    private static func emit(_ level: Int, _ tag: String, _ text: @autoclosure () -> String, _ category: LogCategory) {
        guard level >= minimumLevel else { return }
        let line = "[\(tag)][\(category.rawValue)] \(text())"
        if let sink = sink { sink(line); return }
        #if canImport(os)
        os_log("%{public}@", line)
        #else
        print(line)
        #endif
    }

    static func debug(_ text: @autoclosure () -> String, category: LogCategory = .general) { emit(0, "D", text(), category) }
    static func info(_ text: @autoclosure () -> String, category: LogCategory = .general) { emit(1, "I", text(), category) }
    static func warning(_ text: @autoclosure () -> String, category: LogCategory = .general) { emit(2, "W", text(), category) }
    static func error(_ text: @autoclosure () -> String, category: LogCategory = .general) { emit(3, "E", text(), category) }

    static func debug(_ event: SecurityEvent) { emit(0, "D", event.message, .security) }
    static func info(_ event: SecurityEvent) { emit(1, "I", event.message, .security) }
    static func warning(_ event: SecurityEvent) { emit(2, "W", event.message, .security) }
    static func error(_ event: SecurityEvent) { emit(3, "E", event.message, .security) }
}

/// Subset of BitFoundation.KeychainManagerProtocol needed by NoiseProtocol/NoiseSession.
protocol KeychainManagerProtocol: AnyObject {
    func secureClear(_ data: inout Data)
}

/// Default zeroizer (best effort: Swift CoW means older copies may survive).
final class MemoryZeroizer: KeychainManagerProtocol, @unchecked Sendable {
    static let shared = MemoryZeroizer()
    func secureClear(_ data: inout Data) {
        guard !data.isEmpty else { return }
        data.resetBytes(in: 0..<data.count)
        data = Data()
    }
}

/// Constants mirrored from upstream bitchat Services/TransportConfig.swift @ 04995f68.
enum TransportConfig {
    static let bleDefaultFragmentSize: Int = 469
    static let messageTTLDefault: UInt8 = 7
    static let bleNotificationAssemblerHardCapBytes: Int = 8 * 1024 * 1024
    static let bleAssemblerStallResetMs: Int = 250
    static let bleFragmentLifetimeSeconds: TimeInterval = 30.0
    static let bleFragmentSpacingMs: Int = 30
    static let bleFragmentSpacingDirectedMs: Int = 25
    /// Upstream accepts public messages up to the gossip-sync window; we use the
    /// announce freshness window (900 s) for announces and this for messages.
    static let syncPublicMessageMaxAgeSeconds: TimeInterval = 6 * 60 * 60
}
