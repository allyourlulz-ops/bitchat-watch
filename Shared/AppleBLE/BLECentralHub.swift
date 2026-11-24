//
// BLECentralHub.swift — bitchat-watch
//
// One CBCentralManager for every BLE network. It scans for the bitchat,
// Meshtastic and MeshCore service UUIDs, keeps a candidate list, and every few
// seconds asks ConnectionPlanner which peripherals may hold the (watchOS: 2)
// connection slots. Connected peripherals are handed to the link handler for
// their kind (BitchatTransport / MeshtasticTransport / MeshCoreTransport),
// which becomes the CBPeripheral delegate.
//
// The manager runs on the main queue: traffic is tiny and this keeps every
// model mutation on the main actor. Delegate methods are `nonisolated` and use
// MainActor.assumeIsolated (valid because the queue is main).
//
// watchOS notes: Core Bluetooth on watchOS is central-only; the system limits
// concurrent peripheral connections (2) and suspends/disconnects when the app
// is not running. CBCentralManager state restoration is iOS-only, so it is not
// used here.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

#if canImport(CoreBluetooth)
import CoreBluetooth
import Foundation

@MainActor
protocol BLELinkHandler: AnyObject, CBPeripheralDelegate {
    var radioKind: RadioKind { get }
    func linkConnected(_ peripheral: CBPeripheral)
    func linkDisconnected(_ peripheral: CBPeripheral)
}

enum BLEServiceIDs {
    /// bitchat mainnet service UUID (upstream BLEService, release builds). Debug builds of
    /// upstream use ...4B5A ("testnet"); set BITCHAT_TESTNET to match a Debug phone build.
    #if BITCHAT_TESTNET
    static let bitchat = CBUUID(string: "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5A")
    #else
    static let bitchat = CBUUID(string: "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
    #endif
    static let bitchatCharacteristic = CBUUID(string: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
    static let meshtastic = CBUUID(string: MeshtasticBLE.service)
    static let meshcore = CBUUID(string: MeshCoreBLE.service)

    static func kind(for advertised: [CBUUID]) -> RadioKind? {
        if advertised.contains(bitchat) { return .bitchat }
        if advertised.contains(meshtastic) { return .meshtastic }
        if advertised.contains(meshcore) { return .meshcore }
        return nil
    }
}

@MainActor
final class BLECentralHub: NSObject {
    private(set) var central: CBCentralManager!
    private var handlers: [RadioKind: BLELinkHandler] = [:]
    private(set) var candidates: [String: RadioCandidate] = [:]
    private var peripherals: [String: CBPeripheral] = [:]
    private(set) var connectedSince: [String: Date] = [:]
    private var connecting: [String: Date] = [:]
    private var failures: [String: Date] = [:]
    private var timer: Timer?
    var policy = ConnectionPolicy() { didSet { replan() } }
    var onChange: () -> Void = {}
    private(set) var bluetoothState: CBManagerState = .unknown
    /// Scan for LoRa radios even when none is chosen (Radios screen "find a radio").
    var discoverRadios = false { didSet { restartScan() } }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    func register(_ handler: BLELinkHandler) { handlers[handler.radioKind] = handler }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.replan() }
        }
        restartScan()
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if central.state == .poweredOn { central.stopScan() }
        for p in peripherals.values where p.state != .disconnected { central.cancelPeripheralConnection(p) }
    }

    func disconnect(id: String) {
        if let p = peripherals[id] { central.cancelPeripheralConnection(p) }
    }

    var connectedCount: Int { connectedSince.count }

    func candidates(of kind: RadioKind) -> [RadioCandidate] {
        candidates.values.filter { $0.kind == kind }.sorted { $0.rssi > $1.rssi }
    }

    func isConnected(_ id: String) -> Bool { connectedSince[id] != nil }

    // MARK: scanning / planning

    private func restartScan() {
        guard central.state == .poweredOn else { return }
        var services: [CBUUID] = []
        if policy.directBitchatEnabled { services.append(BLEServiceIDs.bitchat) }
        if policy.preferredRadioID != nil || discoverRadios {
            services.append(BLEServiceIDs.meshtastic); services.append(BLEServiceIDs.meshcore)
        }
        central.stopScan()
        guard !services.isEmpty else { return }
        // Duplicates keep RSSI fresh for slot decisions; acceptable while the app is
        // in the foreground (watchOS throttles/coalesces discovery in background anyway).
        central.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func replan() {
        guard central.state == .poweredOn else { return }
        let now = Date()
        // connection attempts that hang are cancelled after 10 s
        for (id, started) in connecting where now.timeIntervalSince(started) > 10 {
            connecting.removeValue(forKey: id)
            failures[id] = now
            if let p = peripherals[id] { central.cancelPeripheralConnection(p) }
        }
        let plan = ConnectionPlanner.plan(policy: policy, candidates: Array(candidates.values),
                                          connected: connectedSince, connecting: Set(connecting.keys),
                                          failures: failures, now: now)
        for id in plan.disconnect { if let p = peripherals[id] { central.cancelPeripheralConnection(p) } }
        for id in plan.connect {
            guard let p = peripherals[id] else { continue }
            connecting[id] = now
            central.connect(p, options: nil)
        }
        // forget stale candidates (not for connected ones)
        candidates = candidates.filter { connectedSince[$0.key] != nil || now.timeIntervalSince($0.value.lastSeen) < 60 }
        if !plan.connect.isEmpty || !plan.disconnect.isEmpty { onChange() }
    }
}

extension BLECentralHub: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            bluetoothState = central.state
            if central.state == .poweredOn { restartScan() } else {
                for (id, _) in connectedSince { if let p = peripherals[id], let h = handlers[candidates[id]?.kind ?? .bitchat] { h.linkDisconnected(p) } }
                connectedSince.removeAll(); connecting.removeAll()
            }
            onChange()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
            let overflow = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
            guard let kind = BLEServiceIDs.kind(for: services + overflow) else { return }
            let id = peripheral.identifier.uuidString
            let rssi = RSSI.intValue == 127 ? -100 : RSSI.intValue
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? kind.rawValue
            let isNew = candidates[id] == nil
            candidates[id] = RadioCandidate(id: id, kind: kind, name: name, rssi: rssi, lastSeen: Date())
            peripherals[id] = peripheral
            if isNew { onChange(); replan() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier.uuidString
            connecting.removeValue(forKey: id)
            connectedSince[id] = Date()
            guard let kind = candidates[id]?.kind, let h = handlers[kind] else {
                central.cancelPeripheralConnection(peripheral); return
            }
            peripheral.delegate = h
            h.linkConnected(peripheral)
            onChange()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier.uuidString
            connecting.removeValue(forKey: id)
            failures[id] = Date()
            onChange()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            let id = peripheral.identifier.uuidString
            connectedSince.removeValue(forKey: id)
            connecting.removeValue(forKey: id)
            if error != nil { failures[id] = Date() }
            if let kind = candidates[id]?.kind { handlers[kind]?.linkDisconnected(peripheral) }
            onChange()
            replan()
        }
    }
}
#endif
