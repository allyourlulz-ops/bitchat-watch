//
// BLEController.swift — bitchat Mac tester (AppKit/CoreBluetooth, macOS 10.14+, Swift 5.0)
//
// Both BLE roles at once, so the tester can stand in for a phone:
//   * Peripheral (CBPeripheralManager): advertises the bitchat service with one
//     characteristic (read / write / write-without-response / notify), exactly
//     like upstream BLEService. The central-only watch connects here.
//   * Central (CBCentralManager): scans for the bitchat service and connects to
//     phones / other testers, subscribes to notifications and writes frames.
// Raw chunks go into BTMeshNode.receiveChunk; frames the node emits are split
// with BTWriteChunker and written / notified per link (see BTLinkTable).
// Relay between the two sides is BTMeshNode.relayEnabled (off by default).
//
// UUIDs copied from Shared/AppleBLE/BLECentralHub.swift (BLEServiceIDs), which
// mirror upstream bitchat BLEService (release = ...4B5C, Debug/testnet = ...4B5A).
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import CoreBluetooth

enum TesterBLEIDs {
    static let mainnetService = CBUUID(string: "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C")
    static let testnetService = CBUUID(string: "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5A")
    static let characteristic = CBUUID(string: "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D")
}

final class BLEController: NSObject {
    let node: BTMeshNode
    let links = BTLinkTable()
    var serviceUUID: CBUUID
    var maxCentralLinks = 4

    var onStatus: (String) -> Void = { _ in }
    var onLinksChanged: () -> Void = {}

    private var peripheralManager: CBPeripheralManager!
    private var centralManager: CBCentralManager!
    private var characteristic: CBMutableCharacteristic?
    private var subscribed = [String: CBCentral]()             // "p:" links
    private var connected = [String: CBPeripheral]()           // "c:" links
    private var remoteChars = [String: CBCharacteristic]()
    private var notifyQueue = [(data: Data, centrals: [CBCentral])]()
    private var running = false

    init(node: BTMeshNode, testnet: Bool) {
        self.node = node
        self.serviceUUID = testnet ? TesterBLEIDs.testnetService : TesterBLEIDs.mainnetService
        super.init()
        peripheralManager = CBPeripheralManager(delegate: self, queue: DispatchQueue.main)
        centralManager = CBCentralManager(delegate: self, queue: DispatchQueue.main)
        node.sendFrame = { [weak self] frame, link, except in self?.send(frame, link: link, except: except) }
        node.linkLimit = { [weak self] link in return self?.links.limit(for: link) ?? BTLinkTable.defaultLimit }
    }

    func start() {
        running = true
        startPeripheral()
        startScan()
    }

    func stop() {
        running = false
        peripheralManager.stopAdvertising()
        peripheralManager.removeAllServices()
        centralManager.stopScan()
        for p in connected.values { centralManager.cancelPeripheralConnection(p) }
        for id in links.ids { linkGone(id) }
        characteristic = nil
        onStatus("BLE stopped")
    }

    // MARK: outbound

    private func send(_ frame: [UInt8], link: String?, except: String?) {
        for id in links.targets(link: link, except: except) {
            for piece in BTWriteChunker.chunks(frame, limit: links.limit(for: id)) {
                let d = Data(piece)
                if id.hasPrefix("p:") {
                    guard let c = subscribed[id], let ch = characteristic else { continue }
                    if !notifyQueue.isEmpty || !peripheralManager.updateValue(d, for: ch, onSubscribedCentrals: [c]) {
                        notifyQueue.append((d, [c]))
                    }
                } else if let p = connected[id], let ch = remoteChars[id] {
                    let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
                    p.writeValue(d, for: ch, type: type)
                }
            }
        }
    }

    private func flushNotifyQueue() {
        guard let ch = characteristic else { notifyQueue.removeAll(); return }
        while let next = notifyQueue.first {
            if !peripheralManager.updateValue(next.data, for: ch, onSubscribedCentrals: next.centrals) { return }
            notifyQueue.removeFirst()
        }
    }

