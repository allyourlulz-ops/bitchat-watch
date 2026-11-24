//
// KeychainStore.swift — bitchat-watch
// Persists the watch's bitchat identity (Noise static + Ed25519 seeds) in the
// Keychain, this-device-only. Settings go in UserDefaults.
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Security
import CryptoKit

enum KeychainStore {
    private static let service = "chat.bitchat.watch.identity"

    static func loadOrCreateIdentity() -> BitchatIdentity {
        if let n = read("noiseStatic"), let s = read("signing"),
           let nk = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: n),
           let sk = try? Curve25519.Signing.PrivateKey(rawRepresentation: s) {
            return BitchatIdentity(noiseStatic: nk, signing: sk)
        }
        let id = BitchatIdentity.generate()
        write("noiseStatic", id.noiseStatic.rawRepresentation)
        write("signing", id.signing.rawRepresentation)
        return id
    }

    /// "Panic" wipe: new identity next launch.
    static func wipeIdentity() {
        for k in ["noiseStatic", "signing"] {
            SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: k] as CFDictionary)
        }
    }

    private static func read(_ account: String) -> Data? {
        var out: CFTypeRef?
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                  kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private static func write(_ account: String, _ data: Data) {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Small typed wrapper over UserDefaults.
struct WatchSettings {
    private let d = UserDefaults.standard
    var nickname: String {
        get { d.string(forKey: "nickname") ?? "" }
        nonmutating set { d.set(newValue, forKey: "nickname") }
    }
    var preferredRadioID: String? {
        get { d.string(forKey: "preferredRadioID") }
        nonmutating set { d.set(newValue, forKey: "preferredRadioID") }
    }
    var preferredRadioName: String {
        get { d.string(forKey: "preferredRadioName") ?? "" }
        nonmutating set { d.set(newValue, forKey: "preferredRadioName") }
    }
    var directBitchat: Bool {
        get { d.object(forKey: "directBitchat") as? Bool ?? true }
        nonmutating set { d.set(newValue, forKey: "directBitchat") }
    }
    var notifications: Bool {
        get { d.object(forKey: "notifications") as? Bool ?? true }
        nonmutating set { d.set(newValue, forKey: "notifications") }
    }
    var favorites: Set<String> {
        get { Set(d.stringArray(forKey: "favorites") ?? []) }
        nonmutating set { d.set(Array(newValue), forKey: "favorites") }
    }
}