    // MARK: links

    private func linkUp(_ id: String, limit: Int) {
        guard !links.contains(id) else { return }
        links.add(id, writeLimit: limit)
        node.linkUp(id)
        onStatus("link up \(id) (write limit \(links.limit(for: id)))")
        onLinksChanged()
    }

    private func linkGone(_ id: String) {
        guard links.remove(id) else { return }
        subscribed[id] = nil
        connected[id] = nil
        remoteChars[id] = nil
        node.linkDown(id)
        onStatus("link down \(id)")
        onLinksChanged()
    }

    // MARK: peripheral role

    private func startPeripheral() {
        guard running, peripheralManager.state == .poweredOn, characteristic == nil else { return }
        let ch = CBMutableCharacteristic(type: TesterBLEIDs.characteristic,
                                         properties: [.read, .write, .writeWithoutResponse, .notify],
                                         value: nil, permissions: [.readable, .writeable])
        let svc = CBMutableService(type: serviceUUID, primary: true)
        svc.characteristics = [ch]
        characteristic = ch
        peripheralManager.add(svc)
    }

    // MARK: central role

    private func startScan() {
        guard running, centralManager.state == .poweredOn else { return }
        centralManager.scanForPeripherals(withServices: [serviceUUID],
                                          options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        onStatus("scanning for \(serviceUUID.uuidString)")
    }
}

extension BLEController: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        onStatus("peripheral state \(peripheral.state.rawValue)")
        if peripheral.state == .poweredOn { startPeripheral() } else { characteristic = nil }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let e = error { onStatus("add service failed: \(e.localizedDescription)"); return }
        // Name kept short: the 31-byte legacy advertisement also carries the 128-bit service UUID.
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
                                     CBAdvertisementDataLocalNameKey: "bc-tester"])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        onStatus(error == nil ? "advertising bitchat service" : "advertising failed: \(error!.localizedDescription)")
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        let id = "p:" + central.identifier.uuidString
        subscribed[id] = central
        linkUp(id, limit: central.maximumUpdateValueLength)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        linkGone("p:" + central.identifier.uuidString)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests {
            let id = "p:" + r.central.identifier.uuidString
            if !links.contains(id) {
                // A central may write before subscribing; track it so replies can be notified once it subscribes.
                subscribed[id] = r.central
                linkUp(id, limit: r.central.maximumUpdateValueLength)
            }
            if let v = r.value { node.receiveChunk([UInt8](v), from: id) }
        }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        request.value = Data()
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        flushNotifyQueue()
    }
}

extension BLEController: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onStatus("central state \(central.state.rawValue)")
        if central.state == .poweredOn { startScan() }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = "c:" + peripheral.identifier.uuidString
        guard connected[id] == nil, connected.count < maxCentralLinks, RSSI.intValue > -95 else { return }
        connected[id] = peripheral
        peripheral.delegate = self
        onStatus("connecting \(peripheral.name ?? "?") rssi \(RSSI)")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connected["c:" + peripheral.identifier.uuidString] = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = "c:" + peripheral.identifier.uuidString
        connected[id] = nil
        linkGone(id)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            centralManager.cancelPeripheralConnection(peripheral); return
        }
        peripheral.discoverCharacteristics([TesterBLEIDs.characteristic], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let ch = service.characteristics?.first(where: { $0.uuid == TesterBLEIDs.characteristic }) else {
            centralManager.cancelPeripheralConnection(peripheral); return
        }
        remoteChars["c:" + peripheral.identifier.uuidString] = ch
        peripheral.setNotifyValue(true, for: ch)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.isNotifying else { return }
        linkUp("c:" + peripheral.identifier.uuidString, limit: peripheral.maximumWriteValueLength(for: .withoutResponse))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let v = characteristic.value else { return }
        node.receiveChunk([UInt8](v), from: "c:" + peripheral.identifier.uuidString)
    }
}
